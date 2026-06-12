/// A library for async retry, circuit breaker, request hedging, and adaptive throttling.
///
/// This package provides advanced resilience patterns to improve system performance
/// by addressing service failures and latency bottlenecks in distributed systems.
///
/// ## Key Features
///
/// - **Circuit Breaker**: Prevents cascading failures by failing fast when a service is struggling.
/// - **Retry with Backoff**: Automatically retries transient failures with exponential backoff and full jitter.
/// - **Request Hedging**: Mitigates tail latency by speculatively duplicating operations.
/// - **Adaptive Throttling**: Dynamically rejects requests based on rolling success rates to protect backends.
///
/// ## Usage
///
/// The main entry point is [RetryContext]. You can use it to execute operations
/// with configured policies for named resources.
///
/// ```dart
/// import 'package:circuit_breaker/circuit_breaker.dart';
///
/// void main() async {
///   final context = RetryContext();
///
///   // Define a resource with base configuration
///   final myService = Resource('my-service', config: ResourceConfig(
///     circuitBreaker: CircuitBreakerConfig(failureThreshold: 3),
///   ));
///
///   // Define operations on that resource
///   final readOp = Operation('read', myService, hedgingOverride: HedgingConfig(enabled: true));
///   final writeOp = Operation('write', myService);
///
///   // Execute an operation that supports cancellation
///   try {
///     final result = await context.executeCancelable(readOp, (cancelSignal) async {
///       final work = Future.delayed(Duration(seconds: 1), () => 'result');
///       return await Future.any([
///         work,
///         cancelSignal.future.then((_) => throw Exception('Cancelled')),
///       ]);
///     });
///     print(result);
///   } catch (e) {
///     print('Failed: $e');
///   }
///
///   // Execute a simple operation without cancellation
///   final writeResult = await context.execute(writeOp, () async {
///     return await makeNetworkCall();
///   });
/// ```
/// }
/// ```
library circuit_breaker;

export 'src/context.dart'
    show
        RetryContext,
        Resource,
        Operation,
        ResourceConfig,
        CircuitBreakerConfig,
        RetryConfig,
        ThrottlingConfig,
        HedgingConfig;
export 'src/throttling.dart' show ThrottledException;
