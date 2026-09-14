import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Criticality-Aware Throttling & Shedding', () {
    late ResilienceContext context;
    late Resource resource;

    setUp(() {
      context = ResilienceContext();
    });

    test(
      'failures on critical operations cause sheddable operations to be throttled first via context',
      () async {
        resource = Resource(
          'criticality-test-service',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 100, // Do not trip circuit breaker
            ),
            throttling: ThrottlingConfig(
              k: 2.0,
              spread: 1.0, // sheddable: 1.2, critical: 2.0
              minRequests: 10,
            ),
          ),
        );

        final criticalOp = Operation(
          'crit-op',
          resource,
          criticality: Criticality.critical,
          retryOverride: RetryConfig(maxAttempts: 1),
        );
        final sheddableOp = Operation(
          'shed-op',
          resource,
          criticality: Criticality.sheddable,
          retryOverride: RetryConfig(maxAttempts: 1),
        );

        // Execute 6 successful and 4 failed critical requests (total = 10, accepts = 6)
        for (int i = 0; i < 6; i++) {
          await context.execute(criticalOp, () async => 'ok');
        }
        for (int i = 0; i < 4; i++) {
          try {
            await context.execute(
              criticalOp,
              () async => throw Exception('backend error'),
            );
          } catch (_) {}
        }

        final state = context.states[resource.name]!;
        // Total requests across resource: 10, total accepts: 6
        expect(state.totalThrottlingRequests, 10);
        expect(state.totalThrottlingAccepts, 6);
        expect(state.getThrottlingRequests(Criticality.critical), 10);
        expect(state.getThrottlingRequests(Criticality.sheddable), 0);

        // Critical (K = 2.0): P = max(0, (10 - 2.0 * 6) / 11) = 0.0
        // Sheddable (K = 1.2): P = max(0, (10 - 1.2 * 6) / 11) = 2.8 / 11 ≈ 0.2545 > 0
        final throttler = AdaptiveThrottler(resource.config, state);
        expect(throttler.rejectionProbability(Criticality.critical), 0.0);
        expect(
          throttler.rejectionProbability(Criticality.sheddable),
          closeTo(2.8 / 11, 0.001),
        );

        // Critical operations should never be throttled under this load
        int criticalThrottled = 0;
        for (int i = 0; i < 100; i++) {
          if (throttler.shouldThrottle(Criticality.critical)) {
            criticalThrottled++;
          }
        }
        expect(criticalThrottled, 0);

        // Critical operations execute successfully through context
        final res = await context.execute(
          criticalOp,
          () async => 'critical-ok',
        );
        expect(res, 'critical-ok');

        // Sheddable operations experience throttling through throttler and context
        int sheddableThrottled = 0;
        for (int i = 0; i < 1000; i++) {
          if (throttler.shouldThrottle(Criticality.sheddable)) {
            sheddableThrottled++;
          }
        }
        expect(sheddableThrottled, greaterThan(150));

        bool sheddableThrottledInContext = false;
        for (int i = 0; i < 100; i++) {
          try {
            await context.execute(sheddableOp, () async => 'sheddable-ok');
          } on ThrottledException {
            sheddableThrottledInContext = true;
            break;
          } catch (_) {}
        }
        expect(sheddableThrottledInContext, isTrue);
      },
    );

    test('minRequests aggregates traffic across all criticalities', () async {
      resource = Resource(
        'min-requests-service',
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 100,
          ),
          throttling: ThrottlingConfig(
            k: 1.0, // Any failure triggers throttling if requests >= minRequests
            minRequests: 20,
          ),
        ),
      );

      final shedOp = Operation(
        'shed',
        resource,
        criticality: Criticality.sheddable,
        retryOverride: RetryConfig(maxAttempts: 1),
      );
      final critOp = Operation(
        'crit',
        resource,
        criticality: Criticality.critical,
        retryOverride: RetryConfig(maxAttempts: 1),
      );

      // Record 10 failed sheddable requests and 9 failed critical requests (total = 19 < 20)
      for (int i = 0; i < 10; i++) {
        try {
          await context.execute(shedOp, () async => throw Exception('fail'));
        } catch (_) {}
      }
      for (int i = 0; i < 9; i++) {
        try {
          await context.execute(critOp, () async => throw Exception('fail'));
        } catch (_) {}
      }

      final state = context.states[resource.name]!;
      expect(state.totalThrottlingRequests, 19);
      final throttler = AdaptiveThrottler(resource.config, state);

      // Below minRequests (19 < 20): no throttling for any criticality
      expect(throttler.rejectionProbability(Criticality.sheddable), 0.0);
      expect(throttler.rejectionProbability(Criticality.critical), 0.0);

      // 1 more request reaches minRequests (20)
      try {
        await context.execute(critOp, () async => throw Exception('fail'));
      } catch (_) {}

      expect(state.totalThrottlingRequests, 20);
      // Now totalRequests = 20 >= minRequests (20), with 0 accepts, throttling kicks in
      expect(
        throttler.rejectionProbability(Criticality.sheddable),
        greaterThan(0.0),
      );
      expect(
        throttler.rejectionProbability(Criticality.critical),
        greaterThan(0.0),
      );
    });

    test(
      'rejection probabilities follow strict criticality ordering under degraded backend health',
      () {
        final config = ResourceConfig(
          throttling: ThrottlingConfig(k: 2.0, spread: 1.0),
        );
        final state = ResourceState(config);
        final throttler = AdaptiveThrottler(config, state);

        // 100 requests on critical operations: 40 accepted, 60 failed
        for (int i = 0; i < 40; i++) {
          state.requestHistory[Criticality.critical]!.add(
            RequestRecord(DateTime.now(), true),
          );
        }
        for (int i = 0; i < 60; i++) {
          state.requestHistory[Criticality.critical]!.add(
            RequestRecord(DateTime.now(), false),
          );
        }

        final pSheddable = throttler.rejectionProbability(
          Criticality.sheddable,
        );
        final pSheddablePlus = throttler.rejectionProbability(
          Criticality.sheddablePlus,
        );
        final pCritical = throttler.rejectionProbability(Criticality.critical);
        final pCriticalPlus = throttler.rejectionProbability(
          Criticality.criticalPlus,
        );

        // P = (100 - K * 40) / 101
        // sheddable: K=1.2 -> (100 - 48)/101 = 52/101 ≈ 0.5148
        // sheddablePlus: K=1.6 -> (100 - 64)/101 = 36/101 ≈ 0.3564
        // critical: K=2.0 -> (100 - 80)/101 = 20/101 ≈ 0.1980
        // criticalPlus: K=8.0 -> max(0, (100 - 320)/101) = 0.0
        expect(pSheddable, closeTo(52 / 101, 0.0001));
        expect(pSheddablePlus, closeTo(36 / 101, 0.0001));
        expect(pCritical, closeTo(20 / 101, 0.0001));
        expect(pCriticalPlus, 0.0);

        expect(pSheddable, greaterThan(pSheddablePlus));
        expect(pSheddablePlus, greaterThan(pCritical));
        expect(pCritical, greaterThan(pCriticalPlus));
      },
    );

    test(
      'totalThrottlingRequests and totalThrottlingAccepts aggregate across all criticalities',
      () {
        final config = ResourceConfig(throttling: ThrottlingConfig());
        final state = ResourceState(config);

        expect(state.totalThrottlingRequests, 0);
        expect(state.totalThrottlingAccepts, 0);

        state.recordRequest(true, Criticality.sheddable);
        state.recordRequest(false, Criticality.sheddablePlus);
        state.recordRequest(true, Criticality.critical);
        state.recordRequest(false, Criticality.criticalPlus);

        expect(state.totalThrottlingRequests, 4);
        expect(state.totalThrottlingAccepts, 2);

        expect(state.getThrottlingRequests(Criticality.sheddable), 1);
        expect(state.getThrottlingAccepts(Criticality.sheddable), 1);
        expect(state.getThrottlingRequests(Criticality.sheddablePlus), 1);
        expect(state.getThrottlingAccepts(Criticality.sheddablePlus), 0);
      },
    );
  });
}
