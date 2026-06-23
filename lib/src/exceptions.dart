/// Exception thrown when the circuit breaker is open.
final class CircuitBreakerOpenException implements Exception {
  /// The message describing the error.
  final String message;

  /// Creates a [CircuitBreakerOpenException].
  const CircuitBreakerOpenException(this.message);

  @override
  String toString() => 'CircuitBreakerOpenException: $message';
}

/// Exception thrown when an operation times out.
final class ResilienceTimeoutException implements Exception {
  /// The message describing the error.
  final String message;

  /// Creates a [ResilienceTimeoutException].
  const ResilienceTimeoutException(this.message);

  @override
  String toString() => 'ResilienceTimeoutException: $message';
}

/// Exception thrown when an operation is cancelled.
final class OperationCancelledException implements Exception {
  /// The message describing the error.
  final String message;

  /// Creates an [OperationCancelledException].
  const OperationCancelledException([this.message = 'Operation was cancelled']);

  @override
  String toString() => 'OperationCancelledException: $message';
}
