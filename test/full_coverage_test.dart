import 'dart:async';
import 'dart:io';
import 'package:test/test.dart' hide Retry;
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/hedging.dart';
import 'package:circuit_breaker/src/retry.dart';

void main() {
  group('Full 100% Coverage Suite', () {
    test(
      'ResilienceContext clock skew backward jump when open normalizes failureTime',
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

        // Executing should detect now.isBefore(failureTime), normalize to now, and block as open
        await expectLater(
          context.execute(res, () async => 'ok'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );

        // Verify failureTime was normalized to now (not in the future anymore)
        expect(state.lastFailureTime!.isBefore(futureTime), isTrue);
        expect(state.lastStateChange.isBefore(futureTime), isTrue);
      },
    );

    test(
      'Retry: executeWithRetry throws when ambient deadline is in the past before attempt',
      () async {
        final res = Resource('direct-retry-deadline-res');
        final state = ResourceState(res.config);

        await expectLater(
          ResilienceContext.runWithDeadline(
            DateTime.now().subtract(const Duration(seconds: 1)),
            () => executeWithRetry(
              () async => 'ok',
              config: res.config,
              state: state,
            ),
          ),
          throwsA(isA<ResilienceTimeoutException>()),
        );
      },
    );

    test(
      'Retry: backoff delay with jitter when maxAttemptDelayUs >= maxDelay',
      () async {
        final retrier = Retry.standalone(
          config: RetryConfig(
            maxAttempts: 2,
            baseDelay: const Duration(milliseconds: 10),
            maxDelay: const Duration(milliseconds: 10),
            enableJitter: true,
          ),
        );

        int attempts = 0;
        final res = await retrier.execute(() async {
          attempts++;
          if (attempts == 1) throw Exception('transient failure');
          return 'retry-success';
        });

        expect(res, equals('retry-success'));
        expect(attempts, equals(2));
      },
    );

    test(
      'Retry.standalone: earlier parent deadline, expired deadline, and cancellation',
      () async {
        // 1. parentDeadline earlier than localDeadline
        final parentDeadline = DateTime.now().add(
          const Duration(milliseconds: 50),
        );
        final retrier = Retry.standalone(timeout: const Duration(seconds: 10));

        final res = await ResilienceContext.runWithDeadline(
          parentDeadline,
          () async {
            return await retrier.execute(() async => 'deadline-ok');
          },
        );
        expect(res, equals('deadline-ok'));

        // 2. deadline already expired before execution
        final expiredRetrier = Retry.standalone(
          timeout: const Duration(milliseconds: 1),
        );
        await Future.delayed(const Duration(milliseconds: 10));
        await expectLater(
          ResilienceContext.runWithDeadline(
            DateTime.now().subtract(const Duration(milliseconds: 50)),
            () => expiredRetrier.execute(() async => 'fail'),
          ),
          throwsA(isA<ResilienceTimeoutException>()),
        );

        // 3. parent cancellation token attached and cancelled during execution
        final parentToken = CancellationToken();
        final tokenRetrier = Retry.standalone();
        final completer = Completer<String>();

        final future = ResilienceContext.runWithCancellationToken(
          parentToken,
          () {
            return tokenRetrier.execute(() => completer.future);
          },
        );

        parentToken.cancel();
        await expectLater(future, throwsA(isA<OperationCancelledException>()));

        // 4. unhandled error inside runZonedGuarded
        final errorRetrier = Retry.standalone();
        await expectLater(
          errorRetrier.execute(() {
            Timer.run(
              () => throw StateError('unhandled async error in retry zone'),
            );
            return Completer<String>().future;
          }),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'RequestHedger: cancel before delayCompleter, dynamic hedging timer cleanup, and disabled config copy',
      () async {
        // 1. HedgingConfig with enabled: false gets cloned with enabled: true
        final customConfig = HedgingConfig(
          enabled: false,
          delay: const Duration(milliseconds: 50),
        );
        final hedgerFromDisabled = RequestHedger.standalone(
          config: customConfig,
        );
        expect(hedgerFromDisabled.config.hedging.enabled, isTrue);

        // 2. Token cancelled during delayCompleter.future in executeWithHedging
        final cancelToken = CancellationToken();
        final resConfig = ResourceConfig(
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 50),
            dynamicPercentile: 0.9,
          ),
        );
        Timer(const Duration(milliseconds: 10), () => cancelToken.cancel());
        await expectLater(
          ResilienceContext.runWithCancellationToken(cancelToken, () {
            return executeWithHedging(
              (c) => Completer<String>().future,
              config: resConfig,
              state: ResourceState(resConfig),
            );
          }),
          throwsA(isA<OperationCancelledException>()),
        );

        // 3. Dynamic hedging: synchronous hedge exception cancels earlyRegTimer
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
        final dynState = ResourceState(dynConfig);
        int attempts = 0;
        await expectLater(
          executeWithHedging(
            (c) {
              attempts++;
              if (attempts == 1) {
                return Completer<String>().future;
              }
              throw StateError('sync hedge crash');
            },
            config: dynConfig,
            state: dynState,
          ),
          throwsA(isA<StateError>()),
        );

        // 4. Dynamic hedging: cancellation while both f1 and f2 in flight cancels earlyRegTimer
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
        // Wait for hedge to start
        await Future.delayed(const Duration(milliseconds: 30));
        expect(activeAttempts, equals(2));
        activeToken.cancel();
        await expectLater(f, throwsA(isA<OperationCancelledException>()));

        // 5. Dynamic hedging: both f1 and f2 fail cancels earlyRegTimer
        final bothFailConfig = ResourceConfig(
          hedging: HedgingConfig(
            enabled: true,
            delay: const Duration(milliseconds: 10),
            dynamicPercentile: 0.9,
          ),
        );
        int failAttempts = 0;
        await expectLater(
          executeWithHedging(
            (c) async {
              failAttempts++;
              if (failAttempts == 1) {
                await Future.delayed(const Duration(milliseconds: 25));
              } else {
                await Future.delayed(const Duration(milliseconds: 5));
              }
              throw StateError('both fail');
            },
            config: bothFailConfig,
            state: ResourceState(bothFailConfig),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'RequestHedger.standalone: parent deadline, expired deadline, cancellation, and unhandled async error',
      () async {
        // 1. parentDeadline earlier than localDeadline
        final parentDeadline = DateTime.now().add(
          const Duration(milliseconds: 50),
        );
        final hedger = RequestHedger.standalone(
          timeout: const Duration(seconds: 10),
        );

        final res = await ResilienceContext.runWithDeadline(
          parentDeadline,
          () async {
            return await hedger.execute(() async => 'hedger-deadline-ok');
          },
        );
        expect(res, equals('hedger-deadline-ok'));

        // 2. deadline already expired before execution
        await expectLater(
          ResilienceContext.runWithDeadline(
            DateTime.now().subtract(const Duration(milliseconds: 50)),
            () => hedger.executeCancelable((c) async => 'fail'),
          ),
          throwsA(isA<ResilienceTimeoutException>()),
        );

        // 3. parent token attached and cancelled triggers topLevelCancel in executeCancelable
        final parentToken = CancellationToken();
        final cCompleter = Completer<String>();
        final f = ResilienceContext.runWithCancellationToken(parentToken, () {
          return hedger.executeCancelable((c) => cCompleter.future);
        });
        parentToken.cancel();
        await expectLater(f, throwsA(isA<OperationCancelledException>()));

        // 4. deadline expires during execution check in wrappedAction
        final slowHedgerState = DelayingHedgerState(
          ResourceConfig(
            timeout: const Duration(milliseconds: 5),
            hedging: HedgingConfig(
              enabled: true,
              delay: const Duration(milliseconds: 50),
            ),
          ),
        );
        final slowHedger = RequestHedger(
          slowHedgerState.config,
          slowHedgerState,
        );
        await expectLater(
          slowHedger.executeCancelable((c) async => 'ok'),
          throwsA(
            isA<ResilienceTimeoutException>().having(
              (e) => e.message,
              'message',
              contains('Deadline exceeded during execution'),
            ),
          ),
        );

        // 5. unhandled async error in runZonedGuarded
        await expectLater(
          hedger.executeCancelable((c) {
            Timer.run(
              () => throw StateError('unhandled async error in hedger zone'),
            );
            return Completer<String>().future;
          }),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}

class DelayingHedgerState extends ResourceState {
  DelayingHedgerState(super.config);

  @override
  void recordLogicalRequest() {
    super.recordLogicalRequest();
    sleep(const Duration(milliseconds: 10));
  }
}
