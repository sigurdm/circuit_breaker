import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/hedging.dart';

void main() {
  group('Bug H4: Hung losing hedge concurrency slot reclamation', () {
    test(
      'losing hedges that ignore cancellation reclaim concurrency slots after gracePeriod',
      () async {
        final config = ResourceConfig(
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 10),
            maxConcurrentHedges: 2,
            gracePeriod: const Duration(milliseconds: 40),
            maxOverloadTokens: 10.0,
            overloadPercentile: 0.0, // refill on every request
          ),
        );
        final state = ResourceState(config);

        // Keep hold of the hung hedge completers so they never complete on their own
        final hungCompleters = <Completer<String>>[];

        // Run 2 operations where primary request completes at 25ms (after 10ms hedge delay),
        // but hedge hangs indefinitely and ignores cancellation.
        for (int i = 0; i < 2; i++) {
          int attempts = 0;
          final result = await executeWithHedging<String>(
            (cancelSignal) async {
              attempts++;
              if (attempts == 1) {
                // Primary attempt: wait 25ms (> 10ms hedge delay) then succeed
                await Future.delayed(const Duration(milliseconds: 25));
                return 'primary_$i';
              } else {
                // Hedge attempt: ignores cancelSignal and hangs indefinitely
                final c = Completer<String>();
                hungCompleters.add(c);
                return await c.future;
              }
            },
            config: config,
            state: state,
          );

          expect(result, equals('primary_$i'));
          expect(attempts, equals(2));
        }

        // Both operations returned, but both hedges are hung in background.
        // Immediately after returning, activeHedges is at the cap (2).
        expect(state.activeHedges, equals(2));

        // Now, before gracePeriod expires, verify hedge limit is reached:
        // A 3rd request starting right now would not be admitted for hedging.
        int call3Attempts = 0;
        final result3Fast = await executeWithHedging<String>(
          (cancelSignal) async {
            call3Attempts++;
            await Future.delayed(const Duration(milliseconds: 15));
            return 'primary_blocked';
          },
          config: config,
          state: state,
        );
        expect(result3Fast, equals('primary_blocked'));
        // Because activeHedges was 2, tryStartHedge() was rejected; only 1 attempt ran
        expect(call3Attempts, equals(1));

        // Wait for the gracePeriod (40ms) to elapse + safety margin
        await Future.delayed(const Duration(milliseconds: 60));

        // Concurrency slots must have been reclaimed!
        expect(
          state.activeHedges,
          equals(0),
          reason:
              'Hung losing hedges must release activeHedges slots after gracePeriod',
        );

        // Subsequent requests must now successfully admit hedges again!
        int call4Attempts = 0;
        final result4 = await executeWithHedging<String>(
          (cancelSignal) async {
            call4Attempts++;
            if (call4Attempts == 1) {
              // Primary takes long
              await Future.delayed(const Duration(milliseconds: 50));
              return 'primary_slow';
            } else {
              // Hedge finishes fast
              await Future.delayed(const Duration(milliseconds: 5));
              return 'hedge_admitted';
            }
          },
          config: config,
          state: state,
        );

        expect(result4, equals('hedge_admitted'));
        expect(
          call4Attempts,
          equals(2),
          reason: 'Hedge was admitted after slot reclamation',
        );
        expect(state.activeHedges, equals(0));

        // Clean up hung completers to prevent leaks
        for (final c in hungCompleters) {
          c.complete('cleanup');
        }
      },
    );

    test(
      'completing a hung hedge after gracePeriod does not double-decrement activeHedges',
      () async {
        final config = ResourceConfig(
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 10),
            maxConcurrentHedges: 2,
            gracePeriod: const Duration(milliseconds: 20),
          ),
        );
        final state = ResourceState(config);

        final hungCompleter = Completer<String>();
        int attempts = 0;

        final result = await executeWithHedging<String>(
          (cancelSignal) async {
            attempts++;
            if (attempts == 1) {
              await Future.delayed(const Duration(milliseconds: 25));
              return 'primary_done';
            }
            return await hungCompleter.future;
          },
          config: config,
          state: state,
        );

        expect(result, equals('primary_done'));
        expect(state.activeHedges, equals(1));

        // Wait for gracePeriod to reclaim slot
        await Future.delayed(const Duration(milliseconds: 40));
        expect(state.activeHedges, equals(0));

        // Now complete the hung future after grace period
        hungCompleter.complete('late_response');
        await Future.delayed(const Duration(milliseconds: 10));

        // activeHedges must remain 0 and not become negative or corrupt future counts
        expect(state.activeHedges, equals(0));
      },
    );

    test(
      'gracePeriod = Duration.zero reclaims slot immediately when primary completes',
      () async {
        final config = ResourceConfig(
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 10),
            maxConcurrentHedges: 1,
            gracePeriod: Duration.zero,
          ),
        );
        final state = ResourceState(config);

        final hung = Completer<String>();
        int attempts = 0;

        final result = await executeWithHedging<String>(
          (cancelSignal) async {
            attempts++;
            if (attempts == 1) {
              await Future.delayed(const Duration(milliseconds: 20));
              return 'primary_win';
            }
            return await hung.future;
          },
          config: config,
          state: state,
        );

        expect(result, equals('primary_win'));
        // With gracePeriod: Duration.zero, activeHedges is reclaimed immediately
        expect(state.activeHedges, equals(0));

        hung.complete('done');
      },
    );

    test(
      'reclaims slot using ResourceConfig.timeout when gracePeriod is null',
      () async {
        final config = ResourceConfig(
          timeout: const Duration(milliseconds: 60),
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 10),
            maxConcurrentHedges: 1,
            // gracePeriod is null -> uses timeout
          ),
        );
        final state = ResourceState(config);

        final hung = Completer<String>();
        int attempts = 0;

        final result = await executeWithHedging<String>(
          (cancelSignal) async {
            attempts++;
            if (attempts == 1) {
              await Future.delayed(const Duration(milliseconds: 20));
              return 'primary_win';
            }
            return await hung.future;
          },
          config: config,
          state: state,
        );

        expect(result, equals('primary_win'));
        // Immediately after primary returns, timeout hasn't elapsed yet
        expect(state.activeHedges, equals(1));

        // Wait for remaining timeout (60ms - 20ms = 40ms) + safety buffer
        await Future.delayed(const Duration(milliseconds: 60));
        expect(state.activeHedges, equals(0));

        hung.complete('done');
      },
    );

    test(
      'ResilienceContext reclaims activeHedges for hung hedges and admits subsequent hedges',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'context-hedge-reclaim',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 10),
              maxConcurrentHedges: 1,
              gracePeriod: const Duration(milliseconds: 30),
              maxOverloadTokens: 10.0,
              overloadPercentile: 0.0,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(k: 100.0, minRequests: 100),
          ),
        );
        final op = Operation('op', resource);

        final hung = Completer<String>();
        int attempts = 0;

        final res1 = await context.executeCancelable<String>(op, (
          cancel,
        ) async {
          attempts++;
          if (attempts == 1) {
            await Future.delayed(const Duration(milliseconds: 25));
            return 'req1_primary';
          }
          return await hung.future;
        });

        expect(res1, equals('req1_primary'));
        expect(attempts, equals(2));

        final state = context.states['context-hedge-reclaim']!;
        expect(state.activeHedges, equals(1));

        // Wait for grace period
        await Future.delayed(const Duration(milliseconds: 50));
        expect(state.activeHedges, equals(0));

        // Subsequent call is admitted to hedge
        int attempts2 = 0;
        final res2 = await context.executeCancelable<String>(op, (
          cancel,
        ) async {
          attempts2++;
          if (attempts2 == 1) {
            await Future.delayed(const Duration(milliseconds: 50));
            return 'req2_primary';
          }
          await Future.delayed(const Duration(milliseconds: 5));
          return 'req2_hedge';
        });

        expect(res2, equals('req2_hedge'));
        expect(attempts2, equals(2));
        expect(state.activeHedges, equals(0));

        hung.complete('done');
      },
    );

    test(
      'RequestHedger.standalone and hedge() reclaim activeHedges on hung hedges',
      () async {
        final hedger = RequestHedger.standalone(
          delay: const Duration(milliseconds: 10),
          gracePeriod: const Duration(milliseconds: 30),
        );

        final hung = Completer<String>();
        int attempts = 0;

        final res = await hedger.executeCancelable<String>((cancel) async {
          attempts++;
          if (attempts == 1) {
            await Future.delayed(const Duration(milliseconds: 25));
            return 'standalone_primary';
          }
          return await hung.future;
        });

        expect(res, equals('standalone_primary'));
        expect(attempts, equals(2));
        expect(hedger.state.activeHedges, equals(1));

        await Future.delayed(const Duration(milliseconds: 45));
        expect(hedger.state.activeHedges, equals(0));

        hung.complete('done');
      },
    );

    test(
      'RequestHedger.standalone overrides gracePeriod on enabled config',
      () {
        final hedger = RequestHedger.standalone(
          config: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 100),
          ),
          gracePeriod: const Duration(milliseconds: 50),
        );
        expect(
          hedger.config.hedging.gracePeriod,
          equals(const Duration(milliseconds: 50)),
        );
        expect(hedger.config.hedging.enabled, isTrue);
      },
    );
  });
}
