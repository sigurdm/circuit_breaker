import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:circuit_breaker/src/hedging.dart';
import 'package:test/test.dart';

void main() {
  group('Dynamic Hedging Regression Tests', () {
    late ResourceConfig config;
    late ResourceState state;

    setUp(() {
      config = ResourceConfig(
        hedging: HedgingConfig(
          enabled: true,
          delay: const Duration(milliseconds: 20),
          maxConcurrentHedges: 2,
        ),
      );
      state = ResourceState(config);
    });

    test('hedging is bypassed in halfOpen state', () async {
      state.circuitState = CircuitState.halfOpen;

      int executions = 0;
      final result = await executeWithHedging(
        (cancel) async {
          executions++;
          await Future.delayed(const Duration(milliseconds: 50));
          return 'ok';
        },
        config: config,
        state: state,
      );

      expect(result, equals('ok'));
      // Only 1 execution because hedging was bypassed
      expect(executions, equals(1));
    });

    test(
      'synchronous exception during hedge start does not leak activeHedges',
      () async {
        int attempts = 0;
        try {
          await executeWithHedging(
            (cancel) {
              attempts++;
              if (attempts == 1) {
                final c = Completer<String>();
                return c.future; // primary never finishes
              } else {
                // Hedge attempt throws synchronously
                throw ArgumentError('sync error in hedge');
              }
            },
            config: config,
            state: state,
          );
        } catch (_) {}

        // Even if synchronous error was thrown in hedge, activeHedges must be 0
        expect(state.activeHedges, equals(0));
      },
    );
  });
}
