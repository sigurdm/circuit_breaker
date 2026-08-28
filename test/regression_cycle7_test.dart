import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/hedging.dart';
import 'package:test/test.dart';

void main() {
  group('Cycle 7 Regression Tests', () {
    test(
      'CircuitBreaker.execute handles throwing failureClassifier without corrupting state',
      () async {
        final cb = CircuitBreaker.standalone(
          config: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1,
            resetTimeout: const Duration(milliseconds: 20),
            halfOpenSuccessThreshold: 1,
          ),
          // Buggy user classifier that throws on unexpected exceptions
          failureClassifier: (e) {
            if (e is FormatException) return true;
            throw TypeError(); // Buggy throw!
          },
        );

        // Trip to OPEN
        await expectLater(
          cb.execute(() async => throw const FormatException('fail')),
          throwsA(isA<FormatException>()),
        );
        expect(cb.state.circuitState, equals(CircuitState.open));

        // Wait for reset timeout
        await Future.delayed(const Duration(milliseconds: 30));

        // Run trial request that throws an unhandled error causing failureClassifier to throw
        await expectLater(
          cb.execute(() async => throw StateError('system crash')),
          throwsA(isA<StateError>()),
        );

        // Circuit breaker should have safely tripped back to OPEN, not stuck in half-open
        expect(cb.state.circuitState, equals(CircuitState.open));
        expect(cb.state.trialRequestInProgress, isFalse);
        expect(cb.state.isExecutingTrial, isFalse);
      },
    );

    test(
      'AdaptiveThrottler.execute handles throwing failureClassifier cleanly',
      () async {
        final throttler = AdaptiveThrottler.standalone(
          failureClassifier: (e) => throw TypeError(),
        );

        await expectLater(
          throttler.execute(() async => throw StateError('crash')),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('cleanHistory fast prefix slicing and backward clock jump defense', () {
      final config = ResourceConfig();
      final state = ResourceState(config);

      final now = DateTime.now();
      final oldTime = now.subtract(const Duration(hours: 1));
      final futureTime = now.add(const Duration(hours: 1)); // From clock jump!

      // Add old records, current records, and future records
      state.requestHistory[Criticality.critical]!.addAll([
        RequestRecord(oldTime, true),
        RequestRecord(now, true),
        RequestRecord(futureTime, true),
      ]);

      // Call cleanHistory
      state.cleanHistory(now);

      // Future records must be purged, old records must be purged, only current remains
      final remaining = state.requestHistory[Criticality.critical]!;
      expect(remaining.length, equals(1));
      expect(remaining.first.timestamp, equals(now));
    });

    test(
      'CircuitBreaker.isAllowed adapts to backward clock jump without prolonged lockout',
      () async {
        final cb = CircuitBreaker.standalone(
          config: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 1,
            resetTimeout: const Duration(milliseconds: 20),
          ),
        );

        cb.recordFailure();
        expect(cb.state.circuitState, equals(CircuitState.open));

        // Simulate backward clock jump: set failureTime to 1 hour in the future
        cb.state.lastFailureTime = DateTime.now().add(const Duration(hours: 1));

        // Query isAllowed - it should detect backward clock jump, adjust failureTime to now, and return false
        expect(cb.isAllowed, isFalse);
        expect(
          cb.state.lastFailureTime!.isBefore(
            DateTime.now().add(const Duration(seconds: 1)),
          ),
          isTrue,
        );

        // After resetTimeout elapses, it transitions to half-open
        await Future.delayed(const Duration(milliseconds: 30));
        expect(cb.isAllowed, isTrue);
        expect(cb.state.circuitState, equals(CircuitState.halfOpen));
      },
    );

    test('runWithCancellationToken attaches nested token to parent token', () {
      final parentToken = CancellationToken();
      final childToken = CancellationToken();

      ResilienceContext.runWithCancellationToken(parentToken, () {
        ResilienceContext.runWithCancellationToken(childToken, () {
          expect(childToken.isCancelled, isFalse);
          parentToken.cancel();
          expect(childToken.isCancelled, isTrue);
        });
      });
    });

    test(
      'executeWithHedging cleans up completers on synchronous operation exception',
      () async {
        final config = ResourceConfig(hedging: HedgingConfig(enabled: true));
        final state = ResourceState(config);

        expect(
          () => executeWithHedging<String>(
            (cancel) => throw ArgumentError('sync error on primary'),
            config: config,
            state: state,
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });
}
