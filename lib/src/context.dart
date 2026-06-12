import 'dart:async';
import 'circuit_breaker.dart';
import 'retry.dart';
import 'hedging.dart';
import 'throttling.dart';
import 'exceptions.dart';

/// Configuration for a specific resource's resilience policies.
///
/// This class aggregates configurations for all supported resilience patterns:
/// - Circuit Breaker
/// - Retry with Backoff
/// - Adaptive Throttling
/// - Request Hedging
///
/// Use this class to customize the behavior for specific named resources.
///
/// Example:
/// ```dart
/// final config = ResourceConfig(
///   circuitBreaker: CircuitBreakerConfig(failureThreshold: 3),
///   retry: RetryConfig(maxAttempts: 5),
///   hedging: HedgingConfig(enabled: true, delay: Duration(milliseconds: 200)),
/// );
/// ```
bool _defaultFailureClassifier(Object _) => true;

class ResourceConfig {
  /// Configuration for the circuit breaker mechanism.
  final CircuitBreakerConfig circuitBreaker;

  /// Configuration for the retry mechanism.
  final RetryConfig retry;

  /// Configuration for the adaptive throttling mechanism.
  final ThrottlingConfig throttling;

  /// Configuration for the request hedging mechanism.
  final HedgingConfig hedging;

  /// The maximum duration allowed for the entire operation (including retries and hedges).
  ///
  /// If null, no timeout is enforced.
  final Duration? timeout;

  /// A function that determines whether a given exception is considered a
  /// system failure (trips circuit breaker, counts as failure for throttling).
  ///
  /// By default, all exceptions are considered failures.
  final bool Function(Object) failureClassifier;

  /// Creates a new [ResourceConfig] with the specified policies.
  ///
  /// Defaults are used for any omitted configuration.
  const ResourceConfig({
    this.circuitBreaker = const CircuitBreakerConfig(),
    this.retry = const RetryConfig(),
    this.throttling = const ThrottlingConfig(),
    this.hedging = const HedgingConfig(),
    this.timeout,
    this.failureClassifier = _defaultFailureClassifier,
  });

  /// Creates a default configuration.
  factory ResourceConfig.defaultConfig() => const ResourceConfig();
}

/// Represents a remote service or component.
///
/// Resources hold shared state like circuit breakers and throttling history.
class Resource {
  /// The name of the resource (e.g., 'users-api').
  final String name;

  /// The base configuration for this resource.
  final ResourceConfig config;

  /// Creates a [Resource].
  const Resource(this.name, {this.config = const ResourceConfig()});
}

/// The criticality of a request, as described in the Google SRE book.
///
/// Throttling statistics are kept separately for each criticality level.
enum Criticality {
  /// Reserved for the most critical requests (e.g., those directly impacting UI).
  criticalPlus,

  /// Default for normal production requests.
  critical,

  /// Batch traffic, retries.
  sheddablePlus,

  /// Highly sheddable traffic (e.g., pre-fetching).
  sheddable,
}

/// Represents a specific call on a resource.
///
/// Operations belong to a [Resource] and can have specific overrides
/// for hedging and retry configurations.
class Operation {
  /// The name of the operation (e.g., 'get-user').
  final String name;

  /// The resource this operation belongs to.
  final Resource resource;

  /// Optional override for hedging configuration.
  final HedgingConfig? hedgingOverride;

  /// Optional override for retry configuration.
  final RetryConfig? retryOverride;

  /// The criticality of this operation.
  final Criticality criticality;

  /// Creates an [Operation].
  const Operation(
    this.name,
    this.resource, {
    this.hedgingOverride,
    this.retryOverride,
    this.criticality = Criticality.critical,
  });
}

