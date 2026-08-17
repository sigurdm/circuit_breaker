import 'package:test/test.dart';
import 'package:circuit_breaker/src/circuit_breaker.dart';
import 'package:circuit_breaker/src/context.dart';

void main() {
  group('CircuitBreaker', () {
    late ResourceConfig config;
    late ResourceState state;
    late CircuitBreaker cb;

    setUp(() {
      config = ResourceConfig(
        circuitBreaker: CircuitBreakerConfig(
          consecutiveFailuresThreshold: 2,
          resetTimeout: Duration(milliseconds: 100),
        ),
      );
      state = ResourceState(config);
      cb = CircuitBreaker(config, state);
    });

    test('starts in closed state and allows requests', () {
      expect(state.circuitState, CircuitState.closed);
      expect(cb.isAllowed, isTrue);
    });

    test('trips to open after failures exceed threshold', () {
      cb.recordFailure();
      expect(state.circuitState, CircuitState.closed);
      expect(cb.isAllowed, isTrue);

      cb.recordFailure();
      expect(state.circuitState, CircuitState.open);
      expect(cb.isAllowed, isFalse);
    });

    test('transitions to half-open after timeout', () async {
      cb.recordFailure();
      cb.recordFailure();
      expect(state.circuitState, CircuitState.open);

      await Future.delayed(const Duration(milliseconds: 150));

      expect(cb.isAllowed, isTrue);
      expect(state.circuitState, CircuitState.halfOpen);
    });

    test(
      'half-open success transitions to closed (default threshold = 3)',
      () async {
        cb.recordFailure();
        cb.recordFailure();
        await Future.delayed(const Duration(milliseconds: 150));

        expect(
          cb.isAllowed,
          isTrue,
        ); // Transitions to half-open, trial 1 starts
        cb.recordSuccess();
        expect(state.circuitState, CircuitState.halfOpen); // Still half-open

        expect(cb.isAllowed, isTrue); // Trial 2 starts
        cb.recordSuccess();
        expect(state.circuitState, CircuitState.halfOpen); // Still half-open

        expect(cb.isAllowed, isTrue); // Trial 3 starts
        cb.recordSuccess();
        expect(
          state.circuitState,
          CircuitState.closed,
        ); // Transitions to closed
        expect(state.failureCount, 0);
      },
    );

    test('half-open failure transitions back to open', () async {
      cb.recordFailure();
      cb.recordFailure();
      await Future.delayed(const Duration(milliseconds: 150));

      expect(cb.isAllowed, isTrue); // Transitions to half-open

      cb.recordFailure();
      expect(state.circuitState, CircuitState.open);
    });

    test('limits requests in half-open state', () async {
      cb.recordFailure();
      cb.recordFailure();
      await Future.delayed(const Duration(milliseconds: 150));

      expect(cb.isAllowed, isTrue); // First allowed (transitions to half-open)
      expect(cb.isAllowed, isFalse); // Second rejected
    });

    test(
      'requires multiple successes in half-open state if threshold > 1',
      () async {
        final customConfig = ResourceConfig(
          circuitBreaker: CircuitBreakerConfig(
            consecutiveFailuresThreshold: 2,
            resetTimeout: const Duration(milliseconds: 100),
            halfOpenSuccessThreshold: 3,
          ),
        );
        final customState = ResourceState(customConfig);
        final customCb = CircuitBreaker(customConfig, customState);

        customCb.recordFailure();
        customCb.recordFailure();
        expect(customState.circuitState, CircuitState.open);

        await Future.delayed(const Duration(milliseconds: 150));

        expect(customCb.isAllowed, isTrue);
        expect(customState.circuitState, CircuitState.halfOpen);
        expect(customState.trialRequestInProgress, isTrue);
        expect(customCb.isAllowed, isFalse);

        customCb.recordSuccess();
        expect(customState.circuitState, CircuitState.halfOpen);
        expect(customState.trialRequestInProgress, isFalse);
        expect(customState.halfOpenSuccessCount, 1);

        expect(customCb.isAllowed, isTrue);
        expect(customState.trialRequestInProgress, isTrue);
        expect(customCb.isAllowed, isFalse);

        customCb.recordSuccess();
        expect(customState.circuitState, CircuitState.halfOpen);
        expect(customState.trialRequestInProgress, isFalse);
        expect(customState.halfOpenSuccessCount, 2);

        expect(customCb.isAllowed, isTrue);
        expect(customState.trialRequestInProgress, isTrue);

        customCb.recordSuccess();
        expect(customState.circuitState, CircuitState.closed);
        expect(customState.trialRequestInProgress, isFalse);
        expect(customState.halfOpenSuccessCount, 0);
        expect(customState.failureCount, 0);
      },
    );

    test('half-open failure resets success count and opens circuit', () async {
      final customConfig = ResourceConfig(
        circuitBreaker: CircuitBreakerConfig(
          consecutiveFailuresThreshold: 2,
          resetTimeout: const Duration(milliseconds: 100),
          halfOpenSuccessThreshold: 3,
        ),
      );
      final customState = ResourceState(customConfig);
      final customCb = CircuitBreaker(customConfig, customState);

      customCb.recordFailure();
      customCb.recordFailure();
      await Future.delayed(const Duration(milliseconds: 150));

      expect(customCb.isAllowed, isTrue);
      customCb.recordSuccess();
      expect(customState.halfOpenSuccessCount, 1);

      expect(customCb.isAllowed, isTrue);
      customCb.recordFailure();

      expect(customState.circuitState, CircuitState.open);
      expect(customState.halfOpenSuccessCount, 0);
      expect(customState.trialRequestInProgress, isFalse);
    });
  });
}
