import 'dart:async';
import 'dart:io';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Deadline & Cancellation Contract Tests', () {
    group('Zone-Based Deadline Propagation', () {
      late ResilienceContext context;
      late Resource resource;

      setUp(() {
        context = ResilienceContext();
        resource = Resource('deadline-res');
      });

      test(
        'deadline is established in zone and propagates to child operations',
        () async {
          final timeout = const Duration(milliseconds: 100);
          final resWithTimeout = Resource(
            'res-timeout',
            config: ResourceConfig(timeout: timeout),
          );
          final startTime = DateTime.now();

          await context.executeCancelable(Operation('parent', resWithTimeout), (
            cancel,
          ) async {
            final deadline = ResilienceContext.currentDeadline;
            expect(deadline, isNotNull);
            expect(
              deadline!.difference(startTime).inMilliseconds,
              closeTo(timeout.inMilliseconds, 25),
            );

            await context.executeCancelable(Operation('child', resource), (
              childCancel,
            ) async {
              final childDeadline = ResilienceContext.currentDeadline;
              expect(childDeadline, equals(deadline));
            });
          });
        },
      );

      test(
        'nested runWithDeadline merges with parent deadline (monotonically non-increasing)',
        () {
          final tNow = DateTime.now();
          final tOuter = tNow.add(const Duration(milliseconds: 100));
          final tInnerShorter = tNow.add(const Duration(milliseconds: 50));
          final tInnerLonger = tNow.add(const Duration(milliseconds: 500));

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

      test(
        'merge deadlines chooses earliest when parent and child have different timeouts',
        () async {
          final parentTimeout = const Duration(milliseconds: 100);
          final parentRes = Resource(
            'parent-timeout-res',
            config: ResourceConfig(timeout: parentTimeout),
          );

          // Child with longer timeout inherits parent's shorter deadline
          await context.executeCancelable(Operation('parent1', parentRes), (
            cancel,
          ) async {
            final parentDeadline = ResilienceContext.currentDeadline;
            expect(parentDeadline, isNotNull);

            final childResLonger = Resource(
              'child-longer',
              config: ResourceConfig(
                timeout: const Duration(milliseconds: 200),
              ),
            );
            await context.executeCancelable(
              Operation('child1', childResLonger),
              (childCancel) async {
                final childDeadline = ResilienceContext.currentDeadline;
                expect(childDeadline, equals(parentDeadline));
              },
            );
          });

          // Child with shorter timeout tightens deadline
          await context.executeCancelable(Operation('parent2', parentRes), (
            cancel,
          ) async {
            final parentDeadline = ResilienceContext.currentDeadline;
            expect(parentDeadline, isNotNull);

            final childResShorter = Resource(
              'child-shorter',
              config: ResourceConfig(timeout: const Duration(milliseconds: 50)),
            );
            await context.executeCancelable(
              Operation('child2', childResShorter),
              (childCancel) async {
                final childDeadline = ResilienceContext.currentDeadline;
                expect(childDeadline!.isBefore(parentDeadline!), isTrue);
              },
            );
          });
        },
      );
    });

    group('Deadline Enforcement & Timeouts', () {
      late ResilienceContext context;
      late Resource resource;

      setUp(() {
        context = ResilienceContext();
        resource = Resource('timeout-enforce-res');
      });

      test(
        'throws ResilienceTimeoutException when deadline is reached',
        () async {
          final resTimeout = Resource(
            'strict-timeout',
            config: ResourceConfig(
              timeout: const Duration(milliseconds: 30),
              retry: RetryConfig(maxAttempts: 1),
            ),
          );
          final op = Operation('op', resTimeout);

          await expectLater(
            context.execute(op, () async {
              await Future.delayed(const Duration(milliseconds: 100));
              return 'done';
            }),
            throwsA(isA<ResilienceTimeoutException>()),
          );
        },
      );

      test(
        'fails fast if deadline already exceeded before execution starts',
        () async {
          final pastDeadline = DateTime.now().subtract(
            const Duration(seconds: 1),
          );
          final op = Operation('op', resource);

          await expectLater(
            ResilienceContext.runWithDeadline(
              pastDeadline,
              () => context.execute(op, () async => 'success'),
            ),
            throwsA(isA<ResilienceTimeoutException>()),
          );
        },
      );

      test(
        'deadline exceeded during execution check throws ResilienceTimeoutException',
        () async {
          final slowResource = Resource(
            'slow-setup-service',
            config: ResourceConfig(
              timeout: const Duration(milliseconds: 5),
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(milliseconds: 50),
              ),
              retry: RetryConfig(maxAttempts: 1),
            ),
          );

          final delayingState = DelayingResourceState(slowResource.config);
          context.states[slowResource.name] = delayingState;

          await expectLater(
            () => context.execute(
              Operation('test', slowResource),
              () async => 'success',
            ),
            throwsA(
              isA<ResilienceTimeoutException>().having(
                (e) => e.message,
                'message',
                contains('Deadline exceeded during execution'),
              ),
            ),
          );
        },
      );

      test(
        'uncaught background async error inside zone does not crash isolate',
        () async {
          final res = Resource(
            'zone-isolation',
            config: ResourceConfig(
              timeout: const Duration(milliseconds: 30),
              retry: RetryConfig(maxAttempts: 1),
            ),
          );
          final op = Operation('op', res);

          await expectLater(
            context.execute(op, () async {
              Timer(const Duration(milliseconds: 50), () {
                throw StateError('unhandled async error in background timer');
              });
              await Future.delayed(const Duration(milliseconds: 100));
              return 'done';
            }),
            throwsA(isA<ResilienceTimeoutException>()),
          );

          await Future.delayed(const Duration(milliseconds: 80));
        },
      );

      test('ResilienceTimeoutException toString contains message', () {
        final ex = ResilienceTimeoutException(
          'Operation timed out (deadline exceeded)',
        );
        expect(
          ex.toString(),
          equals(
            'ResilienceTimeoutException: Operation timed out (deadline exceeded)',
          ),
        );
        expect(ex.message, contains('Operation timed out'));
      });
    });

    group('CancellationToken Hierarchy & Lifecycle', () {
      test('attach propagates cancellation from parent to child', () {
        final parent = CancellationToken();
        final child = CancellationToken();
        child.attach(parent);

        expect(child.isCancelled, isFalse);
        parent.cancel();
        expect(child.isCancelled, isTrue);
      });

      test('detach stops cancellation propagation', () {
        final parent = CancellationToken();
        final child = CancellationToken();
        child.attach(parent);

        expect(child.isCancelled, isFalse);
        child.detach();
        parent.cancel();
        expect(child.isCancelled, isFalse);
      });

      test('cancel detaches child from parent to prevent memory leaks', () {
        final parent = CancellationToken();
        final child = CancellationToken();
        child.attach(parent);

        child.cancel();
        expect(child.isCancelled, isTrue);
        expect(parent.isCancelled, isFalse);
      });

      test('attach to already-cancelled parent immediately cancels child', () {
        final parent = CancellationToken()..cancel();
        final child = CancellationToken();

        expect(child.isCancelled, isFalse);
        child.attach(parent);
        expect(child.isCancelled, isTrue);
      });

      test('attaching cancelled child does not leak in parent', () {
        final parent = CancellationToken();
        final cancelledChild = CancellationToken()..cancel();

        cancelledChild.attach(parent);
        expect(cancelledChild.isCancelled, isTrue);
        parent.cancel();
        expect(parent.isCancelled, isTrue);
      });

      test('self-attachment throws ArgumentError', () {
        final token = CancellationToken();
        expect(() => token.attach(token), throwsArgumentError);
      });

      test('transitive ancestor cycle detection throws ArgumentError', () {
        final tokenA = CancellationToken();
        final tokenB = CancellationToken();
        final tokenC = CancellationToken();

        tokenB.attach(tokenA); // B child of A
        tokenC.attach(tokenB); // C child of B

        // Attaching A to C would create cycle A -> B -> C -> A
        expect(() => tokenA.attach(tokenC), throwsArgumentError);
      });

      test('cancel can be called multiple times idempotently', () {
        final token = CancellationToken();
        expect(token.isCancelled, isFalse);
        token.cancel();
        expect(token.isCancelled, isTrue);
        expect(() => token.cancel(), returnsNormally);
        expect(token.isCancelled, isTrue);
      });

      test(
        'nested runWithCancellationToken attaches nested token to parent token',
        () {
          final parent = CancellationToken();
          final child = CancellationToken();

          ResilienceContext.runWithCancellationToken(parent, () {
            ResilienceContext.runWithCancellationToken(child, () {
              expect(ResilienceContext.currentCancellationToken, equals(child));
              expect(child.isCancelled, isFalse);
              parent.cancel();
              expect(child.isCancelled, isTrue);
            });
          });
        },
      );

      test(
        'pre-flight rejection detaches execution token from parent token',
        () async {
          final context = ResilienceContext();
          final res = Resource(
            'preflight-detach',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 1,
              ),
            ),
          );
          final op = Operation('op', res);

          try {
            await context.execute(op, () async => throw Exception('fail'));
          } catch (_) {}

          final parentToken = CancellationToken();

          await ResilienceContext.runWithCancellationToken(
            parentToken,
            () async {
              try {
                await context.execute(op, () async => 'unreachable');
              } catch (_) {}
            },
          );

          expect(parentToken.isCancelled, isFalse);
          parentToken.cancel();
          expect(parentToken.isCancelled, isTrue);
        },
      );

      test('attemptToken is detached after successful execution', () async {
        final parentToken = CancellationToken();
        final context = ResilienceContext();
        final resource = Resource('detach-success-res');
        final operation = Operation('test_operation', resource);

        CancellationToken? capturedAttemptToken;

        await ResilienceContext.runWithCancellationToken(parentToken, () async {
          await context.executeCancelable(operation, (cancelCompleter) async {
            capturedAttemptToken = ResilienceContext.currentCancellationToken;
            expect(capturedAttemptToken, isNotNull);
            expect(capturedAttemptToken!.isCancelled, isFalse);
            return 'success';
          });
        });

        expect(capturedAttemptToken, isNotNull);
        parentToken.cancel();
        // Child was detached so it shouldn't receive parent's cancellation
        expect(capturedAttemptToken!.isCancelled, isFalse);
      });

      test('attemptToken is detached after failed execution', () async {
        final parentToken = CancellationToken();
        final context = ResilienceContext();
        final resource = Resource('detach-fail-res');
        final operation = Operation('test_operation', resource);

        CancellationToken? capturedAttemptToken;

        await ResilienceContext.runWithCancellationToken(parentToken, () async {
          try {
            await context.executeCancelable(operation, (cancelCompleter) async {
              capturedAttemptToken = ResilienceContext.currentCancellationToken;
              throw Exception('failed');
            });
          } catch (_) {}
        });

        expect(capturedAttemptToken, isNotNull);
        parentToken.cancel();
        expect(capturedAttemptToken!.isCancelled, isFalse);
      });

      test(
        'detached token can be garbage collected (WeakReference verification)',
        () async {
          final parent = CancellationToken();

          WeakReference<CancellationToken> getWeakRef() {
            final child = CancellationToken();
            child.attach(parent);
            child.detach();
            return WeakReference(child);
          }

          final weakRef = getWeakRef();
          expect(weakRef.target, isNotNull);

          for (int i = 0; i < 10; i++) {
            List<dynamic>? pin = [];
            for (var j = 0; j < 10000; j++) {
              pin.add(List.filled(100, j));
            }
            pin = null;
            await Future.delayed(const Duration(milliseconds: 1));
          }
          expect(weakRef.target, isNull);
        },
      );
    });

    group('Cancellation Flow & Interruption', () {
      late ResilienceContext context;
      late Resource resource;

      setUp(() {
        context = ResilienceContext();
        resource = Resource('cancellation-flow-res');
      });

      test('cancellation propagates to child and aborts operation', () async {
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
        await childCancelled.future;
      });

      test(
        'executeCancelable fails fast immediately when parent token is already cancelled',
        () async {
          final parentToken = CancellationToken()..cancel();
          final op = Operation('op', resource);

          await ResilienceContext.runWithCancellationToken(
            parentToken,
            () async {
              await expectLater(
                () => context.execute(op, () async => 'should not run'),
                throwsA(isA<OperationCancelledException>()),
              );
            },
          );
        },
      );

      test('cancellation aborts hanging action even without timeout', () async {
        final parentToken = CancellationToken();
        final op = Operation('hang-op', resource);

        final future = ResilienceContext.runWithCancellationToken(
          parentToken,
          () => context.executeCancelable(op, (cancel) async {
            await Completer<void>().future;
            return 'success';
          }),
        );

        Timer(const Duration(milliseconds: 10), () {
          parentToken.cancel();
        });

        await expectLater(future, throwsA(isA<OperationCancelledException>()));
      });

      test(
        'hedge attempt is cancelled before start if parent token is cancelled',
        () async {
          final hedgeResource = Resource(
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
            () => context.executeCancelable(Operation('test', hedgeResource), (
              cancel,
            ) async {
              await Completer<void>().future;
              return 'primary';
            }),
          );

          Timer(const Duration(milliseconds: 5), () {
            parentToken.cancel();
          });

          await expectLater(
            future,
            throwsA(isA<OperationCancelledException>()),
          );
        },
      );

      test('OperationCancelledException toString contains message', () {
        const e = OperationCancelledException('custom message');
        expect(
          e.toString(),
          equals('OperationCancelledException: custom message'),
        );

        const e2 = OperationCancelledException();
        expect(
          e2.toString(),
          equals('OperationCancelledException: Operation was cancelled'),
        );
      });
    });
  });
}

final class DelayingResourceState extends ResourceState {
  DelayingResourceState(super.config);

  @override
  void recordLogicalRequest() {
    super.recordLogicalRequest();
    sleep(const Duration(milliseconds: 10));
  }
}