/// Configuration for the Circuit Breaker pattern.
///
/// The circuit breaker prevents an application from repeatedly trying to
/// execute an operation that is likely to fail. It improves performance by
/// failing fast and gives struggling downstream services breathing room.
///
/// Reasons to use:
/// - Prevent cascading failures in distributed systems.
/// - Save resources (threads, memory) by not waiting for timeouts on known-failing services.
/// - Allow external services time to recover when overloaded.
///
/// Example:
/// ```dart
/// final cbConfig = CircuitBreakerConfig(
///   failureThreshold: 5, // Trip after 5 consecutive failures
///   resetTimeout: Duration(seconds: 30), // Wait 30s before trying again
/// );
/// ```
class CircuitBreakerConfig {
  /// The number of consecutive failures allowed before the circuit trips to Open.
  final int failureThreshold;

  /// The duration to wait in Open state before transitioning to Half-Open
  /// to test the service again.
  final Duration resetTimeout;

  /// Creates a [CircuitBreakerConfig].
  const CircuitBreakerConfig({
    this.failureThreshold = 5,
    this.resetTimeout = const Duration(seconds: 30),
  });
}

/// Configuration for the Retry pattern with Exponential Backoff and Jitter.
///
/// Retrying transient failures can increase application availability.
/// Exponential backoff prevents overwhelming the backend, and jitter
/// helps desynchronize clients to avoid "thundering herd" problems.
///
/// Reasons to use:
/// - Handle transient network glitches.
/// - Smooth out temporary backend overload.
///
/// Example:
/// ```dart
/// final retryConfig = RetryConfig(
///   maxAttempts: 3,
///   baseDelay: Duration(milliseconds: 100),
///   enableJitter: true,
/// );
/// ```
class RetryConfig {
  /// The maximum number of attempts (including the initial call) to make.
  final int maxAttempts;

  /// The initial delay before the first retry.
  final Duration baseDelay;

  /// The maximum delay allowed between retries.
  final Duration maxDelay;

  /// The multiplier applied to the delay on each subsequent attempt.
  final double backoffFactor;

  /// Whether to apply "Full Jitter" to randomize the delay.
  /// Recommended to prevent synchronized retries from overwhelming the server.
  final bool enableJitter;

  /// The minimum number of requests before the retry budget is enforced.
  /// Helps avoid failing initial retries when history is small.
  final int minRequestsForBudget;

  /// The fraction of requests that can be retries (e.g., 0.1 for 10%).
  final double retryBudgetRatio;

  /// The duration of the rolling window used to calculate the retry budget.
  final Duration budgetWindow;

  /// Creates a [RetryConfig].
  const RetryConfig({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 100),
    this.maxDelay = const Duration(seconds: 10),
    this.backoffFactor = 2.0,
    this.enableJitter = true,
    this.minRequestsForBudget = 10,
    this.retryBudgetRatio = 0.1,
    this.budgetWindow = const Duration(minutes: 1),
  });
}

/// Configuration for Adaptive Throttling.
///
/// Adaptive throttling allows the client to dynamically calculate the
/// probability of rejecting a request based on recent backend performance
/// (success rate over a rolling window).
///
/// Reasons to use:
/// - Prevent the client from overwhelming a struggling backend.
/// - More dynamic and adaptive than fixed rate limits.
///
/// Example:
/// ```dart
/// final throttlingConfig = ThrottlingConfig(
///   k: 2.0, // Allow up to half of requests to fail before throttling
///   windowDuration: Duration(minutes: 2),
/// );
/// ```
class ThrottlingConfig {
  /// The acceptance multiplier (K).
  ///
  /// A value of 2.0 means the client will allow the backend to fail up to
  /// half of its requests before it begins to aggressively throttle traffic.
  final double k;

  /// The duration of the rolling window used to calculate success rates.
  final Duration windowDuration;

  /// Creates a [ThrottlingConfig].
  const ThrottlingConfig({
    this.k = 2.0,
    this.windowDuration = const Duration(minutes: 2),
  });
}

/// Configuration for Request Hedging (Speculative Retries).
///
/// Request hedging improves tail latency by sending a second, identical
/// request in parallel if the primary request takes longer than a threshold.
///
/// **CRITICAL**: Only use this for non-transactional, idempotent operations
/// (like reads) because it actively duplicates calls.
///
/// Reasons to use:
/// - Mitigate "tail latency" (P99 bottlenecks).
/// - Improve responsiveness for time-sensitive operations.
///
/// Example:
/// ```dart
/// final hedgingConfig = HedgingConfig(
///   enabled: true,
///   delay: Duration(milliseconds: 200), // Hedge if not finished in 200ms
/// );
/// ```
class HedgingConfig {
  /// The delay after which a speculative second request is sent.
  /// Typically set to P95 or P99 latency of the resource.
  final Duration delay;

