import 'dart:async';
import 'package:circuit_breaker/circuit_breaker.dart';

// --- Mock Backend Setup ---

enum BackendState { healthy, overloaded }

BackendState backendState = BackendState.healthy;

class HttpException implements Exception {
  final int statusCode;
  final String message;
  HttpException(this.statusCode, this.message);
  @override
  String toString() => 'HttpException: $statusCode $message';
}

Future<String> mockBackendCall(
  String opName, {
  bool invalidInput = false,
}) async {
  if (invalidInput) {
    throw HttpException(400, 'Bad Request (Client Error)');
  }
  if (backendState == BackendState.overloaded) {
    throw HttpException(503, 'Service Unavailable (Server Overload)');
  }
  // Simulate normal network latency
  await Future.delayed(const Duration(milliseconds: 10));
  return '$opName data';
}

// --- Main Example ---

void main() async {
  final context = ResilienceContext();

  // Define a resource with comprehensive configuration
  final myService = Resource(
    'my-service',
    config: ResourceConfig(
      // 1. Circuit Breaker: Trip after 3 consecutive failures, retry after 2 seconds
      circuitBreaker: CircuitBreakerConfig(
        consecutiveFailuresThreshold: 3,
        resetTimeout: Duration(seconds: 2),
      ),
      // 2. Adaptive Throttling: Aggressive K=1.5 to show throttling quickly
      throttling: ThrottlingConfig(
        k: 1.5,
        windowDuration: Duration(seconds: 5),
      ),
      // 3. Retries: Up to 3 attempts with exponential backoff
      retry: RetryConfig(maxAttempts: 3, baseDelay: Duration(milliseconds: 50)),
      // 4. Failure Classifier: Distinguish client errors from system failures
      failureClassifier: (e) {
        if (e is HttpException) {
          // 400 Bad Request is a client error, not a system failure.
          // Tripping the circuit breaker on 400s would allow clients to DOS us.
          final isSystemFailure = e.statusCode != 400;
          print(
            '  [Classifier] Classified error ($e) as system failure: $isSystemFailure',
          );
          return isSystemFailure;
        }
        return true;
      },
    ),
  );

  // Define operations with different criticalities
  final checkoutOp = Operation(
    'checkout',
    myService,
    criticality: Criticality.criticalPlus, // High priority
  );

  final recommendationsOp = Operation(
    'recommendations',
    myService,
    criticality: Criticality.sheddable, // Low priority
    retryOverride: RetryConfig(maxAttempts: 1), // Don't retry low priority
  );

  print(
    '=== Scenario 1: Client Errors (400) do not trip the Circuit Breaker ===',
  );
  // We send requests that fail with 400.
  for (int i = 1; i <= 3; i++) {
    try {
      print('Sending invalid request $i...');
      await context.execute(
        checkoutOp,
        () => mockBackendCall('checkout', invalidInput: true),
      );
    } on HttpException catch (e) {
      print('  Caught expected error: $e');
    }
  }

  // The circuit breaker should still be CLOSED because 400s are not system failures.
  print('Sending valid request to verify circuit is still closed...');
  try {
    final result = await context.execute(
      checkoutOp,
      () => mockBackendCall('checkout'),
    );
    print('  Success: $result');
  } catch (e) {
    print('  Unexpected failure: $e');
  }

  print(
    '\n=== Scenario 2: Backend Overload triggers Throttling and Circuit Breaker ===',
  );
  print('Simulating backend overload (503)...');
  backendState = BackendState.overloaded;

  // We send a mix of high and low priority traffic.
  // Low priority (sheddable) should start getting throttled by client-side adaptive throttling.
  // High priority will fail and trigger retries, eventually tripping the CB.
  for (int i = 1; i <= 5; i++) {
    print('\n--- Round $i ---');

    // Low priority request
    try {
      print('Sending low-priority recommendations request...');
      final result = await context.execute(
        recommendationsOp,
        () => mockBackendCall('recommendations'),
      );
      print('  Success: $result');
    } on ThrottledException catch (e) {
      print('  [Throttled] Client proactively rejected request: $e');
    } catch (e) {
      print('  Failed: $e');
    }

    // High priority request
    try {
      print('Sending high-priority checkout request...');
      final result = await context.execute(
        checkoutOp,
        () => mockBackendCall('checkout'),
      );
      print('  Success: $result');
    } on ThrottledException catch (e) {
      print('  [Throttled] Client proactively rejected request: $e');
    } on CircuitBreakerOpenException catch (e) {
      print('  [Circuit Breaker] Open! Blocked fast: $e');
    } catch (e) {
      print('  Failed (after retries): $e');
    }

    // Small delay between rounds
    await Future.delayed(const Duration(milliseconds: 100));
  }

  print('\n=== Scenario 3: Recovery (Half-Open to Closed) ===');
  print('Simulating backend recovery...');
  backendState = BackendState.healthy;

  print('Attempting call immediately (should still be blocked by open CB)...');
  try {
    await context.execute(checkoutOp, () => mockBackendCall('checkout'));
  } on CircuitBreakerOpenException catch (e) {
    print('  [Circuit Breaker] Correctly still open: $e');
  }

  print('Waiting for reset timeout (2.5 seconds)...');
  await Future.delayed(const Duration(milliseconds: 2500));

  print('Sending request (CB should be Half-Open and allow 1 trial)...');
  try {
    final result = await context.execute(
      checkoutOp,
      () => mockBackendCall('checkout'),
    );
    print('  Success: $result');
    print('Circuit Breaker is now CLOSED again.');
  } catch (e) {
    print('  Failed: $e');
  }
}
