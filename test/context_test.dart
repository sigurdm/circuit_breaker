import 'dart:async';
import 'package:test/test.dart';
import 'package:circuit_breaker/circuit_breaker.dart';

void main() {
  group('RetryContext with Hierarchy', () {
    late RetryContext context;
    late Resource resource;
    late Operation readOp;
    late Operation writeOp;

    setUp(() {
      context = RetryContext();
      resource = const Resource('my-service', config: ResourceConfig(
        circuitBreaker: CircuitBreakerConfig(failureThreshold: 2),
        throttling: ThrottlingConfig(k: 100.0), // Prevent throttling from interfering
      ));
      readOp = Operation('read', resource, hedgingOverride: const HedgingConfig(enabled: true, delay: Duration(milliseconds: 10)));
      writeOp = Operation('write', resource); // Uses defaults (hedging disabled)
    });

    test('shared circuit breaker state', () async {
      // Add successes to avoid adaptive throttling kicking in on failures
      for (int i = 0; i < 10; i++) {
        await context.execute(writeOp, () async => 'success');
      }

      // Cause 2 failures on write operation
      try {
        await context.execute(writeOp, () async => throw Exception('fail'));
      } catch (_) {}
      try {
        await context.execute(writeOp, () async => throw Exception('fail'));
      } catch (_) {}

      // Circuit should be open now for the resource
      expect(
        () => context.execute(readOp, () async => 'success'),
        throwsA(predicate((e) => e.toString().contains('Circuit breaker is open'))),
      );
    });

    test('independent hedging configuration', () async {
      // Read operation has hedging enabled
      final readCompleter = Completer<String>();
      
      // We don't complete it immediately to trigger hedging
      final future = context.executeCancelable(readOp, (cancel) async {
        if (cancel.isCompleted) return 'cancelled';
        return await readCompleter.future;
      });

      int calls = 0;
      final future2 = context.executeCancelable(readOp, (cancel) async {
        calls++;
        if (calls == 2) return 'hedged';
        await Future.delayed(const Duration(milliseconds: 100));
        return 'slow';
      });

      expect(await future2, equals('hedged'));
      
      // Clean up the first request
      readCompleter.complete('done');
      await future;
    });
  });
}
