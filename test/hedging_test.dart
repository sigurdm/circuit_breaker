import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/src/hedging.dart';
import 'package:circuit_breaker/src/context.dart';

void main() {
  group('Hedging', () {
    late ResourceConfig config;
    late ResourceState state;

    setUp(() {
      config = const ResourceConfig(
        hedging: HedgingConfig(
          enabled: true,
          delay: Duration(milliseconds: 50),
        ),
      );
      state = ResourceState(config);
    });

    test('executes normally when hedging disabled', () async {
      final disabledConfig = const ResourceConfig(
        hedging: HedgingConfig(enabled: false),
      );

      int attempts = 0;
      final result = await executeWithHedging(
        (cancelSignal) async {
          attempts++;
          return 'success';
        },
        config: disabledConfig,
        state: state,
      );

      expect(result, 'success');
      expect(attempts, 1);
    });

    test('returns first result if fast enough', () async {
      int attempts = 0;
      final result = await executeWithHedging(
        (cancelSignal) async {
          attempts++;
          return 'success';
        },
        config: config,
        state: state,
      );

      expect(result, 'success');
      expect(attempts, 1); // Second request shouldn't start
    });

    test('starts second request after delay', () async {
      int attempts = 0;
      final result = await executeWithHedging(
        (cancelSignal) async {
          attempts++;
          if (attempts == 1) {
            // First request takes longer than hedging delay
            await Future.delayed(const Duration(milliseconds: 100));
            return 'slow';
          }
          return 'fast';
        },
        config: config,
        state: state,
      );

      expect(result, 'fast');
      expect(attempts, 2);
    });

    test('signals cancellation to slower request', () async {
      final c1 = Completer<void>();
      final c2 = Completer<void>();

      final completers = [c1, c2];
      int attempts = 0;

      final f = executeWithHedging(
        (cancelSignal) async {
          attempts++;
          final myIndex = attempts - 1;

          cancelSignal.future.then((_) {
            if (!completers[myIndex].isCompleted) {
              completers[myIndex].complete();
            }
          });

          if (myIndex == 0) {
            await Future.delayed(const Duration(milliseconds: 200));
            return 'slow';
          } else {
            await Future.delayed(const Duration(milliseconds: 10));
            return 'fast';
          }
        },
        config: config,
        state: state,
      );

      final result = await f;

      expect(result, 'fast');
      expect(attempts, 2);

      // The first request should have been cancelled
      expect(c1.isCompleted, isTrue);
      // The second request succeeded, so it wasn't cancelled
      expect(c2.isCompleted, isFalse);
    });
  });
}
