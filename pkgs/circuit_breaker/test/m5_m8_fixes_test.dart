import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:clock/clock.dart';
import 'package:test/test.dart';

void main() {
  group('M5 — Resource-name collisions and config validation', () {
    late ResilienceContext context;

    setUp(() {
      context = ResilienceContext();
    });

    test('identical configs share state successfully without error', () async {
      final r1 = Resource(
        'service-a',
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
        ),
      );
      final r2 = Resource(
        'service-a',
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
        ),
      );

      final state1 = context.getOrCreateState(r1.name, r1.config);
      final state2 = context.getOrCreateState(r2.name, r2.config);

      expect(identical(state1, state2), isTrue);
      expect(context.resourceCount, equals(1));
    });

    test(
      'conflicting circuit breaker config throws ArgumentError on getOrCreateState',
      () {
        final config1 = ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
        );
        final config2 = ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 10,
          ),
        );

        context.getOrCreateState('api-users', config1);

        expect(
          () => context.getOrCreateState('api-users', config2),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('conflicting configuration'),
            ),
          ),
        );
      },
    );

    test(
      'conflicting configs via Resource.execute throws ArgumentError',
      () async {
        final r1 = Resource(
          'service-collision',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
            ),
          ),
        );
        final r2 = Resource(
          'service-collision',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 100,
            ),
          ),
        );

        await context.execute(r1, () async => 'ok1');

        expect(
          () => context.execute(r2, () async => 'ok2'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('service-collision'),
            ),
          ),
        );
      },
    );

    test('conflicting retry configs throw ArgumentError', () {
      final c1 = ResourceConfig(retry: RetryConfig(maxAttempts: 2));
      final c2 = ResourceConfig(retry: RetryConfig(maxAttempts: 5));

      context.getOrCreateState('retry-res', c1);
      expect(
        () => context.getOrCreateState('retry-res', c2),
        throwsArgumentError,
      );
    });

    test('conflicting throttling configs throw ArgumentError', () {
      final c1 = ResourceConfig(
        throttling: ThrottlingConfig(
          windowDuration: const Duration(seconds: 10),
        ),
      );
      final c2 = ResourceConfig(
        throttling: ThrottlingConfig(
          windowDuration: const Duration(minutes: 5),
        ),
      );

      context.getOrCreateState('throttle-res', c1);
      expect(
        () => context.getOrCreateState('throttle-res', c2),
        throwsArgumentError,
      );
    });

    test('conflicting hedging configs throw ArgumentError', () {
      final c1 = ResourceConfig(hedging: HedgingConfig(delayMultiplier: 1.5));
      final c2 = ResourceConfig(hedging: HedgingConfig(delayMultiplier: 3.0));

      context.getOrCreateState('hedge-res', c1);
      expect(
        () => context.getOrCreateState('hedge-res', c2),
        throwsArgumentError,
      );
    });

    test('conflicting timeouts throw ArgumentError', () {
      final c1 = ResourceConfig(timeout: const Duration(seconds: 5));
      final c2 = ResourceConfig(timeout: const Duration(seconds: 10));

      context.getOrCreateState('timeout-res', c1);
      expect(
        () => context.getOrCreateState('timeout-res', c2),
        throwsArgumentError,
      );
    });

    test(
      'removeResource clears state and permits registering new configuration',
      () {
        final c1 = ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
        );
        final c2 = ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 10,
          ),
        );

        context.getOrCreateState('cleared-res', c1);
        expect(context.removeResource('cleared-res'), isTrue);

        // Now registering with c2 should succeed
        final state2 = context.getOrCreateState('cleared-res', c2);
        expect(
          state2.config.circuitBreaker.consecutiveFailuresThreshold,
          equals(10),
        );
      },
    );
  });

  group('M6 — runWithCancellationToken detachment and leak prevention', () {
    test('synchronous action detaches child token from parent on return', () {
      final parent = CancellationToken();
      final child = CancellationToken();

      expect(parent.childCount, equals(0));

      final result = ResilienceContext.runWithCancellationToken(parent, () {
        return ResilienceContext.runWithCancellationToken(child, () {
          expect(parent.childCount, equals(1));
          expect(child.parent, equals(parent));
          return 42;
        });
      });

      expect(result, equals(42));
      // Child must be detached from parent
      expect(parent.childCount, equals(0));
      expect(child.parent, isNull);

      // Cancelling parent does not affect the detached child
      parent.cancel();
      expect(child.isCancelled, isFalse);
    });

    test('synchronous exception detaches child token from parent', () {
      final parent = CancellationToken();
      final child = CancellationToken();

      expect(parent.childCount, equals(0));

      expect(
        () => ResilienceContext.runWithCancellationToken(parent, () {
          ResilienceContext.runWithCancellationToken(child, () {
            expect(parent.childCount, equals(1));
            throw StateError('test sync failure');
          });
        }),
        throwsStateError,
      );

      expect(parent.childCount, equals(0));
      expect(child.parent, isNull);

      parent.cancel();
      expect(child.isCancelled, isFalse);
    });

    test(
      'asynchronous action detaches child token after Future completes',
      () async {
        final parent = CancellationToken();
        final child = CancellationToken();
        final completer = Completer<String>();

        final future = ResilienceContext.runWithCancellationToken(parent, () {
          return ResilienceContext.runWithCancellationToken(
            child,
            () => completer.future,
          );
        });

        // While async operation is pending, child is attached to parent
        expect(parent.childCount, equals(1));
        expect(child.parent, equals(parent));

        completer.complete('async done');
        final result = await future;

        expect(result, equals('async done'));
        // Once future completes, child must be detached
        expect(parent.childCount, equals(0));
        expect(child.parent, isNull);

        parent.cancel();
        expect(child.isCancelled, isFalse);
      },
    );

    test(
      'asynchronous error detaches child token after Future fails',
      () async {
        final parent = CancellationToken();
        final child = CancellationToken();
        final completer = Completer<String>();

        final future = ResilienceContext.runWithCancellationToken(parent, () {
          return ResilienceContext.runWithCancellationToken(
            child,
            () => completer.future,
          );
        });

        expect(parent.childCount, equals(1));

        completer.completeError(Exception('async failure'));

        await expectLater(future, throwsException);

        expect(parent.childCount, equals(0));
        expect(child.parent, isNull);

        parent.cancel();
        expect(child.isCancelled, isFalse);
      },
    );

    test(
      'cancellation propagation works while in-flight before detachment',
      () async {
        final parent = CancellationToken();
        final child = CancellationToken();
        final completer = Completer<void>();

        final future = ResilienceContext.runWithCancellationToken(parent, () {
          return ResilienceContext.runWithCancellationToken(child, () async {
            await completer.future;
          });
        });

        expect(child.isCancelled, isFalse);
        parent.cancel();
        expect(child.isCancelled, isTrue);

        completer.complete();
        await future;
        expect(parent.childCount, equals(0));
      },
    );
  });

  group('M7 — Hedge delay clamp strictly respects [minDelay, maxDelay]', () {
    test('static hedging returns static delay', () {
      final config = HedgingConfig(
        delay: const Duration(milliseconds: 250),
        enabled: true,
      );
      final state = ResourceState(ResourceConfig(hedging: config));

      expect(
        calculateHedgeDelay(config, state),
        equals(const Duration(milliseconds: 250)),
      );
    });

    test(
      'calculated delay clamped to maxDelay when multiplied delay exceeds maxDelay',
      () {
        final config = HedgingConfig(
          enabled: true,
          dynamicPercentile: 0.95,
          minDelay: const Duration(milliseconds: 50),
          maxDelay: const Duration(milliseconds: 500),
          delayMultiplier: 3.0,
        );
        final state = ResourceState(ResourceConfig(hedging: config));

        // Simulate tracked delay estimate reaching 300ms
        // 300ms * 3.0 = 900ms, which exceeds maxDelay (500ms)
        for (int i = 0; i < 20; i++) {
          state.recordHedgingSample(isSlow: true);
        }

        final dynamicDelay = calculateHedgeDelay(config, state);
        expect(dynamicDelay, lessThanOrEqualTo(config.maxDelay));
        expect(dynamicDelay, equals(const Duration(milliseconds: 500)));
      },
    );

    test(
      'calculated delay clamped to minDelay when multiplied delay falls below minDelay',
      () {
        final config = HedgingConfig(
          enabled: true,
          dynamicPercentile: 0.50,
          minDelay: const Duration(milliseconds: 100),
          maxDelay: const Duration(seconds: 10),
          delayMultiplier: 0.5,
        );
        final state = ResourceState(ResourceConfig(hedging: config));

        // Fast samples drive estimate down towards minDelay
        for (int i = 0; i < 30; i++) {
          state.recordHedgingSample(isSlow: false);
        }

        final dynamicDelay = calculateHedgeDelay(config, state);
        expect(dynamicDelay, greaterThanOrEqualTo(config.minDelay));
        expect(dynamicDelay, equals(const Duration(milliseconds: 100)));
      },
    );
  });

  group('M8 — pruneIdleResources and state lifecycle', () {
    test('pruneIdleResources returns 0 on empty context', () {
      final context = ResilienceContext();
      expect(context.pruneIdleResources(), equals(0));
    });

    test('pruning throws ArgumentError on negative maxIdle', () {
      final context = ResilienceContext();
      expect(
        () => context.pruneIdleResources(maxIdle: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });

    test('evicts idle closed resources that exceeded maxIdle', () {
      final context = ResilienceContext();
      DateTime fakeTime = DateTime(2026, 9, 14, 12, 0);

      withClock(Clock(() => fakeTime), () {
        final r1 = Resource('idle-res-1');
        final r2 = Resource('idle-res-2');
        final r3 = Resource('active-res');

        context.getOrCreateState(r1.name, r1.config);
        context.getOrCreateState(r2.name, r2.config);
        context.getOrCreateState(r3.name, r3.config);
        expect(context.resourceCount, equals(3));

        // Advance clock by 15 minutes
        fakeTime = fakeTime.add(const Duration(minutes: 15));

        // Touch r3 so it is not idle
        context.states[r3.name]!.touch();

        // Prune resources idle for >= 10 minutes
        final evictedCount = context.pruneIdleResources(
          maxIdle: const Duration(minutes: 10),
        );

        expect(evictedCount, equals(2));
        expect(context.resourceCount, equals(1));
        expect(context.containsResource('idle-res-1'), isFalse);
        expect(context.containsResource('idle-res-2'), isFalse);
        expect(context.containsResource('active-res'), isTrue);
      });
    });

    test('does NOT prune open or half-open circuit breakers even if idle', () {
      final context = ResilienceContext();
      DateTime fakeTime = DateTime(2026, 9, 14, 12, 0);

      withClock(Clock(() => fakeTime), () {
        final rOpen = Resource('open-res');
        final rHalfOpen = Resource('half-open-res');

        final stateOpen = context.getOrCreateState(rOpen.name, rOpen.config);
        final stateHalfOpen = context.getOrCreateState(
          rHalfOpen.name,
          rHalfOpen.config,
        );

        stateOpen.circuitState = CircuitState.open;
        stateHalfOpen.circuitState = CircuitState.halfOpen;

        // Advance clock by 1 hour
        fakeTime = fakeTime.add(const Duration(hours: 1));

        final evictedCount = context.pruneIdleResources(
          maxIdle: const Duration(minutes: 10),
        );

        // Neither open nor half-open should be evicted
        expect(evictedCount, equals(0));
        expect(context.containsResource('open-res'), isTrue);
        expect(context.containsResource('half-open-res'), isTrue);
      });
    });

    test('does NOT prune resources with active hedges or in-flight trials', () {
      final context = ResilienceContext();
      DateTime fakeTime = DateTime(2026, 9, 14, 12, 0);

      withClock(Clock(() => fakeTime), () {
        final rHedge = Resource('hedging-res');
        final rTrial = Resource('trial-res');

        final stateHedge = context.getOrCreateState(rHedge.name, rHedge.config);
        final stateTrial = context.getOrCreateState(rTrial.name, rTrial.config);

        stateHedge.activeHedges = 1;
        stateTrial.circuitState = CircuitState.halfOpen;
        stateTrial.trialRequestInProgress = true;

        fakeTime = fakeTime.add(const Duration(hours: 1));

        final evictedCount = context.pruneIdleResources(
          maxIdle: const Duration(minutes: 10),
        );

        expect(evictedCount, equals(0));
        expect(context.containsResource('hedging-res'), isTrue);
        expect(context.containsResource('trial-res'), isTrue);
      });
    });

    test('pruned resource can be re-registered on subsequent demand', () {
      final context = ResilienceContext();
      DateTime fakeTime = DateTime(2026, 9, 14, 12, 0);

      withClock(Clock(() => fakeTime), () {
        final r = Resource('recycled-res');
        final s1 = context.getOrCreateState(r.name, r.config);
        s1.failureCount = 2;

        fakeTime = fakeTime.add(const Duration(minutes: 20));
        expect(
          context.pruneIdleResources(maxIdle: const Duration(minutes: 10)),
          equals(1),
        );
        expect(context.containsResource('recycled-res'), isFalse);

        // Accessing resource again allocates clean state
        final s2 = context.getOrCreateState(r.name, r.config);
        expect(identical(s1, s2), isFalse);
        expect(s2.failureCount, equals(0));
      });
    });
  });
}