  /// Whether hedging is enabled for this resource.
  final bool enabled;

  /// Creates a [HedgingConfig].
  const HedgingConfig({
    this.delay = const Duration(milliseconds: 500),
    this.enabled = false,
  });
}

/// Context that holds state for named resources and executes operations.
///
/// This is the main entry point for using the `circuit_breaker` package.
/// You should typically create one instance of this class and share it
/// across your application to maintain state (like failure counts and
/// request history) for different resources.
///
/// Example:
/// ```dart
/// final context = ResilienceContext();
///
/// // Configure specific resource
/// context.configure('users-api', ResourceConfig(
///   circuitBreaker: CircuitBreakerConfig(failureThreshold: 3),
/// ));
///
/// // Execute operation
/// try {
///   final user = await context.execute('users-api', (cancelSignal) async {
///     return await fetchUser(123);
///   });
/// } catch (e) {
///   print('Operation failed or was throttled: $e');
/// }
/// ```
class ResilienceContext {
  final Map<String, ResourceState> _states = {};

  /// Gets the states for all resources.
  Map<String, ResourceState> get states => _states;

  /// Gets or creates the state for a specific resource.
  ResourceState _getState(Resource resource) {
    return _states.putIfAbsent(resource.name, () {
      return ResourceState(resource.config);
    });
  }

  /// Executes an operation with the configured resilience policies.
  ///
  /// Use this version for operations that DO NOT support cancellation.
  /// See [executeCancelable] for operations that support cancellation.
  Future<T> execute<T>(
    Operation operation,
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
  }) {
    return executeCancelable(operation, (_) => action(), retryOn: retryOn);
  }

  /// Executes an operation with the configured resilience policies.
  ///
  /// The [operation] defines which resource this call belongs to and any
  /// overrides for this specific call.
  ///
  /// The [action] is the async function to execute. It receives a `Completer<void>`
  /// named `cancelCompleter` as an argument. If request hedging is enabled and
  /// a faster request completes first, this completer will be completed to signal
  /// that the operation should be aborted if possible.
  ///
  /// The [retryOn] parameter allows specifying an optional callback to determine
  /// whether a specific error should trigger a retry. If omitted, all exceptions
  /// will trigger retries (up to max attempts).
  ///
  /// Throws [ThrottledException] if the request is rejected by adaptive throttling.
  /// Throws [CircuitBreakerOpenException] if the circuit breaker is open.
  /// Throws [ResilienceTimeoutException] if the operation times out.
  /// Rethrows the last exception if all retries fail.
  Future<T> executeCancelable<T>(
    Operation operation,
    Future<T> Function(Completer<void> cancelCompleter) action, {
    bool Function(Object)? retryOn,
  }) async {
    final resource = operation.resource;
    final state = _getState(resource);

    // Fallback chain for configs: Operation Override -> Resource Config -> Default
    final hedgingConfig = operation.hedgingOverride ?? resource.config.hedging;
    final retryConfig = operation.retryOverride ?? resource.config.retry;

    // We create a temporary config for this execution if there are overrides
    final execConfig = ResourceConfig(
      circuitBreaker: resource.config.circuitBreaker,
      throttling: resource.config.throttling,
      retry: retryConfig,
      hedging: hedgingConfig,
      timeout: resource.config.timeout,
      failureClassifier: resource.config.failureClassifier,
    );

    final throttler = AdaptiveThrottler(execConfig, state);
    final circuitBreaker = CircuitBreaker(execConfig, state);

    // 1. Adaptive Throttling
    if (throttler.shouldThrottle(operation.criticality)) {
      state.recordRequest(false, operation.criticality);
      throw ThrottledException('Request throttled for ${resource.name}');
    }

    // 2. Circuit Breaker
    if (!circuitBreaker.isAllowed) {
      state.recordRequest(false, operation.criticality);
      throw CircuitBreakerOpenException(
        'Circuit breaker is open for ${resource.name}',
      );
    }

    final topLevelCancel = Completer<void>();

    // Wrap action to record attempt outcomes
    Future<T> instrumentedAction(Completer<void> cancel) async {
      final combinedCancel = Completer<void>();

      void onCancel() {
        if (!combinedCancel.isCompleted) {
          combinedCancel.complete();
        }
      }

      unawaited(cancel.future.then((_) => onCancel()));
      unawaited(topLevelCancel.future.then((_) => onCancel()));

      try {
        final result = await action(combinedCancel);
        if (!combinedCancel.isCompleted) {
          circuitBreaker.recordSuccess();
          state.recordRequest(true, operation.criticality);
        }
        return result;
      } catch (e) {
        if (!combinedCancel.isCompleted) {
          if (execConfig.failureClassifier(e)) {
            circuitBreaker.recordFailure();
            state.recordRequest(false, operation.criticality);
          } else {
            circuitBreaker.recordSuccess();
            state.recordRequest(true, operation.criticality);
          }
        }
        rethrow;
      }
    }

    final executionFuture = executeWithRetry(
      () => executeWithHedging(
        instrumentedAction,
        config: execConfig,
        state: state,
      ),
      config: execConfig,
      state: state,
      retryOn: retryOn,
    );

    if (execConfig.timeout != null) {
      final timeout = execConfig.timeout!;
      final timer = Timer(timeout, () {
        if (!topLevelCancel.isCompleted) {
          topLevelCancel.complete();
        }
      });

      try {
        final result = await Future.any([
          executionFuture,
          topLevelCancel.future.then(
            (_) => throw ResilienceTimeoutException(
              'Operation timed out after $timeout',
            ),
          ),
        ]);
        timer.cancel();
        return result;
      } catch (e) {
        timer.cancel();
        if (e is ResilienceTimeoutException) {
          circuitBreaker.recordFailure();
          state.recordRequest(false, operation.criticality);
        }
        rethrow;
      }
    } else {
      return await executionFuture;
    }
  }
}

