import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Retry Math & Overflow Regression Tests', () {
    test(
      'baseDelay = Duration.zero does not produce NaN or throw at high attempt counts',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'zero-delay-service',
          config: ResourceConfig(
            retry: RetryConfig(maxAttempts: 1050, baseDelay: Duration.zero),
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2000,
            ),
            throttling: ThrottlingConfig(k: 100.0),
          ),
        );
        final op = Operation('call', resource);

        int attempts = 0;
        final result = await context.execute(op, () async {
          attempts++;
          if (attempts < 5) {
            throw Exception('retry me');
          }
          return 'done';
        });

        expect(result, equals('done'));
        expect(attempts, equals(5));
      },
    );

    test(
      'large maxDelay does not throw Random.nextInt bounds violation RangeError',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'large-max-delay-service',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: const Duration(milliseconds: 1),
              maxDelay: const Duration(
                days: 60,
              ), // > 49.7 days would overflow 32-bit int
              enableJitter: true,
            ),
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 10,
            ),
            throttling: ThrottlingConfig(k: 100.0),
          ),
        );
        final op = Operation('call', resource);

        int attempts = 0;
        final result = await context.execute(op, () async {
          attempts++;
          if (attempts == 1) {
            throw Exception('retry me');
          }
          return 'success';
        });

        expect(result, equals('success'));
        expect(attempts, equals(2));
      },
    );
  });
}
