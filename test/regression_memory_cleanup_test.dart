import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:test/test.dart';

void main() {
  group('Memory Cleanup Regression Tests', () {
    test('retryHistory is cleaned up during successful requests', () async {
      final context = ResilienceContext();
      final resource = Resource(
        'cleanup-service',
        config: ResourceConfig(
          retry: RetryConfig(budgetWindow: const Duration(milliseconds: 100)),
          throttling: ThrottlingConfig(k: 100.0),
        ),
      );
      final op = Operation('call', resource);
      final state =
          context.states['cleanup-service'] ??
          context.states.putIfAbsent(
            'cleanup-service',
            () => ResourceState(resource.config),
          );

      // Add old records
      final oldTime = DateTime.now().subtract(
        const Duration(milliseconds: 200),
      );
      for (int i = 0; i < 50; i++) {
        state.retryHistory.add(RetryAttemptRecord(oldTime, isRetry: false));
      }
      expect(state.retryHistory.length, equals(50));

      // Execute a new successful request
      await context.execute(op, () async => 'success');

      // The old records older than budgetWindow (100ms) should be cleaned up!
      // Only the new request attempt record should remain.
      expect(state.retryHistory.length, equals(1));
    });
  });
}
