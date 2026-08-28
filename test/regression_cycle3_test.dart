import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Cycle 3 Regression Tests', () {
    test(
      'early backend failure does not poison dynamic hedging delay estimate',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'hedge-metric-poisoning',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 100),
              dynamicPercentile: 0.9,
              adaptationRate: 5.0,
              minDelay: const Duration(milliseconds: 20),
              maxDelay: const Duration(seconds: 1),
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(minRequests: 100),
          ),
        );
        final op = Operation('op', resource);

        // Run a probe to create state
        try {
          await context.execute(op, () async => 'init');
        } catch (_) {}
        final state = context.states['hedge-metric-poisoning']!;

        final initialEstimate = state.dynamicDelayEstimate;

        // Execute 5 fast failures (e.g. 500 error in 2ms)
        for (int i = 0; i < 5; i++) {
          try {
            await context.executeCancelable<String>(op, (cancel) async {
              await Future.delayed(const Duration(milliseconds: 2));
              throw Exception('backend 500 outage');
            });
          } catch (_) {}
        }

        // If metric poisoning was present, fast failures would have registered as isSlow: false
        // and depressed the dynamic delay estimate towards minDelay (20ms).
        // With the fix, failures are NEVER registered as fast latency samples.
        expect(state.dynamicDelayEstimate, equals(initialEstimate));
      },
    );

    test(
      'cancelled operation prevents phantom hedge spawn and cleans up timers',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'phantom-hedge',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 150),
              maxConcurrentHedges: 2,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(minRequests: 100),
            timeout: const Duration(milliseconds: 40),
          ),
        );
        final op = Operation('op', resource);

        int hedgeStarts = 0;
        int primaryStarts = 0;

        try {
          await context.executeCancelable<String>(op, (cancel) async {
            if (primaryStarts == 0) {
              primaryStarts++;
              // Primary is slow and will be timed out at 40ms
              await Future.delayed(const Duration(milliseconds: 250));
              return 'primary';
            } else {
              hedgeStarts++;
              return 'hedge';
            }
          });
        } catch (_) {}

        // Wait past the hedging delay (150ms) to ensure no phantom hedge was spawned
        await Future.delayed(const Duration(milliseconds: 180));

        final state = context.states['phantom-hedge']!;
        expect(primaryStarts, equals(1));
        expect(
          hedgeStarts,
          equals(0),
          reason:
              'Speculative hedge must not be spawned for a cancelled/timed-out call',
        );
        expect(state.activeHedges, equals(0));
      },
    );

    test('uncaught background async error does not crash isolate', () async {
      final context = ResilienceContext();
      final resource = Resource(
        'zone-isolation',
        config: ResourceConfig(
          timeout: const Duration(milliseconds: 30),
          retry: RetryConfig(maxAttempts: 1),
          throttling: ThrottlingConfig(minRequests: 100),
        ),
      );
      final op = Operation('op', resource);

      // Execute an uncancelable operation that times out, and in the background
      // an unhandled async error occurs in a timer callback.
      await expectLater(
        context.execute(op, () async {
          Timer(const Duration(milliseconds: 50), () {
            throw StateError('unhandled async error in background timer');
          });
          await Future.delayed(const Duration(milliseconds: 100));
          return 'done';
        }),
        throwsA(isA<ResilienceTimeoutException>()),
      );

      // Wait past the timer to ensure the unhandled error was safely contained by runZonedGuarded
      await Future.delayed(const Duration(milliseconds: 80));
    });

    test('CancellationToken detects transitive ancestor cycles', () {
      final tokenA = CancellationToken();
      final tokenB = CancellationToken();
      final tokenC = CancellationToken();

      tokenB.attach(tokenA); // B child of A
      tokenC.attach(tokenB); // C child of B

      // Attaching A to C would create a cycle: A -> B -> C -> A
      expect(() => tokenA.attach(tokenC), throwsArgumentError);
    });

    test(
      'RetryConfig handles sub-millisecond baseDelay with microsecond precision',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'sub-ms-retry',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: const Duration(microseconds: 500),
              backoffFactor: 2.0,
              enableJitter: false,
            ),
            throttling: ThrottlingConfig(minRequests: 100),
          ),
        );
        final op = Operation('op', resource);

        int attempts = 0;
        try {
          await context.execute(op, () async {
            attempts++;
            if (attempts < 3) throw Exception('transient');
            return 'done';
          });
        } catch (_) {}

        expect(attempts, equals(3));
      },
    );

    test('Resource and Operation reject whitespace-only names', () {
      expect(() => Resource('   '), throwsArgumentError);
      expect(() => Resource('\t\n'), throwsArgumentError);

      final validRes = Resource('valid-res');
      expect(() => Operation('   ', validRes), throwsArgumentError);
      expect(() => Operation('\t\n', validRes), throwsArgumentError);
    });

    test('HedgingConfig validates overloadPercentile strictly < 1.0', () {
      expect(() => HedgingConfig(overloadPercentile: 0.95), returnsNormally);
      expect(() => HedgingConfig(overloadPercentile: 1.0), throwsArgumentError);
      expect(() => HedgingConfig(overloadPercentile: 1.1), throwsArgumentError);
    });

    test(
      'HedgingConfig validates delay within [minDelay, maxDelay] when dynamic',
      () {
        expect(
          () => HedgingConfig(
            dynamicPercentile: 0.9,
            delay: const Duration(milliseconds: 10),
            minDelay: const Duration(milliseconds: 50),
            maxDelay: const Duration(seconds: 2),
          ),
          throwsArgumentError,
        );

        expect(
          () => HedgingConfig(
            dynamicPercentile: 0.9,
            delay: const Duration(seconds: 3),
            minDelay: const Duration(milliseconds: 50),
            maxDelay: const Duration(seconds: 2),
          ),
          throwsArgumentError,
        );
      },
    );

    test('ResilienceContext.states supports custom state injection', () {
      final context = ResilienceContext();
      final config = ResourceConfig();
      final customState = ResourceState(config);
      context.states['custom'] = customState;
      expect(identical(context.states['custom'], customState), isTrue);
    });

    test(
      'AdaptiveThrottler.shouldThrottle delegates to rejectionProbability correctly',
      () {
        final throttler = AdaptiveThrottler.standalone(
          config: ThrottlingConfig(k: 2.0, minRequests: 2),
        );

        expect(throttler.shouldThrottle(Criticality.critical), isFalse);

        throttler.recordRequest(false, Criticality.critical);
        throttler.recordRequest(false, Criticality.critical);

        expect(
          throttler.rejectionProbability(Criticality.critical),
          closeTo(0.666, 0.01),
        );
      },
    );

    test(
      'cleanHistory sorted pruning correctly evicts expired items and preserves recent ones',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'sorted-prune',
          config: ResourceConfig(
            throttling: ThrottlingConfig(
              windowDuration: const Duration(milliseconds: 50),
              minRequests: 1,
            ),
            retry: RetryConfig(
              maxAttempts: 1,
              budgetWindow: const Duration(milliseconds: 50),
            ),
          ),
        );
        final op = Operation('op', resource);

        // Record 3 requests now
        for (int i = 0; i < 3; i++) {
          await context.execute(op, () async => 'ok');
        }

        final state = context.states['sorted-prune']!;
        expect(state.getThrottlingRequests(Criticality.critical), equals(3));

        // Wait past window duration (50ms)
        await Future.delayed(const Duration(milliseconds: 70));

        // Record 2 fresh requests
        for (int i = 0; i < 2; i++) {
          await context.execute(op, () async => 'ok');
        }

        // Older 3 should be pruned, newer 2 should remain
        expect(state.getThrottlingRequests(Criticality.critical), equals(2));
      },
    );
  });
}
