import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/context.dart';

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
            config: const ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(failureThreshold: 2),
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
            circuitBreaker: const CircuitBreakerConfig(failureThreshold: 2),
            throttling: const ThrottlingConfig(
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
            circuitBreaker: const CircuitBreakerConfig(failureThreshold: 2),
            throttling: const ThrottlingConfig(
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
          config: const ResourceConfig(
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
          config: const ResourceConfig(
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
  });
}
