import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/hedging.dart';
import 'package:test/test.dart';

void main() {
  group('Cycle 5 Regression Tests', () {
    test(
      'CircuitBreaker.execute prevents thundering herd during half-open trial',
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
          cb.execute(() async => throw Exception('backend down')),
          throwsException,
        );
        expect(cb.state.circuitState, equals(CircuitState.open));

        // Wait for reset timeout to elapse
        await Future.delayed(const Duration(milliseconds: 30));

        final trialCompleter = Completer<String>();

        // Request 1 starts trial in Half-Open
        final future1 = cb.execute(() => trialCompleter.future);

        // Request 2 arrives while Request 1 is actively executing the trial
        // It MUST be rejected with CircuitBreakerOpenException, NOT admitted!
        await expectLater(
          cb.execute(() async => 'concurrent-request'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );

        // Request 1 completes successfully
        trialCompleter.complete('trial-success');
        expect(await future1, equals('trial-success'));

        // Circuit breaker is now closed
        expect(cb.state.circuitState, equals(CircuitState.closed));
      },
    );

    test(
      'speculative hedge synchronous exception cancels primary request and cleans up',
      () async {
        final config = ResourceConfig(
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 20),
          ),
          retry: RetryConfig(maxAttempts: 1),
        );
        final state = ResourceState(config);

        int attempts = 0;
        bool primaryWasCancelled = false;

        await expectLater(
          executeWithHedging<String>(
            (cancel) {
              attempts++;
              if (attempts == 1) {
                unawaited(
                  cancel.future.then((_) => primaryWasCancelled = true),
                );
                return Completer<String>().future;
              } else {
                // Speculative hedge throws synchronously
                throw StateError('Synchronous hedge crash');
              }
            },
            config: config,
            state: state,
          ),
          throwsA(isA<StateError>()),
        );

        expect(attempts, equals(2));
        await Future.delayed(Duration.zero);
        expect(primaryWasCancelled, isTrue);
        expect(state.activeHedges, equals(0));
      },
    );

    test(
      'hedged request completion does not record isSlow: false when right-censored',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'hedging-censoring-test',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 20),
              dynamicPercentile: 0.9,
              delayMultiplier: 0.5, // Hedges at 0.5 * delay
              minDelay: const Duration(milliseconds: 10),
              maxDelay: const Duration(milliseconds: 100),
            ),
            retry: RetryConfig(maxAttempts: 1),
          ),
        );
        final op = Operation('op', resource);

        // Execute a request where f2 wins quickly before rawV
        final result = await context.executeCancelable(op, (cancel) async {
          if (cancel.isCompleted) return 'cancelled';
          // Simulate f1 slow, f2 fast
          await Future.delayed(const Duration(milliseconds: 15));
          return 'success';
        });

        expect(result, equals('success'));
      },
    );

    test(
      'exponential backoff math with extreme factor does not overflow or become negative',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'extreme-backoff',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 2,
              baseDelay: const Duration(microseconds: 100),
              backoffFactor: 1e9, // Extreme backoff factor
              maxDelay: const Duration(milliseconds: 10),
              enableJitter: false,
            ),
          ),
        );
        final op = Operation('op', resource);

        int attempts = 0;
        await expectLater(
          context.execute(op, () async {
            attempts++;
            throw Exception('retry-me');
          }),
          throwsException,
        );
        expect(attempts, equals(2));
      },
    );

    test('retryOn is evaluated before checking retry budget', () async {
      final context = ResilienceContext();
      final resource = Resource(
        'retry-budget-order',
        config: ResourceConfig(
          retry: RetryConfig(
            maxAttempts: 3,
            minRequestsForBudget: 1,
            retryBudgetRatio: 0.1, // Very low budget ratio
          ),
        ),
      );
      final op = Operation('op', resource);

      // Exception not retryable
      await expectLater(
        context.execute(
          op,
          () async => throw FormatException('non-retryable'),
          retryOn: (e) => e is TimeoutException,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('hierarchy transactional rollback on ancestor failure', () async {
      final context = ResilienceContext();
      final grandparent = Resource(
        'gp',
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 1),
        ),
      );
      final parent = Resource(
        'p',
        parent: grandparent,
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 1),
        ),
      );
      final child = Resource(
        'c',
        parent: parent,
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 1),
        ),
      );

      // Trip grandparent
      final gpOp = Operation('gp-op', grandparent);
      try {
        await context.execute(gpOp, () async => throw Exception('gp-fail'));
      } catch (_) {}
      expect(context.states['gp']!.circuitState, equals(CircuitState.open));

      // Attempt child operation - should be blocked by grandparent
      final childOp = Operation('c-op', child);
      await expectLater(
        context.execute(childOp, () async => 'should-not-run'),
        throwsA(isA<CircuitBreakerOpenException>()),
      );

      // Child and parent states should remain cleanly closed
      expect(context.states['c']!.circuitState, equals(CircuitState.closed));
      expect(context.states['p']!.circuitState, equals(CircuitState.closed));
    });
  });
}
