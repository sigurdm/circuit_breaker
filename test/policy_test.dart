import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('ResiliencePolicy - Basic properties & initialization', () {
    test('initial state and properties', () {
      final policy = ResiliencePolicy(
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 4),
        retry: RetryConfig(maxAttempts: 2),
        timeout: const Duration(seconds: 5),
      );

      expect(policy.circuitState, equals(CircuitState.closed));
      expect(policy.failureCount, equals(0));
      expect(
        policy.config.circuitBreaker.consecutiveFailuresThreshold,
        equals(4),
      );
      expect(policy.config.retry.maxAttempts, equals(2));
      expect(policy.config.timeout, equals(const Duration(seconds: 5)));
      expect(policy.state, isA<ResourceState>());
      expect(policy.resource, isA<Resource>());
      expect(policy.circuitBreaker, isA<CircuitBreaker>());
      expect(policy.throttler, isA<AdaptiveThrottler>());
    });

    test('executes successfully and returns result', () async {
      final policy = ResiliencePolicy();
      final result = await policy.execute(() async => 'success');

      expect(result, equals('success'));
      expect(policy.circuitState, equals(CircuitState.closed));
      expect(policy.failureCount, equals(0));
    });

    test('executes with non-critical criticality level', () async {
      final policy = ResiliencePolicy();
      final res1 = await policy.execute(
        () async => 'sheddable-ok',
        criticality: Criticality.sheddable,
      );
      expect(res1, equals('sheddable-ok'));

      final res2 = await policy.executeCancelable(
        (cancel) async => 'sheddable-cancelable-ok',
        criticality: Criticality.sheddable,
      );
      expect(res2, equals('sheddable-cancelable-ok'));
    });

    test('separate policies have independent state', () async {
      final policy1 = ResiliencePolicy(
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 1),
        retry: RetryConfig(maxAttempts: 1),
      );
      final policy2 = ResiliencePolicy(
        circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 1),
        retry: RetryConfig(maxAttempts: 1),
      );

      try {
        await policy1.execute(() async => throw Exception('err'));
      } catch (_) {}

      expect(policy1.circuitState, equals(CircuitState.open));
      expect(policy2.circuitState, equals(CircuitState.closed));
    });
  });

  group('ResiliencePolicy - Combining CircuitBreaker and Retry', () {
    test(
      'retries fail and trip circuit breaker mid-retry when threshold is reached',
      () async {
        var attempts = 0;
        final policy = ResiliencePolicy(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
          retry: RetryConfig(
            maxAttempts: 4,
            baseDelay: const Duration(milliseconds: 1),
            enableJitter: false,
            retryBudgetRatio: 1.0,
            minRequestsForBudget: 0,
          ),
          throttling: ThrottlingConfig(k: 100.0),
        );

        await expectLater(
          policy.execute(() async {
            attempts++;
            throw Exception('failing attempt $attempts');
          }),
          throwsA(isA<CircuitBreakerOpenException>()),
        );

        // Attempt 1 fails (failureCount=1)
        // Attempt 2 fails (failureCount=2 -> CB trips OPEN)
        // Attempt 3 fails fast before running because CB is OPEN!
        expect(attempts, equals(2));
        expect(policy.circuitState, equals(CircuitState.open));
        expect(policy.failureCount, equals(2));

        // Subsequent execution immediately fails fast
        expect(
          () => policy.execute(() async => 'should not run'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );
        expect(attempts, equals(2));
      },
    );

    test(
      'transient failures retry and succeed, keeping circuit breaker closed',
      () async {
        var attempts = 0;
        final policy = ResiliencePolicy(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
          retry: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(milliseconds: 1),
            enableJitter: false,
            retryBudgetRatio: 1.0,
            minRequestsForBudget: 0,
          ),
        );

        final result = await policy.execute(() async {
          attempts++;
          if (attempts < 3) {
            throw Exception('transient error $attempts');
          }
          return 'recovered';
        });

        expect(result, equals('recovered'));
        expect(attempts, equals(3));
        expect(policy.circuitState, equals(CircuitState.closed));
        expect(policy.failureCount, equals(0));
      },
    );

    test(
      'circuit breaker recovers via half-open state after reset timeout',
      () async {
        final policy = ResiliencePolicy(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1,
            resetTimeout: const Duration(milliseconds: 30),
            halfOpenSuccessThreshold: 2,
          ),
          retry: RetryConfig(maxAttempts: 1),
        );

        // Fail once to trip to open
        try {
          await policy.execute(() async => throw Exception('initial fail'));
        } catch (_) {}

        expect(policy.circuitState, equals(CircuitState.open));

        // Wait for reset timeout
        await Future<void>.delayed(const Duration(milliseconds: 40));

        // First trial success -> transitions to halfOpen
        final res1 = await policy.execute(() async => 'trial 1');
        expect(res1, equals('trial 1'));
        expect(policy.circuitState, equals(CircuitState.halfOpen));

        // Second trial success -> transitions to closed
        final res2 = await policy.execute(() async => 'trial 2');
        expect(res2, equals('trial 2'));
        expect(policy.circuitState, equals(CircuitState.closed));
        expect(policy.failureCount, equals(0));
      },
    );
  });

  group('ResiliencePolicy - Timeout enforcement', () {
    test('enforces timeout on long-running action', () async {
      final policy = ResiliencePolicy(
        timeout: const Duration(milliseconds: 50),
        retry: RetryConfig(maxAttempts: 1),
      );

      expect(
        () => policy.execute(() async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          return 'done';
        }),
        throwsA(isA<ResilienceTimeoutException>()),
      );
    });

    test(
      'cancelCompleter completes when timeout triggers in executeCancelable',
      () async {
        final policy = ResiliencePolicy(
          timeout: const Duration(milliseconds: 40),
          retry: RetryConfig(maxAttempts: 1),
        );

        final cancelObserved = Completer<void>();

        try {
          await policy.executeCancelable((cancelCompleter) async {
            unawaited(
              cancelCompleter.future.then((_) {
                if (!cancelObserved.isCompleted) cancelObserved.complete();
              }),
            );
            await Future<void>.delayed(const Duration(milliseconds: 150));
            return 'done';
          });
        } catch (_) {}

        await expectLater(cancelObserved.future, completes);
      },
    );
  });

  group('ResiliencePolicy - Decorators (wrap & wrapUnary)', () {
    test('wrap creates zero-argument decorated function', () async {
      var callCount = 0;
      final policy = ResiliencePolicy(
        retry: RetryConfig(
          maxAttempts: 3,
          baseDelay: const Duration(milliseconds: 1),
          enableJitter: false,
          retryBudgetRatio: 1.0,
          minRequestsForBudget: 0,
        ),
      );

      Future<int> getScore() async {
        callCount++;
        if (callCount < 2) throw Exception('temporary');
        return 100;
      }

      final wrapped = policy.wrap(getScore);
      final result = await wrapped();

      expect(result, equals(100));
      expect(callCount, equals(2));
    });

    test('wrapUnary creates single-argument decorated function', () async {
      var callCount = 0;
      final policy = ResiliencePolicy(
        retry: RetryConfig(
          maxAttempts: 2,
          baseDelay: const Duration(milliseconds: 1),
          enableJitter: false,
          retryBudgetRatio: 1.0,
          minRequestsForBudget: 0,
        ),
      );

      Future<String> fetchUser(int id) async {
        callCount++;
        if (callCount < 2) throw Exception('network error');
        return 'user_$id';
      }

      final wrappedUnary = policy.wrapUnary(fetchUser);
      final result = await wrappedUnary(42);

      expect(result, equals('user_42'));
      expect(callCount, equals(2));
    });

    test('wrap and wrapUnary respect retryOn filter', () async {
      var callCount = 0;
      final policy = ResiliencePolicy(
        retry: RetryConfig(
          maxAttempts: 3,
          baseDelay: const Duration(milliseconds: 1),
          enableJitter: false,
          retryBudgetRatio: 1.0,
          minRequestsForBudget: 0,
        ),
      );

      final wrapped = policy.wrap(() async {
        callCount++;
        throw FormatException('fatal error');
      }, retryOn: (e) => e is! FormatException);

      expect(() => wrapped(), throwsA(isA<FormatException>()));
      // Because retryOn returned false for FormatException, no retries were performed
      expect(callCount, equals(1));
    });
  });

  group('ResiliencePolicy - Parity with full ResilienceContext', () {
    test(
      'behaves identically to ResilienceContext for a single service',
      () async {
        // Configuration shared between both
        final cbConfig = CircuitBreakerConfig(consecutiveFailuresThreshold: 2);
        final retryConfig = RetryConfig(
          maxAttempts: 2,
          baseDelay: const Duration(milliseconds: 1),
          enableJitter: false,
          retryBudgetRatio: 1.0,
          minRequestsForBudget: 0,
        );
        final throttlingConfig = ThrottlingConfig(k: 100.0);

        // 1. Traditional ResilienceContext setup
        final context = ResilienceContext();
        final resource = Resource(
          'payment-service',
          config: ResourceConfig(
            circuitBreaker: cbConfig,
            retry: retryConfig,
            throttling: throttlingConfig,
          ),
        );
        final operation = Operation('charge', resource);

        // 2. Zero-boilerplate ResiliencePolicy setup
        final policy = ResiliencePolicy(
          circuitBreaker: cbConfig,
          retry: retryConfig,
          throttling: throttlingConfig,
        );

        // Step 1: Initial success
        final ctxRes1 = await context.execute(
          operation,
          () async => 'success_1',
        );
        final polRes1 = await policy.execute(() async => 'success_1');
        expect(polRes1, equals(ctxRes1));
        expect(
          policy.circuitState,
          equals(context.states[resource.name]!.circuitState),
        );
        expect(
          policy.failureCount,
          equals(context.states[resource.name]!.failureCount),
        );

        // Step 2: Consecutive failures exhausting retries
        Object? ctxError;
        try {
          await context.execute(
            operation,
            () async => throw StateError('fail_A'),
          );
        } catch (e) {
          ctxError = e;
        }

        Object? polError;
        try {
          await policy.execute(() async => throw StateError('fail_A'));
        } catch (e) {
          polError = e;
        }

        expect(polError, isA<StateError>());
        expect(ctxError, isA<StateError>());
        expect(
          policy.failureCount,
          equals(context.states[resource.name]!.failureCount),
        );
        expect(
          policy.circuitState,
          equals(context.states[resource.name]!.circuitState),
        );
        expect(policy.circuitState, equals(CircuitState.open));

        // Step 3: Both fail fast with CircuitBreakerOpenException on next call
        expect(
          () => context.execute(operation, () async => 'ok'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );
        expect(
          () => policy.execute(() async => 'ok'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );
      },
    );
  });

  group('ResiliencePolicy - Hedging, Throttling, and Custom Classifiers', () {
    test('supports request hedging', () async {
      final policy = ResiliencePolicy(
        hedging: HedgingConfig(
          enabled: true,
          delay: const Duration(milliseconds: 15),
          maxConcurrentHedges: 1,
        ),
        retry: RetryConfig(maxAttempts: 1),
      );

      var attemptCount = 0;
      final result = await policy.executeCancelable((cancelCompleter) async {
        attemptCount++;
        final currentAttempt = attemptCount;
        if (currentAttempt == 1) {
          // Slow first attempt
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return 'slow';
        } else {
          // Fast hedged attempt
          return 'fast hedge';
        }
      });

      expect(result, equals('fast hedge'));
      expect(attemptCount, equals(2));
    });

    test(
      'custom failureClassifier controls what counts as a failure',
      () async {
        final policy = ResiliencePolicy(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 1),
          retry: RetryConfig(maxAttempts: 1),
          failureClassifier: (e) => e is FormatException,
        );

        // Throw an error that is NOT a FormatException
        try {
          await policy.execute(() async => throw StateError('not a failure'));
        } catch (_) {}

        // Did not count as failure
        expect(policy.failureCount, equals(0));
        expect(policy.circuitState, equals(CircuitState.closed));

        // Throw FormatException
        try {
          await policy.execute(
            () async => throw FormatException('counts as failure'),
          );
        } catch (_) {}

        // Counted as failure and tripped circuit breaker
        expect(policy.failureCount, equals(1));
        expect(policy.circuitState, equals(CircuitState.open));
      },
    );
  });
  test('throws ArgumentError on invalid timeout', () {
    expect(() => ResiliencePolicy(timeout: Duration.zero), throwsArgumentError);
    expect(
      () => ResiliencePolicy(timeout: const Duration(seconds: -1)),
      throwsArgumentError,
    );
  });

  test('supports adaptive throttling rejection', () async {
    final policy = ResiliencePolicy(
      throttling: ThrottlingConfig(k: 1.1, minRequests: 2),
      circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 50),
      retry: RetryConfig(maxAttempts: 1),
    );

    // Record failures to drive up rejection probability
    for (int i = 0; i < 15; i++) {
      try {
        await policy.execute(() async => throw StateError('backend down'));
      } catch (_) {}
    }

    // Should now throw ThrottledException for some requests
    var throttledCount = 0;
    for (int i = 0; i < 50; i++) {
      try {
        await policy.execute(() async => 'success');
      } on ThrottledException {
        throttledCount++;
      } catch (_) {}
    }

    expect(throttledCount, greaterThan(0));
  });

  test('wrapUnary propagates arguments and returns typed results', () async {
    final policy = ResiliencePolicy();
    int multiplyByTwo(int n) => n * 2;

    final wrapped = policy.wrapUnary((int n) async => multiplyByTwo(n));
    expect(await wrapped(21), equals(42));
    expect(await wrapped(0), equals(0));
    expect(await wrapped(-5), equals(-10));
  });

  test('executeCancelable respects ambient cancellation token', () async {
    final policy = ResiliencePolicy();
    final token = CancellationToken();
    token.cancel();

    expect(
      () => ResilienceContext.runWithCancellationToken(
        token,
        () => policy.executeCancelable((_) async => 'should not run'),
      ),
      throwsA(isA<OperationCancelledException>()),
    );
  });
}
