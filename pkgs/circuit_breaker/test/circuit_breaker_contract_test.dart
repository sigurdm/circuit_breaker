import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('CircuitBreaker Contract Tests', () {
    group('State Machine & Transitions', () {
      late ResourceConfig config;
      late ResourceState state;
      late CircuitBreaker cb;

      setUp(() {
        config = ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 2,
            resetTimeout: const Duration(milliseconds: 100),
            halfOpenSuccessThreshold: 3,
          ),
        );
        state = ResourceState(config);
        cb = CircuitBreaker(config, state);
      });

      test('starts in closed state and permits requests', () {
        expect(state.circuitState, equals(CircuitState.closed));
        expect(cb.isAllowed, isTrue);
      });

      test(
        'trips from closed to open when consecutive failures reach threshold',
        () {
          cb.recordFailure();
          expect(state.circuitState, equals(CircuitState.closed));
          expect(cb.isAllowed, isTrue);

          cb.recordFailure();
          expect(state.circuitState, equals(CircuitState.open));
          expect(cb.isAllowed, isFalse);
        },
      );

      test('fast-fails requests immediately when circuit is open', () async {
        cb.recordFailure();
        cb.recordFailure();
        expect(state.circuitState, equals(CircuitState.open));

        bool actionInvoked = false;
        await expectLater(
          cb.execute(() async {
            actionInvoked = true;
            return 'ok';
          }),
          throwsA(isA<CircuitBreakerOpenException>()),
        );
        expect(actionInvoked, isFalse);
      });

      test(
        'transitions from open to half-open after reset timeout expires',
        () async {
          cb.recordFailure();
          cb.recordFailure();
          expect(state.circuitState, equals(CircuitState.open));

          await Future.delayed(const Duration(milliseconds: 150));

          expect(cb.isAllowed, isTrue);
          expect(state.circuitState, equals(CircuitState.halfOpen));
        },
      );

      test(
        'half-open state requires configured consecutive successes to close circuit',
        () async {
          cb.recordFailure();
          cb.recordFailure();
          await Future.delayed(const Duration(milliseconds: 150));

          // Trial 1 starts
          expect(cb.isAllowed, isTrue);
          expect(cb.tryAcquireTrial(), isTrue);
          expect(state.circuitState, equals(CircuitState.halfOpen));
          expect(state.trialRequestInProgress, isTrue);
          expect(cb.tryAcquireTrial(), isFalse);
          expect(cb.isAllowed, isFalse);

          cb.recordSuccess();
          expect(state.circuitState, equals(CircuitState.halfOpen));
          expect(state.trialRequestInProgress, isFalse);
          expect(cb.isAllowed, isTrue);
          expect(state.halfOpenSuccessCount, equals(1));

          // Trial 2 starts
          expect(cb.tryAcquireTrial(), isTrue);
          expect(state.trialRequestInProgress, isTrue);
          expect(cb.tryAcquireTrial(), isFalse);
          expect(cb.isAllowed, isFalse);

          cb.recordSuccess();
          expect(state.circuitState, equals(CircuitState.halfOpen));
          expect(state.trialRequestInProgress, isFalse);
          expect(cb.isAllowed, isTrue);
          expect(state.halfOpenSuccessCount, equals(2));

          // Trial 3 starts
          expect(cb.tryAcquireTrial(), isTrue);
          expect(state.trialRequestInProgress, isTrue);

          cb.recordSuccess();
          expect(state.circuitState, equals(CircuitState.closed));
          expect(state.trialRequestInProgress, isFalse);
          expect(state.halfOpenSuccessCount, equals(0));
          expect(state.failureCount, equals(0));
        },
      );

      test(
        'single failure in half-open resets success count and trips back to open',
        () async {
          cb.recordFailure();
          cb.recordFailure();
          await Future.delayed(const Duration(milliseconds: 150));

          // Trial 1: success
          expect(cb.isAllowed, isTrue);
          cb.recordSuccess();
          expect(state.halfOpenSuccessCount, equals(1));

          // Trial 2: failure
          expect(cb.isAllowed, isTrue);
          cb.recordFailure();

          expect(state.circuitState, equals(CircuitState.open));
          expect(state.halfOpenSuccessCount, equals(0));
          expect(state.trialRequestInProgress, isFalse);
        },
      );
    });

    group('Reset Timeout & Clock Drift Defenses', () {
      test(
        'backward clock jump in open state normalizes failure timestamp',
        () async {
          final context = ResilienceContext();
          final res = Resource(
            'clock-skew-res',
            circuitBreaker: CircuitBreakerConfig(
              resetTimeout: const Duration(seconds: 1),
            ),
          );
          final state = context.states.putIfAbsent(
            res.name,
            () => ResourceState(res.config),
          );

          // Simulate state open with future failure time (backward clock shift)
          state.circuitState = CircuitState.open;
          final futureTime = DateTime.now().add(const Duration(hours: 1));
          state.lastFailureTime = futureTime;
          state.lastStateChange = futureTime;

          // Executing should detect clock skew, normalize to now, and block as open
          await expectLater(
            context.execute(res, () async => 'ok'),
            throwsA(isA<CircuitBreakerOpenException>()),
          );

          // Verify failureTime was normalized to now
          expect(state.lastFailureTime!.isBefore(futureTime), isTrue);
          expect(state.lastStateChange.isBefore(futureTime), isTrue);
        },
      );

      test(
        'isAllowed adapts to backward clock jump without prolonged lockout',
        () async {
          final config = ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
              resetTimeout: const Duration(milliseconds: 50),
            ),
          );
          final state = ResourceState(config);
          final cb = CircuitBreaker(config, state);

          cb.recordFailure();
          expect(state.circuitState, equals(CircuitState.open));

          // Inject future timestamp as if clock jumped backward after failure was recorded
          state.lastFailureTime = DateTime.now().add(const Duration(hours: 1));

          // Querying isAllowed should normalize and not hang for 1 hour
          expect(cb.isAllowed, isFalse);
          expect(
            state.lastFailureTime!.isBefore(
              DateTime.now().add(const Duration(seconds: 1)),
            ),
            isTrue,
          );

          await Future.delayed(const Duration(milliseconds: 70));
          expect(cb.isAllowed, isTrue);
        },
      );

      test(
        'retry attempt recovers circuit breaker if reset timeout expires during retry delay',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'cb-retry-recover',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 1,
                resetTimeout: const Duration(milliseconds: 50),
                halfOpenSuccessThreshold: 1,
              ),
              retry: RetryConfig(
                maxAttempts: 2,
                baseDelay: const Duration(milliseconds: 80),
                enableJitter: false,
              ),
              throttling: ThrottlingConfig(k: 100.0),
            ),
          );
          final op = Operation('call', resource);

          int attempts = 0;
          final result = await context.execute(op, () async {
            attempts++;
            if (attempts == 1) {
              throw Exception('temporary fail');
            }
            return 'recovered';
          });

          expect(result, equals('recovered'));
          expect(attempts, equals(2));

          final state = context.states[resource.name]!;
          expect(state.circuitState, equals(CircuitState.closed));
        },
      );
    });

    group('Half-Open Concurrency & Trial Locks', () {
      test(
        'limits concurrent requests in half-open state to single trial',
        () async {
          final config = ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
              resetTimeout: const Duration(milliseconds: 50),
            ),
          );
          final state = ResourceState(config);
          final cb = CircuitBreaker(config, state);

          cb.recordFailure();
          cb.recordFailure();
          await Future.delayed(const Duration(milliseconds: 70));

          expect(cb.isAllowed, isTrue);
          expect(cb.tryAcquireTrial(), isTrue); // First allowed
          expect(cb.tryAcquireTrial(), isFalse); // Second rejected
          expect(
            cb.isAllowed,
            isFalse,
          ); // Request not allowed while trial in flight
        },
      );

      test(
        'thundering herd defense: 50 concurrent requests allow exactly 1 trial and reject 49',
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
              throttling: ThrottlingConfig(k: 100.0, minRequests: 100),
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

          await Future.delayed(const Duration(milliseconds: 70));

          final trialCompleter = Completer<String>();
          int trialCount = 0;
          int rejectedCount = 0;

          final futures = List.generate(50, (index) {
            return context
                .execute(op, () async {
                  trialCount++;
                  return await trialCompleter.future;
                })
                .then((val) => val)
                .catchError((e) {
                  if (e is CircuitBreakerOpenException) {
                    rejectedCount++;
                  }
                  return 'rejected';
                });
          });

          // Let the first admitted trial start executing
          await Future.delayed(const Duration(milliseconds: 20));
          expect(trialCount, equals(1));

          trialCompleter.complete('trial-success');
          await Future.wait(futures);

          expect(trialCount, equals(1));
          expect(rejectedCount, equals(49));
          expect(
            context.states['concurrent-half-open']?.circuitState,
            equals(CircuitState.closed),
          );
        },
      );

      test(
        'CircuitBreaker.execute prevents thundering herd during half-open trial',
        () async {
          final cb = CircuitBreaker.standalone(
            config: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
              resetTimeout: const Duration(milliseconds: 20),
              halfOpenSuccessThreshold: 1,
            ),
          );

          await expectLater(
            cb.execute(() async => throw Exception('backend down')),
            throwsException,
          );
          expect(cb.state.circuitState, equals(CircuitState.open));

          await Future.delayed(const Duration(milliseconds: 30));

          final trialCompleter = Completer<String>();
          final future1 = cb.execute(() => trialCompleter.future);

          // Arrives while trial is in flight; must be rejected immediately
          await expectLater(
            cb.execute(() async => 'concurrent-request'),
            throwsA(isA<CircuitBreakerOpenException>()),
          );

          trialCompleter.complete('trial-success');
          expect(await future1, equals('trial-success'));
          expect(cb.state.circuitState, equals(CircuitState.closed));
        },
      );

      test(
        'external cancellation of trial request releases trial lock',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'deadlock-service',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 2,
                resetTimeout: const Duration(milliseconds: 50),
                halfOpenSuccessThreshold: 1,
              ),
              throttling: ThrottlingConfig(k: 100.0),
            ),
          );
          final op = Operation('call', resource);

          for (int i = 0; i < 2; i++) {
            try {
              await context.execute(op, () async => throw Exception('fail'));
            } catch (_) {}
          }
          final state = context.states['deadlock-service']!;
          expect(state.circuitState, equals(CircuitState.open));

          await Future.delayed(const Duration(milliseconds: 70));

          final cancelToken = CancellationToken();
          final inFlightCompleter = Completer<void>();

          final trialFuture = ResilienceContext.runWithCancellationToken(
            cancelToken,
            () {
              return context.executeCancelable<String>(op, (cancel) async {
                inFlightCompleter.complete();
                await cancel.future;
                throw const OperationCancelledException();
              });
            },
          );

          await inFlightCompleter.future;
          expect(state.circuitState, equals(CircuitState.halfOpen));
          expect(state.trialRequestInProgress, isTrue);

          cancelToken.cancel();

          await expectLater(
            trialFuture,
            throwsA(isA<OperationCancelledException>()),
          );

          expect(state.trialRequestInProgress, isFalse);

          final recoveryResult = await context.execute(
            op,
            () async => 'success',
          );
          expect(recoveryResult, equals('success'));
          expect(state.circuitState, equals(CircuitState.closed));
        },
      );

      test(
        'pre-execution cancellation of trial request releases trial lock',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'deadlock-pre-cancel',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 2,
                resetTimeout: const Duration(milliseconds: 50),
                halfOpenSuccessThreshold: 1,
              ),
              throttling: ThrottlingConfig(k: 100.0),
            ),
          );
          final op = Operation('call', resource);

          for (int i = 0; i < 2; i++) {
            try {
              await context.execute(op, () async => throw Exception('fail'));
            } catch (_) {}
          }
          final state = context.states['deadlock-pre-cancel']!;
          expect(state.circuitState, equals(CircuitState.open));

          await Future.delayed(const Duration(milliseconds: 70));

          final cancelToken = CancellationToken()..cancel();

          await expectLater(
            () => ResilienceContext.runWithCancellationToken(cancelToken, () {
              return context.execute(op, () async => 'done');
            }),
            throwsA(isA<OperationCancelledException>()),
          );

          expect(state.trialRequestInProgress, isFalse);

          final result = await context.execute(op, () async => 'success');
          expect(result, equals('success'));
          expect(state.circuitState, equals(CircuitState.closed));
        },
      );

      test(
        'unhandled exception in trial request releases trial lock',
        () async {
          final context = ResilienceContext();
          final resource = Resource(
            'deadlock-unhandled-err',
            config: ResourceConfig(
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 2,
                resetTimeout: const Duration(milliseconds: 50),
                halfOpenSuccessThreshold: 1,
              ),
              throttling: ThrottlingConfig(k: 100.0),
            ),
          );
          final op = Operation('call', resource);

          for (int i = 0; i < 2; i++) {
            try {
              await context.execute(op, () async => throw Exception('fail'));
            } catch (_) {}
          }
          final state = context.states['deadlock-unhandled-err']!;
          expect(state.circuitState, equals(CircuitState.open));

          await Future.delayed(const Duration(milliseconds: 70));

          await expectLater(
            () => context.execute(
              op,
              () async => throw ArgumentError('bad input'),
            ),
            throwsArgumentError,
          );

          expect(state.trialRequestInProgress, isFalse);

          final result = await context.execute(op, () async => 'success');
          expect(result, equals('success'));
        },
      );

      test(
        'isAllowed query before execute does not deadlock half-open state',
        () async {
          final cb = CircuitBreaker.standalone(
            config: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
              resetTimeout: const Duration(milliseconds: 20),
              halfOpenSuccessThreshold: 1,
            ),
          );

          await expectLater(
            cb.execute(() async => throw Exception('backend failure')),
            throwsException,
          );
          expect(cb.state.circuitState, equals(CircuitState.open));

          await Future.delayed(const Duration(milliseconds: 30));

          expect(cb.isAllowed, isTrue);

          final result = await cb.execute(() async => 'recovered');
          expect(result, equals('recovered'));
          expect(cb.state.circuitState, equals(CircuitState.closed));
        },
      );

      test(
        'permits re-entrant calls within active trial on standalone CircuitBreaker',
        () async {
          final cb = CircuitBreaker.standalone(
            config: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
              resetTimeout: const Duration(milliseconds: 20),
              halfOpenSuccessThreshold: 1,
            ),
          );

          await expectLater(
            cb.execute(() async => throw Exception('outage')),
            throwsException,
          );
          expect(cb.state.circuitState, equals(CircuitState.open));

          await Future.delayed(const Duration(milliseconds: 30));

          final result = await cb.execute(() async {
            final subResult = await cb.execute(() async => 'sub-ok');
            return 'root-$subResult';
          });

          expect(result, equals('root-sub-ok'));
          expect(cb.state.circuitState, equals(CircuitState.closed));
        },
      );
    });

    group('Hierarchical Resources (Parent-Child Circuit Breakers)', () {
      late ResilienceContext context;
      late Resource parent;
      late Resource child;
      late Operation parentOp;
      late Operation childOp;

      setUp(() {
        context = ResilienceContext();
        parent = Resource(
          'parent-service',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 2,
              resetTimeout: const Duration(milliseconds: 100),
              halfOpenSuccessThreshold: 2,
            ),
            retry: RetryConfig(maxAttempts: 1),
            throttling: ThrottlingConfig(minRequests: 100),
          ),
        );
        child = Resource(
          'child-service',
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
        parentOp = Operation('parentOp', parent);
        childOp = Operation('childOp', child);
      });

      test(
        'open parent blocks child requests with informative exception',
        () async {
          for (int i = 0; i < 2; i++) {
            try {
              await context.execute(
                parentOp,
                () async => throw Exception('fail'),
              );
            } catch (_) {}
          }

          expect(
            context.states['parent-service']?.circuitState,
            equals(CircuitState.open),
          );

          expect(
            () => context.execute(childOp, () async => 'success'),
            throwsA(
              predicate(
                (e) =>
                    e is CircuitBreakerOpenException &&
                    e.toString().contains(
                      'Circuit breaker is open for parent-service',
                    ),
              ),
            ),
          );
        },
      );

      test('child failure does not trip parent (selectivity)', () async {
        for (int i = 0; i < 2; i++) {
          try {
            await context.execute(childOp, () async => throw Exception('fail'));
          } catch (_) {}
        }

        expect(
          context.states['child-service']?.circuitState,
          equals(CircuitState.open),
        );
        expect(
          context.states['parent-service']?.circuitState,
          equals(CircuitState.closed),
        );

        final res = await context.execute(
          parentOp,
          () async => 'parent-success',
        );
        expect(res, equals('parent-success'));
      });

      test('parent recovery via child trial request', () async {
        for (int i = 0; i < 2; i++) {
          try {
            await context.execute(
              parentOp,
              () async => throw Exception('fail'),
            );
          } catch (_) {}
        }
        expect(
          context.states['parent-service']?.circuitState,
          equals(CircuitState.open),
        );

        await Future.delayed(const Duration(milliseconds: 120));

        final res1 = await context.execute(childOp, () async => 'success1');
        expect(res1, equals('success1'));
        expect(
          context.states['parent-service']?.circuitState,
          equals(CircuitState.halfOpen),
        );
        expect(
          context.states['parent-service']?.halfOpenSuccessCount,
          equals(1),
        );

        final res2 = await context.execute(childOp, () async => 'success2');
        expect(res2, equals('success2'));
        expect(
          context.states['parent-service']?.circuitState,
          equals(CircuitState.closed),
        );
      });

      test('sequential trials enforced hierarchically', () async {
        for (int i = 0; i < 2; i++) {
          try {
            await context.execute(
              parentOp,
              () async => throw Exception('fail'),
            );
          } catch (_) {}
        }

        await Future.delayed(const Duration(milliseconds: 120));

        final trialCompleter = Completer<String>();
        final trialFuture = context.execute(childOp, () async {
          return await trialCompleter.future;
        });

        await Future.delayed(const Duration(milliseconds: 10));
        expect(
          context.states['parent-service']?.circuitState,
          equals(CircuitState.halfOpen),
        );
        expect(
          context.states['parent-service']?.trialRequestInProgress,
          isTrue,
        );

        expect(
          () => context.execute(childOp, () async => 'success'),
          throwsA(
            predicate(
              (e) =>
                  e is CircuitBreakerOpenException &&
                  e.toString().contains(
                    'Circuit breaker is half-open for parent-service',
                  ),
            ),
          ),
        );

        trialCompleter.complete('trial-success');
        expect(await trialFuture, equals('trial-success'));
      });

      test(
        '3-level hierarchy (Grandparent -> Parent -> Child) propagates state',
        () async {
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
          final p = Resource(
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
          final c = Resource(
            'c',
            parent: p,
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
          final cOp = Operation('cOp', c);

          for (int i = 0; i < 2; i++) {
            try {
              await context.execute(gpOp, () async => throw Exception('fail'));
            } catch (_) {}
          }

          expect(context.states['gp']?.circuitState, equals(CircuitState.open));

          await expectLater(
            context.execute(cOp, () async => 'ok'),
            throwsA(isA<CircuitBreakerOpenException>()),
          );

          await Future.delayed(const Duration(milliseconds: 120));

          final result = await context.execute(cOp, () async => 'healed');
          expect(result, equals('healed'));
          expect(
            context.states['gp']?.circuitState,
            equals(CircuitState.closed),
          );
        },
      );

      test('hierarchy transactional rollback on ancestor failure', () async {
        final grandparent = Resource(
          'rollback-gp',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
            ),
          ),
        );
        final p = Resource(
          'rollback-p',
          parent: grandparent,
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
            ),
          ),
        );
        final c = Resource(
          'rollback-c',
          parent: p,
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
            ),
          ),
        );

        final gpOp = Operation('gp-op', grandparent);
        try {
          await context.execute(gpOp, () async => throw Exception('gp-fail'));
        } catch (_) {}
        expect(
          context.states['rollback-gp']!.circuitState,
          equals(CircuitState.open),
        );

        final childOp = Operation('c-op', c);
        await expectLater(
          context.execute(childOp, () async => 'should-not-run'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );

        expect(
          context.states['rollback-c']!.circuitState,
          equals(CircuitState.closed),
        );
        expect(
          context.states['rollback-p']!.circuitState,
          equals(CircuitState.closed),
        );
      });
    });

    group('Failure Classification & Error Handling', () {
      late ResilienceContext context;
      late Resource resource;
      late Operation op;

      setUp(() {
        context = ResilienceContext();
        resource = Resource(
          'classifier-service',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 3,
              resetTimeout: const Duration(seconds: 5),
            ),
            throttling: ThrottlingConfig(k: 100.0),
          ),
        );
        op = Operation('call', resource);
      });

      test('trips circuit breaker on backend exceptions', () async {
        final state = context.states.putIfAbsent(
          'classifier-service',
          () => ResourceState(resource.config),
        );

        for (int i = 0; i < 3; i++) {
          try {
            await context.execute(
              op,
              () async => throw Exception('503 Service Unavailable'),
            );
          } catch (_) {}
        }

        expect(state.failureCount, equals(3));
        expect(state.circuitState, equals(CircuitState.open));
      });

      test('client programmer errors do not trip circuit breaker', () async {
        final state = context.states.putIfAbsent(
          'classifier-service',
          () => ResourceState(resource.config),
        );

        try {
          await context.execute(
            op,
            () async => throw ArgumentError('invalid param'),
          );
        } catch (_) {}
        try {
          await context.execute(
            op,
            () async => throw const FormatException('bad json'),
          );
        } catch (_) {}
        try {
          await context.execute(
            op,
            () async => throw RangeError('index out of range'),
          );
        } catch (_) {}

        expect(state.failureCount, equals(0));
        expect(state.circuitState, equals(CircuitState.closed));
      });

      test('user cancellations do not trip circuit breaker', () async {
        final state = context.states.putIfAbsent(
          'classifier-service',
          () => ResourceState(resource.config),
        );

        for (int i = 0; i < 5; i++) {
          final cancelToken = CancellationToken()..cancel();
          try {
            await ResilienceContext.runWithCancellationToken(cancelToken, () {
              return context.execute(op, () async => 'success');
            });
          } catch (_) {}
        }

        expect(state.failureCount, equals(0));
        expect(state.circuitState, equals(CircuitState.closed));
      });

      test(
        'unclassified / client error in half-open does not falsely close circuit breaker',
        () async {
          final customConfig = ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
              resetTimeout: const Duration(milliseconds: 50),
              halfOpenSuccessThreshold: 1,
            ),
          );
          final customState = ResourceState(customConfig);
          final customCb = CircuitBreaker(customConfig, customState);

          customCb.recordFailure();
          expect(customState.circuitState, equals(CircuitState.open));

          await Future.delayed(const Duration(milliseconds: 70));
          expect(customCb.isAllowed, isTrue);
          expect(customState.circuitState, equals(CircuitState.halfOpen));

          // Throwing ArgumentError (programmer error, not backend failure)
          await expectLater(
            customCb.execute(() async => throw ArgumentError('invalid arg')),
            throwsArgumentError,
          );

          // Circuit breaker must NOT close; it remains open / releases trial lock
          expect(customState.circuitState, isNot(equals(CircuitState.closed)));
          expect(customState.trialRequestInProgress, isFalse);
        },
      );

      test(
        'fault inversion: CircuitBreakerOpenException & ThrottledException are not server failures',
        () {
          final config = ResourceConfig();
          expect(
            config.failureClassifier(CircuitBreakerOpenException('open')),
            isFalse,
          );
          expect(
            config.failureClassifier(const ThrottledException('throttled')),
            isFalse,
          );
          expect(
            config.failureClassifier(const OperationCancelledException()),
            isFalse,
          );
          expect(config.failureClassifier(Exception('server error')), isTrue);
        },
      );

      test(
        'handles throwing failureClassifier without corrupting state',
        () async {
          final cb = CircuitBreaker.standalone(
            config: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
              resetTimeout: const Duration(milliseconds: 20),
              halfOpenSuccessThreshold: 1,
            ),
            failureClassifier: (e) {
              if (e is FormatException) return true;
              throw TypeError();
            },
          );

          await expectLater(
            cb.execute(() async => throw const FormatException('fail')),
            throwsA(isA<FormatException>()),
          );
          expect(cb.state.circuitState, equals(CircuitState.open));

          await Future.delayed(const Duration(milliseconds: 30));

          await expectLater(
            cb.execute(() async => throw StateError('system crash')),
            throwsA(isA<StateError>()),
          );

          expect(cb.state.circuitState, equals(CircuitState.open));
          expect(cb.state.trialRequestInProgress, isFalse);
          expect(cb.state.isExecutingTrial, isFalse);
        },
      );

      test(
        'timeout does not double-record failures in circuit breaker',
        () async {
          final timeoutResource = Resource(
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
          final timeoutOp = Operation('op', timeoutResource);

          // Timeout 1
          try {
            await context.execute(timeoutOp, () async {
              await Future.delayed(const Duration(milliseconds: 80));
              return 'ok';
            });
          } catch (_) {}

          final state = context.states['timeout-no-double-count']!;
          expect(state.failureCount, equals(1));
          expect(state.circuitState, equals(CircuitState.closed));

          // Timeout 2
          try {
            await context.execute(timeoutOp, () async {
              await Future.delayed(const Duration(milliseconds: 80));
              return 'ok';
            });
          } catch (_) {}

          expect(state.failureCount, equals(2));
          expect(state.circuitState, equals(CircuitState.closed));

          // Timeout 3 -> Trips breaker
          try {
            await context.execute(timeoutOp, () async {
              await Future.delayed(const Duration(milliseconds: 80));
              return 'ok';
            });
          } catch (_) {}

          expect(state.failureCount, equals(3));
          expect(state.circuitState, equals(CircuitState.open));
        },
      );

      test(
        'failureClassifier is respected on top-level timeout in executeCancelable',
        () async {
          final timeoutClassifierResource = Resource(
            'timeout-classifier-test',
            config: ResourceConfig(
              timeout: const Duration(milliseconds: 20),
              circuitBreaker: CircuitBreakerConfig(
                consecutiveFailuresThreshold: 1,
              ),
              failureClassifier: (e) => e is! ResilienceTimeoutException,
            ),
          );
          final toOp = Operation('op', timeoutClassifierResource);

          try {
            await context.execute(toOp, () async {
              await Future.delayed(const Duration(milliseconds: 100));
              return 'ok';
            });
          } catch (_) {}

          final state = context.states['timeout-classifier-test']!;
          expect(state.circuitState, equals(CircuitState.closed));
          expect(state.failureCount, equals(0));
        },
      );
    });

    group('Exception Formatting', () {
      test(
        'CircuitBreakerOpenException toString contains informative message',
        () {
          final ex = CircuitBreakerOpenException('auth-service');
          expect(
            ex.toString(),
            equals('CircuitBreakerOpenException: auth-service'),
          );
          expect(ex.message, contains('auth-service'));
        },
      );
    });
  });
}
