import 'dart:async';
import 'package:test/test.dart' hide Retry;
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  tearDown(() {
    ResilienceContext.defaultContext.clearResources();
  });
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

    test('accepts custom state parameter', () {
      final cfg = ResourceConfig(
        retry: RetryConfig(maxAttempts: 2, baseDelay: Duration.zero),
      );
      final state = ResourceState(cfg);
      final r = Retry.standalone(config: cfg.retry, state: state);
      expect(r.state, same(state));
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

    test(
      'enforces retry budget ratio across consecutive calls to retry()',
      () async {
        final config = RetryConfig(
          minRequestsForBudget: 4,
          retryBudgetRatio: 0.2,
          maxAttempts: 3,
          baseDelay: Duration.zero,
        );

        int totalAttempts = 0;

        // Call 1: fails once, succeeds on attempt 2 (1 initial, 1 retry).
        // Total requests in state: 2, retries: 1.
        final res1 = await retry(() async {
          totalAttempts++;
          if (totalAttempts == 1) throw Exception('fail 1');
          return 'ok 1';
        }, config: config);
        expect(res1, equals('ok 1'));
        expect(totalAttempts, equals(2));

        // Call 2: fails once, succeeds on attempt 2 (1 initial, 1 retry).
        // Total requests in state: 4, retries: 2.
        final res2 = await retry(() async {
          totalAttempts++;
          if (totalAttempts == 3) throw Exception('fail 2');
          return 'ok 2';
        }, config: config);
        expect(res2, equals('ok 2'));
        expect(totalAttempts, equals(4));

        // Call 3: attempt 1 fails (totalAttempts becomes 5).
        // Total requests in state: 5 >= minRequestsForBudget (4).
        // Total retries in state: 2.
        // Next retry check: (2 + 1) > (5 + 1) * 0.2 => 3 > 1.2 => Budget exceeded!
        // Attempt 2 must NOT be made; Exception must be rethrown immediately!
        await expectLater(
          retry(() async {
            totalAttempts++;
            throw Exception('fail 3');
          }, config: config),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('fail 3'),
            ),
          ),
        );
        expect(totalAttempts, equals(5));
      },
    );

    test(
      'isolates retry budget when using custom resourceName or context',
      () async {
        final config = RetryConfig(
          minRequestsForBudget: 2,
          retryBudgetRatio: 0.1,
          maxAttempts: 3,
          baseDelay: Duration.zero,
        );

        // Exhaust budget on resource-a
        await retry(
          () async => 'ok-initial',
          config: config,
          resourceName: 'resource-a',
        );
        await expectLater(
          retry(
            () async => throw Exception('error-a'),
            config: config,
            resourceName: 'resource-a',
          ),
          throwsA(isA<Exception>()),
        );

        // resource-b should have a clean budget and succeed with retry
        int attemptsB = 0;
        final resB = await retry(
          () async {
            attemptsB++;
            if (attemptsB == 1) throw Exception('error-b');
            return 'ok-b';
          },
          config: config,
          resourceName: 'resource-b',
        );
        expect(resB, equals('ok-b'));
        expect(attemptsB, equals(2));

        // Custom context is also completely isolated
        final customCtx = ResilienceContext();
        int attemptsCustom = 0;
        final resCustom = await retry(
          () async {
            attemptsCustom++;
            if (attemptsCustom == 1) throw Exception('error-custom');
            return 'ok-custom';
          },
          config: config,
          context: customCtx,
        );
        expect(resCustom, equals('ok-custom'));
        expect(attemptsCustom, equals(2));
      },
    );

    test(
      'preserves existing state config when subsequent call omits config',
      () async {
        int attempts = 0;
        final config = RetryConfig(maxAttempts: 4, baseDelay: Duration.zero);

        await retry(
          () async => 'init',
          config: config,
          resourceName: 'preserved-retry',
        );

        final res = await retry(() async {
          attempts++;
          if (attempts < 4) throw Exception('retry $attempts');
          return 'done';
        }, resourceName: 'preserved-retry');

        expect(res, equals('done'));
        expect(attempts, equals(4));
      },
    );
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

    test('accepts custom state parameter', () {
      final cfg = ResourceConfig(
        hedging: HedgingConfig(delay: const Duration(milliseconds: 50)),
      );
      final state = ResourceState(cfg);
      final h = RequestHedger.standalone(config: cfg.hedging, state: state);
      expect(h.state, same(state));
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

    test(
      'hedge() respects token bucket and caps duplicate requests across consecutive calls',
      () async {
        int totalInvocations = 0;
        final config = HedgingConfig(
          maxOverloadTokens: 2.0,
          overloadPercentile: 0.9,
          delay: const Duration(milliseconds: 20),
        );

        Future<String> slowAction() async {
          totalInvocations++;
          await Future.delayed(const Duration(milliseconds: 80));
          return 'ok';
        }

        // Call 1: primary slow -> hedges (takes 1 token, leaving 1.0 token). Invocations += 2.
        final res1 = await hedge(slowAction, config: config);
        expect(res1, equals('ok'));
        expect(totalInvocations, equals(2));

        // Call 2: primary slow -> hedges (takes 1 token, leaving 0.1 token). Invocations += 2.
        final res2 = await hedge(slowAction, config: config);
        expect(res2, equals('ok'));
        expect(totalInvocations, equals(4));

        // Call 3: primary slow -> token bucket has 0.2 < 1.0 token, so hedge is blocked!
        // Only primary runs. Invocations += 1.
        final res3 = await hedge(slowAction, config: config);
        expect(res3, equals('ok'));
        expect(totalInvocations, equals(5));

        final defaultState =
            ResilienceContext.defaultContext.states['__adhoc_hedge__'];
        expect(defaultState, isNotNull);
        expect(defaultState!.hedgingTokens, lessThan(1.0));
      },
    );

    test(
      'hedge() adapts dynamicDelayEstimate across consecutive calls',
      () async {
        final config = HedgingConfig(
          dynamicPercentile: 0.9,
          delayMultiplier: 1.5,
          minDelay: const Duration(milliseconds: 10),
          maxDelay: const Duration(milliseconds: 500),
          delay: const Duration(milliseconds: 30),
          adaptationRate: 2.0,
        );

        final stateBefore =
            ResilienceContext.defaultContext.states['dynamic_hedge'];
        expect(stateBefore, isNull);

        // Call 1: primary slow (takes 80ms)
        await hedge(
          () async {
            await Future.delayed(const Duration(milliseconds: 80));
            return 'done1';
          },
          config: config,
          resourceName: 'dynamic_hedge',
        );

        final stateAfter =
            ResilienceContext.defaultContext.states['dynamic_hedge'];
        expect(stateAfter, isNotNull);
        expect(
          stateAfter!.dynamicDelayEstimate,
          greaterThan(const Duration(milliseconds: 30)),
        );
      },
    );

    test(
      'hedge() enforces maxConcurrentHedges across concurrent calls',
      () async {
        final config = HedgingConfig(
          maxConcurrentHedges: 1,
          maxOverloadTokens: 10.0,
          delay: const Duration(milliseconds: 20),
        );

        int totalCalls = 0;
        final completer1 = Completer<void>();
        final completer2 = Completer<void>();

        final f1 = hedge(
          () async {
            totalCalls++;
            await completer1.future;
            return 'res1';
          },
          config: config,
          resourceName: 'concurrent_hedge',
        );

        final f2 = hedge(
          () async {
            totalCalls++;
            await completer2.future;
            return 'res2';
          },
          config: config,
          resourceName: 'concurrent_hedge',
        );

        await Future.delayed(const Duration(milliseconds: 60));

        completer1.complete();
        completer2.complete();

        await Future.wait([f1, f2]);

        // f1 had primary + hedge = 2 calls.
        // f2 had primary only (hedge blocked by maxConcurrentHedges) = 1 call.
        expect(totalCalls, equals(3));
      },
    );

    test(
      'hedge() isolates state with custom resourceName or context',
      () async {
        final config = HedgingConfig(
          maxOverloadTokens: 1.0,
          overloadPercentile: 0.9,
          delay: const Duration(milliseconds: 20),
        );

        int callsA = 0;
        await hedge(
          () async {
            callsA++;
            await Future.delayed(const Duration(milliseconds: 60));
            return 'a';
          },
          config: config,
          resourceName: 'hedge-a',
        );
        expect(callsA, equals(2));

        await hedge(
          () async {
            callsA++;
            await Future.delayed(const Duration(milliseconds: 60));
            return 'a';
          },
          config: config,
          resourceName: 'hedge-a',
        );
        expect(callsA, equals(3));

        int callsB = 0;
        await hedge(
          () async {
            callsB++;
            await Future.delayed(const Duration(milliseconds: 60));
            return 'b';
          },
          config: config,
          resourceName: 'hedge-b',
        );
        expect(callsB, equals(2));
      },
    );

    test(
      'preserves existing state config when subsequent call omits config',
      () async {
        final config = HedgingConfig(
          maxOverloadTokens: 5.0,
          delay: const Duration(milliseconds: 20),
        );

        await hedge(
          () async => 'init',
          config: config,
          resourceName: 'preserved-hedge',
        );

        // Call without config, default delay
        int callsDefault = 0;
        final resDefault = await hedge(() async {
          callsDefault++;
          if (callsDefault == 1) {
            await Future.delayed(const Duration(milliseconds: 60));
          }
          return 'ok-default';
        }, resourceName: 'preserved-hedge');
        expect(resDefault, equals('ok-default'));

        // Call without config, custom delay
        int callsCustom = 0;
        final resCustom = await hedge(
          () async {
            callsCustom++;
            if (callsCustom == 1) {
              await Future.delayed(const Duration(milliseconds: 60));
            }
            return 'ok-custom';
          },
          delay: const Duration(milliseconds: 10),
          resourceName: 'preserved-hedge',
        );
        expect(resCustom, equals('ok-custom'));
        expect(callsCustom, equals(2));
      },
    );
  });
}
