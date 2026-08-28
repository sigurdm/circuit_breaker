import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Circuit Breaker Deadlock Regression Tests', () {
    late ResilienceContext context;
    late Resource resource;
    late Operation op;

    setUp(() {
      context = ResilienceContext();
      resource = Resource(
        'deadlock-service',
        config: ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 2,
            resetTimeout: const Duration(milliseconds: 50),
            halfOpenSuccessThreshold: 1,
          ),
          throttling: ThrottlingConfig(k: 100.0), // Disable throttling
        ),
      );
      op = Operation('call', resource);
    });

    test('external cancellation of trial request releases trial lock', () async {
      // 1. Trip circuit breaker to OPEN
      for (int i = 0; i < 2; i++) {
        try {
          await context.execute(op, () async => throw Exception('fail'));
        } catch (_) {}
      }
      final state = context.states['deadlock-service']!;
      expect(state.circuitState, equals(CircuitState.open));

      // 2. Wait for resetTimeout to expire (50ms)
      await Future.delayed(const Duration(milliseconds: 70));

      // 3. Start trial request attached to a CancellationToken
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

      // Wait until trial is confirmed in flight
      await inFlightCompleter.future;
      expect(state.circuitState, equals(CircuitState.halfOpen));
      expect(state.trialRequestInProgress, isTrue);

      // 4. Cancel token while trial request is in-flight
      cancelToken.cancel();

      await expectLater(
        trialFuture,
        throwsA(isA<OperationCancelledException>()),
      );

      // 5. Verify trial request lock is NOT stuck
      expect(
        state.trialRequestInProgress,
        isFalse,
        reason: 'activeTrialToken must be cleared upon cancellation',
      );

      // 6. Dispatch subsequent request and verify it succeeds without deadlock
      final recoveryResult = await context.execute(op, () async => 'success');
      expect(recoveryResult, equals('success'));
      expect(state.circuitState, equals(CircuitState.closed));
    });

    test(
      'pre-execution cancellation of trial request releases trial lock',
      () async {
        // Trip circuit breaker to OPEN
        for (int i = 0; i < 2; i++) {
          try {
            await context.execute(op, () async => throw Exception('fail'));
          } catch (_) {}
        }
        final state = context.states['deadlock-service']!;
        expect(state.circuitState, equals(CircuitState.open));

        // Wait for resetTimeout
        await Future.delayed(const Duration(milliseconds: 70));

        // Cancel token before dispatching
        final cancelToken = CancellationToken()..cancel();

        await expectLater(
          () => ResilienceContext.runWithCancellationToken(cancelToken, () {
            return context.execute(op, () async => 'done');
          }),
          throwsA(isA<OperationCancelledException>()),
        );

        expect(state.trialRequestInProgress, isFalse);

        // Subsequent request must be allowed as trial
        final result = await context.execute(op, () async => 'success');
        expect(result, equals('success'));
        expect(state.circuitState, equals(CircuitState.closed));
      },
    );

    test('unhandled exception in trial request releases trial lock', () async {
      // Trip circuit breaker to OPEN
      for (int i = 0; i < 2; i++) {
        try {
          await context.execute(op, () async => throw Exception('fail'));
        } catch (_) {}
      }
      final state = context.states['deadlock-service']!;
      expect(state.circuitState, equals(CircuitState.open));

      // Wait for resetTimeout
      await Future.delayed(const Duration(milliseconds: 70));

      // Trial request throws a non-classified error (e.g. ArgumentError)
      await expectLater(
        () => context.execute(op, () async => throw ArgumentError('bad input')),
        throwsArgumentError,
      );

      // Lock must be released
      expect(state.trialRequestInProgress, isFalse);

      // Next request can run
      final result = await context.execute(op, () async => 'success');
      expect(result, equals('success'));
    });
  });
}
