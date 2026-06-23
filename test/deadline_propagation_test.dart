import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('Deadline and Cancellation Propagation', () {
    late ResilienceContext context;
    late Resource resource;
    late Operation operation;

    setUp(() {
      context = ResilienceContext();
      resource = Resource(
        'test-service',
        config: ResourceConfig(
          throttling: ThrottlingConfig(k: 100.0), // disable throttling
        ),
      );
      operation = Operation('test-op', resource);
    });

    test('deadline is set in zone and propagates', () async {
      final timeout = const Duration(milliseconds: 100);
      final resourceWithTimeout = Resource(
        'test-service-timeout',
        config: ResourceConfig(
          throttling: ThrottlingConfig(k: 100.0),
          timeout: timeout,
        ),
      );
      final startTime = DateTime.now();

      await context.executeCancelable(
        Operation(
          'parent',
          resourceWithTimeout,
          retryOverride: RetryConfig(maxAttempts: 1),
        ),
        (cancel) async {
          final deadline = ResilienceContext.currentDeadline;
          expect(deadline, isNotNull);
          // Allow some slack for execution time
          expect(
            deadline!.difference(startTime).inMilliseconds,
            closeTo(timeout.inMilliseconds, 15),
          );

          // Run child operation, it should inherit the deadline
          await context.executeCancelable(
            Operation(
              'child',
              resource,
              retryOverride: RetryConfig(maxAttempts: 1),
            ),
            (childCancel) async {
              final childDeadline = ResilienceContext.currentDeadline;
              expect(childDeadline, equals(deadline));
            },
          );
        },
      );
    });

    test('child operation respects parent deadline (earlier)', () async {
      final parentTimeout = const Duration(milliseconds: 50);
      final resourceWithTimeout = Resource(
        'test-service-timeout',
        config: ResourceConfig(
          throttling: ThrottlingConfig(k: 100.0),
          timeout: parentTimeout,
        ),
      );

      final parentOp = Operation(
        'parent',
        resourceWithTimeout,
        retryOverride: RetryConfig(maxAttempts: 1),
      );

      final startTime = DateTime.now();

      expect(
        () => context.executeCancelable(parentOp, (parentCancel) async {
          // Run child with no timeout, but it should inherit parent's smaller deadline
          await context.executeCancelable(
            Operation(
              'child',
              resource,
              retryOverride: RetryConfig(maxAttempts: 1),
            ),
            (childCancel) async {
              // Wait longer than parent timeout
              await Future.delayed(const Duration(milliseconds: 100));
              return 'should not reach here';
            },
          );
        }),
        throwsA(isA<ResilienceTimeoutException>()),
      );

      expect(
        DateTime.now().difference(startTime).inMilliseconds,
        lessThan(100),
      );
    });

    test('cancellation propagates to child', () async {
      final parentToken = CancellationToken();
      final childStarted = Completer<void>();
      final childCancelled = Completer<void>();

      final future = ResilienceContext.runWithCancellationToken(
        parentToken,
        () => context.executeCancelable(
          Operation(
            'parent',
            resource,
            retryOverride: RetryConfig(maxAttempts: 1),
          ),
          (parentCancel) async {
            await context.executeCancelable(
              Operation(
                'child',
                resource,
                retryOverride: RetryConfig(maxAttempts: 1),
              ),
              (childCancel) async {
                childStarted.complete();
                final token = ResilienceContext.currentCancellationToken;
                expect(token, isNotNull);
                expect(token!.isCancelled, isFalse);
                await token.onCancelled;
                childCancelled.complete();
                throw const OperationCancelledException();
              },
            );
          },
        ),
      );

      await childStarted.future;
      parentToken.cancel();

      await expectLater(future, throwsA(isA<OperationCancelledException>()));
      await childCancelled.future; // Should complete
    });

    test('fail fast if deadline already exceeded', () async {
      final pastDeadline = DateTime.now().subtract(const Duration(seconds: 1));

      expect(
        () => ResilienceContext.runWithDeadline(
          pastDeadline,
          () => context.execute(operation, () async => 'success'),
        ),
        throwsA(isA<ResilienceTimeoutException>()),
      );
    });

    test('fail fast if token already cancelled', () async {
      final token = CancellationToken()..cancel();

      expect(
        () => ResilienceContext.runWithCancellationToken(
          token,
          () => context.execute(operation, () async => 'success'),
        ),
        throwsA(isA<OperationCancelledException>()),
      );
    });

    test('retry backoff is cancelled immediately on timeout', () async {
      final resourceWithTimeoutAndRetry = Resource(
        'test-service-timeout-retry',
        config: ResourceConfig(
          throttling: ThrottlingConfig(k: 100.0),
          timeout: const Duration(milliseconds: 50),
          retry: RetryConfig(
            maxAttempts: 3,
            baseDelay: const Duration(seconds: 10), // Large delay
            enableJitter: false,
          ),
        ),
      );

      final startTime = DateTime.now();

      expect(
        () => context.execute(
          Operation('test', resourceWithTimeoutAndRetry),
          () async => throw Exception('fail'),
        ),
        throwsA(isA<ResilienceTimeoutException>()),
      );

      final duration = DateTime.now().difference(startTime);
      expect(duration.inMilliseconds, lessThan(500));
    });
  });
}
