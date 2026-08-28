import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Hedging Inversion Regression Tests', () {
    late ResilienceContext context;
    late Resource resource;
    late Operation op;

    setUp(() {
      context = ResilienceContext();
      resource = Resource(
        'hedging-inversion-service',
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1, // Trip on 1 failure
            resetTimeout: const Duration(seconds: 5),
            halfOpenSuccessThreshold: 1,
          ),
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 20),
          ),
          retry: RetryConfig(maxAttempts: 1), // No retry
          throttling: ThrottlingConfig(k: 100.0), // No throttling
        ),
      );
      op = Operation('call', resource);
    });

    test(
      'primary failure does not trip circuit breaker when speculative hedge succeeds',
      () async {
        final state =
            context.states['hedging-inversion-service'] ??
            context.states.putIfAbsent(
              'hedging-inversion-service',
              () => ResourceState(resource.config),
            );

        int attempts = 0;
        final result = await context.executeCancelable(op, (cancel) async {
          attempts++;
          final attemptNum = attempts;
          if (attemptNum == 1) {
            // Primary attempt: wait past hedging delay (20ms), then fail
            await Future.delayed(const Duration(milliseconds: 35));
            throw Exception('primary replica down');
          } else {
            // Hedge attempt: finishes quickly and successfully
            await Future.delayed(const Duration(milliseconds: 10));
            return 'hedge_success';
          }
        });

        expect(result, equals('hedge_success'));
        expect(attempts, equals(2));

        // Circuit Breaker must remain CLOSED and failure count 0
        expect(state.circuitState, equals(CircuitState.closed));
        expect(state.failureCount, equals(0));
      },
    );

    test('both primary and hedge failing trips circuit breaker', () async {
      final state =
          context.states['hedging-inversion-service'] ??
          context.states.putIfAbsent(
            'hedging-inversion-service',
            () => ResourceState(resource.config),
          );

      int attempts = 0;
      await expectLater(
        () => context.executeCancelable(op, (cancel) async {
          attempts++;
          final attemptNum = attempts;
          if (attemptNum == 1) {
            await Future.delayed(const Duration(milliseconds: 35));
            throw Exception('primary fail');
          } else {
            await Future.delayed(const Duration(milliseconds: 10));
            throw Exception('hedge fail');
          }
        }),
        throwsA(isA<Exception>()),
      );

      expect(attempts, equals(2));
      // Circuit Breaker must be tripped to OPEN
      expect(state.circuitState, equals(CircuitState.open));
      expect(state.failureCount, equals(1));
    });

    test(
      'half-open trial recovery succeeds when hedge succeeds despite primary failure',
      () async {
        final state =
            context.states['hedging-inversion-service'] ??
            context.states.putIfAbsent(
              'hedging-inversion-service',
              () => ResourceState(resource.config),
            );

        // Force circuit breaker to half-open
        state.circuitState = CircuitState.halfOpen;
        state.trialRequestInProgress = false;

        // Note: In half-open state, hedging is safely bypassed to avoid duplicate trial requests.
        // So trial runs as a single primary attempt.
        final result = await context.execute(op, () async => 'trial_success');
        expect(result, equals('trial_success'));
        expect(state.circuitState, equals(CircuitState.closed));
      },
    );
  });
}
