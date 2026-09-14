import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/retry.dart' as cb_retry;
import 'package:test/test.dart' hide Retry;

void main() {
  group('ResilienceEvent hierarchy and toString', () {
    test('Event toString formatting and properties', () {
      final res = Resource('service_a');
      final now = DateTime.now();

      final cbEvent = CircuitBreakerStateChangedEvent(
        resource: res,
        timestamp: now,
        previousState: CircuitState.closed,
        newState: CircuitState.open,
      );
      expect(cbEvent.resourceName, 'service_a');
      expect(cbEvent.previousState, CircuitState.closed);
      expect(cbEvent.newState, CircuitState.open);
      expect(cbEvent.toString(), contains('service_a'));
      expect(
        cbEvent.toString(),
        contains('previousState: CircuitState.closed'),
      );
      expect(cbEvent.toString(), contains('newState: CircuitState.open'));

      final throttleEvent = RequestThrottledEvent(
        resource: res,
        timestamp: now,
        criticality: Criticality.sheddable,
        rejectionProbability: 0.75,
      );
      expect(throttleEvent.criticality, Criticality.sheddable);
      expect(throttleEvent.rejectionProbability, 0.75);
      expect(throttleEvent.toString(), contains('sheddable'));
      expect(throttleEvent.toString(), contains('0.75'));

      final retryEvent = RetryAttemptEvent(
        resource: res,
        timestamp: now,
        attemptNumber: 2,
        delay: const Duration(milliseconds: 100),
        error: Exception('boom'),
      );
      expect(retryEvent.attemptNumber, 2);
      expect(retryEvent.delay, const Duration(milliseconds: 100));
      expect(retryEvent.error.toString(), contains('boom'));
      expect(retryEvent.toString(), contains('attemptNumber: 2'));

      final hedgeEvent = HedgeFiredEvent(
        resource: res,
        timestamp: now,
        delay: const Duration(milliseconds: 50),
        activeHedges: 1,
      );
      expect(hedgeEvent.delay, const Duration(milliseconds: 50));
      expect(hedgeEvent.activeHedges, 1);
      expect(hedgeEvent.toString(), contains('activeHedges: 1'));

      final opEvent = OperationCompletedEvent(
        resource: res,
        operation: res.operation('query'),
        timestamp: now,
        duration: const Duration(milliseconds: 120),
        isSuccess: true,
      );
      expect(opEvent.operationName, 'query');
      expect(opEvent.isSuccess, isTrue);
      expect(opEvent.error, isNull);
      expect(opEvent.toString(), contains('operation: query'));

      final opEventDirect = OperationCompletedEvent(
        resource: res,
        timestamp: now,
        duration: const Duration(milliseconds: 80),
        isSuccess: false,
        error: 'error',
      );
      expect(opEventDirect.operationName, isEmpty);
      expect(opEventDirect.isSuccess, isFalse);
      expect(opEventDirect.error, 'error');
      expect(opEventDirect.toString(), contains('isSuccess: false'));
    });
  });

  group('Observability Streams and Subscriptions', () {
    test(
      'CircuitBreakerStateChangedEvent and OperationCompletedEvent emission',
      () async {
        final context = ResilienceContext();
        final res = Resource(
          'db',
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 2,
            resetTimeout: const Duration(milliseconds: 50),
          ),
          retry: RetryConfig(maxAttempts: 1),
          throttling: ThrottlingConfig(minRequests: 100),
        );

        final contextEvents = <ResilienceEvent>[];
        final resourceEvents = <ResilienceEvent>[];
        final sub1 = context.events.listen(contextEvents.add);
        final sub2 = res.events.listen(resourceEvents.add);

        await expectLater(
          () => context.execute(
            res,
            () => Future<void>.error(Exception('fail1')),
          ),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          () => context.execute(
            res,
            () => Future<void>.error(Exception('fail2')),
          ),
          throwsA(isA<Exception>()),
        );

        // Expect circuit to have opened
        expect(
          contextEvents.any(
            (e) =>
                e is CircuitBreakerStateChangedEvent &&
                e.newState == CircuitState.open,
          ),
          isTrue,
        );
        expect(
          resourceEvents.any(
            (e) =>
                e is CircuitBreakerStateChangedEvent &&
                e.newState == CircuitState.open,
          ),
          isTrue,
        );

        // Verify OperationCompletedEvent
        final failedOps = contextEvents
            .whereType<OperationCompletedEvent>()
            .toList();
        expect(failedOps.length, 2);
        expect(failedOps[0].isSuccess, isFalse);
        expect(failedOps[0].error.toString(), contains('fail1'));
        expect(failedOps[1].isSuccess, isFalse);
        expect(failedOps[1].error.toString(), contains('fail2'));

        await sub1.cancel();
        await sub2.cancel();
      },
    );

    test('Hierarchy event bubbling to parent resource', () async {
      final parent = Resource('parent_service');
      final child = Resource('child_service', parent: parent);
      final context = ResilienceContext();

      final parentEvents = <ResilienceEvent>[];
      final childEvents = <ResilienceEvent>[];
      final sub1 = parent.events.listen(parentEvents.add);
      final sub2 = child.events.listen(childEvents.add);

      await context.execute(child, () async => 'success');

      expect(childEvents.length, 1);
      expect(childEvents.first, isA<OperationCompletedEvent>());

      // Bubbled to parent
      expect(parentEvents.length, 1);
      expect(parentEvents.first, isA<OperationCompletedEvent>());
      expect(parentEvents.first.resource.name, 'child_service');

      await sub1.cancel();
      await sub2.cancel();
    });

    test(
      'RetryAttemptEvent emission in context and standalone retry',
      () async {
        final context = ResilienceContext();
        final res = Resource(
          'api',
          retry: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(milliseconds: 10),
            enableJitter: false,
          ),
        );

        final events = <ResilienceEvent>[];
        final sub = res.events.listen(events.add);

        var callCount = 0;
        final result = await context.execute(res, () async {
          callCount++;
          if (callCount < 3) throw Exception('transient error');
          return 'ok';
        });

        expect(result, 'ok');
        expect(callCount, 3);

        final retryEvents = events.whereType<RetryAttemptEvent>().toList();
        expect(retryEvents.length, 2);
        expect(retryEvents[0].attemptNumber, 2);
        expect(retryEvents[1].attemptNumber, 3);

        final opCompleted = events
            .whereType<OperationCompletedEvent>()
            .toList();
        expect(opCompleted.length, 1);
        expect(opCompleted.first.isSuccess, isTrue);

        await sub.cancel();

        // Standalone Retry with resource
        final standaloneEvents = <ResilienceEvent>[];
        final standaloneSub = res.events.listen(standaloneEvents.add);
        final standaloneRetry = cb_retry.Retry(
          ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 2,
              baseDelay: const Duration(milliseconds: 5),
              enableJitter: false,
            ),
          ),
          ResourceState(ResourceConfig()),
          resource: res,
        );

        var standaloneAttempts = 0;
        await standaloneRetry.execute(() async {
          standaloneAttempts++;
          if (standaloneAttempts < 2) throw Exception('retry me');
          return 42;
        });

        expect(standaloneEvents.whereType<RetryAttemptEvent>().length, 1);
        await standaloneSub.cancel();
      },
    );

    test('HedgeFiredEvent emission in context and standalone hedge', () async {
      final context = ResilienceContext();
      final res = Resource(
        'hedged_service',
        hedging: HedgingConfig(
          delay: const Duration(milliseconds: 10),
          enabled: true,
          maxConcurrentHedges: 2,
        ),
      );

      final events = <ResilienceEvent>[];
      final sub = res.events.listen(events.add);

      final result = await context.execute(res, () async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return 'done';
      });

      expect(result, 'done');
      final hedgeEvents = events.whereType<HedgeFiredEvent>().toList();
      expect(hedgeEvents.isNotEmpty, isTrue);
      expect(hedgeEvents.first.activeHedges, greaterThanOrEqualTo(1));

      await sub.cancel();

      // Standalone RequestHedger with resource
      final standaloneEvents = <ResilienceEvent>[];
      final standaloneSub = res.events.listen(standaloneEvents.add);
      final cfg = ResourceConfig(
        hedging: HedgingConfig(
          delay: const Duration(milliseconds: 5),
          enabled: true,
          maxConcurrentHedges: 1,
        ),
      );
      final standaloneHedger = RequestHedger(
        cfg,
        ResourceState(cfg),
        resource: res,
      );

      await standaloneHedger.execute(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return 'standalone done';
      });

      expect(standaloneEvents.whereType<HedgeFiredEvent>().isNotEmpty, isTrue);
      await standaloneSub.cancel();
    });

    test('RequestThrottledEvent emission on adaptive throttling', () async {
      final context = ResilienceContext();
      final res = Resource(
        'throttled_service',
        throttling: ThrottlingConfig(k: 1.0, spread: 0.0),
      );

      // Force failure state on the internal throttler state to cause high rejection probability
      final state = context.states.putIfAbsent(
        res.name,
        () => ResourceState(res.config),
      );
      for (var i = 0; i < 20; i++) {
        state.recordRequest(false, Criticality.sheddable);
      }
      // No accepts -> rejection probability ~ 20/21 = 0.95

      final events = <ResilienceEvent>[];
      final sub = res.events.listen(events.add);

      var rejected = false;
      for (var i = 0; i < 10; i++) {
        try {
          await context.execute(
            res.operation('op', criticality: Criticality.sheddable),
            () async => 'ok',
          );
        } catch (e) {
          if (e is ThrottledException) {
            rejected = true;
            break;
          }
        }
      }

      expect(rejected, isTrue);
      final throttledEvents = events
          .whereType<RequestThrottledEvent>()
          .toList();
      expect(throttledEvents.isNotEmpty, isTrue);
      expect(throttledEvents.first.criticality, Criticality.sheddable);
      expect(throttledEvents.first.rejectionProbability, greaterThan(0.0));

      await sub.cancel();
    });
  });

  group('ResourceMetricsSnapshot', () {
    test(
      'Metrics snapshot on Resource, BoundResource, and ResiliencePolicy',
      () async {
        final policy = ResiliencePolicy(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
        );

        // Policy events and getSnapshot
        final policyEvents = <ResilienceEvent>[];
        final pSub = policy.events.listen(policyEvents.add);

        await policy.execute(() async => 'hello');
        final snapshot = policy.getSnapshot();

        expect(snapshot.resourceName, policy.resource.name);
        expect(snapshot.circuitState, CircuitState.closed);
        expect(snapshot.consecutiveFailures, 0);
        expect(snapshot.activeHedges, 0);
        expect(snapshot.retryBudgetRequests, 1);
        expect(snapshot.retryBudgetRetries, 0);
        expect(snapshot.retryBudgetRatio, 0.0);
        expect(
          snapshot.throttlingByCriticality.containsKey(Criticality.critical),
          isTrue,
        );
        expect(
          snapshot.throttlingByCriticality[Criticality.critical]?.requests,
          1,
        );
        expect(
          snapshot.throttlingByCriticality[Criticality.critical]?.accepts,
          1,
        );
        expect(snapshot.toString(), contains(policy.resource.name));
        expect(
          snapshot.throttlingByCriticality[Criticality.critical]?.toString(),
          contains('critical'),
        );

        // BoundResource events and getSnapshot
        final context = ResilienceContext();
        final bound = context.bind(
          Resource(
            'bound_service',
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
            ),
            retry: RetryConfig(maxAttempts: 1),
          ),
        );

        final boundEvents = <ResilienceEvent>[];
        final bSub = bound.events.listen(boundEvents.add);

        await expectLater(
          () => bound.execute(() => Future<void>.error(Exception('err'))),
          throwsA(isA<Exception>()),
        );

        final boundSnapshot = bound.getSnapshot();
        expect(boundSnapshot.resourceName, 'bound_service');
        expect(boundSnapshot.consecutiveFailures, 1);
        expect(boundSnapshot.lastFailureTime, isNotNull);

        // Resource.getSnapshot direct
        final directSnapshot = bound.resource.getSnapshot(context);
        expect(directSnapshot.consecutiveFailures, 1);

        // Resource.getSnapshot with defaultContext
        final defaultSnapshot = Resource('default_res').getSnapshot();
        expect(defaultSnapshot.resourceName, 'default_res');

        await pSub.cancel();
        await bSub.cancel();
      },
    );
  });
}
