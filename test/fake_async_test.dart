import 'dart:async';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart' hide Retry;
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/retry.dart';
import 'package:circuit_breaker/src/hedging.dart';

void main() {
  group('Deterministic Testing with FakeAsync & Clock', () {
    group('Circuit Breaker state transitions and reset timeouts', () {
      test(
        'standalone CircuitBreaker transitions through Closed -> Open -> HalfOpen -> Closed in 0ms',
        () {
          fakeAsync((async) {
            final config = ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 3,
                resetTimeout: const Duration(seconds: 45),
                halfOpenSuccessThreshold: 2,
              ),
            );
            final state = ResourceState(config);
            final cb = CircuitBreaker(config, state);

            // 1. Initial State: Closed
            expect(cb.isAllowed, isTrue);
            expect(state.circuitState, CircuitState.closed);

            // 2. Consecutive failures trip breaker
            cb.recordFailure();
            cb.recordFailure();
            expect(state.circuitState, CircuitState.closed);
            cb.recordFailure();
            expect(state.circuitState, CircuitState.open);
            expect(cb.isAllowed, isFalse);

            // 3. During reset timeout: requests are blocked fast
            async.elapse(const Duration(seconds: 30));
            expect(state.circuitState, CircuitState.open);
            expect(cb.isAllowed, isFalse);
            expect(
              () => cb.execute(() async => 'value'),
              throwsA(isA<CircuitBreakerOpenException>()),
            );

            // 4. After reset timeout expires: transition to HalfOpen for trial
            async.elapse(const Duration(seconds: 16)); // total 46s > 45s
            expect(cb.isAllowed, isTrue);
            expect(state.circuitState, CircuitState.halfOpen);

            // Concurrent requests during trial are blocked
            expect(cb.isAllowed, isFalse);

            // 5. First trial succeeds: remains in half-open until threshold
            cb.recordSuccess();
            expect(state.circuitState, CircuitState.halfOpen);
            expect(cb.isAllowed, isTrue);

            // Second trial succeeds: reaches threshold and recovers to closed
            cb.recordSuccess();
            expect(state.circuitState, CircuitState.closed);
            expect(cb.isAllowed, isTrue);
          });
        },
      );

      test(
        'failed trial in HalfOpen resets timeout from current fake clock',
        () {
          fakeAsync((async) {
            final config = ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 1,
                resetTimeout: const Duration(minutes: 5),
              ),
            );
            final state = ResourceState(config);
            final cb = CircuitBreaker(config, state);

            cb.recordFailure();
            expect(state.circuitState, CircuitState.open);

            // Advance 5 minutes to allow trial
            async.elapse(const Duration(minutes: 5, seconds: 1));
            expect(cb.isAllowed, isTrue);
            expect(state.circuitState, CircuitState.halfOpen);

            // Trial fails: trips back to Open
            cb.recordFailure();
            expect(state.circuitState, CircuitState.open);
            expect(cb.isAllowed, isFalse);

            // 4 minutes later: still blocked
            async.elapse(const Duration(minutes: 4));
            expect(cb.isAllowed, isFalse);

            // Another 1 minute 1 second later: trial allowed again
            async.elapse(const Duration(minutes: 1, seconds: 1));
            expect(cb.isAllowed, isTrue);
            expect(state.circuitState, CircuitState.halfOpen);
          });
        },
      );

      test('ResilienceContext circuit breaker resets deterministically', () {
        fakeAsync((async) {
          final context = ResilienceContext();
          final resource = Resource(
            'backend-api',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 2,
                resetTimeout: const Duration(seconds: 10),
                halfOpenSuccessThreshold: 1,
              ),
              retry: RetryConfig(maxAttempts: 1),
              throttling: ThrottlingConfig(minRequests: 100),
            ),
          );

          int calls = 0;
          Future<int> action() async {
            calls++;
            if (calls <= 2) throw StateError('fail');
            return 42;
          }

          Object? err1;
          context.execute(resource, action).catchError((e) {
            err1 = e;
            return -1;
          });
          async.flushMicrotasks();
          expect(err1, isA<StateError>());
          expect(calls, 1);

          Object? err2;
          context.execute(resource, action).catchError((e) {
            err2 = e;
            return -1;
          });
          async.flushMicrotasks();
          expect(err2, isA<StateError>());
          expect(calls, 2);

          // Circuit is Open: immediate fast-fail without calling action
          Object? err3;
          context.execute(resource, action).catchError((e) {
            err3 = e;
            return -1;
          });
          async.flushMicrotasks();
          expect(err3, isA<CircuitBreakerOpenException>());
          expect(calls, 2);

          // Advance 9s: still open
          async.elapse(const Duration(seconds: 9));
          Object? err4;
          context.execute(resource, action).catchError((e) {
            err4 = e;
            return -1;
          });
          async.flushMicrotasks();
          expect(err4, isA<CircuitBreakerOpenException>());
          expect(calls, 2);

          // Advance past 10s reset timeout (1s + 1s = 11s total)
          async.elapse(const Duration(seconds: 2));

          // Next call executes trial and closes circuit
          int? output;
          context.execute(resource, action).then((v) => output = v);
          async.flushMicrotasks();

          expect(output, 42);
          expect(calls, 3);
        });
      });
    });

    group('Retry backoffs', () {
      test('retry delays follow backoff schedule in 0ms wall clock time', () {
        fakeAsync((async) {
          final config = ResourceConfig(
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: const Duration(seconds: 2),
              maxDelay: const Duration(seconds: 60),
              backoffFactor: 3.0,
              enableJitter: false,
            ),
          );
          final state = ResourceState(config);

          int attempts = 0;
          bool completed = false;
          String? result;

          executeWithRetry<String>(
            () async {
              attempts++;
              if (attempts < 3) {
                throw StateError('transient failure ');
              }
              return 'success!';
            },
            config: config,
            state: state,
          ).then((res) {
            result = res;
            completed = true;
          });

          // Attempt 1 runs at t = 0s
          async.flushMicrotasks();
          expect(attempts, 1);
          expect(completed, isFalse);

          // 1st backoff delay is baseDelay = 2s
          async.elapse(const Duration(seconds: 1));
          expect(attempts, 1);
          expect(completed, isFalse);

          async.elapse(const Duration(seconds: 1)); // total 2s
          expect(attempts, 2);
          expect(completed, isFalse);

          // 2nd backoff delay is 2s * 3.0 = 6s
          async.elapse(const Duration(seconds: 5));
          expect(attempts, 2);
          expect(completed, isFalse);

          async.elapse(const Duration(seconds: 1)); // total 8s
          expect(attempts, 3);
          expect(completed, isTrue);
          expect(result, 'success!');
        });
      });

      test('standalone Retry respects deadline during backoff sleep', () {
        fakeAsync((async) {
          final retry = Retry.standalone(
            config: RetryConfig(
              maxAttempts: 5,
              baseDelay: const Duration(seconds: 10),
              enableJitter: false,
            ),
            timeout: const Duration(seconds: 5),
          );

          int attempts = 0;
          Object? failure;

          retry
              .execute<String>(() async {
                attempts++;
                throw StateError('failed attempt ');
              })
              .catchError((err) {
                failure = err;
                return 'failed';
              });

          async.flushMicrotasks();
          expect(attempts, 1);
          expect(failure, isNull);

          // 5s timeout expires while waiting 10s for retry attempt 2
          async.elapse(const Duration(seconds: 6));
          expect(failure, isA<ResilienceTimeoutException>());
          expect(attempts, 1);
        });
      });
    });

    group('Sliding window expiry', () {
      test(
        'adaptive throttling request history expires after windowDuration',
        () {
          fakeAsync((async) {
            final config = ResourceConfig(
              throttling: ThrottlingConfig(
                windowDuration: const Duration(minutes: 1),
                minRequests: 5,
              ),
            );
            final state = ResourceState(config);

            // Record requests at t = 0
            for (int i = 0; i < 5; i++) {
              state.recordRequest(true, Criticality.critical);
            }
            for (int i = 0; i < 5; i++) {
              state.recordRequest(false, Criticality.critical);
            }

            expect(state.getThrottlingRequests(Criticality.critical), 10);
            expect(state.getThrottlingAccepts(Criticality.critical), 5);

            // Advance 30s: window still holds all requests
            async.elapse(const Duration(seconds: 30));
            expect(state.getThrottlingRequests(Criticality.critical), 10);
            expect(state.getThrottlingAccepts(Criticality.critical), 5);

            // Record 3 more requests at t = 30s
            state.recordRequest(true, Criticality.critical);
            state.recordRequest(true, Criticality.critical);
            state.recordRequest(false, Criticality.critical);

            expect(state.getThrottlingRequests(Criticality.critical), 13);
            expect(state.getThrottlingAccepts(Criticality.critical), 7);

            // Advance 31s (total 61s): requests from t = 0s expire!
            async.elapse(const Duration(seconds: 31));
            expect(state.getThrottlingRequests(Criticality.critical), 3);
            expect(state.getThrottlingAccepts(Criticality.critical), 2);

            // Advance another 30s: remaining requests from t = 30s expire
            async.elapse(const Duration(seconds: 30));
            expect(state.getThrottlingRequests(Criticality.critical), 0);
            expect(state.getThrottlingAccepts(Criticality.critical), 0);
          });
        },
      );

      test('retry budget history window expires after budgetWindow', () {
        fakeAsync((async) {
          final config = ResourceConfig(
            retry: RetryConfig(
              budgetWindow: const Duration(minutes: 5),
              retryBudgetRatio: 0.2,
              minRequestsForBudget: 1,
            ),
          );
          final state = ResourceState(config);

          // Add records at t = 0
          state.retryHistory.add(
            RetryAttemptRecord(clock.now(), isRetry: false),
          );
          state.retryHistory.add(
            RetryAttemptRecord(clock.now(), isRetry: true),
          );

          expect(state.getRetryBudgetRequests(), 2);
          expect(state.getRetryBudgetRetries(), 1);
          expect(state.getRetryBudgetRatio(), 0.5);

          // Advance 3 minutes
          async.elapse(const Duration(minutes: 3));
          expect(state.getRetryBudgetRequests(), 2);
          expect(state.getRetryBudgetRetries(), 1);

          // Add fresh record at t = 3min
          state.retryHistory.add(
            RetryAttemptRecord(clock.now(), isRetry: false),
          );
          expect(state.getRetryBudgetRequests(), 3);

          // Advance 2 minutes 1 second (total 5m 1s from start)
          async.elapse(const Duration(minutes: 2, seconds: 1));

          // Records from t=0 have expired; only the record from t=3min remains
          expect(state.getRetryBudgetRequests(), 1);
          expect(state.getRetryBudgetRetries(), 0);
          expect(state.getRetryBudgetRatio(), 0.0);

          // Advance another 3 minutes
          async.elapse(const Duration(minutes: 3));
          expect(state.getRetryBudgetRequests(), 0);
          expect(state.getRetryBudgetRetries(), 0);
        });
      });
    });

    group('Request Hedging', () {
      test(
        'hedged request triggers after hedging delay in 0ms wall clock time',
        () {
          fakeAsync((async) {
            final config = ResourceConfig(
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(seconds: 5),
              ),
            );
            final state = ResourceState(config);

            int executions = 0;
            bool primaryCancelled = false;
            final primaryCompleter = Completer<String>();
            final hedgedCompleter = Completer<String>();

            executeWithHedging<String>(
              (cancel) {
                executions++;
                if (executions == 1) {
                  cancel.future.then((_) => primaryCancelled = true);
                  return primaryCompleter.future;
                } else {
                  return hedgedCompleter.future;
                }
              },
              config: config,
              state: state,
            );

            async.flushMicrotasks();
            // Initial request is running, hedged request not yet spawned
            expect(executions, 1);
            expect(primaryCancelled, isFalse);

            // Advance 4s: hedged request still not spawned
            async.elapse(const Duration(seconds: 4));
            expect(executions, 1);

            // Advance 1s (total 5s = hedging delay): hedged request spawned!
            async.elapse(const Duration(seconds: 1));
            expect(executions, 2);
            expect(primaryCancelled, isFalse);

            // Hedged request completes at t = 6s
            async.elapse(const Duration(seconds: 1));
            hedgedCompleter.complete('hedged result');
            async.flushMicrotasks();

            // Primary request received cancellation
            expect(primaryCancelled, isTrue);
          });
        },
      );
    });
  });
}
