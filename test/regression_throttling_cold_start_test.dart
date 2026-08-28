import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Adaptive Throttling Cold-Start Regression Tests', () {
    test('does not throttle when total requests are below minRequests', () {
      final config = ResourceConfig(
        throttling: ThrottlingConfig(
          k: 1.0, // Strict: any failure causes throttling if requests >= minRequests
          minRequests: 20,
        ),
      );
      final state = ResourceState(config);
      final throttler = AdaptiveThrottler(config, state);

      // Add 5 failed requests
      for (int i = 0; i < 5; i++) {
        state.requestHistory[Criticality.critical]!.add(
          RequestRecord(DateTime.now(), false),
        );
      }

      // requests = 5 < minRequests (20), must return false
      for (int i = 0; i < 50; i++) {
        expect(throttler.shouldThrottle(Criticality.critical), isFalse);
      }
    });

    test('throttles normally once requests reach minRequests', () {
      final config = ResourceConfig(
        throttling: ThrottlingConfig(k: 1.0, minRequests: 20),
      );
      final state = ResourceState(config);
      final throttler = AdaptiveThrottler(config, state);

      // Add 20 failed requests
      for (int i = 0; i < 20; i++) {
        state.requestHistory[Criticality.critical]!.add(
          RequestRecord(DateTime.now(), false),
        );
      }

      // requests = 20, accepts = 0, P = 20/21 ~ 0.95
      int throttledCount = 0;
      for (int i = 0; i < 100; i++) {
        if (throttler.shouldThrottle(Criticality.critical)) {
          throttledCount++;
        }
      }

      expect(throttledCount, greaterThan(50));
    });

    test('validates that minRequests must be non-negative', () {
      expect(() => ThrottlingConfig(minRequests: -1), throwsArgumentError);
      expect(
        () => ThrottlingConfig.withCriticality(
          k: (
            criticalPlus: 2.0,
            critical: 2.0,
            sheddablePlus: 2.0,
            sheddable: 2.0,
          ),
          minRequests: -5,
        ),
        throwsArgumentError,
      );
    });
  });
}
