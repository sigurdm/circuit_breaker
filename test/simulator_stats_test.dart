import 'package:test/test.dart';
import '../example/simulator.dart';
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('StatsTracker Latency', () {
    late StatsTracker tracker;

    setUp(() {
      tracker = StatsTracker(windowDuration: const Duration(seconds: 1));
    });

    test('returns 0.0 when no events recorded', () {
      expect(tracker.getRollingAverageLatencyMs(Criticality.critical), 0.0);
      expect(
        tracker.getRollingPercentileLatencyMs(Criticality.critical, 0.95),
        0.0,
      );
      expect(tracker.getRollingAverageLatencyMsOverall(), 0.0);
      expect(tracker.getRollingPercentileLatencyMsOverall(0.95), 0.0);
    });

    test('calculates average latency per criticality and overall', () {
      // Critical: 10ms, 20ms. Avg: 15ms.
      tracker.record(
        Criticality.critical,
        EventType.requestSuccess,
        latency: const Duration(milliseconds: 10),
      );
      tracker.record(
        Criticality.critical,
        EventType.requestSuccess,
        latency: const Duration(milliseconds: 20),
      );

      // Sheddable: 100ms, 200ms, 300ms. Avg: 200ms.
      tracker.record(
        Criticality.sheddable,
        EventType.requestSuccess,
        latency: const Duration(milliseconds: 100),
      );
      tracker.record(
        Criticality.sheddable,
        EventType.requestSuccess,
        latency: const Duration(milliseconds: 200),
      );
      tracker.record(
        Criticality.sheddable,
        EventType.requestSuccess,
        latency: const Duration(milliseconds: 300),
      );

      expect(tracker.getRollingAverageLatencyMs(Criticality.critical), 15.0);
      expect(tracker.getRollingAverageLatencyMs(Criticality.sheddable), 200.0);

      // Overall: (10 + 20 + 100 + 200 + 300) / 5 = 630 / 5 = 126ms.
      expect(tracker.getRollingAverageLatencyMsOverall(), 126.0);
    });

    test(
      'calculates percentiles correctly (using standard round to nearest index)',
      () {
        // Latencies: 10, 20, 30, 40, 50. (sorted)
        // indices: 0, 1, 2, 3, 4
        for (var lat in [50, 10, 40, 20, 30]) {
          tracker.record(
            Criticality.critical,
            EventType.requestSuccess,
            latency: Duration(milliseconds: lat),
          );
        }

        // P50: index = (0.5 * 4).round() = 2. Value: 30.
        expect(
          tracker.getRollingPercentileLatencyMs(Criticality.critical, 0.5),
          30.0,
        );

        // P90: index = (0.9 * 4).round() = 3.6.round() = 4. Value: 50.
        expect(
          tracker.getRollingPercentileLatencyMs(Criticality.critical, 0.9),
          50.0,
        );

        // P95: index = (0.95 * 4).round() = 3.8.round() = 4. Value: 50.
        expect(
          tracker.getRollingPercentileLatencyMs(Criticality.critical, 0.95),
          50.0,
        );

        // P10: index = (0.1 * 4).round() = 0.4.round() = 0. Value: 10.
        expect(
          tracker.getRollingPercentileLatencyMs(Criticality.critical, 0.1),
          10.0,
        );
      },
    );

    test('only counts requestSuccess events with latency', () {
      tracker.record(
        Criticality.critical,
        EventType.requestSuccess,
        latency: const Duration(milliseconds: 10),
      );
      tracker.record(
        Criticality.critical,
        EventType.requestFailure,
        latency: const Duration(milliseconds: 100),
      ); // Should ignore
      tracker.record(
        Criticality.critical,
        EventType.requestTimeout,
        latency: const Duration(milliseconds: 500),
      ); // Should ignore
      tracker.record(
        Criticality.critical,
        EventType.requestThrottled,
      ); // Should ignore
      tracker.record(
        Criticality.critical,
        EventType.requestSuccess,
      ); // Should ignore because latency is null

      expect(tracker.getRollingAverageLatencyMs(Criticality.critical), 10.0);
      expect(
        tracker.getRollingPercentileLatencyMs(Criticality.critical, 0.95),
        10.0,
      );
    });

    test('purges old events outside the window', () async {
      tracker = StatsTracker(windowDuration: const Duration(milliseconds: 100));

      tracker.record(
        Criticality.critical,
        EventType.requestSuccess,
        latency: const Duration(milliseconds: 10),
      );
      expect(tracker.getRollingAverageLatencyMs(Criticality.critical), 10.0);

      await Future.delayed(const Duration(milliseconds: 150));

      expect(tracker.getRollingAverageLatencyMs(Criticality.critical), 0.0);
    });
  });
}
