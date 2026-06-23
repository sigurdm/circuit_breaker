import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('ResilienceContext Improvements', () {
    late ResilienceContext context;
    late Resource resource;
    late Operation op;

    setUp(() {
      context = ResilienceContext();
    });

    group('Timeout', () {
      test(
        'throws ResilienceTimeoutException, cancels action, and trips CB',
        () async {
          resource = Resource(
            'timeout-service',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 2,
              ),
              throttling: ThrottlingConfig(k: 100.0),
              timeout: Duration(milliseconds: 50),
            ),
          );
          op = Operation('call', resource);

          // Warmup to avoid throttling
          for (int i = 0; i < 10; i++) {
            await context.execute(op, () async => 'success');
          }

          final cancelCompleter = Completer<void>();
          final actionCompleter = Completer<String>();

          // 1st timeout
          final execution = context.executeCancelable(op, (cancel) async {
            unawaited(
              cancel.future.then((_) {
                if (!cancelCompleter.isCompleted) cancelCompleter.complete();
              }),
            );
            return await actionCompleter.future;
          });

          await expectLater(
            execution,
            throwsA(isA<ResilienceTimeoutException>()),
          );

          await Future.delayed(
            Duration.zero,
          ); // Yield to event loop to allow cancel listeners to run
          expect(cancelCompleter.isCompleted, isTrue);

          // 2nd timeout (using simple execute)
          await expectLater(
            context.execute(op, () async {
              await Future.delayed(const Duration(milliseconds: 100));
              return 'success';
            }),
            throwsA(isA<ResilienceTimeoutException>()),
          );

          // 3rd call should fail immediately with CircuitBreakerOpenException
          bool actionCalled = false;
          await expectLater(
            context.execute(op, () async {
              actionCalled = true;
              return 'success';
            }),
            throwsA(isA<CircuitBreakerOpenException>()),
          );
          expect(actionCalled, isFalse);
        },
      );
    });

    group('Failure Classifier', () {
      test('ignores application errors (non-failures)', () async {
        resource = Resource(
          'classifier-service',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
            ),
            throttling: ThrottlingConfig(
              k: 100.0,
            ), // Prevent throttling from interfering
            failureClassifier: (e) =>
                e is! ArgumentError, // ArgumentError is NOT a failure
          ),
        );
        op = Operation('call', resource);

        // Cause 2 ArgumentErrors
        try {
          await context.execute(op, () async => throw ArgumentError('bad arg'));
        } catch (_) {}
        try {
          await context.execute(op, () async => throw ArgumentError('bad arg'));
        } catch (_) {}

        // Circuit should still be CLOSED because they were not failures
        final result = await context.execute(op, () async => 'success');
        expect(result, 'success');
      });

      test('trips on system failures', () async {
        resource = Resource(
          'classifier-service-2',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
            ),
            throttling: ThrottlingConfig(
              k: 100.0,
            ), // Prevent throttling from interfering
            failureClassifier: (e) => e is! ArgumentError,
          ),
        );
        op = Operation('call', resource);

        // Warmup to avoid throttling
        for (int i = 0; i < 10; i++) {
          await context.execute(op, () async => 'success');
        }

        // Cause 2 regular Exceptions (failures)
        try {
          await context.execute(op, () async => throw Exception('system fail'));
        } catch (_) {}
        try {
          await context.execute(op, () async => throw Exception('system fail'));
        } catch (_) {}

        // Circuit should be OPEN
        await expectLater(
          context.execute(op, () async => 'success'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );
      });
    });

    group('Rolling Retry Budget', () {
      test('cleans up old attempts and enforces budget only on recent ones', () async {
        resource = Resource(
          'budget-service',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              minRequestsForBudget: 5,
              retryBudgetRatio: 0.1, // 10%
              budgetWindow: Duration(seconds: 1),
            ),
          ),
        );
        op = Operation('call', resource);

        // Trigger initialization of state by running one successful call
        await context.execute(op, () async => 'success');
        final state = context.states[resource.name]!;

        // Manually add 10 OLD successful requests (older than 1 second)
        final oldTime = DateTime.now().subtract(const Duration(seconds: 2));
        for (int i = 0; i < 10; i++) {
          state.retryHistory.add(RetryAttemptRecord(oldTime, isRetry: false));
        }

        // If we didn't clean up, we would have 11 total requests, 0 retries.
        // We could retry because budget ratio is 10%, and we have plenty of "credit".
        // But cleanHistory should run and remove the 10 old ones, leaving only 1 recent success.

        // Now cause a failure.
        // Recent history: 1 success.
        // We try to retry.
        // New attempt (retry) would make it: 1 success + 1 failure + 1 retry = 3 attempts, 1 retry (33% ratio).
        // Since 33% > 10%, and total requests (3) is NOT > minRequestsForBudget (5)?
        // Wait, if minRequestsForBudget is 5, we need at least 5 requests in history to enforce.
        // If we only have 1 recent success + 1 failure = 2 requests.
        // 2 is not > 5, so budget is NOT enforced yet!
        // Let's add 5 recent successes to cross the minRequestsForBudget.
        for (int i = 0; i < 5; i++) {
          await context.execute(op, () async => 'success');
        }
        // Now we have 6 recent successes.
        // Total requests in window = 6. Retries = 0.
        // We cause a failure.
        // Attempt 1: fails. (recorded as isRetry: false). Total requests = 7.
        // We want to retry.
        // If we retry, it would be 1 retry.
        // Total requests if we retry = 8 (6 success + 1 fail + 1 retry).
        // Total retries = 1.
        // Ratio = 1/8 = 12.5% > 10%.
        // So it should be BLOCKED because 12.5% exceeds 10% budget, and total requests (8) > min (5).

        // If OLD requests were NOT cleaned up, we would have:
        // 10 old success + 6 recent success + 1 fail = 17 requests.
        // If we retry: 18 requests, 1 retry. Ratio = 1/18 = 5.5% < 10%.
        // It would be ALLOWED.

        // So, if it is BLOCKED, it proves old requests were cleaned up.
        int attempts = 0;
        await expectLater(
          context.execute(op, () async {
            attempts++;
            throw Exception('fail');
          }),
          throwsException,
        );

        expect(attempts, 1); // Only 1 attempt, retry was blocked.
      });
    });

    group('Throttling Retries', () {
      test('records internal retries in throttling history', () async {
        resource = Resource(
          'throttling-retries-service',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: Duration(milliseconds: 1),
            ),
          ),
        );
        op = Operation('call', resource);

        // Run one successful call to init state
        await context.execute(op, () async => 'success');
        final state = context.states[resource.name]!;

        // Clear history to start clean
        state.requestHistory[Criticality.critical]!.clear();

        // Run call that fails and retries 2 times (total 3 attempts)
        try {
          await context.execute(op, () async {
            throw Exception('fail');
          });
        } catch (_) {}

        // We expect 3 records in requestHistory (all failed/not accepted)
        final history = state.requestHistory[Criticality.critical]!;
        expect(history.length, 3);
        expect(history.every((r) => !r.accepted), isTrue);
      });
    });

    group('ResourceConfig', () {
      test('defaultConfig creates default config', () {
        final config = ResourceConfig.defaultConfig();
        expect(config.timeout, isNull);
        expect(config.circuitBreaker.consecutiveFailuresThreshold, equals(5));
      });
    });

    group('Exceptions toString', () {
      test('CircuitBreakerOpenException toString', () {
        final e = CircuitBreakerOpenException('open');
        expect(e.toString(), contains('CircuitBreakerOpenException: open'));
      });

      test('ResilienceTimeoutException toString', () {
        final e = ResilienceTimeoutException('timeout');
        expect(e.toString(), contains('ResilienceTimeoutException: timeout'));
      });

      test('ThrottledException toString', () {
        final e = ThrottledException('throttled');
        expect(e.toString(), contains('ThrottledException: throttled'));
      });
    });

    group('Throttling Integration', () {
      test('throws ThrottledException when throttling kicks in', () async {
        resource = Resource(
          'throttling-service',
          config: ResourceConfig(
            throttling: ThrottlingConfig(
              k: 1.0, // Strict throttling
              windowDuration: Duration(seconds: 10),
            ),
          ),
        );
        op = Operation(
          'call',
          resource,
          retryOverride: RetryConfig(maxAttempts: 1),
        );

        // Cause 5 failures to trigger throttling (accepts = 0)
        for (int i = 0; i < 5; i++) {
          try {
            await context.execute(op, () async => throw Exception('fail'));
          } catch (_) {}
        }

        // Next call should have high probability of being throttled.
        bool throttled = false;
        for (int i = 0; i < 20; i++) {
          try {
            await context.execute(op, () async => 'success');
          } on ThrottledException catch (e) {
            throttled = true;
            expect(
              e.message,
              contains('Request throttled for throttling-service'),
            );
            break;
          } catch (_) {}
        }
        expect(throttled, isTrue);
      });
    });

    group('Hedging Gaps', () {
      test('fails immediately if f1 fails before delay', () async {
        resource = Resource(
          'hedging-fail-service',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: Duration(milliseconds: 100),
            ),
            retry: RetryConfig(
              maxAttempts: 1,
            ), // Disable retry to see immediate failure
          ),
        );
        op = Operation('call', resource);

        int attempts = 0;
        final execution = context.execute(op, () async {
          attempts++;
          if (attempts == 1) {
            throw Exception('immediate fail');
          }
          return 'success';
        });

        await expectLater(
          execution,
          throwsA(predicate((e) => e.toString().contains('immediate fail'))),
        );
        expect(attempts, 1); // No second attempt started
      });

      test('throws error if both hedges fail', () async {
        resource = Resource(
          'hedging-both-fail-service',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: Duration(milliseconds: 10),
            ),
            retry: RetryConfig(maxAttempts: 1),
          ),
        );
        op = Operation('call', resource);

        int attempts = 0;
        final execution = context.executeCancelable(op, (cancel) async {
          attempts++;
          if (attempts == 1) {
            await Future.delayed(const Duration(milliseconds: 50));
            throw Exception('f1 fail');
          } else {
            throw Exception('f2 fail');
          }
        });

        await expectLater(
          execution,
          throwsA(predicate((e) => e.toString().contains('f1 fail'))),
        );

        expect(attempts, 2);
      });
    });

    group('Pattern Wrapping Order', () {
      test('Circuit Breaker is checked before Adaptive Throttling', () async {
        resource = Resource(
          'cb-vs-throttling',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
            ),
            throttling: ThrottlingConfig(k: 1.0),
          ),
        );
        op = Operation('call', resource);

        // Warm up / initialize state
        await context.execute(op, () async => 'success');

        final state = context.states[resource.name]!;

        // Force Throttling to be active by adding many failures
        for (int i = 0; i < 10000; i++) {
          state.requestHistory[op.criticality]!.add(
            RequestRecord(DateTime.now(), false),
          );
        }
        expect(state.requestHistory[op.criticality]!.length, 10001);

        // Trip the Circuit Breaker manually
        state.circuitState = CircuitState.open;
        state.lastFailureTime = DateTime.now();

        // Execution should throw CircuitBreakerOpenException, not ThrottledException
        await expectLater(
          context.execute(op, () async => 'success'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );
      });

      test(
        'Adaptive Throttling is bypassed when Circuit Breaker is Half-Open',
        () async {
          resource = Resource(
            'half-open-bypass',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 2,
                resetTimeout: Duration(milliseconds: 50),
              ),
              throttling: ThrottlingConfig(k: 1.0),
            ),
          );
          op = Operation('call', resource);

          // Warm up / initialize state
          await context.execute(op, () async => 'success');

          final state = context.states[resource.name]!;

          // Force Throttling to be active by adding many failures
          for (int i = 0; i < 10000; i++) {
            state.requestHistory[op.criticality]!.add(
              RequestRecord(DateTime.now(), false),
            );
          }
          expect(state.requestHistory[op.criticality]!.length, 10001);

          // Trip the Circuit Breaker manually
          state.circuitState = CircuitState.open;
          state.lastFailureTime = DateTime.now();

          // Wait for reset timeout to expire
          await Future.delayed(const Duration(milliseconds: 60));

          // Next request should transition CB to half-open and bypass throttling, succeeding.
          final result = await context.execute(op, () async => 'recovered');
          expect(result, 'recovered');
          expect(state.circuitState, CircuitState.closed);
        },
      );

      test('Adaptive Throttling is checked before Retry', () async {
        resource = Resource(
          'throttling-vs-retry',
          config: ResourceConfig(
            retry: RetryConfig(maxAttempts: 3),
            throttling: ThrottlingConfig(k: 1.0),
          ),
        );
        op = Operation('call', resource);

        // Warm up / initialize state
        await context.execute(op, () async => 'success');

        final state = context.states[resource.name]!;

        // Force Throttling to be active by adding many failures
        for (int i = 0; i < 10000; i++) {
          state.requestHistory[op.criticality]!.add(
            RequestRecord(DateTime.now(), false),
          );
        }
        expect(state.requestHistory[op.criticality]!.length, 10001);

        int actionCalls = 0;
        state.retryHistory.clear();

        // Execution should throw ThrottledException immediately, without retrying.
        await expectLater(
          context.execute(op, () async {
            actionCalls++;
            return 'success';
          }),
          throwsA(isA<ThrottledException>()),
        );

        expect(actionCalls, 0, reason: 'Action should not be called');
        expect(
          state.retryHistory,
          isEmpty,
          reason: 'Retry loop should not be entered',
        );
      });

      test('Retry wraps Hedging (entire hedging session is retried)', () async {
        resource = Resource(
          'retry-vs-hedging',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 2,
              baseDelay: Duration(milliseconds: 100),
              enableJitter: false,
            ),
            hedging: HedgingConfig(
              enabled: true,
              delay: Duration(milliseconds: 50),
            ),
          ),
        );
        op = Operation('call', resource);

        final List<int> attemptStartTimes = [];
        final stopwatch = Stopwatch()..start();

        // Action takes 80ms (longer than hedging delay of 50ms) and then fails.
        final execution = context.executeCancelable(op, (cancel) async {
          attemptStartTimes.add(stopwatch.elapsedMilliseconds);
          await Future.delayed(const Duration(milliseconds: 80));
          throw Exception('fail');
        });

        await expectLater(execution, throwsA(anything));

        expect(
          attemptStartTimes.length,
          4,
          reason: 'Should have 2 primary attempts and 2 hedge attempts',
        );

        const int tolerance = 30; // Increase tolerance slightly for busy CI

        expect(attemptStartTimes[0], lessThan(tolerance));
        expect(
          attemptStartTimes[1],
          allOf(greaterThanOrEqualTo(50 - tolerance), lessThan(50 + tolerance)),
        );
        expect(
          attemptStartTimes[2],
          allOf(
            greaterThanOrEqualTo(230 - tolerance),
            lessThan(230 + tolerance),
          ),
        );
        expect(
          attemptStartTimes[3],
          allOf(
            greaterThanOrEqualTo(280 - tolerance),
            lessThan(280 + tolerance),
          ),
        );
      });

      test(
        'Retry respects Circuit Breaker tripping (does not retry if CB trips mid-retry)',
        () async {
          resource = Resource(
            'retry-vs-cb-trip',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 2,
              ),
              retry: RetryConfig(
                maxAttempts: 4,
                baseDelay: const Duration(milliseconds: 1),
                enableJitter: false,
              ),
              throttling: ThrottlingConfig(k: 100.0), // Disable throttling
            ),
          );
          op = Operation('call', resource);

          int actionCalls = 0;

          await expectLater(
            context.execute(op, () async {
              actionCalls++;
              throw Exception('fail');
            }),
            throwsA(isA<CircuitBreakerOpenException>()),
          );

          expect(actionCalls, equals(2));
        },
      );
    });

    group('Simulator Integration Fixes', () {
      test(
        'ResourceState.config is updated dynamically in _getState',
        () async {
          final initialConfig = ResourceConfig(
            throttling: ThrottlingConfig(windowDuration: Duration(seconds: 1)),
          );
          final initialResource = Resource(
            'dynamic-config-service',
            config: initialConfig,
          );

          // Triggers creation of state with initial config
          await context.execute(
            Operation('call', initialResource),
            () async => 'success',
          );

          final state = context.states[initialResource.name]!;
          expect(
            state.config.throttling.windowDuration,
            equals(Duration(seconds: 1)),
          );

          // Now use a new Resource object with different config
          final newConfig = ResourceConfig(
            throttling: ThrottlingConfig(windowDuration: Duration(seconds: 5)),
          );
          final newResource = Resource(
            'dynamic-config-service',
            config: newConfig,
          );

          // This should trigger _getState and update the config in the state
          await context.execute(
            Operation('call', newResource),
            () async => 'success',
          );

          expect(
            state.config.throttling.windowDuration,
            equals(Duration(seconds: 5)),
          );
        },
      );

      test('cancellation does not trigger subsequent retries', () async {
        final resource = Resource(
          'cancel-retry-service',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: Duration(milliseconds: 10),
            ),
            timeout: Duration(
              milliseconds: 25,
            ), // Timeout before action finishes
          ),
        );
        final op = Operation('call', resource);

        int attempts = 0;
        final execution = context.executeCancelable(op, (cancel) async {
          attempts++;
          // Wait longer than timeout
          await Future.delayed(const Duration(milliseconds: 100));
          if (cancel.isCompleted) {
            throw Exception('Cancelled');
          }
          return 'success';
        });

        await expectLater(
          execution,
          throwsA(isA<ResilienceTimeoutException>()),
        );

        // Wait to ensure no background retries are running
        await Future.delayed(const Duration(milliseconds: 150));

        // If it retried, attempts would be 3 (since retry max is 3)
        // If it did not retry, attempts should be 1
        expect(attempts, equals(1));
      });

      test('retryOn filter is respected by ResilienceContext', () async {
        resource = Resource(
          'retry-on-filter-service',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: Duration(milliseconds: 10),
            ),
          ),
        );
        op = Operation('call', resource);

        int attempts = 0;
        final execution = context.execute(op, () async {
          attempts++;
          if (attempts == 1) {
            throw ArgumentError('retry me');
          }
          if (attempts == 2) {
            throw StateError('do not retry me');
          }
          return 'success';
        }, retryOn: (e) => e is ArgumentError);

        await expectLater(execution, throwsA(isA<StateError>()));

        // Should try once, fail with ArgumentError, retry (attempt 2),
        // fail with StateError, which is NOT retried.
        expect(attempts, equals(2));
      });
    });

    group('Monitoring APIs', () {
      late ResourceState state;

      setUp(() {
        final config = ResourceConfig(
          throttling: ThrottlingConfig(
            k: 2.0,
            windowDuration: Duration(seconds: 1),
          ),
          retry: RetryConfig(budgetWindow: Duration(seconds: 1)),
        );
        state = ResourceState(config);
      });

      test('Retry Budget metrics', () {
        final now = DateTime.now();
        state.retryHistory.addAll([
          RetryAttemptRecord(now, isRetry: false),
          RetryAttemptRecord(now, isRetry: true),
          RetryAttemptRecord(now, isRetry: false),
        ]);

        expect(state.getRetryBudgetRequests(), 3);
        expect(state.getRetryBudgetRetries(), 1);
        expect(state.getRetryBudgetRatio(), closeTo(1 / 3, 0.0001));
      });

      test('Retry Budget metrics empty', () {
        expect(state.getRetryBudgetRequests(), 0);
        expect(state.getRetryBudgetRetries(), 0);
        expect(state.getRetryBudgetRatio(), 0.0);
      });

      test('Throttling metrics', () {
        final now = DateTime.now();
        state.requestHistory[Criticality.critical]!.addAll([
          RequestRecord(now, true),
          RequestRecord(now, false),
          RequestRecord(now, true),
        ]);

        expect(state.getThrottlingRequests(Criticality.critical), 3);
        expect(state.getThrottlingAccepts(Criticality.critical), 2);

        // P = max(0, (requests - k * accepts) / (requests + 1))
        // requests = 3, accepts = 2, k = 2.0
        // P = max(0, (3 - 2.0 * 2) / (3 + 1)) = max(0, -1 / 4) = 0.0
        expect(
          state.getThrottlingRejectionProbability(Criticality.critical),
          0.0,
        );

        // Add more failures to make P > 0
        state.requestHistory[Criticality.critical]!.addAll([
          RequestRecord(now, false),
          RequestRecord(now, false),
        ]);
        // requests = 5, accepts = 2, k = 2.0
        // P = max(0, (5 - 4) / 6) = 1/6 = 0.1666...
        expect(state.getThrottlingRequests(Criticality.critical), 5);
        expect(state.getThrottlingAccepts(Criticality.critical), 2);
        expect(
          state.getThrottlingRejectionProbability(Criticality.critical),
          closeTo(1 / 6, 0.0001),
        );
      });

      test('Throttling metrics empty', () {
        expect(state.getThrottlingRequests(Criticality.critical), 0);
        expect(state.getThrottlingAccepts(Criticality.critical), 0);
        expect(
          state.getThrottlingRejectionProbability(Criticality.critical),
          0.0,
        );
      });

      test('cleanHistory triggering', () async {
        final oldTime = DateTime.now().subtract(const Duration(seconds: 2));
        final now = DateTime.now();

        state.retryHistory.add(RetryAttemptRecord(oldTime, isRetry: true));
        state.requestHistory[Criticality.critical]!.add(
          RequestRecord(oldTime, true),
        );

        // Before calling monitoring, they are there (if we don't clean)
        // But monitoring methods call cleanHistory first.
        expect(state.getRetryBudgetRequests(), 0); // should be cleaned
        expect(
          state.getThrottlingRequests(Criticality.critical),
          0,
        ); // should be cleaned

        // Add mixed old and new
        state.retryHistory.addAll([
          RetryAttemptRecord(oldTime, isRetry: true),
          RetryAttemptRecord(now, isRetry: false),
        ]);
        state.requestHistory[Criticality.critical]!.addAll([
          RequestRecord(oldTime, true),
          RequestRecord(now, true),
        ]);

        expect(state.getRetryBudgetRequests(), 1); // only new one remains
        expect(
          state.getThrottlingRequests(Criticality.critical),
          1,
        ); // only new one remains
      });
    });
  });
}
