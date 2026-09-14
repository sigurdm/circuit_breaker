import 'cancellation.dart';
import 'context.dart' show CircuitState, Criticality;

/// Base class for all exceptions thrown by the resilience library.
sealed class ResilienceException implements Exception {
  /// The message describing the error.
  String get message;
}

/// Exception thrown when the circuit breaker is open.
final class CircuitBreakerOpenException implements ResilienceException {
  /// The message describing the error.
  @override
  final String message;

  /// The name of the resource whose circuit breaker is open, if known.
  final String? resourceName;

  /// The reset timeout configured for this circuit breaker, if known.
  final Duration? resetTimeout;

  /// The state of the circuit breaker when the exception occurred, if known.
  final CircuitState? state;

  /// Creates a [CircuitBreakerOpenException].
  const CircuitBreakerOpenException(
    this.message, {
    this.resourceName,
    this.resetTimeout,
    this.state,
  });

  @override
  String toString() => 'CircuitBreakerOpenException: $message';
}

/// Exception thrown when a request is throttled by adaptive throttling.
final class ThrottledException implements ResilienceException {
  /// The message describing the error.
  @override
  final String message;

  /// The name of the resource that was throttled, if known.
  final String? resourceName;

  /// The criticality of the throttled request, if known.
  final Criticality? criticality;

  /// The calculated rejection probability at the time of throttling, if known.
  final double? rejectionProbability;

  /// Creates a [ThrottledException].
  const ThrottledException(
    this.message, {
    this.resourceName,
    this.criticality,
    this.rejectionProbability,
  });

  @override
  String toString() => 'ThrottledException: $message';
}

/// Exception thrown when an operation times out.
final class ResilienceTimeoutException implements ResilienceException {
  /// The message describing the error.
  @override
  final String message;

  /// The duration of the timeout that was exceeded, if known.
  final Duration? timeout;

  /// The elapsed duration when the timeout occurred, if known.
  final Duration? elapsed;

  /// Creates a [ResilienceTimeoutException].
  const ResilienceTimeoutException(this.message, {this.timeout, this.elapsed});

  @override
  String toString() => 'ResilienceTimeoutException: $message';
}

/// Exception thrown when an operation is cancelled.
final class OperationCancelledException implements ResilienceException {
  /// The message describing the error.
  @override
  final String message;

  /// The cancellation token associated with this cancellation, if known.
  final CancellationToken? token;

  /// Creates an [OperationCancelledException].
  const OperationCancelledException([
    this.message = 'Operation was cancelled',
    this.token,
  ]);

  @override
  String toString() => 'OperationCancelledException: $message';
}
