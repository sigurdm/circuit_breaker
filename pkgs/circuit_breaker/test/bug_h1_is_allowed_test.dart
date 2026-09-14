import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Bug H1: CircuitBreaker.isAllowed and Trial Watchdog', () {
    test(
      'reading cb.isAllowed on a Resource does not brick subsequent context.execute',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'test-service',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
              resetTimeout: const Duration(milliseconds: 30),
              halfOpenSuccessThreshold: 1,
            ),
            throttling: ThrottlingConfig(k: 100.0),
          ),
        );
        final op = Operation('op', resource);

        // 1. Trip breaker to open
        await expectLater(
          () => context.execute(op, () async => throw Exception('failure')),
          throwsException,
        );

        final state = context.states['test-service']!;
        expect(state.circuitState, equals(CircuitState.open));

        // 2. Wait for resetTimeout
        await Future.delayed(const Duration(milliseconds: 45));

        // 3. Construct CB and read isAllowed multiple times
        final cb = CircuitBreaker(resource.config, state);
        expect(cb.isAllowed, isTrue);
        expect(cb.isAllowed, isTrue);

        // Crucial invariant: reading isAllowed MUST NOT fabricate an activeTrialToken
        expect(state.activeTrialToken, isNull);
        expect(state.trialRequestInProgress, isFalse);

        // 4. Subsequent context.execute must succeed and not be blocked
        final result = await context.execute(op, () async => 'recovered');
        expect(result, equals('recovered'));
        expect(state.circuitState, equals(CircuitState.closed));
      },
    );

    test(
      'reading cb.isAllowed on standalone CircuitBreaker does not brick subsequent cb.execute',
      () async {
        final cb = CircuitBreaker.standalone(
          config: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1,
            resetTimeout: const Duration(milliseconds: 30),
            halfOpenSuccessThreshold: 1,
          ),
        );

        // Trip to open
        await expectLater(
          () => cb.execute(() async => throw Exception('error')),
          throwsException,
        );
        expect(cb.isOpen, isTrue);

        // Wait for resetTimeout
        await Future.delayed(const Duration(milliseconds: 45));

        // Query isAllowed repeatedly
        expect(cb.isAllowed, isTrue);
        expect(cb.isAllowed, isTrue);
        expect(cb.isAllowed, isTrue);

        // Subsequent execute succeeds
        final res = await cb.execute(() async => 'ok');
        expect(res, equals('ok'));
        expect(cb.isClosed, isTrue);
      },
    );

    test('state inspection getters (isOpen, isHalfOpen, isClosed)', () async {
      final cb = CircuitBreaker.standalone(
        config: CircuitBreakerConfig(
          consecutiveFailuresThreshold: 1,
          resetTimeout: const Duration(milliseconds: 40),
          halfOpenSuccessThreshold: 1,
        ),
      );

      // Initially closed
      expect(cb.isClosed, isTrue);
      expect(cb.isOpen, isFalse);
      expect(cb.isHalfOpen, isFalse);
      expect(cb.isAllowed, isTrue);

      // Trip to open
      cb.recordFailure();
      expect(cb.isOpen, isTrue);
      expect(cb.isHalfOpen, isFalse);
      expect(cb.isClosed, isFalse);
      expect(cb.isAllowed, isFalse);

      // After timeout elapses
      await Future.delayed(const Duration(milliseconds: 55));
      expect(cb.isOpen, isFalse);
      expect(cb.isHalfOpen, isTrue);
      expect(cb.isClosed, isFalse);
      expect(cb.isAllowed, isTrue);

      // Record success -> closed
      cb.recordSuccess();
      expect(cb.isClosed, isTrue);
      expect(cb.isOpen, isFalse);
      expect(cb.isHalfOpen, isFalse);
      expect(cb.isAllowed, isTrue);
    });

    test(
      'tryAcquireTrial claims permit and prevents concurrent trials',
      () async {
        final cb = CircuitBreaker.standalone(
          config: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1,
            resetTimeout: const Duration(milliseconds: 30),
            halfOpenSuccessThreshold: 1,
          ),
        );

        cb.recordFailure();
        expect(cb.isOpen, isTrue);
        expect(cb.tryAcquireTrial(), isFalse);

        await Future.delayed(const Duration(milliseconds: 45));

        // First acquisition succeeds
        expect(cb.tryAcquireTrial(), isTrue);
        expect(cb.isHalfOpen, isTrue);
        expect(cb.state.trialRequestInProgress, isTrue);

        // Second acquisition rejected
        expect(cb.tryAcquireTrial(), isFalse);
        expect(cb.isAllowed, isFalse);

        // Finishing trial allows isAllowed and further trials
        cb.recordSuccess();
        expect(cb.isClosed, isTrue);
        expect(cb.isAllowed, isTrue);
      },
    );

    test(
      'watchdog: abandoned trial permit in standalone CircuitBreaker expires after resetTimeout',
      () async {
        final cb = CircuitBreaker.standalone(
          config: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1,
            resetTimeout: const Duration(milliseconds: 40),
            halfOpenSuccessThreshold: 1,
          ),
        );

        cb.recordFailure();
        await Future.delayed(const Duration(milliseconds: 50));

        // Someone claims the trial permit via tryAcquireTrial() but abandons it
        expect(cb.tryAcquireTrial(), isTrue);
        expect(cb.isAllowed, isFalse);
        expect(cb.state.trialRequestInProgress, isTrue);

        // Immediate execute is blocked because permit was claimed and not expired
        // (Wait: if tryAcquireTrial was called, cb.execute without trial expiration
        // executes the claimed permit. But another tryAcquireTrial fails.)
        expect(cb.tryAcquireTrial(), isFalse);

        // Wait for resetTimeout to expire the abandoned trial
        await Future.delayed(const Duration(milliseconds: 60));

        expect(
          cb.state.isTrialExpired(cb.config.circuitBreaker.resetTimeout),
          isTrue,
        );
        expect(cb.isAllowed, isTrue);

        // Subsequent execute can run and recover
        final result = await cb.execute(() async => 'recovered-after-abandon');
        expect(result, equals('recovered-after-abandon'));
        expect(cb.isClosed, isTrue);
      },
    );

    test(
      'watchdog: hanging trial in ResilienceContext times out and allows new trial',
      () async {
        final context = ResilienceContext();
        final resource = Resource(
          'hanging-service',
          config: ResourceConfig(
            circuitBreaker: CircuitBreakerConfig(
              consecutiveFailuresThreshold: 1,
              resetTimeout: const Duration(milliseconds: 40),
              halfOpenSuccessThreshold: 1,
            ),
            throttling: ThrottlingConfig(k: 100.0),
          ),
        );
        final op = Operation('op', resource);

        // Trip breaker to open
        await expectLater(
          () => context.execute(op, () async => throw Exception('fail')),
          throwsException,
        );

        await Future.delayed(const Duration(milliseconds: 50));

        // Start a hanging trial
        final hangingCompleter = Completer<String>();
        final hangingTrialFuture = context.execute(
          op,
          () => hangingCompleter.future,
        );
        final hangingExpectation = expectLater(
          hangingTrialFuture,
          throwsA(isA<OperationCancelledException>()),
        );

        // Ensure hanging trial registered
        await Future.delayed(const Duration(milliseconds: 5));
        final state = context.states['hanging-service']!;
        expect(state.circuitState, equals(CircuitState.halfOpen));
        expect(state.trialRequestInProgress, isTrue);
        final oldToken = state.activeTrialToken;
        expect(oldToken, isNotNull);

        // Concurrent request right now is blocked
        expect(
          () => context.execute(op, () async => 'blocked'),
          throwsA(isA<CircuitBreakerOpenException>()),
        );

        // Wait for resetTimeout to elapse on the hanging trial
        await Future.delayed(const Duration(milliseconds: 60));

        // Stale trial is now expired
        expect(
          state.isTrialExpired(resource.config.circuitBreaker.resetTimeout),
          isTrue,
        );

        // New request arrives: watchdog cancels old trial and executes new trial
        final newResult = await context.execute(
          op,
          () async => 'watchdog-success',
        );
        expect(newResult, equals('watchdog-success'));
        expect(state.circuitState, equals(CircuitState.closed));
        expect(oldToken!.isCancelled, isTrue);

        // Verify the old hanging trial was cancelled by the watchdog
        await hangingExpectation;
      },
    );
  });
}
