import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('ResilienceContext with Hierarchy', () {
    late ResilienceContext context;
    late Resource resource;
    late Operation readOp;
    late Operation writeOp;

    setUp(() {
      context = ResilienceContext();
      resource = Resource(
        'my-service',
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
          throttling: ThrottlingConfig(
            k: 100.0,
          ), // Prevent throttling from interfering
        ),
      );
      readOp = Operation(
        'read',
        resource,
        hedgingOverride: HedgingConfig(
          enabled: true,
          delay: Duration(milliseconds: 10),
        ),
      );
      writeOp = Operation(
        'write',
        resource,
      ); // Uses defaults (hedging disabled)
    });

    test('shared circuit breaker state', () async {
      // Add successes to avoid adaptive throttling kicking in on failures
      for (int i = 0; i < 10; i++) {
        await context.execute(writeOp, () async => 'success');
      }

      // Cause 2 failures on write operation
      try {
        await context.execute(writeOp, () async => throw Exception('fail'));
      } catch (_) {}
      try {
        await context.execute(writeOp, () async => throw Exception('fail'));
      } catch (_) {}

      // Circuit should be open now for the resource
      expect(
        () => context.execute(readOp, () async => 'success'),
        throwsA(
          predicate((e) => e.toString().contains('Circuit breaker is open')),
        ),
      );
    });

    test('independent hedging configuration', () async {
      // Read operation has hedging enabled
      final readCompleter = Completer<String>();

      // We don't complete it immediately to trigger hedging
      final future = context.executeCancelable(readOp, (cancel) async {
        if (cancel.isCompleted) return 'cancelled';
        return await readCompleter.future;
      });

      int calls = 0;
      final future2 = context.executeCancelable(readOp, (cancel) async {
        calls++;
        if (calls == 2) return 'hedged';
        await Future.delayed(const Duration(milliseconds: 100));
        return 'slow';
      });

      expect(await future2, equals('hedged'));

      // Clean up the first request
      readCompleter.complete('done');
      await future;
    });
  });

  group('ResilienceContext with Parent-Child Hierarchy', () {
    late ResilienceContext context;
    late Resource parent;
    late Resource child;
    late Operation parentOp;
    late Operation childOp;

    setUp(() {
      context = ResilienceContext();
      parent = Resource(
        'parent-service',
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 2,
            resetTimeout: const Duration(milliseconds: 100),
            halfOpenSuccessThreshold: 2,
          ),
          retry: RetryConfig(maxAttempts: 1),
          throttling: ThrottlingConfig(minRequests: 100),
        ),
      );
      child = Resource(
        'child-service',
        parent: parent,
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 2,
            resetTimeout: const Duration(milliseconds: 100),
            halfOpenSuccessThreshold: 1,
          ),
          retry: RetryConfig(maxAttempts: 1),
          throttling: ThrottlingConfig(minRequests: 100),
        ),
      );
      parentOp = Operation('parentOp', parent);
      childOp = Operation('childOp', child);
    });

    test('open parent blocks child', () async {
      // Trip parent
      try {
        await context.execute(parentOp, () async => throw Exception('fail'));
      } catch (_) {}
      try {
        await context.execute(parentOp, () async => throw Exception('fail'));
      } catch (_) {}

      // Parent should be open
      expect(
        context.states['parent-service']?.circuitState,
        equals(CircuitState.open),
      );

      // Child should be blocked
      expect(
        () => context.execute(childOp, () async => 'success'),
        throwsA(
          predicate(
            (e) =>
                e is CircuitBreakerOpenException &&
                e.toString().contains(
                  'Circuit breaker is open for parent-service',
                ),
          ),
        ),
      );
    });

    test('child failure does not trip parent (selectivity)', () async {
      // Trip child
      try {
        await context.execute(childOp, () async => throw Exception('fail'));
      } catch (_) {}
      try {
        await context.execute(childOp, () async => throw Exception('fail'));
      } catch (_) {}

      // Child should be open
      expect(
        context.states['child-service']?.circuitState,
        equals(CircuitState.open),
      );

      // Parent should remain closed
      expect(
        context.states['parent-service']?.circuitState,
        equals(CircuitState.closed),
      );

      // Requests to parent should succeed
      final res = await context.execute(parentOp, () async => 'parent-success');
      expect(res, equals('parent-success'));
    });

    test('parent recovery via child request (deadlock avoidance)', () async {
      // Trip parent (threshold 2)
      try {
        await context.execute(parentOp, () async => throw Exception('fail'));
      } catch (_) {}
      try {
        await context.execute(parentOp, () async => throw Exception('fail'));
      } catch (_) {}
      expect(
        context.states['parent-service']?.circuitState,
        equals(CircuitState.open),
      );

      // Child is blocked
      expect(
        () => context.execute(childOp, () async => 'success'),
        throwsA(isA<CircuitBreakerOpenException>()),
      );

      // Wait for reset timeout of parent (100ms)
      await Future.delayed(const Duration(milliseconds: 120));

      // Parent reset timeout expired. Child request should be allowed as trial for parent.
      // Parent needs 2 successes to close (halfOpenSuccessThreshold: 2).

      // Trial 1: Success
      final res1 = await context.execute(childOp, () async => 'success1');
      expect(res1, equals('success1'));
      expect(
        context.states['parent-service']?.circuitState,
        equals(CircuitState.halfOpen),
      );
      expect(context.states['parent-service']?.halfOpenSuccessCount, equals(1));

      // Trial 2: Success -> Closes parent
      final res2 = await context.execute(childOp, () async => 'success2');
      expect(res2, equals('success2'));
      expect(
        context.states['parent-service']?.circuitState,
        equals(CircuitState.closed),
      );
    });

    test('sequential trials enforced hierarchically', () async {
      // Trip parent
      try {
        await context.execute(parentOp, () async => throw Exception('fail'));
      } catch (_) {}
      try {
        await context.execute(parentOp, () async => throw Exception('fail'));
      } catch (_) {}

      // Wait for reset timeout
      await Future.delayed(const Duration(milliseconds: 120));

      // Start a slow trial on child
      final trialCompleter = Completer<String>();
      final trialFuture = context.execute(childOp, () async {
        return await trialCompleter.future;
      });

      // Wait a bit to ensure trial is registered
      await Future.delayed(const Duration(milliseconds: 10));
      expect(
        context.states['parent-service']?.circuitState,
        equals(CircuitState.halfOpen),
      );
      expect(context.states['parent-service']?.trialRequestInProgress, isTrue);

      // Concurrent request on child (or parent) should be blocked because parent trial is in progress
      expect(
        () => context.execute(childOp, () async => 'success'),
        throwsA(
          predicate(
            (e) =>
                e is CircuitBreakerOpenException &&
                e.toString().contains(
                  'Circuit breaker is half-open for parent-service',
                ),
          ),
        ),
      );

      // Complete the trial
      trialCompleter.complete('trial-success');
      expect(await trialFuture, equals('trial-success'));
    });
  });
}
