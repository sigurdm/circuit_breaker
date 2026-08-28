import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Cycle 2 Hardening Regression Tests', () {
    test(
      'nested runWithDeadline merges with parent deadline (monotonically non-increasing)',
      () {
        final tNow = DateTime.now();
        final tOuter = tNow.add(const Duration(milliseconds: 100));
        final tInnerShorter = tNow.add(const Duration(milliseconds: 50));
        final tInnerLonger = tNow.add(const Duration(milliseconds: 500));

        // Outer zone establishes tOuter
        ResilienceContext.runWithDeadline(tOuter, () {
          expect(ResilienceContext.currentDeadline, equals(tOuter));

          // Shorter inner deadline tightens the deadline
          ResilienceContext.runWithDeadline(tInnerShorter, () {
            expect(ResilienceContext.currentDeadline, equals(tInnerShorter));
          });

          // Longer inner deadline MUST NOT extend past outer deadline
          ResilienceContext.runWithDeadline(tInnerLonger, () {
            expect(ResilienceContext.currentDeadline, equals(tOuter));
          });
        });
      },
    );

    test('CancellationToken self-attachment throws ArgumentError', () {
      final token = CancellationToken();
      expect(() => token.attach(token), throwsArgumentError);
    });

    test(
      'CancellationToken attaching cancelled child does not leak in parent',
      () {
        final parent = CancellationToken();
        final cancelledChild = CancellationToken()..cancel();

        cancelledChild.attach(parent);
        // Parent's cancel should work cleanly and child was not retained
        expect(cancelledChild.isCancelled, isTrue);
        parent.cancel();
        expect(parent.isCancelled, isTrue);
      },
    );

    test(
      'unclassified / client error in half-open does not falsely close circuit breaker',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'half-open-safety',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
              resetTimeout: const Duration(milliseconds: 50),
              halfOpenSuccessThreshold: 1,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(k: 100.0, minRequests: 100),
          ),
        );
        final op = Operation('op', resource);

        // 1. Trip breaker to open
        for (int i = 0; i < 2; i++) {
          try {
            await context.execute(
              op,
              () async => throw Exception('backend error'),
            );
          } catch (_) {}
        }
        final state = context.states['half-open-safety']!;
        expect(state.circuitState, equals(CircuitState.open));

        // 2. Wait for reset timeout
        await Future.delayed(const Duration(milliseconds: 70));

        // 3. Trial request throws ArgumentError (client error, not system failure)
        await expectLater(
          context.execute(
            op,
            () async => throw ArgumentError('invalid parameter'),
          ),
          throwsArgumentError,
        );

        // Circuit breaker MUST NOT have closed! It should remain in half-open or open, NOT closed!
        expect(state.circuitState, isNot(equals(CircuitState.closed)));

        // 4. A real successful request can now run as trial and close it
        final result = await context.execute(op, () async => 'healthy');
        expect(result, equals('healthy'));
        expect(state.circuitState, equals(CircuitState.closed));
      },
    );

    test(
      'timeout does not double-record failures in circuit breaker',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'timeout-no-double-count',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 3,
              resetTimeout: const Duration(seconds: 10),
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(k: 100.0, minRequests: 100),
            timeout: const Duration(milliseconds: 30),
          ),
        );
        final op = Operation('slow-op', resource);

        // Request 1 times out
        try {
          await context.execute(op, () async {
            await Future.delayed(const Duration(milliseconds: 80));
            return 'ok';
          });
        } catch (_) {}

        final state = context.states['timeout-no-double-count']!;
        // Failure count must be exactly 1, not 2!
        expect(state.failureCount, equals(1));
        expect(state.circuitState, equals(CircuitState.closed));

        // Request 2 times out
        try {
          await context.execute(op, () async {
            await Future.delayed(const Duration(milliseconds: 80));
            return 'ok';
          });
        } catch (_) {}

        expect(state.failureCount, equals(2));
        expect(state.circuitState, equals(CircuitState.closed));

        // Request 3 times out -> Now trips the breaker
        try {
          await context.execute(op, () async {
            await Future.delayed(const Duration(milliseconds: 80));
            return 'ok';
          });
        } catch (_) {}

        expect(state.failureCount, equals(3));
        expect(state.circuitState, equals(CircuitState.open));
      },
    );

    test('retries abort immediately if overall deadline has expired', () async {
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
      // Should have aborted after deadline (within ~150ms), rather than sleeping 100ms * 4
      expect(sw.elapsedMilliseconds, lessThan(350));
      expect(attemptsRun, lessThan(5));
    });

    test(
      'standalone CircuitBreaker can be instantiated and used independently',
      () async {
        final cb = CircuitBreaker.standalone(
          config: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 2,
            resetTimeout: const Duration(milliseconds: 50),
          ),
        );

        expect(cb.isAllowed, isTrue);

        final val = await cb.execute(() async => 'hello');
        expect(val, equals('hello'));

        // Two failures trip the breaker
        for (int i = 0; i < 2; i++) {
          try {
            await cb.execute(() async => throw Exception('error'));
          } catch (_) {}
        }

        expect(cb.isAllowed, isFalse);
        expect(
          () => cb.execute(() async => 'test'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );

        // Wait for reset timeout
        await Future.delayed(const Duration(milliseconds: 70));

        final recovered = await cb.execute(() async => 'recovered');
        expect(recovered, equals('recovered'));
        expect(cb.isAllowed, isTrue);
      },
    );

    test(
      'standalone AdaptiveThrottler can be instantiated and queried independently',
      () {
        final throttler = AdaptiveThrottler.standalone(
          config: ThrottlingConfig(k: 2.0, minRequests: 10),
        );
        // Under minRequests, should not throttle
        expect(throttler.shouldThrottle(Criticality.critical), isFalse);
      },
    );

    test(
      '3-level hierarchy (Grandparent -> Parent -> Child) propagates state',
      () async {
        final context = ResilienceContext();
        final grandparent = Resource(
          'gp',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
              resetTimeout: const Duration(milliseconds: 100),
              halfOpenSuccessThreshold: 1,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(minRequests: 100),
          ),
        );
        final parent = Resource(
          'p',
          parent: grandparent,
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
              resetTimeout: const Duration(milliseconds: 100),
              halfOpenSuccessThreshold: 1,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(minRequests: 100),
          ),
        );
        final child = Resource(
          'c',
          parent: parent,
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
              resetTimeout: const Duration(milliseconds: 100),
              halfOpenSuccessThreshold: 1,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(minRequests: 100),
          ),
        );

        final gpOp = Operation('gpOp', grandparent);
        final cOp = Operation('cOp', child);

        // Trip grandparent
        for (int i = 0; i < 2; i++) {
          try {
            await context.execute(gpOp, () async => throw Exception('fail'));
          } catch (_) {}
        }

        expect(context.states['gp']?.circuitState, equals(CircuitState.open));

        // Child call is blocked because grandparent is open
        await expectLater(
          context.execute(cOp, () async => 'ok'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );

        // Wait for grandparent reset timeout
        await Future.delayed(const Duration(milliseconds: 120));

        // Child call acts as trial for grandparent
        final result = await context.execute(cOp, () async => 'healed');
        expect(result, equals('healed'));
        expect(context.states['gp']?.circuitState, equals(CircuitState.closed));
      },
    );

    test(
      '50 concurrent requests in half-open state allow exactly 1 trial and reject 49',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'concurrent-half-open',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
              resetTimeout: const Duration(milliseconds: 50),
              halfOpenSuccessThreshold: 1,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(
              k: 100.0,
              minRequests: 100,
            ), // Disable throttling
          ),
        );
        final op = Operation('op', resource);

        // Trip to open
        for (int i = 0; i < 2; i++) {
          try {
            await context.execute(op, () async => throw Exception('fail'));
          } catch (_) {}
        }
        expect(
          context.states['concurrent-half-open']?.circuitState,
          equals(CircuitState.open),
        );

        // Wait for reset timeout
        await Future.delayed(const Duration(milliseconds: 70));

        // Launch 50 concurrent requests simultaneously
        final trialCompleter = Completer<String>();
        int trialCount = 0;
        int rejectedCount = 0;

        final futures = List.generate(50, (index) {
          return context
              .execute(op, () async {
                trialCount++;
                return await trialCompleter.future;
              })
              .then((val) {
                return val;
              })
              .catchError((e) {
                if (e is CircuitBreakerOpenException) {
                  rejectedCount++;
                }
                return 'rejected';
              });
        });

        // Allow event loop to dispatch all 50 synchronous preamble checks
        await Future.delayed(const Duration(milliseconds: 20));

        expect(
          trialCount,
          equals(1),
          reason: 'Only 1 request should be admitted as the trial',
        );
        expect(
          rejectedCount,
          equals(49),
          reason:
              '49 requests should fail-fast with CircuitBreakerOpenException',
        );

        // Complete the single trial
        trialCompleter.complete('trial-success');
        final results = await Future.wait(futures);

        expect(results.where((r) => r == 'trial-success').length, equals(1));
        expect(results.where((r) => r == 'rejected').length, equals(49));
        expect(
          context.states['concurrent-half-open']?.circuitState,
          equals(CircuitState.closed),
        );
      },
    );

    test(
      '50 concurrent hedged requests strictly respect maxConcurrentHedges',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'concurrent-hedges',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 10),
              maxConcurrentHedges: 3,
              maxOverloadTokens: 3.0,
              overloadPercentile: 0.0,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(k: 100.0, minRequests: 100),
          ),
        );
        final op = Operation('hedged-op', resource);

        final barrier = Completer<void>();

        final futures = List.generate(50, (index) {
          return context.executeCancelable<String>(op, (cancel) async {
            await barrier.future;
            return 'ok';
          });
        });

        // Wait enough for hedging delay (10ms) to trigger hedges
        await Future.delayed(const Duration(milliseconds: 40));

        final state = context.states['concurrent-hedges']!;
        expect(
          state.activeHedges,
          lessThanOrEqualTo(3),
          reason: 'activeHedges must not exceed maxConcurrentHedges',
        );

        barrier.complete();
        await Future.wait(futures);
        expect(
          state.activeHedges,
          equals(0),
          reason: 'activeHedges must return to 0 when completed',
        );
      },
    );

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
            // Attempt 2 hangs and times out
            await Future.delayed(const Duration(milliseconds: 150));
            return 'ok';
          });
        } catch (_) {}

        final state = context.states['retry-then-timeout']!;
        // Attempt 1 recorded failure (1), Attempt 2 timeout must be recorded (2) -> breaker trips to open!
        expect(state.failureCount, equals(2));
        expect(state.circuitState, equals(CircuitState.open));
      },
    );

    test(
      'speculative hedge throwing synchronous exception does not leak tokens or activeHedges',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'sync-hedge-error',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 10),
              maxConcurrentHedges: 2,
              maxOverloadTokens: 2.0,
              overloadPercentile: 0.0,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(minRequests: 100),
          ),
        );
        final op = Operation('op', resource);

        int callCount = 0;
        try {
          await context.executeCancelable<String>(op, (cancel) async {
            callCount++;
            if (callCount == 1) {
              await Future.delayed(const Duration(milliseconds: 50));
              return 'primary-success';
            } else {
              throw StateError('synchronous hedge error');
            }
          });
        } catch (_) {}

        final state = context.states['sync-hedge-error']!;
        expect(state.activeHedges, equals(0));
        expect(callCount, equals(2));
      },
    );

    test(
      'CircuitBreaker.standalone respects failureClassifier and half-open non-failure',
      () async {
        final cb = CircuitBreaker.standalone(
          config: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 2,
            resetTimeout: const Duration(milliseconds: 50),
            halfOpenSuccessThreshold: 1,
          ),
          failureClassifier: (e) => e is! FormatException,
        );

        // FormatException is not classified as system failure
        try {
          await cb.execute(
            () async => throw const FormatException('bad format'),
          );
        } catch (_) {}

        expect(cb.state.failureCount, equals(0));
        expect(cb.state.circuitState, equals(CircuitState.closed));

        // Real failures trip the breaker
        for (int i = 0; i < 2; i++) {
          try {
            await cb.execute(() async => throw Exception('real error'));
          } catch (_) {}
        }
        expect(cb.state.circuitState, equals(CircuitState.open));

        // Wait for reset timeout
        await Future.delayed(const Duration(milliseconds: 70));

        // Trial request with FormatException does not trip breaker back to open
        try {
          await cb.execute(
            () async => throw const FormatException('bad format'),
          );
        } catch (_) {}

        expect(cb.state.circuitState, equals(CircuitState.halfOpen));
        expect(cb.state.trialRequestInProgress, isFalse);

        // Successful trial recovers breaker
        final val = await cb.execute(() async => 'recovered');
        expect(val, equals('recovered'));
        expect(cb.state.circuitState, equals(CircuitState.closed));
      },
    );

    test(
      'AdaptiveThrottler.standalone supports recordRequest and rejectionProbability',
      () {
        final throttler = AdaptiveThrottler.standalone(
          config: ThrottlingConfig(k: 2.0, minRequests: 2),
        );

        expect(
          throttler.rejectionProbability(Criticality.critical),
          equals(0.0),
        );

        // Record 2 failed requests
        throttler.recordRequest(false, Criticality.critical);
        throttler.recordRequest(false, Criticality.critical);

        // Now requests >= minRequests (2 >= 2) and accepts == 0
        // P = (2 - 2*0)/(2+1) = 2/3 ≈ 0.666...
        expect(
          throttler.rejectionProbability(Criticality.critical),
          closeTo(0.666, 0.01),
        );
      },
    );
  });
}
