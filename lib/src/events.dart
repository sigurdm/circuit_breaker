import 'context.dart';

/// Base class for all resilience lifecycle and health events in `package:circuit_breaker`.
///
/// Listeners can subscribe to events via:
/// - `ResilienceContext.events`
/// - `ResiliencePolicy.events`
/// - `Resource.events`
/// - `BoundResource.events`
///
/// Concrete event subclasses:
/// - [CircuitBreakerStateChangedEvent]
/// - [RequestThrottledEvent]
/// - [RetryAttemptEvent]
/// - [HedgeFiredEvent]
/// - [OperationCompletedEvent]
sealed class ResilienceEvent {
  /// The resource associated with this event.
  final Resource resource;

  /// The timestamp when this event occurred.
  final DateTime timestamp;

  /// Creates a [ResilienceEvent].
  const ResilienceEvent({required this.resource, required this.timestamp});

  /// The name of the resource associated with this event.
  String get resourceName => resource.name;
}

/// Event emitted whenever a circuit breaker transitions between states
/// ([CircuitState.closed], [CircuitState.open], [CircuitState.halfOpen]).
final class CircuitBreakerStateChangedEvent extends ResilienceEvent {
  /// The previous state of the circuit breaker.
  final CircuitState previousState;

  /// The new state of the circuit breaker.
  final CircuitState newState;

  /// Creates a [CircuitBreakerStateChangedEvent].
  const CircuitBreakerStateChangedEvent({
    required super.resource,
    required super.timestamp,
    required this.previousState,
    required this.newState,
  });

  @override
  String toString() =>
      'CircuitBreakerStateChangedEvent(resource: $resourceName, '
      'previousState: $previousState, newState: $newState, timestamp: $timestamp)';
}

/// Event emitted when an incoming request is throttled (rejected proactively)
/// by adaptive throttling.
final class RequestThrottledEvent extends ResilienceEvent {
  /// The criticality of the throttled request.
  final Criticality criticality;

  /// The rejection probability at the moment the request was throttled.
  final double rejectionProbability;

  /// Creates a [RequestThrottledEvent].
  const RequestThrottledEvent({
    required super.resource,
    required super.timestamp,
    required this.criticality,
    required this.rejectionProbability,
  });

  @override
  String toString() =>
      'RequestThrottledEvent(resource: $resourceName, criticality: $criticality, '
      'rejectionProbability: $rejectionProbability, timestamp: $timestamp)';
}

/// Event emitted when a retry attempt is scheduled or executed.
final class RetryAttemptEvent extends ResilienceEvent {
  /// The attempt number for this retry (starts at 2 for the first retry).
  final int attemptNumber;

  /// The backoff delay before this attempt was made.
  final Duration delay;

  /// The error that triggered this retry attempt.
  final Object error;

  /// Creates a [RetryAttemptEvent].
  const RetryAttemptEvent({
    required super.resource,
    required super.timestamp,
    required this.attemptNumber,
    required this.delay,
    required this.error,
  });

  @override
  String toString() =>
      'RetryAttemptEvent(resource: $resourceName, attemptNumber: $attemptNumber, '
      'delay: $delay, error: $error, timestamp: $timestamp)';
}

/// Event emitted when a speculative hedge request is dispatched.
final class HedgeFiredEvent extends ResilienceEvent {
  /// The delay elapsed on the primary request before this speculative hedge was fired.
  final Duration delay;

  /// The number of currently active hedges for this resource (including this one).
  final int activeHedges;

  /// Creates a [HedgeFiredEvent].
  const HedgeFiredEvent({
    required super.resource,
    required super.timestamp,
    required this.delay,
    required this.activeHedges,
  });

  @override
  String toString() =>
      'HedgeFiredEvent(resource: $resourceName, delay: $delay, '
      'activeHedges: $activeHedges, timestamp: $timestamp)';
}

/// Event emitted when a top-level operation completes execution, whether
/// successfully, with an error, or by cancellation/timeout.
final class OperationCompletedEvent extends ResilienceEvent {
  /// The operation target, if specified, or null if executed directly against a [Resource].
  final Operation? operation;

