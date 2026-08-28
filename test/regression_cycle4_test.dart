import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Cycle 4 Regression Tests', () {
    test(
      'CircuitBreaker.isAllowed does not deadlock Half-Open state when queried before execute',
      () async {
        final cb = CircuitBreaker.standalone(
          config: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1,
            resetTimeout: const Duration(milliseconds: 20),
            halfOpenSuccessThreshold: 1,
          ),
        );

        // Trip the circuit breaker to OPEN
        await expectLater(
          cb.execute(() async => throw Exception('backend failure')),
          throwsException,
        );
        expect(cb.state.circuitState, equals(CircuitState.open));

        // Wait for reset timeout to elapse
        await Future.delayed(const Duration(milliseconds: 30));

        // Query isAllowed in an idiomatic if-check
        expect(cb.isAllowed, isTrue);

        // The subsequent execute MUST succeed and NOT deadlock or throw CircuitBreakerOpenException
        final result = await cb.execute(() async => 'recovered');
        expect(result, equals('recovered'));
        expect(cb.state.circuitState, equals(CircuitState.closed));
      },
    );

    test(
      'CircuitBreaker.standalone() works with default constructor parameters',
      () {
        final cb = CircuitBreaker.standalone();
        expect(cb.isAllowed, isTrue);
        expect(
          cb.config.circuitBreaker.consecutiveFailuresThreshold,
          equals(5),
        );
      },
    );

    test(
      'AdaptiveThrottler.execute runs action and throws ThrottledException when throttled',
      () async {
        final throttler = AdaptiveThrottler.standalone(
          config: ThrottlingConfig(k: 1.1, minRequests: 2),
        );

        // Successfully execute action
        final res = await throttler.execute(() async => 'success');
        expect(res, equals('success'));

        // Cause failures to trigger throttling
        for (int i = 0; i < 5; i++) {
          throttler.recordRequest(false);
        }

        // Rejection probability is high
        expect(
          throttler.rejectionProbability(Criticality.critical),
          greaterThan(0.5),
        );

        // Attempting execute should eventually throw ThrottledException
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
      'pre-flight rejection detaches execution token from parent token',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'preflight-detach',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
            ),
          ),
        );
        final op = Operation('op', resource);

        // Trip breaker to Open
        try {
          await context.execute(op, () async => throw Exception('fail'));
        } catch (_) {}

        final parentToken = CancellationToken();

        // Execute while circuit is open under parentToken
        await ResilienceContext.runWithCancellationToken(parentToken, () async {
          try {
            await context.execute(op, () async => 'unreachable');
          } catch (_) {}
        });

        // Cancellation on parent token should not throw or have lingering references
        expect(parentToken.isCancelled, isFalse);
        parentToken.cancel();
        expect(parentToken.isCancelled, isTrue);
      },
    );

    test(
      'executeCancelable fails fast immediately when parent token is already cancelled',
      () async {
        final context = ResilienceContext();
        final resource = Resource('already-cancelled');
        final op = Operation('op', resource);

        final parentToken = CancellationToken()..cancel();

        await ResilienceContext.runWithCancellationToken(parentToken, () async {
          expect(
            () => context.execute(op, () async => 'should not run'),
            throwsA(isA<OperationCancelledException>()),
          );
        });
      },
    );

    test(
      'executeWithHedging pre-hedge cancellation throws OperationCancelledException immediately',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'hedge-cancel-fast',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 100),
            ),
            timeout: const Duration(milliseconds: 20),
          ),
        );
        final op = Operation('op', resource);

        final sw = Stopwatch()..start();
        await expectLater(
          context.executeCancelable(op, (cancel) async {
            // Primary hangs for 1 second
            await Future.delayed(const Duration(seconds: 1));
            return 'done';
          }),
          throwsA(isA<ResilienceTimeoutException>()),
        );
        sw.stop();

        // Must complete promptly around the 20ms timeout, NOT hanging for 1s
        expect(sw.elapsedMilliseconds, lessThan(150));
      },
    );

    test(
      'failureClassifier is respected on top-level timeout in executeCancelable',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'timeout-classifier-test',
          config: ResourceConfig(
            timeout: const Duration(milliseconds: 20),
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
            ),
            // Explicitly classify timeouts as non-failures:
            failureClassifier: (e) => e is! ResilienceTimeoutException,
          ),
        );
        final op = Operation('op', resource);

        // Run operation that times out
        try {
          await context.execute(op, () async {
            await Future.delayed(const Duration(milliseconds: 100));
            return 'ok';
          });
        } catch (_) {}

        final state = context.states['timeout-classifier-test']!;
        // Circuit breaker should NOT have tripped because failureClassifier excluded timeout
        expect(state.circuitState, equals(CircuitState.closed));
        expect(state.failureCount, equals(0));
      },
    );

    test(
      'RetryConfig with jitter enabled produces sub-millisecond delays without truncation',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'jitter-sub-ms',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: const Duration(microseconds: 500),
              backoffFactor: 2.0,
              enableJitter: true,
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
  });
}
