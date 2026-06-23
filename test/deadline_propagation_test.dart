import 'dart:async';
import 'dart:io';
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

    test('CancellationToken cancel can be called multiple times', () {
      final token = CancellationToken();
      expect(token.isCancelled, isFalse);
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(() => token.cancel(), returnsNormally);
      expect(token.isCancelled, isTrue);
    });

    test('OperationCancelledException toString contains message', () {
      final e = const OperationCancelledException('custom message');
      expect(
        e.toString(),
        contains('OperationCancelledException: custom message'),
      );

      final e2 = const OperationCancelledException();
      expect(
        e2.toString(),
        contains('OperationCancelledException: Operation was cancelled'),
      );
    });

    test('merge deadlines chooses earliest', () async {
      final parentTimeout = const Duration(milliseconds: 100);
      final resourceWithParentTimeout = Resource(
        'parent-timeout',
        config: ResourceConfig(
          throttling: ThrottlingConfig(k: 100.0),
          timeout: parentTimeout,
        ),
      );

      await context.executeCancelable(
        Operation(
          'parent',
          resourceWithParentTimeout,
          retryOverride: RetryConfig(maxAttempts: 1),
        ),
        (cancel) async {
          final parentDeadline = ResilienceContext.currentDeadline;
          expect(parentDeadline, isNotNull);

          final childTimeout = const Duration(milliseconds: 200);
          final resourceWithChildTimeout = Resource(
            'child-timeout',
            config: ResourceConfig(
              throttling: ThrottlingConfig(k: 100.0),
              timeout: childTimeout,
            ),
          );

          await context.executeCancelable(
            Operation(
              'child',
              resourceWithChildTimeout,
              retryOverride: RetryConfig(maxAttempts: 1),
            ),
            (childCancel) async {
              final childDeadline = ResilienceContext.currentDeadline;
              expect(childDeadline, equals(parentDeadline));
            },
          );
        },
      );

      await context.executeCancelable(
        Operation(
          'parent2',
          resourceWithParentTimeout,
          retryOverride: RetryConfig(maxAttempts: 1),
        ),
        (cancel) async {
          final parentDeadline = ResilienceContext.currentDeadline;
          expect(parentDeadline, isNotNull);

          final childTimeout = const Duration(milliseconds: 50);
          final resourceWithChildTimeout = Resource(
            'child-timeout-2',
            config: ResourceConfig(
              throttling: ThrottlingConfig(k: 100.0),
              timeout: childTimeout,
            ),
          );

          await context.executeCancelable(
            Operation(
              'child2',
              resourceWithChildTimeout,
              retryOverride: RetryConfig(maxAttempts: 1),
            ),
            (childCancel) async {
              final childDeadline = ResilienceContext.currentDeadline;
              expect(childDeadline!.isBefore(parentDeadline!), isTrue);
            },
          );
        },
      );
    });

    test(
      'retry backoff aborts immediately if token already cancelled',
      () async {
        final resourceWithRetry = Resource(
          'test-service-retry-cancel',
          config: ResourceConfig(
            throttling: ThrottlingConfig(k: 100.0),
            retry: RetryConfig(
              maxAttempts: 3,
              baseDelay: const Duration(seconds: 10),
              enableJitter: false,
            ),
          ),
        );

        final token = CancellationToken();
        int actionCalls = 0;

        final future = ResilienceContext.runWithCancellationToken(
          token,
          () => context.execute(
            Operation('test', resourceWithRetry),
            () async {
              actionCalls++;
              throw Exception('fail');
            },
            retryOn: (e) {
              ResilienceContext.currentCancellationToken?.cancel();
              return true;
            },
          ),
        );

        await expectLater(future, throwsA(isA<OperationCancelledException>()));
        expect(actionCalls, equals(1));
      },
    );

    test('deadline exceeded during execution check', () async {
      final resource = Resource(
        'slow-setup-service',
        config: ResourceConfig(
          throttling: ThrottlingConfig(k: 100.0),
          timeout: const Duration(milliseconds: 5),
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 50),
          ),
          retry: RetryConfig(maxAttempts: 1),
        ),
      );

      final delayingState = DelayingResourceState(resource.config);
      context.states[resource.name] = delayingState;

      expect(
        () =>
            context.execute(Operation('test', resource), () async => 'success'),
        throwsA(
          isA<ResilienceTimeoutException>().having(
            (e) => e.message,
            'message',
            contains('Deadline exceeded during execution'),
          ),
        ),
      );
    });

    test('cancellation aborts hanging action even without timeout', () async {
      final resourceWithoutTimeout = Resource(
        'no-timeout-service',
        config: ResourceConfig(throttling: ThrottlingConfig(k: 100.0)),
      );

      final parentToken = CancellationToken();

      final future = ResilienceContext.runWithCancellationToken(
        parentToken,
        () => context.executeCancelable(
          Operation('test', resourceWithoutTimeout),
          (cancel) async {
            await Completer<void>().future;
            return 'success';
          },
        ),
      );

      Timer(const Duration(milliseconds: 10), () {
        parentToken.cancel();
      });

      await expectLater(future, throwsA(isA<OperationCancelledException>()));
    });

    test(
      'hedge attempt is cancelled before start if parent cancelled',
      () async {
        final resource = Resource(
          'hedge-cancel-before-start',
          config: ResourceConfig(
            timeout: const Duration(milliseconds: 100),
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 10),
            ),
            retry: RetryConfig(maxAttempts: 1),
          ),
        );

        final parentToken = CancellationToken();

        final future = ResilienceContext.runWithCancellationToken(
          parentToken,
          () => context.executeCancelable(Operation('test', resource), (
            cancel,
          ) async {
            await Completer<void>().future;
            return 'primary';
          }),
        );

        Timer(const Duration(milliseconds: 5), () {
          parentToken.cancel();
        });

        await expectLater(future, throwsA(isA<OperationCancelledException>()));
      },
    );
  });
}

class DelayingResourceState extends ResourceState {
  DelayingResourceState(super.config);

  @override
  void recordLogicalRequest() {
    super.recordLogicalRequest();
    sleep(const Duration(milliseconds: 10));
  }
}
