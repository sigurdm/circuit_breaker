import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Cancellation & Error Classifier Regression Tests', () {
    late ResilienceContext context;
    late Resource resource;
    late Operation op;

    setUp(() {
      context = ResilienceContext();
      resource = Resource(
        'classifier-service',
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 3,
            resetTimeout: const Duration(seconds: 5),
          ),
          throttling: ThrottlingConfig(k: 2.0),
        ),
      );
      op = Operation('call', resource);
    });

    test(
      'user cancellations do not increment failureCount or trip circuit breaker',
      () async {
        final state =
            context.states['classifier-service'] ??
            context.states.putIfAbsent(
              'classifier-service',
              () => ResourceState(resource.config),
            );

        // Execute 5 cancelled requests
        for (int i = 0; i < 5; i++) {
          final cancelToken = CancellationToken()..cancel();
          try {
            await ResilienceContext.runWithCancellationToken(cancelToken, () {
              return context.execute(op, () async => 'success');
            });
          } catch (_) {}
        }

        expect(state.failureCount, equals(0));
        expect(state.circuitState, equals(CircuitState.closed));
        expect(state.getThrottlingRequests(Criticality.critical), equals(0));
      },
    );

    test('client programmer errors do not trip circuit breaker', () async {
      final state =
          context.states['classifier-service'] ??
          context.states.putIfAbsent(
            'classifier-service',
            () => ResourceState(resource.config),
          );

      // Throw ArgumentError, FormatException, RangeError
      try {
        await context.execute(
          op,
          () async => throw ArgumentError('invalid param'),
        );
      } catch (_) {}

      try {
        await context.execute(
          op,
          () async => throw const FormatException('bad json'),
        );
      } catch (_) {}

      try {
        await context.execute(
          op,
          () async => throw RangeError('index out of range'),
        );
      } catch (_) {}

      expect(state.failureCount, equals(0));
      expect(state.circuitState, equals(CircuitState.closed));
    });

    test('actual backend exceptions still trip circuit breaker', () async {
      final state =
          context.states['classifier-service'] ??
          context.states.putIfAbsent(
            'classifier-service',
            () => ResourceState(resource.config),
          );

      for (int i = 0; i < 3; i++) {
        try {
          await context.execute(
            op,
            () async => throw Exception('503 Service Unavailable'),
          );
        } catch (_) {}
      }

      expect(state.failureCount, equals(3));
      expect(state.circuitState, equals(CircuitState.open));
    });
  });
}