/// Holds the runtime state for a resource.
/// This is internal state used by the resilience patterns.
class ResourceState {
  final ResourceConfig config;

  // Circuit Breaker State
  int failureCount = 0;
  DateTime? lastFailureTime;
  CircuitState circuitState = CircuitState.closed;
  int halfOpenRequests = 0;

  // Throttling State (isolated per criticality)
  final Map<Criticality, List<RequestRecord>> requestHistory = {
    Criticality.criticalPlus: [],
    Criticality.critical: [],
    Criticality.sheddablePlus: [],
    Criticality.sheddable: [],
  };

  // Retry Budget State
  final List<RetryAttemptRecord> retryHistory = [];

  ResourceState(this.config);

  void recordRequest(bool accepted, Criticality criticality) {
    requestHistory[criticality]!.add(RequestRecord(DateTime.now(), accepted));
  }

  void cleanHistory(DateTime now) {
    final cutoff = now.subtract(config.throttling.windowDuration);
    for (final history in requestHistory.values) {
      history.removeWhere((record) => record.timestamp.isBefore(cutoff));
    }

    final retryCutoff = now.subtract(config.retry.budgetWindow);
    retryHistory.removeWhere(
      (record) => record.timestamp.isBefore(retryCutoff),
    );
  }
}

/// Represents the state of a circuit breaker.
enum CircuitState { closed, open, halfOpen }

/// Records a request attempt for throttling calculations.
class RequestRecord {
  final DateTime timestamp;
  final bool accepted;

  RequestRecord(this.timestamp, this.accepted);
}

/// Records a retry attempt for budget calculations.
final class RetryAttemptRecord {
  /// The timestamp of the attempt.
  final DateTime timestamp;

  /// Whether this attempt was a retry (true) or the initial request (false).
  final bool isRetry;

  /// Creates a [RetryAttemptRecord].
  const RetryAttemptRecord(this.timestamp, {required this.isRetry});
}
