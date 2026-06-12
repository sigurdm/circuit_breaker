import 'package:test/test.dart';
import 'package:circuit_breaker/src/throttling.dart';
import 'package:circuit_breaker/src/context.dart';

void main() {
  group('AdaptiveThrottling', () {
    late ResourceConfig config;
    late ResourceState state;
    late AdaptiveThrottler throttler;

    setUp(() {
      config = const ResourceConfig(
        throttling: ThrottlingConfig(
          k: 2.0,
          windowDuration: Duration(minutes: 2),
        ),
      );
      state = ResourceState(config);
      throttler = AdaptiveThrottler(config, state);
    });

    test('does not throttle when no history', () {
      expect(throttler.shouldThrottle(Criticality.critical), isFalse);
    });

    test('does not throttle when all requests accepted', () {
      state.requestHistory[Criticality.critical]!.add(RequestRecord(DateTime.now(), true));
      state.requestHistory[Criticality.critical]!.add(RequestRecord(DateTime.now(), true));
      expect(throttler.shouldThrottle(Criticality.critical), isFalse);
    });

    test('throttles when failure rate is high', () {
      // Formula: P = max(0, (requests - K * accepts) / (requests + 1))
      // Add 10 failed requests
      for (int i = 0; i < 10; i++) {
        state.requestHistory[Criticality.critical]!.add(RequestRecord(DateTime.now(), false));
      }

      // requests = 10, accepts = 0
      // P = (10 - 0) / 11 = 0.909...
      // Highly likely to throttle.

      int throttledCount = 0;
      for (int i = 0; i < 100; i++) {
        if (throttler.shouldThrottle(Criticality.critical)) {
          throttledCount++;
        }
      }

      // We expect a high number of throttled requests (around 90)
      expect(throttledCount, greaterThan(50));
    });

    test(
      'does not throttle when accepts are at least half of requests (with K=2)',
      () {
        // Add 5 accepted and 5 failed requests
        for (int i = 0; i < 5; i++) {
          state.requestHistory[Criticality.critical]!.add(RequestRecord(DateTime.now(), true));
          state.requestHistory[Criticality.critical]!.add(RequestRecord(DateTime.now(), false));
        }

        // requests = 10, accepts = 5
        // P = (10 - 2 * 5) / 11 = 0 / 11 = 0
        // Should never throttle

        int throttledCount = 0;
        for (int i = 0; i < 100; i++) {
          if (throttler.shouldThrottle(Criticality.critical)) {
            throttledCount++;
          }
        }

        expect(throttledCount, 0);
      },
    );

    test('throttling is isolated per criticality', () {
      // Add 10 failed requests for sheddable
      for (int i = 0; i < 10; i++) {
        state.requestHistory[Criticality.sheddable]!.add(RequestRecord(DateTime.now(), false));
      }

      // sheddable should be throttled
      int sheddableThrottled = 0;
      for (int i = 0; i < 100; i++) {
        if (throttler.shouldThrottle(Criticality.sheddable)) {
          sheddableThrottled++;
        }
      }
      expect(sheddableThrottled, greaterThan(50));

      // critical should NOT be throttled
      int criticalThrottled = 0;
      for (int i = 0; i < 100; i++) {
        if (throttler.shouldThrottle(Criticality.critical)) {
          criticalThrottled++;
        }
      }
      expect(criticalThrottled, 0);
    });
  });
}
