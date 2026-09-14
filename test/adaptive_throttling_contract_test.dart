import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:clock/clock.dart';
import 'package:test/test.dart';

void main() {
  group('Adaptive Throttling Contract Tests', () {
    group('Google SRE Formula Verification', () {
      late ResourceConfig config;
      late ResourceState state;
      late AdaptiveThrottler throttler;

      setUp(() {
        config = ResourceConfig(
          throttling: ThrottlingConfig(
            k: 2.0,
            windowDuration: const Duration(minutes: 2),
            minRequests: 1,
          ),
        );
        state = ResourceState(config);
        throttler = AdaptiveThrottler(config, state);
      });

      test('does not throttle when no history (P = 0.0)', () {
        expect(throttler.shouldThrottle(Criticality.critical), isFalse);
        expect(
          throttler.rejectionProbability(Criticality.critical),
          equals(0.0),
        );
      });

      test('does not throttle when all requests accepted', () {
        state.requestHistory[Criticality.critical]!.add(
          RequestRecord(DateTime.now(), true),
        );
        state.requestHistory[Criticality.critical]!.add(
          RequestRecord(DateTime.now(), true),
        );
        expect(throttler.shouldThrottle(Criticality.critical), isFalse);
        expect(
          throttler.rejectionProbability(Criticality.critical),
          equals(0.0),
        );
      });

      test(
        'does not throttle when accepts are at least half of requests (with K=2.0)',
        () {
          for (int i = 0; i < 5; i++) {
            state.requestHistory[Criticality.critical]!.add(
              RequestRecord(DateTime.now(), true),
            );
            state.requestHistory[Criticality.critical]!.add(
              RequestRecord(DateTime.now(), false),
            );
          }

          // requests = 10, accepts = 5
          // P = max(0, (10 - 2 * 5) / 11) = 0
          expect(
            throttler.rejectionProbability(Criticality.critical),
            equals(0.0),
          );

          int throttledCount = 0;
          for (int i = 0; i < 100; i++) {
            if (throttler.shouldThrottle(Criticality.critical)) {
              throttledCount++;
            }
          }
          expect(throttledCount, equals(0));
        },
      );

      test(
        'throttles with probability matching formula when failure rate is high',
        () {
          // Add 10 failed requests
          for (int i = 0; i < 10; i++) {
            state.requestHistory[Criticality.critical]!.add(
              RequestRecord(DateTime.now(), false),
            );
          }

          // requests = 10, accepts = 0
          // P = (10 - 0) / 11 ≈ 0.909...
          expect(
            throttler.rejectionProbability(Criticality.critical),
            closeTo(10 / 11, 0.001),
          );

          int throttledCount = 0;
          for (int i = 0; i < 100; i++) {
            if (throttler.shouldThrottle(Criticality.critical)) {
              throttledCount++;
            }
          }
          expect(throttledCount, greaterThan(50));
        },
      );

      test(
        'throws ThrottledException when throttling kicks in during execution',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'throttling-service',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 100,
              ),
              throttling: ThrottlingConfig(
                k: 1.0,
                windowDuration: const Duration(seconds: 10),
                minRequests: 5,
              ),
            ),
          );
          final op = Operation(
            'call',
            resource,
            retryOverride: RetryConfig(maxAttempts: 1),
          );

          // Cause 5 failures to trigger throttling (accepts = 0)
          for (int i = 0; i < 5; i++) {
            try {
              await context.execute(op, () async => throw Exception('fail'));
            } catch (_) {}
          }

          bool throttled = false;
          for (int i = 0; i < 20; i++) {
            try {
              await context.execute(op, () async => 'success');
            } on ThrottledException catch (e) {
              throttled = true;
              expect(
                e.message,
                contains('Request throttled for throttling-service'),
              );
              break;
            } catch (_) {}
          }
          expect(throttled, isTrue);
        },
      );

      test('throttled requests are not recorded in request history', () async {
        final context = ResilienceContext();
        final resource = Resource(
          'throttling-history-test',
          config: ResourceConfig(
            throttling: ThrottlingConfig(
              k: 1.0,
              windowDuration: const Duration(seconds: 10),
              minRequests: 5,
            ),
          ),
        );
        final op = Operation(
          'call',
          resource,
          retryOverride: RetryConfig(maxAttempts: 1),
        );

        // Initialize state
        await context.execute(op, () async => 'success');

        final state = context.states[resource.name]!;
        state.requestHistory[op.criticality]!.clear();

        // Add 20 failed requests
        final now = DateTime.now();
        for (int i = 0; i < 20; i++) {
          state.requestHistory[op.criticality]!.add(RequestRecord(now, false));
        }

        expect(state.requestHistory[op.criticality]!.length, equals(20));

        // Attempt requests until one is throttled
        bool throttled = false;
        for (int i = 0; i < 100; i++) {
          try {
            await context.execute(op, () async => 'success');
          } on ThrottledException {
            throttled = true;
            break;
          } catch (_) {}
        }
        expect(throttled, isTrue);

        // Verify no throttled requests were recorded as failures
        final failures = state.requestHistory[op.criticality]!
            .where((r) => !r.accepted)
            .length;
        expect(failures, equals(20));
      });

      test('records internal retries in throttling history', () async {
        final context = ResilienceContext();
        final resource = Resource(
          'throttling-retries-service',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: const Duration(milliseconds: 1),
            ),
          ),
        );
        final op = Operation('call', resource);

        await context.execute(op, () async => 'success');
        final state = context.states[resource.name]!;
        state.requestHistory[Criticality.critical]!.clear();

        // Run call that fails and retries 2 times (total 3 attempts)
        try {
          await context.execute(op, () async => throw Exception('fail'));
        } catch (_) {}

        final history = state.requestHistory[Criticality.critical]!;
        expect(history.length, equals(3));
        expect(history.every((r) => !r.accepted), isTrue);
      });
    });

    group('Cold-Start Protection & Windowing', () {
      test('does not throttle when total requests are below minRequests', () {
        final config = ResourceConfig(
          throttling: ThrottlingConfig(k: 1.0, minRequests: 20),
        );
        final state = ResourceState(config);
        final throttler = AdaptiveThrottler(config, state);

        for (int i = 0; i < 5; i++) {
          state.requestHistory[Criticality.critical]!.add(
            RequestRecord(DateTime.now(), false),
          );
        }

        // requests = 5 < minRequests (20) -> rejectionProbability = 0
        expect(
          throttler.rejectionProbability(Criticality.critical),
          equals(0.0),
        );
        for (int i = 0; i < 50; i++) {
          expect(throttler.shouldThrottle(Criticality.critical), isFalse);
        }
      });

      test('throttles normally once requests reach minRequests', () {
        final config = ResourceConfig(
          throttling: ThrottlingConfig(k: 1.0, minRequests: 20),
        );
        final state = ResourceState(config);
        final throttler = AdaptiveThrottler(config, state);

        for (int i = 0; i < 20; i++) {
          state.requestHistory[Criticality.critical]!.add(
            RequestRecord(DateTime.now(), false),
          );
        }

        expect(
          throttler.rejectionProbability(Criticality.critical),
          closeTo(20 / 21, 0.01),
        );

        int throttledCount = 0;
        for (int i = 0; i < 100; i++) {
          if (throttler.shouldThrottle(Criticality.critical)) {
            throttledCount++;
          }
        }
        expect(throttledCount, greaterThan(50));
      });

      test(
        'cleanHistory sorted pruning evicts expired items and preserves recent ones',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'pruning-service',
            config: ResourceConfig(
              throttling: ThrottlingConfig(
                windowDuration: const Duration(milliseconds: 50),
                minRequests: 1,
              ),
            ),
          );
          final op = Operation('call', resource);

          // Record 3 requests
          for (int i = 0; i < 3; i++) {
            await context.execute(op, () async => 'ok');
          }

          final state = context.states['pruning-service']!;
          expect(state.getThrottlingRequests(Criticality.critical), equals(3));

          // Wait past windowDuration (50ms)
          await Future.delayed(const Duration(milliseconds: 70));

          // Record 2 fresh requests
          for (int i = 0; i < 2; i++) {
            await context.execute(op, () async => 'ok');
          }

          // Older 3 pruned, only 2 remain
          expect(state.getThrottlingRequests(Criticality.critical), equals(2));
        },
      );

      test(
        'cleanHistory fast prefix slicing and backward clock jump defense',
        () {
          final config = ResourceConfig();
          final state = ResourceState(config);

          final now = DateTime.now();
          final oldTime = now.subtract(const Duration(hours: 1));
          final futureTime = now.add(const Duration(hours: 1));

          state.requestHistory[Criticality.critical]!.addAll([
            RequestRecord(oldTime, false),
            RequestRecord(now, true),
            RequestRecord(futureTime, true),
          ]);

          state.cleanHistory(now);

          final history = state.requestHistory[Criticality.critical]!;
          // Old record should be purged, future record normalized/kept
          expect(history.any((r) => r.timestamp == oldTime), isFalse);
          expect(history.length, equals(1));
        },
      );
    });

    group('Criticality-Aware Throttling', () {
      test('default constructor applies formula with spread: 1.0', () {
        final config = ThrottlingConfig(k: 2.0, spread: 1.0);
        expect(config.k.criticalPlus, closeTo(8.0, 0.001));
        expect(config.k.critical, closeTo(2.0, 0.001));
        expect(config.k.sheddablePlus, closeTo(1.6, 0.001));
        expect(config.k.sheddable, closeTo(1.2, 0.001));
      });

      test('spread: 0.0 collapses all criticality levels to base k', () {
        final config = ThrottlingConfig(k: 2.0, spread: 0.0);
        expect(config.k.criticalPlus, closeTo(2.0, 0.001));
        expect(config.k.critical, closeTo(2.0, 0.001));
        expect(config.k.sheddablePlus, closeTo(2.0, 0.001));
        expect(config.k.sheddable, closeTo(2.0, 0.001));
      });

      test('spread: 0.5 applies intermediate multipliers', () {
        final config = ThrottlingConfig(k: 2.0, spread: 0.5);
        expect(config.k.criticalPlus, closeTo(5.0, 0.001));
        expect(config.k.critical, closeTo(2.0, 0.001));
        expect(config.k.sheddablePlus, closeTo(1.8, 0.001));
        expect(config.k.sheddable, closeTo(1.6, 0.001));
      });

      test(
        'enforces minimum K of 1.1 and prevents priority inversion with low k',
        () {
          final config = ThrottlingConfig(k: 1.0, spread: 1.0);
          expect(config.k.sheddable, closeTo(1.1, 0.001));
          expect(config.k.sheddablePlus, closeTo(1.1, 0.001));
          expect(config.k.critical, closeTo(1.1, 0.001));
          expect(config.k.criticalPlus, closeTo(4.0, 0.001));
        },
      );

      test('withCriticality applies exact custom K values', () {
        const exactK = (
          criticalPlus: 5.0,
          critical: 3.0,
          sheddablePlus: 2.0,
          sheddable: 1.5,
        );
        final config = ThrottlingConfig.withCriticality(k: exactK);
        expect(config.k.criticalPlus, equals(5.0));
        expect(config.k.critical, equals(3.0));
        expect(config.k.sheddablePlus, equals(2.0));
        expect(config.k.sheddable, equals(1.5));

        expect(config.getK(Criticality.criticalPlus), equals(5.0));
        expect(config.getK(Criticality.critical), equals(3.0));
        expect(config.getK(Criticality.sheddablePlus), equals(2.0));
        expect(config.getK(Criticality.sheddable), equals(1.5));
      });

      test(
        'criticality integration: drops sheddable traffic first under overload',
        () {
          final config = ResourceConfig(
            throttling: ThrottlingConfig(
              k: 2.0,
              spread: 1.0,
              windowDuration: const Duration(minutes: 2),
              minRequests: 1,
            ),
          );
          final state = ResourceState(config);
          final throttler = AdaptiveThrottler(config, state);

          void populateHistory(Criticality criticality) {
            for (int i = 0; i < 4; i++) {
              state.requestHistory[criticality]!.add(
                RequestRecord(DateTime.now(), true),
              );
            }
            for (int i = 0; i < 6; i++) {
              state.requestHistory[criticality]!.add(
                RequestRecord(DateTime.now(), false),
              );
            }
          }

          for (final c in Criticality.values) {
            populateHistory(c);
          }

          int criticalPlusThrottled = 0;
          for (int i = 0; i < 1000; i++) {
            if (throttler.shouldThrottle(Criticality.criticalPlus)) {
              criticalPlusThrottled++;
            }
          }
          expect(criticalPlusThrottled, equals(0));

          int sheddableThrottled = 0;
          int criticalThrottled = 0;
          int sheddablePlusThrottled = 0;

          for (int i = 0; i < 1000; i++) {
            if (throttler.shouldThrottle(Criticality.sheddable))
              sheddableThrottled++;
            if (throttler.shouldThrottle(Criticality.critical))
              criticalThrottled++;
            if (throttler.shouldThrottle(Criticality.sheddablePlus))
              sheddablePlusThrottled++;
          }

          expect(sheddableThrottled, greaterThan(criticalThrottled));
          expect(sheddablePlusThrottled, greaterThan(criticalThrottled));
          expect(sheddableThrottled, greaterThan(sheddablePlusThrottled));
        },
      );

      test(
        'failures on critical operations cause sheddable traffic to be throttled first',
        () {
          final config = ResourceConfig(
            throttling: ThrottlingConfig(k: 2.0, minRequests: 1),
          );
          final state = ResourceState(config);
          final throttler = AdaptiveThrottler(config, state);

          // 10 requests: 6 accepted, 4 failed (40% failure rate)
          for (int i = 0; i < 6; i++) {
            state.requestHistory[Criticality.critical]!.add(
              RequestRecord(clock.now(), true),
            );
          }
          for (int i = 0; i < 4; i++) {
            state.requestHistory[Criticality.critical]!.add(
              RequestRecord(clock.now(), false),
            );
          }

          // Critical (K = 2.0) tolerates up to 50% failure rate -> rejection probability 0
          expect(
            throttler.rejectionProbability(Criticality.critical),
            equals(0.0),
          );
          // Sheddable (K = 1.2) tolerates only up to 16.7% failure rate -> rejection probability > 0
          expect(
            throttler.rejectionProbability(Criticality.sheddable),
            greaterThan(0.0),
          );

          int criticalThrottled = 0;
          for (int i = 0; i < 100; i++) {
            if (throttler.shouldThrottle(Criticality.critical)) {
              criticalThrottled++;
            }
          }
          expect(criticalThrottled, equals(0));

          int sheddableThrottled = 0;
          for (int i = 0; i < 1000; i++) {
            if (throttler.shouldThrottle(Criticality.sheddable)) {
              sheddableThrottled++;
            }
          }
          expect(sheddableThrottled, greaterThan(100));
        },
      );
    });

    group('Standalone & Monitoring APIs', () {
      test(
        'AdaptiveThrottler.standalone supports recordRequest and rejectionProbability',
        () {
          final throttler = AdaptiveThrottler.standalone(
            config: ThrottlingConfig(k: 2.0, minRequests: 2),
          );

          expect(
            throttler.rejectionProbability(Criticality.critical),
            equals(0.0),
          );

          throttler.recordRequest(false, Criticality.critical);
          throttler.recordRequest(false, Criticality.critical);

          // requests = 2, accepts = 0 -> P = 2/3 ≈ 0.666
          expect(
            throttler.rejectionProbability(Criticality.critical),
            closeTo(0.666, 0.01),
          );
        },
      );

      test(
        'AdaptiveThrottler.shouldThrottle delegates to rejectionProbability correctly',
        () {
          final throttler = AdaptiveThrottler.standalone(
            config: ThrottlingConfig(k: 1.0, minRequests: 1),
          );

          expect(throttler.shouldThrottle(Criticality.critical), isFalse);

          throttler.recordRequest(false, Criticality.critical);
          expect(
            throttler.rejectionProbability(Criticality.critical),
            greaterThan(0.0),
          );
        },
      );

      test(
        'AdaptiveThrottler.execute runs action and throws ThrottledException when throttled',
        () async {
          final throttler = AdaptiveThrottler.standalone(
            config: ThrottlingConfig(k: 1.1, minRequests: 2),
          );

          final res = await throttler.execute(() async => 'success');
          expect(res, equals('success'));

          for (int i = 0; i < 5; i++) {
            throttler.recordRequest(false);
          }

          expect(
            throttler.rejectionProbability(Criticality.critical),
            greaterThan(0.5),
          );

          bool throttled = false;
          for (int i = 0; i < 50; i++) {
            try {
              await throttler.execute(() async => 'ok');
            } on ThrottledException {
              throttled = true;
              break;
            } catch (_) {}
          }
          expect(throttled, isTrue);
        },
      );

      test(
        'AdaptiveThrottler.execute handles throwing failureClassifier cleanly',
        () async {
          final throttler = AdaptiveThrottler.standalone(
            failureClassifier: (e) => throw TypeError(),
          );

          await expectLater(
            throttler.execute(() async => throw StateError('crash')),
            throwsA(isA<StateError>()),
          );
        },
      );

      test(
        'monitoring metrics report requests, accepts, and rejection probability',
        () {
          final config = ResourceConfig(
            throttling: ThrottlingConfig(k: 2.0, minRequests: 1),
          );
          final state = ResourceState(config);

          expect(state.getThrottlingRequests(Criticality.critical), equals(0));
          expect(state.getThrottlingAccepts(Criticality.critical), equals(0));
          expect(
            state.getThrottlingRejectionProbability(Criticality.critical),
            equals(0.0),
          );

          final now = DateTime.now();
          state.requestHistory[Criticality.critical]!.addAll([
            RequestRecord(now, true),
            RequestRecord(now, true),
            RequestRecord(now, false),
          ]);

          expect(state.getThrottlingRequests(Criticality.critical), equals(3));
          expect(state.getThrottlingAccepts(Criticality.critical), equals(2));
          // requests = 3, accepts = 2, K = 2.0 -> (3 - 4) / 4 = 0
          expect(
            state.getThrottlingRejectionProbability(Criticality.critical),
            equals(0.0),
          );
        },
      );
    });

    group('Exception Formatting', () {
      test('ThrottledException toString contains informative message', () {
        const e = ThrottledException('Request throttled for payment-service');
        expect(
          e.toString(),
          equals('ThrottledException: Request throttled for payment-service'),
        );
        expect(e.message, contains('payment-service'));
      });
    });
  });
}
