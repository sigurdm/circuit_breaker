import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/hedging.dart';
import 'package:test/test.dart';

void main() {
  group('Hedging Contract Tests', () {
    group('Static Hedging Contract', () {
      late ResourceConfig config;
      late ResourceState state;

      setUp(() {
        config = ResourceConfig(
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 50),
          ),
        );
        state = ResourceState(config);
      });

      test('executes normally when hedging is disabled', () async {
        final disabledConfig = ResourceConfig(
          hedging: HedgingConfig(enabled: false),
        );

        int attempts = 0;
        final result = await executeWithHedging(
          (cancelSignal) async {
            attempts++;
            return 'success';
          },
          config: disabledConfig,
          state: state,
        );

        expect(result, equals('success'));
        expect(attempts, equals(1));
      });

      test('returns primary result if fast enough before delay', () async {
        int attempts = 0;
        final result = await executeWithHedging(
          (cancelSignal) async {
            attempts++;
            return 'success';
          },
          config: config,
          state: state,
        );

        expect(result, equals('success'));
        expect(attempts, equals(1));
      });

      test(
        'starts speculative second request after delay when primary is slow',
        () async {
          int attempts = 0;
          final result = await executeWithHedging(
            (cancelSignal) async {
              attempts++;
              if (attempts == 1) {
                await Future.delayed(const Duration(milliseconds: 100));
                return 'slow';
              }
              return 'fast';
            },
            config: config,
            state: state,
          );

          expect(result, equals('fast'));
          expect(attempts, equals(2));
        },
      );

      test('signals cancellation to the slower request', () async {
        final c1 = Completer<void>();
        final c2 = Completer<void>();
        final completers = [c1, c2];
        int attempts = 0;

        final f = executeWithHedging(
          (cancelSignal) async {
            attempts++;
            final myIndex = attempts - 1;

            cancelSignal.future.then((_) {
              if (!completers[myIndex].isCompleted) {
                completers[myIndex].complete();
              }
            });

            if (myIndex == 0) {
              await Future.delayed(const Duration(milliseconds: 200));
              return 'slow';
            } else {
              await Future.delayed(const Duration(milliseconds: 10));
              return 'fast';
            }
          },
          config: config,
          state: state,
        );

        final result = await f;

        expect(result, equals('fast'));
        expect(attempts, equals(2));
        expect(c1.isCompleted, isTrue);
        expect(c2.isCompleted, isFalse);
      });

      test(
        'fails immediately without starting hedge if primary fails before delay',
        () async {
          int attempts = 0;
          await expectLater(
            executeWithHedging(
              (cancelSignal) async {
                attempts++;
                throw StateError('early failure');
              },
              config: config,
              state: state,
            ),
            throwsA(isA<StateError>()),
          );

          expect(attempts, equals(1));
        },
      );

      test('preserves original StackTrace when both attempts fail', () async {
        int attempts = 0;
        StackTrace? caughtStackTrace;

        try {
          await executeWithHedging(
            (cancelSignal) async {
              attempts++;
              if (attempts == 1) {
                await Future.delayed(const Duration(milliseconds: 60));
              }
              throw StateError('failed attempt $attempts');
            },
            config: config,
            state: state,
          );
        } catch (e, st) {
          caughtStackTrace = st;
        }

        expect(attempts, equals(2));
        expect(caughtStackTrace, isNotNull);
        expect(
          caughtStackTrace.toString(),
          contains('hedging_contract_test.dart'),
        );
      });
    });

    group('Dynamic (Adaptive) Hedging & Stochastic Percentile Tracking', () {
      late ResilienceContext context;

      setUp(() {
        context = ResilienceContext();
      });

      test(
        'when dynamicPercentile is null, static delay is used without adaptation',
        () async {
          final resource = Resource(
            'static-hedging',
            config: ResourceConfig(
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(milliseconds: 50),
                dynamicPercentile: null,
              ),
            ),
          );
          final op = Operation('call', resource);
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          int attempts = 0;
          final result = await context.executeCancelable(op, (cancel) async {
            attempts++;
            if (attempts == 1) {
              await Future.delayed(const Duration(milliseconds: 80));
              return 'slow';
            }
            return 'fast';
          });

          expect(result, equals('fast'));
          expect(attempts, equals(2));
          expect(
            state.dynamicDelayEstimate,
            equals(const Duration(milliseconds: 50)),
          );
        },
      );

      test(
        'slow request increases tracked delay estimate (Robbins-Monro)',
        () async {
          final resource = Resource(
            'dynamic-adaptation-slow',
            config: ResourceConfig(
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(milliseconds: 50),
                dynamicPercentile: 0.9,
                adaptationRate: 10.0,
                delayMultiplier: 2.0,
              ),
            ),
          );
          final op = Operation('call', resource);
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          int attempts = 0;
          final result = await context.executeCancelable(op, (cancel) async {
            attempts++;
            await Future.delayed(const Duration(milliseconds: 80));
            return 'slow';
          });

          expect(result, equals('slow'));
          expect(attempts, equals(1));
          // 50000 us * (1 + 0.9/10) = 54500 us
          expect(state.dynamicDelayEstimate.inMicroseconds, equals(54500));
        },
      );

      test(
        'fast request decreases tracked delay estimate (Robbins-Monro)',
        () async {
          final resource = Resource(
            'dynamic-adaptation-fast',
            config: ResourceConfig(
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(milliseconds: 50),
                dynamicPercentile: 0.9,
                adaptationRate: 10.0,
                minDelay: const Duration(milliseconds: 10),
              ),
            ),
          );
          final op = Operation('call', resource);
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          int attempts = 0;
          final result = await context.executeCancelable(op, (cancel) async {
            attempts++;
            await Future.delayed(const Duration(milliseconds: 10));
            return 'fast';
          });

          expect(result, equals('fast'));
          expect(attempts, equals(1));
          // 50000 us * (1 - 0.1/10) = 49500 us
          expect(state.dynamicDelayEstimate.inMicroseconds, equals(49500));
        },
      );

      test(
        'early registration updates tracker before request finishes',
        () async {
          final resource = Resource(
            'early-reg-timing',
            config: ResourceConfig(
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(milliseconds: 50),
                dynamicPercentile: 0.9,
                adaptationRate: 10.0,
                delayMultiplier: 2.0,
              ),
            ),
          );
          final op = Operation('call', resource);
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          final completer = Completer<String>();
          final f = context.executeCancelable(op, (cancel) async {
            return await completer.future;
          });

          expect(
            state.dynamicDelayEstimate,
            equals(const Duration(milliseconds: 50)),
          );

          await Future.delayed(const Duration(milliseconds: 70));

          // Estimate updated early because primary exceeded rawV (50ms)
          expect(state.dynamicDelayEstimate.inMicroseconds, equals(54500));

          completer.complete('done');
          await f;
        },
      );

      test(
        'only one latency sample is registered per logical request',
        () async {
          final resource = Resource(
            'single-sample-early',
            config: ResourceConfig(
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(milliseconds: 50),
                dynamicPercentile: 0.9,
                adaptationRate: 10.0,
                delayMultiplier: 2.0,
              ),
            ),
          );
          final op = Operation('call', resource);
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          int attempts = 0;
          final result = await context.executeCancelable(op, (cancel) async {
            attempts++;
            if (attempts == 1) {
              await Future.delayed(const Duration(milliseconds: 150));
              return 'slow';
            }
            return 'fast';
          });

          expect(result, equals('fast'));
          expect(attempts, equals(2));
          expect(state.dynamicDelayEstimate.inMicroseconds, equals(54500));
        },
      );

      test(
        'early backend failure does not poison dynamic hedging delay estimate',
        () async {
          final resource = Resource(
            'fail-no-poison',
            config: ResourceConfig(
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(milliseconds: 50),
                dynamicPercentile: 0.9,
                adaptationRate: 10.0,
              ),
            ),
          );
          final op = Operation('call', resource);
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          try {
            await context.execute(
              op,
              () async => throw Exception('immediate fail'),
            );
          } catch (_) {}

          expect(
            state.dynamicDelayEstimate,
            equals(const Duration(milliseconds: 50)),
          );
        },
      );

      test(
        'hedged request completion does not record isSlow: false when right-censored',
        () async {
          final resource = Resource(
            'hedging-censoring-test',
            config: ResourceConfig(
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(milliseconds: 20),
                dynamicPercentile: 0.9,
                delayMultiplier: 1.0,
              ),
            ),
          );
          final op = Operation('op', resource);
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          final initialV = state.dynamicDelayEstimate;

          // Both attempts take longer than V (20ms)
          final res = await context.executeCancelable(op, (cancel) async {
            await Future.delayed(const Duration(milliseconds: 50));
            return 'ok';
          });

          expect(res, equals('ok'));
          // Delay estimate should have increased or remained >= initialV
          expect(
            state.dynamicDelayEstimate.inMicroseconds,
            greaterThanOrEqualTo(initialV.inMicroseconds),
          );
        },
      );
    });

    group('Token Bucket Overload Protection', () {
      late ResilienceContext context;

      setUp(() {
        context = ResilienceContext();
      });

      test('token bucket limits the rate of hedges', () async {
        final resource = Resource(
          'token-bucket-limit',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 10),
              dynamicPercentile: 0.9,
              maxOverloadTokens: 2.0,
              overloadPercentile: 0.5,
              delayMultiplier: 1.0,
            ),
          ),
        );
        final op = Operation('call', resource);

        List<int> attemptsPerRequest = [];

        for (int i = 0; i < 4; i++) {
          int attempts = 0;
          await context.executeCancelable(op, (cancel) async {
            attempts++;
            if (attempts == 1) {
              await Future.delayed(const Duration(milliseconds: 30));
              return 'slow';
            }
            return 'fast';
          });
          attemptsPerRequest.add(attempts);
        }

        expect(attemptsPerRequest, equals([2, 2, 2, 1]));
      });
    });

    group('Concurrency Limits & State Safety', () {
      late ResilienceContext context;

      setUp(() {
        context = ResilienceContext();
      });

      test('concurrency limit prevents too many concurrent hedges', () async {
        final resource = Resource(
          'concurrency-limit',
          config: ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 10),
              maxConcurrentHedges: 2,
              delayMultiplier: 1.0,
              maxOverloadTokens: 10.0,
              overloadPercentile: 0.0,
            ),
          ),
        );
        final op = Operation('call', resource);

        final completer1 = Completer<String>();
        final completer2 = Completer<String>();
        final completer3 = Completer<String>();
        final completers = [completer1, completer2, completer3];
        List<int> attempts = [0, 0, 0];

        Future<String> runReq(int index) {
          return context.executeCancelable(op, (cancel) async {
            attempts[index]++;
            if (attempts[index] == 1) {
              return await completers[index].future;
            }
            await Future.delayed(const Duration(milliseconds: 50));
            return 'hedge-$index';
          });
        }

        final f1 = runReq(0);
        final f2 = runReq(1);
        final f3 = runReq(2);

        await Future.delayed(const Duration(milliseconds: 100));

        int completedCount = 0;
        int? blockedIndex;

        for (int i = 0; i < 3; i++) {
          final f = i == 0 ? f1 : (i == 1 ? f2 : f3);
          bool isDone = false;
          await f
              .timeout(
                Duration.zero,
                onTimeout: () {
                  isDone = false;
                  blockedIndex = i;
                  return 'timeout';
                },
              )
              .then((val) {
                if (val != 'timeout') isDone = true;
              });
          if (isDone) completedCount++;
        }

        expect(completedCount, equals(2));
        expect(blockedIndex, isNotNull);

        for (int i = 0; i < 3; i++) {
          if (i == blockedIndex) {
            expect(attempts[i], equals(1));
          } else {
            expect(attempts[i], equals(2));
          }
        }

        completers[blockedIndex!].complete('manual-finish');
        await Future.wait([f1, f2, f3]);
      });

      test(
        '50 concurrent hedged requests strictly respect maxConcurrentHedges',
        () async {
          final resource = Resource(
            'concurrency-stress-test',
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
          final op = Operation('stress-op', resource);
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          final barrier = Completer<void>();

          final futures = List.generate(50, (index) {
            return context.executeCancelable<String>(op, (cancel) async {
              await barrier.future;
              return 'ok';
            });
          });

          await Future.delayed(const Duration(milliseconds: 40));

          expect(state.activeHedges, lessThanOrEqualTo(3));

          barrier.complete();
          await Future.wait(futures);
          expect(state.activeHedges, equals(0));
        },
      );

      test(
        'speculative hedge synchronous exception cancels primary and cleans up active hedges',
        () async {
          final config = ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 20),
            ),
            retry: RetryConfig(maxAttempts: 1),
          );
          final state = ResourceState(config);

          int attempts = 0;
          bool primaryWasCancelled = false;

          await expectLater(
            executeWithHedging<String>(
              (cancel) {
                attempts++;
                if (attempts == 1) {
                  unawaited(
                    cancel.future.then((_) => primaryWasCancelled = true),
                  );
                  return Completer<String>().future;
                } else {
                  throw StateError('Synchronous hedge crash');
                }
              },
              config: config,
              state: state,
            ),
            throwsA(isA<StateError>()),
          );

          expect(attempts, equals(2));
          await Future.delayed(Duration.zero);
          expect(primaryWasCancelled, isTrue);
          expect(state.activeHedges, equals(0));
        },
      );
    });

    group('Circuit Breaker & Pattern Coordination', () {
      late ResilienceContext context;
      late Resource resource;
      late Operation op;

      setUp(() {
        context = ResilienceContext();
        resource = Resource(
          'hedging-cb-coord',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
            ),
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 10),
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(k: 100.0),
          ),
        );
        op = Operation('call', resource);
      });

      test(
        'primary failure does not trip circuit breaker when speculative hedge succeeds',
        () async {
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );

          int attempts = 0;
          final result = await context.executeCancelable(op, (cancel) async {
            attempts++;
            if (attempts == 1) {
              await Future.delayed(const Duration(milliseconds: 20));
              throw Exception('primary failed');
            }
            await Future.delayed(const Duration(milliseconds: 5));
            return 'hedge_recovered';
          });

          expect(result, equals('hedge_recovered'));
          expect(state.failureCount, equals(0));
          expect(state.circuitState, equals(CircuitState.closed));
        },
      );

      test('both primary and hedge failing trips circuit breaker', () async {
        final failResource = Resource(
          'both-fail-service',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
            ),
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 20),
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(k: 100.0),
          ),
        );
        final failOp = Operation('fail-call', failResource);
        final state = context.states.putIfAbsent(
          failResource.name,
          () => ResourceState(failResource.config),
        );

        int attempts = 0;
        await expectLater(
          () => context.executeCancelable(failOp, (cancel) async {
            attempts++;
            if (attempts == 1) {
              await Future.delayed(const Duration(milliseconds: 35));
              throw Exception('primary fail');
            } else {
              await Future.delayed(const Duration(milliseconds: 10));
              throw Exception('hedge fail');
            }
          }),
          throwsA(isA<Exception>()),
        );

        expect(attempts, equals(2));
        expect(state.circuitState, equals(CircuitState.open));
        expect(state.failureCount, equals(1));
      });

      test(
        'hedging is bypassed in halfOpen state to protect trial requests',
        () async {
          final state = context.states.putIfAbsent(
            resource.name,
            () => ResourceState(resource.config),
          );
          state.circuitState = CircuitState.halfOpen;
          state.trialRequestInProgress = false;

          int attempts = 0;
          final result = await context.executeCancelable(op, (cancel) async {
            attempts++;
            await Future.delayed(const Duration(milliseconds: 30));
            return 'trial_success';
          });

          expect(result, equals('trial_success'));
          expect(attempts, equals(1));
        },
      );
    });

    group('Cancellation & Cleanups', () {
      test(
        'cancelled operation prevents phantom hedge spawn and cleans up timers',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'cancel-cleanup-service',
            config: ResourceConfig(
              hedging: HedgingConfig(
                enabled: true,
                delay: const Duration(milliseconds: 30),
              ),
            ),
          );
          final op = Operation('call', resource);

          final cancelToken = CancellationToken();
          int attempts = 0;

          final future = ResilienceContext.runWithCancellationToken(
            cancelToken,
            () {
              return context.executeCancelable(op, (cancel) async {
                attempts++;
                return Completer<String>().future;
              });
            },
          );

          // Cancel before hedge delay
          await Future.delayed(const Duration(milliseconds: 10));
          cancelToken.cancel();

          await expectLater(
            future,
            throwsA(isA<OperationCancelledException>()),
          );

          // Wait past original hedge delay to ensure no phantom hedge ran
          await Future.delayed(const Duration(milliseconds: 50));
          expect(attempts, equals(1));
        },
      );

      test(
        'executeWithHedging cleans up completers on synchronous operation exception',
        () async {
          final config = ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 10),
            ),
          );
          final state = ResourceState(config);

          await expectLater(
            executeWithHedging<String>(
              (c) => throw ArgumentError('sync error'),
              config: config,
              state: state,
            ),
            throwsArgumentError,
          );

          expect(state.activeHedges, equals(0));
        },
      );

      test(
        'cancellation while both primary and hedge are in-flight cleans up timers',
        () async {
          final dynConfig = ResourceConfig(
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 20),
              dynamicPercentile: 0.9,
              delayMultiplier: 0.5,
              minDelay: const Duration(milliseconds: 5),
              maxDelay: const Duration(milliseconds: 50),
            ),
          );
          final activeToken = CancellationToken();
          int activeAttempts = 0;

          final f = ResilienceContext.runWithCancellationToken(activeToken, () {
            return executeWithHedging(
              (c) {
                activeAttempts++;
                return Completer<String>().future;
              },
              config: dynConfig,
              state: ResourceState(dynConfig),
            );
          });

          await Future.delayed(const Duration(milliseconds: 30));
          expect(activeAttempts, equals(2));

          activeToken.cancel();
          await expectLater(f, throwsA(isA<OperationCancelledException>()));
        },
      );
    });
  });
}
