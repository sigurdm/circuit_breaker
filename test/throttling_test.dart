import 'package:test/test.dart';
import 'package:circuit_breaker/src/throttling.dart';
import 'package:circuit_breaker/src/context.dart';

void main() {
  group('AdaptiveThrottling', () {
    late ResourceConfig config;
    late ResourceState state;
    late AdaptiveThrottler throttler;

    setUp(() {
      config = ResourceConfig(
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
      state.requestHistory[Criticality.critical]!.add(
        RequestRecord(DateTime.now(), true),
      );
      state.requestHistory[Criticality.critical]!.add(
        RequestRecord(DateTime.now(), true),
      );
      expect(throttler.shouldThrottle(Criticality.critical), isFalse);
    });

    test('throttles when failure rate is high', () {
      // Formula: P = max(0, (requests - K * accepts) / (requests + 1))
      // Add 10 failed requests
      for (int i = 0; i < 10; i++) {
        state.requestHistory[Criticality.critical]!.add(
          RequestRecord(DateTime.now(), false),
        );
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
          state.requestHistory[Criticality.critical]!.add(
            RequestRecord(DateTime.now(), true),
          );
          state.requestHistory[Criticality.critical]!.add(
            RequestRecord(DateTime.now(), false),
          );
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
        state.requestHistory[Criticality.sheddable]!.add(
          RequestRecord(DateTime.now(), false),
        );
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
  group('Criticality-Aware Throttling Config', () {
    test('default constructor applies formula with spread: 1.0', () {
      final config = ThrottlingConfig(k: 2.0, spread: 1.0);
      expect(
        config.k.criticalPlus,
        closeTo(2.0 * (1.0 + 3.0 * 1.0), 0.001),
      ); // 8.0
      expect(config.k.critical, closeTo(2.0, 0.001));
      expect(
        config.k.sheddablePlus,
        closeTo(2.0 * (1.0 - 0.2 * 1.0), 0.001),
      ); // 1.6
      expect(
        config.k.sheddable,
        closeTo(2.0 * (1.0 - 0.4 * 1.0), 0.001),
      ); // 1.2
    });

    test('default constructor applies formula with spread: 0.0', () {
      final config = ThrottlingConfig(k: 2.0, spread: 0.0);
      expect(config.k.criticalPlus, closeTo(2.0, 0.001));
      expect(config.k.critical, closeTo(2.0, 0.001));
      expect(config.k.sheddablePlus, closeTo(2.0, 0.001));
      expect(config.k.sheddable, closeTo(2.0, 0.001));
    });

    test('default constructor applies formula with spread: 0.5', () {
      final config = ThrottlingConfig(k: 2.0, spread: 0.5);
      expect(
        config.k.criticalPlus,
        closeTo(2.0 * (1.0 + 3.0 * 0.5), 0.001),
      ); // 5.0
      expect(config.k.critical, closeTo(2.0, 0.001));
      expect(
        config.k.sheddablePlus,
        closeTo(2.0 * (1.0 - 0.2 * 0.5), 0.001),
      ); // 1.8
      expect(
        config.k.sheddable,
        closeTo(2.0 * (1.0 - 0.4 * 0.5), 0.001),
      ); // 1.6
    });

    test('default constructor enforces minimum K of 1.1', () {
      final config = ThrottlingConfig(k: 1.5, spread: 1.0);
      expect(config.k.sheddablePlus, closeTo(1.2, 0.001));
      expect(config.k.sheddable, closeTo(1.1, 0.001));
    });

    test('default constructor prevents priority inversion with low k', () {
      final config = ThrottlingConfig(k: 1.0, spread: 1.0);
      expect(config.k.sheddable, closeTo(1.1, 0.001));
      expect(config.k.sheddablePlus, closeTo(1.1, 0.001));
      expect(config.k.critical, closeTo(1.1, 0.001));
      expect(config.k.criticalPlus, closeTo(4.0, 0.001));
    });

    test('withCriticality applies exact values', () {
      const exactK = (
        criticalPlus: 5.0,
        critical: 3.0,
        sheddablePlus: 2.0,
        sheddable: 1.5,
      );
      final config = ThrottlingConfig.withCriticality(k: exactK);
      expect(config.k.criticalPlus, 5.0);
      expect(config.k.critical, 3.0);
      expect(config.k.sheddablePlus, 2.0);
      expect(config.k.sheddable, 1.5);
    });

    test('getK returns correct value', () {
      const exactK = (
        criticalPlus: 5.0,
        critical: 3.0,
        sheddablePlus: 2.0,
        sheddable: 1.5,
      );
      final config = ThrottlingConfig.withCriticality(k: exactK);
      expect(config.getK(Criticality.criticalPlus), 5.0);
      expect(config.getK(Criticality.critical), 3.0);
      expect(config.getK(Criticality.sheddablePlus), 2.0);
      expect(config.getK(Criticality.sheddable), 1.5);
    });
  });

  group('AdaptiveThrottler Criticality Integration (Formula Verification)', () {
    late ResourceConfig config;
    late ResourceState state;
    late AdaptiveThrottler throttler;

    setUp(() {
      config = ResourceConfig(
        throttling: ThrottlingConfig(
          k: 2.0,
          spread: 1.0,
          windowDuration: Duration(minutes: 2),
        ),
      );
      state = ResourceState(config);
      throttler = AdaptiveThrottler(config, state);
    });

    test('applies correct K based on criticality', () {
      void populateHistory(Criticality criticality) {
        for (int i = 0; i < 4; i++) {
          state.requestHistory[criticality]!.add(
            RequestRecord(DateTime.now(), true),
          );
        }
        for (int i = 0; i < 6; i++) {
          state.requestHistory[criticality]!.add(
            RequestRecord(DateTime.now(), false),
          );
        }
      }

      for (final c in Criticality.values) {
        populateHistory(c);
      }

      int criticalPlusThrottled = 0;
      for (int i = 0; i < 1000; i++) {
        if (throttler.shouldThrottle(Criticality.criticalPlus)) {
          criticalPlusThrottled++;
        }
      }
      expect(criticalPlusThrottled, 0);

      int sheddableThrottled = 0;
      int criticalThrottled = 0;
      int sheddablePlusThrottled = 0;

      for (int i = 0; i < 1000; i++) {
        if (throttler.shouldThrottle(Criticality.sheddable))
          sheddableThrottled++;
        if (throttler.shouldThrottle(Criticality.critical)) criticalThrottled++;
        if (throttler.shouldThrottle(Criticality.sheddablePlus))
          sheddablePlusThrottled++;
      }

      expect(sheddableThrottled, greaterThan(criticalThrottled));
      expect(sheddablePlusThrottled, greaterThan(criticalThrottled));
      expect(sheddableThrottled, greaterThan(sheddablePlusThrottled));

      expect(sheddableThrottled, closeTo(472, 100));
      expect(sheddablePlusThrottled, closeTo(327, 100));
      expect(criticalThrottled, closeTo(181, 100));
    });
  });

  group('AdaptiveThrottler with Explicit Criticality K', () {
    test('applies correct K based on criticality', () {
      final exactK = (
        criticalPlus: 4.0,
        critical: 2.0,
        sheddablePlus: 1.5,
        sheddable: 1.2,
      );
      final config = ResourceConfig(
        throttling: ThrottlingConfig.withCriticality(k: exactK),
      );
      final state = ResourceState(config);
      final throttler = AdaptiveThrottler(config, state);

      // Add 10 requests, 5 accepted for all criticalities
      for (final c in Criticality.values) {
        for (int i = 0; i < 5; i++) {
          state.requestHistory[c]!.add(RequestRecord(DateTime.now(), true));
          state.requestHistory[c]!.add(RequestRecord(DateTime.now(), false));
        }
      }

      int critPlusThrottled = 0;
      int critThrottled = 0;
      int shedPlusThrottled = 0;
      int shedThrottled = 0;

      for (int i = 0; i < 1000; i++) {
        if (throttler.shouldThrottle(Criticality.criticalPlus))
          critPlusThrottled++;
        if (throttler.shouldThrottle(Criticality.critical)) critThrottled++;
        if (throttler.shouldThrottle(Criticality.sheddablePlus))
          shedPlusThrottled++;
        if (throttler.shouldThrottle(Criticality.sheddable)) shedThrottled++;
      }

      expect(critPlusThrottled, 0);
      expect(critThrottled, 0);
      expect(shedPlusThrottled, greaterThan(0));
      expect(shedThrottled, greaterThan(0));
      expect(shedThrottled, greaterThan(shedPlusThrottled));
    });
  });
}
