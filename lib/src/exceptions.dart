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
