import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('Cycle 8 Regression Tests', () {
    test(
      'Standalone CircuitBreaker permits re-entrant calls within active trial',
      () async {
        final cb = CircuitBreaker.standalone(
          config: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1,
            resetTimeout: const Duration(milliseconds: 20),
            halfOpenSuccessThreshold: 1,
          ),
        );

        // Trip to OPEN
        await expectLater(
          cb.execute(() async => throw Exception('outage')),
          throwsException,
        );
        expect(cb.state.circuitState, equals(CircuitState.open));

        // Wait for reset timeout to expire
        await Future.delayed(const Duration(milliseconds: 30));

        // Trial execution with nested helper calling cb.execute on same instance
        final result = await cb.execute(() async {
          // Inner re-entrant call
          final subResult = await cb.execute(() async => 'sub-ok');
          return 'root-$subResult';
        });

        expect(result, equals('root-sub-ok'));
        expect(cb.state.circuitState, equals(CircuitState.closed));
      },
    );

    test(
      'Fault Inversion: CircuitBreakerOpenException & ThrottledException are not server failures',
      () {
        final config = ResourceConfig();
        // Default classifier should return false for client resilience control exceptions
        expect(
          config.failureClassifier(CircuitBreakerOpenException('open')),
          isFalse,
        );
        expect(
          config.failureClassifier(const ThrottledException('throttled')),
          isFalse,
        );
        expect(
          config.failureClassifier(const OperationCancelledException()),
          isFalse,
        );
        expect(config.failureClassifier(Exception('server error')), isTrue);
      },
    );

    test(
      'ResilienceContext dynamic resource eviction APIs prevent memory leaks',
      () async {
        final context = ResilienceContext();
        final res1 = Resource('tenant-1');
        final res2 = Resource('tenant-2');

        await context.execute(res1, () async => 'ok');
        await context.execute(res2, () async => 'ok');

        expect(context.resourceCount, equals(2));
        expect(context.containsResource('tenant-1'), isTrue);
        expect(context.containsResource('tenant-2'), isTrue);

        // Evict tenant-1
        expect(context.removeResource('tenant-1'), isTrue);
        expect(context.containsResource('tenant-1'), isFalse);
        expect(context.resourceCount, equals(1));

        // Clear all
        context.clearResources();
        expect(context.resourceCount, equals(0));
      },
    );
  });
}