  /// The total duration of the operation from start to completion (including all retries/hedges).
  final Duration duration;

  /// Whether the operation succeeded.
  final bool isSuccess;

  /// The error that caused the operation to fail, if any.
  final Object? error;

  /// Creates an [OperationCompletedEvent].
  const OperationCompletedEvent({
    required super.resource,
    required super.timestamp,
    this.operation,
    required this.duration,
    required this.isSuccess,
    this.error,
  });

  /// The name of the operation if available, or empty string.
  String get operationName => operation?.name ?? '';

  @override
  String toString() =>
      'OperationCompletedEvent(resource: $resourceName, '
      '${operation != null ? 'operation: ${operation!.name}, ' : ''}'
      'duration: $duration, isSuccess: $isSuccess, error: $error, timestamp: $timestamp)';
}

/// An immutable point-in-time snapshot of health and resilience metrics for a [Resource].
///
/// Exposes safe metrics suitable for Prometheus, OpenTelemetry, logging, and health dashboards
/// without exposing internal mutable state or token counters.
final class ResourceMetricsSnapshot {
  /// The resource name.
  final String resourceName;

  /// The timestamp when this snapshot was taken.
  final DateTime timestamp;

  /// The current state of the circuit breaker.
  final CircuitState circuitState;

  /// The number of consecutive failures recorded on the resource.
  final int consecutiveFailures;

  /// The timestamp of the last recorded failure, if any.
  final DateTime? lastFailureTime;

  /// The timestamp of the last circuit breaker state change.
  final DateTime lastStateChange;

  /// The total number of requests in the rolling retry budget window.
  final int retryBudgetRequests;

  /// The number of retry attempts in the rolling retry budget window.
  final int retryBudgetRetries;

  /// The ratio of retries to total requests in the rolling retry budget window (`retries / requests`).
  final double retryBudgetRatio;

  /// Current number of speculative hedges actively executing.
  final int activeHedges;

  /// Available overload tokens in the hedging token bucket.
  final double availableHedgingTokens;

  /// Current estimate of dynamic hedging delay.
  final Duration dynamicDelayEstimate;

  /// Per-criticality throttling metrics in the rolling window.
  final Map<Criticality, CriticalityThrottlingMetrics> throttlingByCriticality;

  /// Creates a [ResourceMetricsSnapshot].
  const ResourceMetricsSnapshot({
    required this.resourceName,
    required this.timestamp,
    required this.circuitState,
    required this.consecutiveFailures,
    this.lastFailureTime,
    required this.lastStateChange,
    required this.retryBudgetRequests,
    required this.retryBudgetRetries,
    required this.retryBudgetRatio,
    required this.activeHedges,
    required this.availableHedgingTokens,
    required this.dynamicDelayEstimate,
    required this.throttlingByCriticality,
  });

  @override
  String toString() =>
      'ResourceMetricsSnapshot(resource: $resourceName, state: $circuitState, '
      'failures: $consecutiveFailures, retryRatio: $retryBudgetRatio, '
      'activeHedges: $activeHedges, timestamp: $timestamp)';
}

/// Immutable snapshot of adaptive throttling metrics for a specific [Criticality] level.
final class CriticalityThrottlingMetrics {
  /// The criticality level.
  final Criticality criticality;

  /// The total number of requests in the rolling window.
  final int requests;

  /// The number of accepted requests in the rolling window.
  final int accepts;

  /// The current rejection probability calculated for this criticality level.
  final double rejectionProbability;

  /// Creates a [CriticalityThrottlingMetrics].
  const CriticalityThrottlingMetrics({
    required this.criticality,
    required this.requests,
    required this.accepts,
    required this.rejectionProbability,
  });

  @override
  String toString() =>
      'CriticalityThrottlingMetrics(criticality: $criticality, '
      'requests: $requests, accepts: $accepts, rejectionProbability: $rejectionProbability)';
}
