import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/hedging.dart';

void main() {
  group('Bug H4: Hung losing hedge concurrency slot reclamation', () {
    test(
      'losing hedges that ignore cancellation reclaim concurrency slots after gracePeriod',
      () {
        fakeAsync((async) {
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
          // Call 0: t=0ms to t=25ms. Grace period expires at t=65ms.
          // Call 1: t=25ms to t=50ms. Grace period expires at t=90ms.
          for (int i = 0; i < 2; i++) {
            int attempts = 0;
            String? result;
            executeWithHedging<String>(
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
            ).then((v) => result = v);

            async.elapse(const Duration(milliseconds: 25));
            expect(result, equals('primary_$i'));
            expect(attempts, equals(2));
          }

          // Both operations returned, both hedges are hung in background.
          // Immediately after returning at t=50ms, activeHedges is at the cap (2).
          expect(state.activeHedges, equals(2));

          // Now, before gracePeriod expires, verify hedge limit is reached:
          // A 3rd request starting right now (t=50ms) would not be admitted for hedging.
          int call3Attempts = 0;
          String? result3Fast;
          executeWithHedging<String>(
            (cancelSignal) async {
              call3Attempts++;
              await Future.delayed(const Duration(milliseconds: 10));
              return 'primary_blocked';
            },
            config: config,
            state: state,
          ).then((v) => result3Fast = v);

          // Advance 10ms to t=60ms: primary completes, no hedge was started because activeHedges was 2.
          async.elapse(const Duration(milliseconds: 10));
          expect(result3Fast, equals('primary_blocked'));
          expect(call3Attempts, equals(1));

          // At t=60ms, both Call 0 (expires t=65ms) and Call 1 (expires t=90ms) still hold slots:
          expect(state.activeHedges, equals(2));

          // Advance 4ms to t=64ms (just before Call 0 gracePeriod expires at 65ms):
          async.elapse(const Duration(milliseconds: 4));
          expect(state.activeHedges, equals(2));

          // Advance 1ms to t=65ms: Call 0 gracePeriod expires, slot 1 reclaimed!
          async.elapse(const Duration(milliseconds: 1));
          expect(state.activeHedges, equals(1));

          // Advance 24ms to t=89ms (just before Call 1 gracePeriod expires at 90ms):
          async.elapse(const Duration(milliseconds: 24));
          expect(state.activeHedges, equals(1));

          // Advance 1ms to t=90ms: Call 1 gracePeriod expires, slot 2 reclaimed!
          async.elapse(const Duration(milliseconds: 1));
          expect(
            state.activeHedges,
            equals(0),
            reason:
                'Hung losing hedges must release activeHedges slots after gracePeriod',
          );

          // Subsequent requests must now successfully admit hedges again!
          int call4Attempts = 0;
          String? result4;
          executeWithHedging<String>(
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
          ).then((v) => result4 = v);

          // Advance 10ms (hedge starts) + 5ms (hedge completes)
          async.elapse(const Duration(milliseconds: 15));

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
        });
      },
    );

    test(
      'completing a hung hedge after gracePeriod does not double-decrement activeHedges',
      () {
        fakeAsync((async) {
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
          String? result;

          executeWithHedging<String>(
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
          ).then((v) => result = v);

          async.elapse(const Duration(milliseconds: 25));
          expect(result, equals('primary_done'));
          expect(state.activeHedges, equals(1));

          // Wait for gracePeriod to reclaim slot
          async.elapse(const Duration(milliseconds: 20));
          expect(state.activeHedges, equals(0));

          // Now complete the hung future after grace period
          hungCompleter.complete('late_response');
          async.flushMicrotasks();

          // activeHedges must remain 0 and not become negative or corrupt future counts
          expect(state.activeHedges, equals(0));
        });
      },
    );

    test(
      'gracePeriod = Duration.zero reclaims slot immediately when primary completes',
      () {
        fakeAsync((async) {
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
          String? result;

          executeWithHedging<String>(
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
          ).then((v) => result = v);

          async.elapse(const Duration(milliseconds: 20));
          expect(result, equals('primary_win'));
          // With gracePeriod: Duration.zero, activeHedges is reclaimed immediately
          expect(state.activeHedges, equals(0));

          hung.complete('done');
        });
      },
    );

    test(
      'reclaims slot using ResourceConfig.timeout when gracePeriod is null',
      () {
        fakeAsync((async) {
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
          String? result;

          executeWithHedging<String>(
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
          ).then((v) => result = v);

          async.elapse(const Duration(milliseconds: 20));
          expect(result, equals('primary_win'));
          // Immediately after primary returns, timeout hasn't elapsed yet
          expect(state.activeHedges, equals(1));

          // Wait for remaining timeout
          async.elapse(const Duration(milliseconds: 60));
          expect(state.activeHedges, equals(0));

          hung.complete('done');
        });
      },
    );

    test(
      'ResilienceContext reclaims activeHedges for hung hedges and admits subsequent hedges',
      () {
        fakeAsync((async) {
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
          String? res1;

          context
              .executeCancelable<String>(op, (cancel) async {
                attempts++;
                if (attempts == 1) {
                  await Future.delayed(const Duration(milliseconds: 25));
                  return 'req1_primary';
                }
                return await hung.future;
              })
              .then((v) => res1 = v);

          async.elapse(const Duration(milliseconds: 25));
          expect(res1, equals('req1_primary'));
          expect(attempts, equals(2));

          final state = context.states['context-hedge-reclaim']!;
          expect(state.activeHedges, equals(1));

          // Wait for grace period
          async.elapse(const Duration(milliseconds: 30));
          expect(state.activeHedges, equals(0));

          // Subsequent call is admitted to hedge
          int attempts2 = 0;
          String? res2;
          context
              .executeCancelable<String>(op, (cancel) async {
                attempts2++;
                if (attempts2 == 1) {
                  await Future.delayed(const Duration(milliseconds: 50));
                  return 'req2_primary';
                }
                await Future.delayed(const Duration(milliseconds: 5));
                return 'req2_hedge';
              })
              .then((v) => res2 = v);

          async.elapse(const Duration(milliseconds: 15));
          expect(res2, equals('req2_hedge'));
          expect(attempts2, equals(2));
          expect(state.activeHedges, equals(0));

          hung.complete('done');
        });
      },
    );

    test(
      'RequestHedger.standalone and hedge() reclaim activeHedges on hung hedges',
      () {
        fakeAsync((async) {
          final hedger = RequestHedger.standalone(
            delay: const Duration(milliseconds: 10),
            gracePeriod: const Duration(milliseconds: 30),
          );

          final hung = Completer<String>();
          int attempts = 0;
          String? res;

          hedger
              .executeCancelable<String>((cancel) async {
                attempts++;
                if (attempts == 1) {
                  await Future.delayed(const Duration(milliseconds: 25));
                  return 'standalone_primary';
                }
                return await hung.future;
              })
              .then((v) => res = v);

          async.elapse(const Duration(milliseconds: 25));
          expect(res, equals('standalone_primary'));
          expect(attempts, equals(2));
          expect(hedger.state.activeHedges, equals(1));

          async.elapse(const Duration(milliseconds: 30));
          expect(hedger.state.activeHedges, equals(0));

          hung.complete('done');
        });
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
