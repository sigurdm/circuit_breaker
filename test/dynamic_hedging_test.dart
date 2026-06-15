import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/src/context.dart';

void main() {
  group('Dynamic Hedging', () {
    late ResilienceContext context;
    late Resource resource;
    late Operation op;

    setUp(() {
      context = ResilienceContext();
    });

    test(
      'when dynamicPercentile is null, static delay is used and no adaptation occurs',
      () async {
        resource = Resource(
          'static-hedging',
          config: const ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: Duration(milliseconds: 50),
              dynamicPercentile: null, // Static
            ),
          ),
        );
        op = Operation('call', resource);
        final state = context.states.putIfAbsent(
          resource.name,
          () => ResourceState(resource.config),
        );

        int attempts = 0;
        final result = await context.executeCancelable(op, (cancel) async {
          attempts++;
          if (attempts == 1) {
            await Future.delayed(
              const Duration(milliseconds: 80),
            ); // Longer than 50ms
            return 'slow';
          }
          return 'fast';
        });

        expect(result, 'fast');
        expect(attempts, 2);
        // Estimate should not change
        expect(state.dynamicDelayEstimate, const Duration(milliseconds: 50));
      },
    );

    test(
      'dynamic delay adapts to latency (slow request increases delay)',
      () async {
        resource = Resource(
          'dynamic-adaptation-slow',
          config: const ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: Duration(milliseconds: 50), // Initial V
              dynamicPercentile: 0.9,
              adaptationRate: 10.0,
              delayMultiplier: 2.0, // Hedging delay = 2 * V = 100ms
            ),
          ),
        );
        op = Operation('call', resource);
        final state = context.states.putIfAbsent(
          resource.name,
          () => ResourceState(resource.config),
        );

        expect(state.dynamicDelayEstimate, const Duration(milliseconds: 50));

        // 1. Send a slow request (takes 80ms, which is > rawV (50ms) but < hedging delay (100ms))
        // It should NOT hedge (since < 100ms) but it IS slow (> 50ms).
        // Early registration should trigger at 50ms and increase V.
        int attempts = 0;
        final result = await context.executeCancelable(op, (cancel) async {
          attempts++;
          await Future.delayed(const Duration(milliseconds: 80));
          return 'slow';
        });

        expect(result, 'slow');
        expect(attempts, 1); // No hedge

        // V should have increased: 50 * (1 + 0.9/10) = 50 * 1.09 = 54.5ms -> rounded to 55ms?
        // 50000 microseconds * 1.09 = 54500 microseconds = 54.5ms.
        // 54500 rounded is 54500.
        expect(state.dynamicDelayEstimate.inMicroseconds, 54500);
      },
    );

    test(
      'dynamic delay adapts to latency (fast request decreases delay)',
      () async {
        resource = Resource(
          'dynamic-adaptation-fast',
          config: const ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: Duration(milliseconds: 50), // Initial V
              dynamicPercentile: 0.9,
              adaptationRate: 10.0,
              minDelay: Duration(milliseconds: 10),
            ),
          ),
        );
        op = Operation('call', resource);
        final state = context.states.putIfAbsent(
          resource.name,
          () => ResourceState(resource.config),
        );

        // Send a fast request (takes 10ms, which is < rawV (50ms))
        // It should NOT hedge.
        // It should decrease V: 50 * (1 - 0.1/10) = 50 * 0.99 = 49.5ms -> 49500 microseconds.
        int attempts = 0;
        final result = await context.executeCancelable(op, (cancel) async {
          attempts++;
          await Future.delayed(const Duration(milliseconds: 10));
          return 'fast';
        });

        expect(result, 'fast');
        expect(attempts, 1);
        expect(state.dynamicDelayEstimate.inMicroseconds, 49500);
      },
    );

    test('token bucket limits the rate of hedges', () async {
      resource = Resource(
        'token-bucket-limit',
        config: const ResourceConfig(
          hedging: HedgingConfig(
            enabled: true,
            delay: Duration(milliseconds: 10), // Small delay to hedge easily
            dynamicPercentile: 0.9, // Dynamic
            maxOverloadTokens: 2.0,
            overloadPercentile: 0.5, // Refill 0.5 tokens per request
            delayMultiplier: 1.0, // Hedge at V (10ms)
          ),
        ),
      );
      op = Operation('call', resource);

      // Initial tokens = 2.0.
      // We will send 4 requests sequentially, all are slow (take 50ms).
      // Req 1: refill 0.5 -> 2.0. Hedge starts -> tokens = 1.0.
      // Req 2: refill 0.5 -> 1.5. Hedge starts -> tokens = 0.5.
      // Req 3: refill 0.5 -> 1.0. Hedge starts -> tokens = 0.0.
      // Req 4: refill 0.5 -> 0.5. Hedge BLOCKED (< 1.0).

      List<int> attemptsPerRequest = [];

      for (int i = 0; i < 4; i++) {
        int attempts = 0;
        await context.executeCancelable(op, (cancel) async {
          attempts++;
          if (attempts == 1) {
            await Future.delayed(const Duration(milliseconds: 30));
            return 'slow';
          }
          return 'fast';
        });
        attemptsPerRequest.add(attempts);
      }

      expect(attemptsPerRequest, [2, 2, 2, 1]);
    });

    test('concurrency limit prevents too many concurrent hedges', () async {
      resource = Resource(
        'concurrency-limit',
        config: const ResourceConfig(
          hedging: HedgingConfig(
            enabled: true,
            delay: Duration(milliseconds: 10),
            maxConcurrentHedges: 2,
            delayMultiplier: 1.0,
            maxOverloadTokens: 10.0, // Ensure token bucket doesn't limit us
            overloadPercentile:
                0.0, // Refill 1.0 tokens per request (never limit)
          ),
        ),
      );
      op = Operation('call', resource);

      // We will start 3 requests concurrently.
      // All should want to hedge after 10ms.
      // Only 2 hedges should be allowed.

      final completer1 = Completer<String>();
      final completer2 = Completer<String>();
      final completer3 = Completer<String>();
      final completers = [completer1, completer2, completer3];

      List<int> attempts = [0, 0, 0];

      Future<String> runReq(int index) {
        return context.executeCancelable(op, (cancel) async {
          attempts[index]++;
          final myAttempt = attempts[index];
          if (myAttempt == 1) {
            // Primary request waits for completer
            return await completers[index].future;
          }
          // Hedge request takes some time to release the slot
          await Future.delayed(const Duration(milliseconds: 50));
          return 'hedge-$index';
        });
      }

      // Start all 3
      final f1 = runReq(0);
      final f2 = runReq(1);
      final f3 = runReq(2);

      // Wait 100ms to ensure hedging delay (10ms) is passed and hedges have time to complete (50ms)
      await Future.delayed(const Duration(milliseconds: 100));

      // At this point, hedges should have tried to start.
      // Since limit is 2, one of them should have been blocked.
      // The blocked one will still be waiting for its primary completer.
      // The other two should have finished with 'hedge-X' because their hedges completed immediately.

      // We don't know which one was blocked, but 2 should be completed and 1 active.
      int completedCount = 0;
      int? blockedIndex;

      for (int i = 0; i < 3; i++) {
        final f = i == 0 ? f1 : (i == 1 ? f2 : f3);
        // We check if it is completed by using a timeout of 0
        bool isDone = false;
        await f
            .timeout(
              Duration.zero,
              onTimeout: () {
                isDone = false;
                blockedIndex = i;
                return 'timeout';
              },
            )
            .then((val) {
              if (val != 'timeout') {
                isDone = true;
              }
            });
        if (isDone) completedCount++;
      }

      expect(
        completedCount,
        2,
        reason: 'Exactly 2 requests should have completed via hedge',
      );
      expect(blockedIndex, isNotNull, reason: 'One request should be blocked');

      // Verify attempts
      // The completed ones should have 2 attempts (primary + hedge).
      // The blocked one should have only 1 attempt (primary) so far.
      for (int i = 0; i < 3; i++) {
        if (i == blockedIndex) {
          expect(
            attempts[i],
            1,
            reason: 'Blocked request should only have primary attempt',
          );
        } else {
          expect(
            attempts[i],
            2,
            reason: 'Completed request should have primary and hedge attempts',
          );
        }
      }

      // Clean up: complete the blocked one to let it finish
      completers[blockedIndex!].complete('manual-finish');
      await Future.wait([f1, f2, f3]);
    });

    test(
      'only one latency sample is registered per request (via early registration)',
      () async {
        resource = Resource(
          'single-sample-early',
          config: const ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: Duration(milliseconds: 50), // rawV
              dynamicPercentile: 0.9,
              adaptationRate: 10.0,
              delayMultiplier: 2.0, // hedging delay = 100ms
            ),
          ),
        );
        op = Operation('call', resource);
        final state = context.states.putIfAbsent(
          resource.name,
          () => ResourceState(resource.config),
        );

        // Send a request that takes 150ms.
        // Early registration triggers at 50ms -> updates V (50 -> 54.5).
        // Hedging triggers at 100ms -> starts hedge (if allowed, but here we don't care, it will start).
        // Primary finishes at 150ms.
        // If it only updated once (early), V should be 54.5ms (54500us).
        // If it updated again when primary finished, it would be 54.5 * 1.09 = 59.4ms.

        int attempts = 0;
        final result = await context.executeCancelable(op, (cancel) async {
          attempts++;
          if (attempts == 1) {
            await Future.delayed(const Duration(milliseconds: 150));
            return 'slow';
          }
          return 'fast'; // Hedge will return fast
        });

        expect(result, 'fast'); // Hedge should win
        expect(attempts, 2);

        // Verify it only updated once
        expect(state.dynamicDelayEstimate.inMicroseconds, 54500);
      },
    );

    test(
      'early registration updates tracker before request finishes',
      () async {
        resource = Resource(
          'early-reg-timing',
          config: const ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: Duration(milliseconds: 50), // rawV
              dynamicPercentile: 0.9,
              adaptationRate: 10.0,
              delayMultiplier: 2.0, // hedging delay = 100ms
            ),
          ),
        );
        op = Operation('call', resource);
        final state = context.states.putIfAbsent(
          resource.name,
          () => ResourceState(resource.config),
        );

        final completer = Completer<String>();
        final f = context.executeCancelable(op, (cancel) async {
          return await completer.future;
        });

        // Initially V is 50ms
        expect(state.dynamicDelayEstimate, const Duration(milliseconds: 50));

        // Wait 70ms (between rawV and hedging delay)
        await Future.delayed(const Duration(milliseconds: 70));

        // V should have already updated to 54.5ms
        expect(state.dynamicDelayEstimate.inMicroseconds, 54500);

        // Complete the request
        completer.complete('done');
        await f;
      },
    );
  });
}
