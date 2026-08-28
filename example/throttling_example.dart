import 'dart:io';

import 'package:circuit_breaker/circuit_breaker.dart';

void main() async {
  print('=== Adaptive Throttling Example ===\n');

  final context = ResilienceContext();
  final resource = Resource(
    'flaky-service',
    config: ResourceConfig(
      circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 20),
      throttling: ThrottlingConfig(k: 1.5, minRequests: 5),
    ),
  );
  final operation = Operation(
    'call-flaky',
    resource,
    criticality: Criticality.sheddable,
  );

  // Simulate an overloaded backend accepting only 1 in 4 requests.
  int totalSent = 0;
  int accepted = 0;
  int throttled = 0;
  int failed = 0;

  for (int i = 1; i <= 20; i++) {
    totalSent++;
    try {
      final result = await context.execute(operation, () async {
        if (i % 4 != 0) {
          throw const HttpException('503 Service Overloaded');
        }
        return 'success';
      }, retryOn: (_) => false);
      accepted++;
      print('Request $i: Accepted ($result)');
    } on ThrottledException {
      throttled++;
      print('Request $i: [Throttled locally] Proactively dropped by client');
    } catch (e) {
      failed++;
      print('Request $i: Failed at backend (503)');
    }
  }

  print('\nSummary:');
  print('Total sent: $totalSent');
  print('Backend accepted: $accepted');
  print('Backend failed: $failed');
  print('Throttled locally: $throttled');
}
