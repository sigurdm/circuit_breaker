import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/retry.dart';
import 'package:test/test.dart' hide Retry;

void main() {
  group('Retry Contract Tests', () {
    group('Backoff Math & Progression', () {
      late ResourceConfig config;
      late ResourceState state;

      setUp(() {
        config = ResourceConfig(
          retry: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(milliseconds: 10),
            enableJitter: false,
          ),
        );
        state = ResourceState(config);
      });

      test('succeeds on first attempt without retrying', () async {
        int attempts = 0;
        final result = await executeWithRetry(
          () async {
            attempts++;
            return 'success';
          },
          config: config,
          state: state,
        );

        expect(result, equals('success'));
        expect(attempts, equals(1));
        expect(state.retryHistory.length, equals(1));
        expect(state.retryHistory.where((r) => r.isRetry).length, equals(0));
      });

      test(
        'retries on failure and succeeds before exhausting max attempts',
        () async {
          int attempts = 0;
          final result = await executeWithRetry(
            () async {
              attempts++;
              if (attempts < 3) {
                throw Exception('fail');
              }
              return 'success';
            },
            config: config,
            state: state,
          );

          expect(result, equals('success'));
          expect(attempts, equals(3));
          expect(state.retryHistory.length, equals(3));
          expect(state.retryHistory.where((r) => r.isRetry).length, equals(2));
        },
      );

      test('fails after exhausting max attempts', () async {
        int attempts = 0;
        await expectLater(
          executeWithRetry(
            () async {
              attempts++;
              throw Exception('fail');
            },
            config: config,
            state: state,
          ),
          throwsException,
        );

        expect(attempts, equals(3));
        expect(state.retryHistory.length, equals(3));
        expect(state.retryHistory.where((r) => r.isRetry).length, equals(2));
      });

      test(
        'RetryConfig handles sub-millisecond baseDelay with microsecond precision',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'microsecond-service',
            config: ResourceConfig(
              retry: RetryConfig(
                maxAttempts: 3,
                baseDelay: const Duration(microseconds: 500),
                backoffFactor: 2.0,
                enableJitter: false,
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
        'exponential backoff math with extreme factor does not overflow or become negative',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'extreme-backoff',
            config: ResourceConfig(
              retry: RetryConfig(
                maxAttempts: 2,
                baseDelay: const Duration(microseconds: 100),
                backoffFactor: 1e9,
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
                maxDelay: const Duration(days: 60),
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

      test(
        'backoff delay with jitter when maxAttemptDelay >= maxDelay',
        () async {
          final retrier = RetryConfig(
            maxAttempts: 2,
            baseDelay: const Duration(milliseconds: 10),
            maxDelay: const Duration(milliseconds: 10),
            enableJitter: true,
          );
          final resConfig = ResourceConfig(retry: retrier);
          final resState = ResourceState(resConfig);

          int attempts = 0;
          final res = await executeWithRetry(
            () async {
              attempts++;
              if (attempts == 1) throw Exception('transient failure');
              return 'retry-success';
            },
            config: resConfig,
            state: resState,
          );

          expect(res, equals('retry-success'));
          expect(attempts, equals(2));
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

    group('Retry Budgets & Token Accounting', () {
      late ResourceConfig config;
      late ResourceState state;

      setUp(() {
        config = ResourceConfig(
          retry: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(milliseconds: 10),
            enableJitter: false,
          ),
        );
        state = ResourceState(config);
      });

      test('enforces retry budget when ratio is exceeded', () async {
        for (int i = 0; i < 9; i++) {
          state.retryHistory.add(
            RetryAttemptRecord(DateTime.now(), isRetry: false),
          );
        }
        state.retryHistory.add(
          RetryAttemptRecord(DateTime.now(), isRetry: true),
        );
        state.retryHistory.add(
          RetryAttemptRecord(DateTime.now(), isRetry: true),
        );

        int attempts = 0;
        await expectLater(
          executeWithRetry(
            () async {
              attempts++;
              throw Exception('fail');
            },
            config: config,
            state: state,
          ),
          throwsException,
        );

        expect(attempts, equals(1));
        expect(state.retryHistory.length, equals(12));
        expect(state.retryHistory.where((r) => r.isRetry).length, equals(2));
      });

      test(
        'allows retry when it results in exactly the budget ratio',
        () async {
          for (int i = 0; i < 17; i++) {
            state.retryHistory.add(
              RetryAttemptRecord(DateTime.now(), isRetry: false),
            );
          }
          state.retryHistory.add(
            RetryAttemptRecord(DateTime.now(), isRetry: true),
          );

          int attempts = 0;
          await executeWithRetry(
            () async {
              attempts++;
              if (attempts == 1) {
                throw Exception('fail');
              }
              return 'success';
            },
            config: config,
            state: state,
          );

          expect(attempts, equals(2));
        },
      );

      test(
        'rolling retry budget cleans up old attempts and enforces budget only on recent ones',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'budget-rolling-service',
            config: ResourceConfig(
              retry: RetryConfig(
                budgetWindow: const Duration(milliseconds: 100),
                retryBudgetRatio: 0.1,
                minRequestsForBudget: 5,
                baseDelay: const Duration(milliseconds: 1),
              ),
              throttling: ThrottlingConfig(k: 100.0),
            ),
          );
          final op = Operation('call', resource);
          final s = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          // Add 10 old successful attempts (> 200ms ago)
          final oldTime = DateTime.now().subtract(
            const Duration(milliseconds: 250),
          );
          for (int i = 0; i < 10; i++) {
            s.retryHistory.add(RetryAttemptRecord(oldTime, isRetry: false));
          }

          // Add 5 recent successes
          for (int i = 0; i < 5; i++) {
            await context.execute(op, () async => 'success');
          }

          // Now cause a failure. If old requests were not cleaned up, 10 old + 6 new allows retry.
          // But cleanHistory purges old requests, so budget is exceeded and retry is blocked.
          int attempts = 0;
          await expectLater(
            context.execute(op, () async {
              attempts++;
              throw Exception('fail');
            }),
            throwsException,
          );

          expect(attempts, equals(1));
        },
      );

      test('retryHistory is cleaned up during successful requests', () async {
        final context = ResilienceContext();
        final resource = Resource(
          'cleanup-service',
          config: ResourceConfig(
            retry: RetryConfig(budgetWindow: const Duration(milliseconds: 100)),
            throttling: ThrottlingConfig(k: 100.0),
          ),
        );
        final op = Operation('call', resource);
        final s = context.states.putIfAbsent(
          resource.name,
          () => ResourceState(resource.config),
        );

        final oldTime = DateTime.now().subtract(
          const Duration(milliseconds: 200),
        );
        for (int i = 0; i < 50; i++) {
          s.retryHistory.add(RetryAttemptRecord(oldTime, isRetry: false));
        }
        expect(s.retryHistory.length, equals(50));

        await context.execute(op, () async => 'success');

        expect(s.retryHistory.length, equals(1));
      });

      test('retryOn is evaluated before checking retry budget', () async {
        final context = ResilienceContext();
        final resource = Resource(
          'retry-budget-order',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              minRequestsForBudget: 1,
              retryBudgetRatio: 0.1,
            ),
          ),
        );
        final op = Operation('op', resource);

        await expectLater(
          context.execute(
            op,
            () async => throw const FormatException('non-retryable'),
            retryOn: (e) => e is TimeoutException,
          ),
          throwsA(isA<FormatException>()),
        );
      });

      test(
        'monitoring APIs report retry budget requests, retries, and ratio',
        () {
          final context = ResilienceContext();
          final resource = Resource(
            'budget-monitoring',
            config: ResourceConfig(),
          );
          final s = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          expect(s.getRetryBudgetRequests(), equals(0));
          expect(s.getRetryBudgetRetries(), equals(0));
          expect(s.getRetryBudgetRatio(), equals(0.0));

          final now = DateTime.now();
          s.retryHistory.addAll([
            RetryAttemptRecord(now, isRetry: false),
            RetryAttemptRecord(now, isRetry: true),
          ]);

          expect(s.getRetryBudgetRequests(), equals(2));
          expect(s.getRetryBudgetRetries(), equals(1));
          expect(s.getRetryBudgetRatio(), equals(0.5));
        },
      );
    });

    group('Programmer-Error Exclusion & Retry Predicates', () {
      late ResourceConfig config;
      late ResourceState state;

      setUp(() {
        config = ResourceConfig(
          retry: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(milliseconds: 1),
            enableJitter: false,
          ),
        );
        state = ResourceState(config);
      });

      test(
        'does not retry control flow exceptions even if attempts remain',
        () async {
          for (final ex in [
            const OperationCancelledException(),
            CircuitBreakerOpenException('open'),
            ResilienceTimeoutException('timeout'),
          ]) {
            int attempts = 0;
            await expectLater(
              executeWithRetry(
                () async {
                  attempts++;
                  throw ex;
                },
                config: config,
                state: state,
              ),
              throwsA(equals(ex)),
            );
            expect(attempts, equals(1));
          }
        },
      );

      test(
        'does not retry programmer errors when excluded by retryOn predicate',
        () async {
          final retrier = Retry.standalone(
            maxAttempts: 3,
            baseDelay: Duration.zero,
            retryOn: (e) => e is! ArgumentError,
          );
          int attempts = 0;
          await expectLater(
            retrier.execute(() async {
              attempts++;
              throw ArgumentError('bad param');
            }),
            throwsArgumentError,
          );
          expect(attempts, equals(1));
        },
      );

      test('custom retryOn filtering retries matching exception', () async {
        int attempts = 0;
        final result = await executeWithRetry(
          () async {
            attempts++;
            if (attempts == 1) throw ArgumentError('invalid');
            return 'success';
          },
          config: config,
          state: state,
          retryOn: (e) => e is ArgumentError,
        );

        expect(result, equals('success'));
        expect(attempts, equals(2));
      });

      test(
        'custom retryOn filtering rethrows immediately when non-matching',
        () async {
          int attempts = 0;
          await expectLater(
            executeWithRetry(
              () async {
                attempts++;
                throw Exception('not an argument error');
              },
              config: config,
              state: state,
              retryOn: (e) => e is ArgumentError,
            ),
            throwsException,
          );

          expect(attempts, equals(1));
        },
      );

      test('retryOn filter is respected by ResilienceContext', () async {
        final context = ResilienceContext();
        final resource = Resource(
          'retryon-filter-service',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: const Duration(milliseconds: 1),
            ),
            throttling: ThrottlingConfig(k: 100.0),
          ),
        );
        final op = Operation('call', resource);

        int attempts = 0;
        await expectLater(
          context.execute(op, () async {
            attempts++;
            throw const FormatException('syntax error');
          }, retryOn: (e) => e is TimeoutException),
          throwsA(isA<FormatException>()),
        );

        expect(attempts, equals(1));
      });
    });

    group('Cancellation & Deadline Interaction', () {
      test('retry loop is aborted immediately on top-level timeout', () async {
        final context = ResilienceContext();
        final resource = Resource(
          'test-service',
          config: ResourceConfig(
            timeout: const Duration(milliseconds: 50),
            retry: RetryConfig(
              maxAttempts: 5,
              baseDelay: const Duration(milliseconds: 10),
              enableJitter: false,
            ),
          ),
        );
        final op = Operation('op', resource);

        int attempts = 0;
        try {
          await context.executeCancelable<void>(op, (cancel) async {
            attempts++;
            final completer = Completer<void>();
            unawaited(
              cancel.future.then((_) {
                if (!completer.isCompleted) completer.complete();
              }),
            );
            await completer.future;
            throw Exception('should be cancelled');
          });
          fail('Should have timed out');
        } catch (e) {
          expect(e, isA<ResilienceTimeoutException>());
        }

        expect(attempts, equals(1));
      });

      test(
        'ambient deadline in the past throws ResilienceTimeoutException before attempt',
        () async {
          final res = Resource('direct-retry-deadline-res');
          final state = ResourceState(res.config);

          await expectLater(
            ResilienceContext.runWithDeadline(
              DateTime.now().subtract(const Duration(seconds: 1)),
              () => executeWithRetry(
                () async => 'ok',
                config: res.config,
                state: state,
              ),
            ),
            throwsA(isA<ResilienceTimeoutException>()),
          );
        },
      );

      test(
        'retries abort immediately if overall deadline has expired during retry loop',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'no-retry-past-deadline',
            config: ResourceConfig(
              retry: RetryConfig(
                maxAttempts: 5,
                baseDelay: const Duration(milliseconds: 100),
              ),
              timeout: const Duration(milliseconds: 40),
              throttling: ThrottlingConfig(k: 100.0, minRequests: 100),
            ),
          );
          final op = Operation('op', resource);

          int attemptsRun = 0;
          final sw = Stopwatch()..start();

          await expectLater(
            context.execute(op, () async {
              attemptsRun++;
              throw Exception('fail');
            }),
            throwsA(isA<ResilienceTimeoutException>()),
          );

          sw.stop();
          expect(sw.elapsedMilliseconds, lessThan(350));
          expect(attemptsRun, lessThan(5));
        },
      );

      test('cancellation does not trigger subsequent retries', () async {
        final context = ResilienceContext();
        final resource = Resource(
          'cancel-no-retry-service',
          config: ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: const Duration(milliseconds: 1),
            ),
          ),
        );
        final op = Operation('call', resource);

        int attempts = 0;
        final cancelToken = CancellationToken();

        await expectLater(
          ResilienceContext.runWithCancellationToken(cancelToken, () {
            return context.executeCancelable(op, (cancel) async {
              attempts++;
              cancelToken.cancel();
              throw const OperationCancelledException();
            });
          }),
          throwsA(isA<OperationCancelledException>()),
        );

        expect(attempts, equals(1));
      });

      test(
        'multi-attempt retry where attempt 1 fails and attempt 2 times out records timeout',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'retry-then-timeout',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 2,
                resetTimeout: const Duration(seconds: 10),
              ),
              retry: RetryConfig(maxAttempts: 2, baseDelay: Duration.zero),
              throttling: ThrottlingConfig(minRequests: 100),
              timeout: const Duration(milliseconds: 60),
            ),
          );
          final op = Operation('op', resource);

          int attemptCount = 0;
          try {
            await context.execute(op, () async {
              attemptCount++;
              if (attemptCount == 1) {
                throw Exception('backend transient error');
              }
              await Future.delayed(const Duration(milliseconds: 150));
              return 'ok';
            });
          } catch (_) {}

          final state = context.states['retry-then-timeout']!;
          expect(state.failureCount, equals(2));
          expect(state.circuitState, equals(CircuitState.open));
        },
      );
    });
  });
}
