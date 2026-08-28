import 'dart:async';
import 'package:test/test.dart' hide Retry;
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('Standalone Retry', () {
    test('succeeds on first attempt without retries', () async {
      final r = Retry.standalone(maxAttempts: 3, baseDelay: Duration.zero);
      int attempts = 0;

      final res = await r.execute(() async {
        attempts++;
        return 'success';
      });

      expect(res, equals('success'));
      expect(attempts, equals(1));
    });

    test('retries transient failures and eventually succeeds', () async {
      final r = Retry.standalone(maxAttempts: 3, baseDelay: Duration.zero);
      int attempts = 0;

      final res = await r.execute(() async {
        attempts++;
        if (attempts < 3) throw Exception('transient $attempts');
        return 'eventual-success';
      });

      expect(res, equals('eventual-success'));
      expect(attempts, equals(3));
    });

    test('rethrows exception when maxAttempts exhausted', () async {
      final r = Retry.standalone(maxAttempts: 2, baseDelay: Duration.zero);
      int attempts = 0;

      await expectLater(
        r.execute(() async {
          attempts++;
          throw FormatException('fatal');
        }),
        throwsFormatException,
      );

      expect(attempts, equals(2));
    });

    test('respects default retryOn predicate', () async {
      final r = Retry.standalone(
        maxAttempts: 3,
        baseDelay: Duration.zero,
        retryOn: (e) => e is FormatException,
      );
      int attempts = 0;

      await expectLater(
        r.execute(() async {
          attempts++;
          throw ArgumentError('fatal argument');
        }),
        throwsArgumentError,
      );

      // Should not retry ArgumentError because retryOn only matches FormatException
      expect(attempts, equals(1));
    });

    test('respects execute retryOn override', () async {
      final r = Retry.standalone(
        maxAttempts: 3,
        baseDelay: Duration.zero,
        retryOn: (e) => e is FormatException,
      );
      int attempts = 0;

      final res = await r.execute(() async {
        attempts++;
        if (attempts < 2) throw ArgumentError('overridden');
        return 'ok';
      }, retryOn: (e) => e is ArgumentError);

      expect(res, equals('ok'));
      expect(attempts, equals(2));
    });

    test('wrap and wrapUnary', () async {
      final r = Retry.standalone(maxAttempts: 2, baseDelay: Duration.zero);

      int nullaryAttempts = 0;
      final wrappedNullary = r.wrap(() async {
        nullaryAttempts++;
        if (nullaryAttempts < 2) throw Exception('retry');
        return 100;
      });
      expect(await wrappedNullary(), equals(100));
      expect(nullaryAttempts, equals(2));

      int unaryAttempts = 0;
      final wrappedUnary = r.wrapUnary<String, int>((n) async {
        unaryAttempts++;
        if (unaryAttempts < 2) throw Exception('retry');
        return 'result_$n';
      });
      expect(await wrappedUnary(5), equals('result_5'));
      expect(unaryAttempts, equals(2));
    });

    test(
      'enforces retry budget across multiple calls on same instance',
      () async {
        final r = Retry.standalone(
          config: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(milliseconds: 5),
            enableJitter: false,
            minRequestsForBudget: 10,
            retryBudgetRatio: 0.1,
          ),
        );

        for (int i = 0; i < 9; i++) {
          r.state.retryHistory.add(
            RetryAttemptRecord(DateTime.now(), isRetry: false),
          );
        }
        r.state.retryHistory.add(
          RetryAttemptRecord(DateTime.now(), isRetry: true),
        );
        r.state.retryHistory.add(
          RetryAttemptRecord(DateTime.now(), isRetry: true),
        );

        int attempts = 0;
        await expectLater(
          r.execute(() async {
            attempts++;
            throw Exception('fail');
          }),
          throwsException,
        );

        expect(attempts, 1);
        expect(r.state.retryHistory.where((rec) => rec.isRetry).length, 2);
      },
    );

    test('enforces timeout when configured', () async {
      final r = Retry.standalone(
        config: RetryConfig(
          maxAttempts: 5,
          baseDelay: const Duration(milliseconds: 50),
          enableJitter: false,
        ),
        timeout: const Duration(milliseconds: 60),
      );

      await expectLater(
        r.execute(() async {
          await Future.delayed(const Duration(milliseconds: 40));
          throw Exception('retry me');
        }),
        throwsA(isA<ResilienceTimeoutException>()),
      );
    });

    test(
      'does not retry OperationCancelledException, CircuitBreakerOpenException, or ResilienceTimeoutException',
      () async {
        final r = Retry.standalone(
          config: RetryConfig(
            maxAttempts: 5,
            baseDelay: Duration.zero,
            enableJitter: false,
          ),
        );

        int cancelAttempts = 0;
        await expectLater(
          r.execute(() async {
            cancelAttempts++;
            throw const OperationCancelledException();
          }),
          throwsA(isA<OperationCancelledException>()),
        );
        expect(cancelAttempts, 1);

        int cbAttempts = 0;
        await expectLater(
          r.execute(() async {
            cbAttempts++;
            throw const CircuitBreakerOpenException('resource is open');
          }),
          throwsA(isA<CircuitBreakerOpenException>()),
        );
        expect(cbAttempts, 1);

        int timeoutAttempts = 0;
        await expectLater(
          r.execute(() async {
            timeoutAttempts++;
            throw ResilienceTimeoutException('timeout');
          }),
          throwsA(isA<ResilienceTimeoutException>()),
        );
        expect(timeoutAttempts, 1);
      },
    );

    test('aborts immediately if ambient token is already cancelled', () async {
      final token = CancellationToken()..cancel();
      final r = Retry.standalone(maxAttempts: 3);

      int attempts = 0;
      await expectLater(
        ResilienceContext.runWithCancellationToken(
          token,
          () => r.execute(() async {
            attempts++;
            return 'not reached';
          }),
        ),
        throwsA(isA<OperationCancelledException>()),
      );
      expect(attempts, 0);
    });
  });

  group('Top-level retry(...) function', () {
    test('succeeds immediately on first try', () async {
      final res = await retry(() async => 'fast');
      expect(res, equals('fast'));
    });

    test('retries on failure with custom maxAttempts and baseDelay', () async {
      int attempts = 0;
      final res = await retry(
        () async {
          attempts++;
          if (attempts < 3) throw Exception('fail $attempts');
          return 'done';
        },
        maxAttempts: 4,
        baseDelay: Duration.zero,
      );

      expect(res, equals('done'));
      expect(attempts, equals(3));
    });

    test('fails after exhausting maxAttempts', () async {
      int attempts = 0;
      await expectLater(
        retry(
          () async {
            attempts++;
            throw UnsupportedError('never works');
          },
          maxAttempts: 2,
          baseDelay: Duration.zero,
        ),
        throwsUnsupportedError,
      );

      expect(attempts, equals(2));
    });

    test('respects retryOn filter', () async {
      int attempts = 0;
      await expectLater(
        retry(
          () async {
            attempts++;
            throw StateError('bad state');
          },
          maxAttempts: 3,
          baseDelay: Duration.zero,
          retryOn: (e) => e is FormatException,
        ),
        throwsStateError,
      );

      expect(attempts, equals(1));
    });

    test('accepts RetryConfig object', () async {
      int attempts = 0;
      final res = await retry(() async {
        attempts++;
        if (attempts < 2) throw Exception('retry');
        return 'ok';
      }, config: RetryConfig(maxAttempts: 3, baseDelay: Duration.zero));

      expect(res, equals('ok'));
      expect(attempts, equals(2));
    });

    test('enforces timeout on top-level retry', () async {
      await expectLater(
        retry(
          () async {
            await Future.delayed(const Duration(milliseconds: 40));
            throw Exception('retry');
          },
          maxAttempts: 5,
          baseDelay: const Duration(milliseconds: 50),
          timeout: const Duration(milliseconds: 60),
        ),
        throwsA(isA<ResilienceTimeoutException>()),
      );
    });
  });

  group('Standalone RequestHedger', () {
    test('returns primary request if completed before hedging delay', () async {
      final hedger = RequestHedger.standalone(
        delay: const Duration(milliseconds: 100),
      );

      int calls = 0;
      final res = await hedger.execute(() async {
        calls++;
        return 'primary';
      });

      expect(res, equals('primary'));
      expect(calls, equals(1));
    });

    test('sends hedged request when primary is delayed', () async {
      final hedger = RequestHedger.standalone(
        delay: const Duration(milliseconds: 20),
      );

      int callIndex = 0;
      final completer1 = Completer<String>();
      final completer2 = Completer<String>();

      final resFuture = hedger.execute(() async {
        final idx = ++callIndex;
        if (idx == 1) {
          return await completer1.future;
        } else {
          return await completer2.future;
        }
      });

      // Allow hedging delay to expire
      await Future.delayed(const Duration(milliseconds: 50));
      expect(callIndex, equals(2)); // Both primary and hedge dispatched

      // Complete hedge first
      completer2.complete('hedge-result');
      expect(await resFuture, equals('hedge-result'));

      // Clean up primary completer
      completer1.complete('primary-late');
    });

    test('executeCancelable cancels slower request', () async {
      final hedger = RequestHedger.standalone(
        delay: const Duration(milliseconds: 20),
      );

      final c1Cancel = Completer<void>();
      final c2Cancel = Completer<void>();
      final primaryCompleter = Completer<String>();
      final hedgeCompleter = Completer<String>();

      int callIndex = 0;
      final resFuture = hedger.executeCancelable((cancelCompleter) async {
        final idx = ++callIndex;
        if (idx == 1) {
          cancelCompleter.future.then((_) => c1Cancel.complete());
          return await primaryCompleter.future;
        } else {
          cancelCompleter.future.then((_) => c2Cancel.complete());
          return await hedgeCompleter.future;
        }
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(callIndex, equals(2));

      // Hedge finishes first
      hedgeCompleter.complete('hedge-fast');
      expect(await resFuture, equals('hedge-fast'));

      // Primary should have received cancel signal
      await expectLater(c1Cancel.future, completes);
      expect(c2Cancel.isCompleted, isFalse);

      primaryCompleter.complete('ignore');
    });

    test('wrap and wrapUnary', () async {
      final hedger = RequestHedger.standalone(
        delay: const Duration(milliseconds: 50),
      );

      final wrappedNullary = hedger.wrap(() async => 'hedged-nullary');
      expect(await wrappedNullary(), equals('hedged-nullary'));

      final wrappedUnary = hedger.wrapUnary<String, int>(
        (x) async => 'hedged-$x',
      );
      expect(await wrappedUnary(42), equals('hedged-42'));
    });

    test(
      'enforces timeout on hedged execution and cancels in-flight actions',
      () async {
        final hedger = RequestHedger.standalone(
          delay: const Duration(milliseconds: 20),
          timeout: const Duration(milliseconds: 50),
        );

        final cancelCompleterReceived = Completer<void>();
        await expectLater(
          hedger.executeCancelable((cancel) async {
            cancel.future.then((_) {
              if (!cancelCompleterReceived.isCompleted) {
                cancelCompleterReceived.complete();
              }
            });
            await Future.delayed(const Duration(milliseconds: 200));
            return 'too late';
          }),
          throwsA(isA<ResilienceTimeoutException>()),
        );

        // Verify that in-flight action was notified of cancellation!
        await expectLater(cancelCompleterReceived.future, completes);
        expect(cancelCompleterReceived.isCompleted, isTrue);
      },
    );

    test('aborts immediately if ambient token is already cancelled', () async {
      final token = CancellationToken()..cancel();
      final hedger = RequestHedger.standalone();

      int attempts = 0;
      await expectLater(
        ResilienceContext.runWithCancellationToken(
          token,
          () => hedger.execute(() async {
            attempts++;
            return 'not reached';
          }),
        ),
        throwsA(isA<OperationCancelledException>()),
      );
      expect(attempts, 0);
    });
  });

  group('Standalone CircuitBreaker and AdaptiveThrottler decorators', () {
    test('CircuitBreaker.wrap and wrapUnary', () async {
      final cb = CircuitBreaker.standalone(
        config: CircuitBreakerConfig(consecutiveFailuresThreshold: 2),
      );

      final wrapped = cb.wrap(() async => 'cb-ok');
      expect(await wrapped(), equals('cb-ok'));

      final wrappedUnary = cb.wrapUnary<String, String>(
        (msg) async => 'cb-$msg',
      );
      expect(await wrappedUnary('test'), equals('cb-test'));

      // Trip circuit breaker
      final failWrapped = cb.wrap(() async => throw Exception('error'));
      await expectLater(failWrapped(), throwsException);
      await expectLater(failWrapped(), throwsException);

      // Now open
      await expectLater(wrapped(), throwsA(isA<CircuitBreakerOpenException>()));
      await expectLater(
        wrappedUnary('x'),
        throwsA(isA<CircuitBreakerOpenException>()),
      );
    });

    test('AdaptiveThrottler.wrap and wrapUnary', () async {
      final throttler = AdaptiveThrottler.standalone(
        config: ThrottlingConfig(k: 2.0),
      );

      final wrapped = throttler.wrap(() async => 'throttle-ok');
      expect(await wrapped(), equals('throttle-ok'));

      final wrappedUnary = throttler.wrapUnary<int, int>((x) async => x * 2);
      expect(await wrappedUnary(21), equals(42));
    });
  });

  group('Top-level hedge(...) function', () {
    test('succeeds fast without hedge if completed before delay', () async {
      final result = await hedge(
        () async => 'fast-result',
        delay: const Duration(milliseconds: 100),
      );
      expect(result, equals('fast-result'));
    });

    test('hedges and returns faster result when primary is slow', () async {
      int calls = 0;
      final result = await hedge(() async {
        calls++;
        if (calls == 1) {
          await Future.delayed(const Duration(milliseconds: 100));
          return 'slow-primary';
        }
        return 'fast-hedge';
      }, delay: const Duration(milliseconds: 20));
      expect(result, equals('fast-hedge'));
      expect(calls, equals(2));
    });

    test(
      'RequestHedger.executeCancelable injects per-attempt CancellationToken',
      () async {
        final hedger = RequestHedger.standalone(
          delay: const Duration(milliseconds: 20),
        );

        CancellationToken? attempt1Token;
        final result = await hedger.executeCancelable((cancel) async {
          attempt1Token ??= ResilienceContext.currentCancellationToken;
          if (attempt1Token != null &&
              attempt1Token == ResilienceContext.currentCancellationToken) {
            // Primary slow request
            await Future.delayed(const Duration(milliseconds: 80));
            return 'primary';
          }
          // Speculative hedge
          return 'hedge-fast';
        });

        expect(result, equals('hedge-fast'));
        expect(attempt1Token, isNotNull);
        expect(attempt1Token!.isCancelled, isTrue);
      },
    );
  });
}
