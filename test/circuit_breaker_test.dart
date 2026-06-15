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

    test('half-open success transitions to closed', () async {
      cb.recordFailure();
      cb.recordFailure();
      await Future.delayed(const Duration(milliseconds: 150));

      expect(cb.isAllowed, isTrue); // Transitions to half-open

      cb.recordSuccess();
      expect(state.circuitState, CircuitState.closed);
      expect(state.failureCount, 0);
    });

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
  });
}
