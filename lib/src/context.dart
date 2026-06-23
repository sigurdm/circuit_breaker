import 'dart:async';
import 'dart:math';
import 'circuit_breaker.dart';
import 'retry.dart';
import 'hedging.dart';
import 'throttling.dart';
import 'exceptions.dart';
import 'cancellation.dart';

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
///   circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
///   retry: RetryConfig(maxAttempts: 5),
///   hedging: HedgingConfig(enabled: true, delay: Duration(milliseconds: 200)),
/// );
/// ```
bool _defaultFailureClassifier(Object _) => true;

final class ResourceConfig {
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
  ///
  /// Throws [ArgumentError] if [timeout] is non-null and not positive.
  ResourceConfig({
    CircuitBreakerConfig? circuitBreaker,
    RetryConfig? retry,
    ThrottlingConfig? throttling,
    HedgingConfig? hedging,
    this.timeout,
    this.failureClassifier = _defaultFailureClassifier,
  }) : circuitBreaker = circuitBreaker ?? CircuitBreakerConfig(),
       retry = retry ?? RetryConfig(),
       throttling = throttling ?? ThrottlingConfig(),
       hedging = hedging ?? HedgingConfig() {
    if (timeout != null && timeout! <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
  }

  /// Creates a default configuration.
  factory ResourceConfig.defaultConfig() => ResourceConfig();
}

/// Represents a remote service or component.
///
/// Resources hold shared state like circuit breakers and throttling history.
final class Resource {
  /// The name of the resource (e.g., 'users-api').
  final String name;

  /// The base configuration for this resource.
  final ResourceConfig config;

  /// Creates a [Resource].
  ///
  /// Throws [ArgumentError] if [name] is empty.
  Resource(this.name, {ResourceConfig? config})
    : config = config ?? ResourceConfig() {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must be non-empty');
    }
  }
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
final class Operation {
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
  ///
  /// Throws [ArgumentError] if [name] is empty.
  Operation(
    this.name,
    this.resource, {
    this.hedgingOverride,
    this.retryOverride,
    this.criticality = Criticality.critical,
  }) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must be non-empty');
    }
  }
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
///   consecutiveFailuresThreshold: 5, // Trip after 5 consecutive failures
///   resetTimeout: Duration(seconds: 30), // Wait 30s before trying again
/// );
/// ```
final class CircuitBreakerConfig {
  /// The number of consecutive failures allowed before the circuit trips to Open.
  final int consecutiveFailuresThreshold;

  /// The duration to wait in Open state before transitioning to Half-Open
  /// to test the service again.
  final Duration resetTimeout;

  /// Creates a [CircuitBreakerConfig].
  ///
  /// Throws [ArgumentError] if [consecutiveFailuresThreshold] is < 1,
  /// or if [resetTimeout] is not positive.
  CircuitBreakerConfig({
    this.consecutiveFailuresThreshold = 5,
    this.resetTimeout = const Duration(seconds: 30),
  }) {
    if (consecutiveFailuresThreshold < 1) {
      throw ArgumentError.value(
        consecutiveFailuresThreshold,
        'consecutiveFailuresThreshold',
        'must be >= 1',
      );
    }
    if (resetTimeout <= Duration.zero) {
      throw ArgumentError.value(
        resetTimeout,
        'resetTimeout',
        'must be positive',
      );
    }
  }
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
///   // ...
/// );
/// ```
final class RetryConfig {
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
  ///
  /// Throws [ArgumentError] if:
  /// - [maxAttempts] is < 1
  /// - [baseDelay] is negative
  /// - [maxDelay] is less than [baseDelay]
  /// - [backoffFactor] is < 1.0
  /// - [retryBudgetRatio] is not in [0.0, 1.0]
  /// - [budgetWindow] is not positive
  /// - [minRequestsForBudget] is negative
  RetryConfig({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 100),
    this.maxDelay = const Duration(seconds: 10),
    this.backoffFactor = 2.0,
    this.enableJitter = true,
    this.minRequestsForBudget = 10,
    this.retryBudgetRatio = 0.1,
    this.budgetWindow = const Duration(minutes: 1),
  }) {
    if (maxAttempts < 1) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be >= 1');
    }
    if (baseDelay < Duration.zero) {
      throw ArgumentError.value(
        baseDelay,
        'baseDelay',
        'must be >= Duration.zero',
      );
    }
    if (maxDelay < baseDelay) {
      throw ArgumentError.value(
        maxDelay,
        'maxDelay',
        'must be >= baseDelay ($baseDelay)',
      );
    }
    if (backoffFactor < 1.0) {
      throw ArgumentError.value(
        backoffFactor,
        'backoffFactor',
        'must be >= 1.0',
      );
    }
    if (retryBudgetRatio < 0.0 || retryBudgetRatio > 1.0) {
      throw ArgumentError.value(
        retryBudgetRatio,
        'retryBudgetRatio',
        'must be in [0.0, 1.0]',
      );
    }
    if (budgetWindow <= Duration.zero) {
      throw ArgumentError.value(
        budgetWindow,
        'budgetWindow',
        'must be positive',
      );
    }
    if (minRequestsForBudget < 0) {
      throw ArgumentError.value(
        minRequestsForBudget,
        'minRequestsForBudget',
        'must be >= 0',
      );
    }
  }
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
final class ThrottlingConfig {
  /// The acceptance multiplier (K) for each criticality level.
  ///
  /// A higher K means more tolerance for failures before throttling begins.
  final ({
    double criticalPlus,
    double critical,
    double sheddablePlus,
    double sheddable,
  })
  k;

  /// The duration of the rolling window used to calculate success rates.
  final Duration windowDuration;

  /// Creates a [ThrottlingConfig] with a base [k] and a [spread] factor.
  ///
  /// Preconditions:
  /// - [k] is the base multiplier. Must be >= 1.0. Defaults to 2.0.
  /// - [spread] must be non-negative (greater than or equal to 0.0). Defaults to 1.0.
  /// - [windowDuration] must be positive.
  ///
  /// The effective K values for each criticality level are calculated as:
  /// - `criticalPlus`: `k * (1.0 + 3.0 * spread)`
  /// - `critical`: `k`
  /// - `sheddablePlus`: `k * (1.0 - 0.2 * spread)` (min 1.1)
  /// - `sheddable`: `k * (1.0 - 0.4 * spread)` (min 1.1)
  ///
  /// Throws [ArgumentError] if preconditions are violated.
  ThrottlingConfig({
    double k = 2.0,
    double spread = 1.0,
    this.windowDuration = const Duration(minutes: 2),
  }) : k = (
         criticalPlus: k * (1.0 + 3.0 * spread) < 1.1
             ? 1.1
             : k * (1.0 + 3.0 * spread),
         critical: k < 1.1 ? 1.1 : k,
         sheddablePlus: k * (1.0 - 0.2 * spread) < 1.1
             ? 1.1
             : k * (1.0 - 0.2 * spread),
         sheddable: k * (1.0 - 0.4 * spread) < 1.1
             ? 1.1
             : k * (1.0 - 0.4 * spread),
       ) {
    if (k < 1.0) {
      throw ArgumentError.value(k, 'k', 'must be >= 1.0');
    }
    if (spread < 0.0) {
      throw ArgumentError.value(spread, 'spread', 'must be >= 0.0');
    }
    if (windowDuration <= Duration.zero) {
      throw ArgumentError.value(
        windowDuration,
        'windowDuration',
        'must be positive',
      );
    }
  }

  /// Creates a [ThrottlingConfig] with explicit K values for each criticality.
  ///
  /// Throws [ArgumentError] if any K value is < 1.0 or [windowDuration] is not positive.
  ThrottlingConfig.withCriticality({
    required this.k,
    this.windowDuration = const Duration(minutes: 2),
  }) {
    if (k.criticalPlus < 1.0) {
      throw ArgumentError.value(
        k.criticalPlus,
        'k.criticalPlus',
        'must be >= 1.0',
      );
    }
    if (k.critical < 1.0) {
      throw ArgumentError.value(k.critical, 'k.critical', 'must be >= 1.0');
    }
    if (k.sheddablePlus < 1.0) {
      throw ArgumentError.value(
        k.sheddablePlus,
        'k.sheddablePlus',
        'must be >= 1.0',
      );
    }
    if (k.sheddable < 1.0) {
      throw ArgumentError.value(k.sheddable, 'k.sheddable', 'must be >= 1.0');
    }
    if (windowDuration <= Duration.zero) {
      throw ArgumentError.value(
        windowDuration,
        'windowDuration',
        'must be positive',
      );
    }
  }

  /// Returns the K value for the given [criticality].
  double getK(Criticality criticality) {
    switch (criticality) {
      case Criticality.criticalPlus:
        return k.criticalPlus;
      case Criticality.critical:
        return k.critical;
      case Criticality.sheddablePlus:
        return k.sheddablePlus;
      case Criticality.sheddable:
        return k.sheddable;
    }
  }
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
final class HedgingConfig {
  /// The static delay after which a speculative second request is sent.
  /// Used if [dynamicPercentile] is null.
  final Duration delay;

  /// Whether hedging is enabled for this resource.
  final bool enabled;

  /// If non-null, dynamic hedging is enabled and this percentile (e.g. 0.95)
  /// is tracked to determine the hedging delay.
  final double? dynamicPercentile;

  /// Multiplier applied to the tracked percentile to calculate the actual hedging delay.
  final double delayMultiplier;

  /// Lower bound for the calculated dynamic delay.
  final Duration minDelay;

  /// Upper bound for the calculated dynamic delay.
  final Duration maxDelay;

  /// Controls the speed at which the dynamic delay adapts.
  final double adaptationRate;

  /// Used to set the token bucket refill rate (e.g. 0.95 means we hedge at most 5% of traffic).
  final double overloadPercentile;

  /// Capacity of the token bucket.
  final double maxOverloadTokens;

  /// Concurrency cap on the number of simultaneous active hedges per resource.
  final int maxConcurrentHedges;

  /// Creates a [HedgingConfig].
  ///
  /// Throws [ArgumentError] if:
  /// - [delay], [minDelay], or [maxDelay] is negative
  /// - [minDelay] is greater than [maxDelay]
  /// - [dynamicPercentile] is non-null and not in [0.0, 1.0]
  /// - [delayMultiplier] is not positive
  /// - [adaptationRate] is not positive
  /// - [overloadPercentile] is not in [0.0, 1.0]
  /// - [maxOverloadTokens] is < 0
  /// - [maxConcurrentHedges] is < 0
  HedgingConfig({
    this.delay = const Duration(milliseconds: 500),
    this.enabled = false,
    this.dynamicPercentile,
    this.delayMultiplier = 2.0,
    this.minDelay = const Duration(milliseconds: 10),
    this.maxDelay = const Duration(seconds: 10),
    this.adaptationRate = 10.0,
    this.overloadPercentile = 0.95,
    this.maxOverloadTokens = 10.0,
    this.maxConcurrentHedges = 5,
  }) {
    if (delay < Duration.zero) {
      throw ArgumentError.value(delay, 'delay', 'must be >= Duration.zero');
    }
    if (minDelay < Duration.zero) {
      throw ArgumentError.value(
        minDelay,
        'minDelay',
        'must be >= Duration.zero',
      );
    }
    if (maxDelay < Duration.zero) {
      throw ArgumentError.value(
        maxDelay,
        'maxDelay',
        'must be >= Duration.zero',
      );
    }
    if (minDelay > maxDelay) {
      throw ArgumentError.value(
        minDelay,
        'minDelay',
        'must be <= maxDelay ($maxDelay)',
      );
    }
    if (dynamicPercentile != null &&
        (dynamicPercentile! < 0.0 || dynamicPercentile! > 1.0)) {
      throw ArgumentError.value(
        dynamicPercentile,
        'dynamicPercentile',
        'must be in [0.0, 1.0]',
      );
    }
    if (delayMultiplier <= 0.0) {
      throw ArgumentError.value(
        delayMultiplier,
        'delayMultiplier',
        'must be positive',
      );
    }
    if (adaptationRate <= 0.0) {
      throw ArgumentError.value(
        adaptationRate,
        'adaptationRate',
        'must be positive',
      );
    }
    if (overloadPercentile < 0.0 || overloadPercentile > 1.0) {
      throw ArgumentError.value(
        overloadPercentile,
        'overloadPercentile',
        'must be in [0.0, 1.0]',
      );
    }
    if (maxOverloadTokens < 0.0) {
      throw ArgumentError.value(
        maxOverloadTokens,
        'maxOverloadTokens',
        'must be >= 0',
      );
    }
    if (maxConcurrentHedges < 0) {
      throw ArgumentError.value(
        maxConcurrentHedges,
        'maxConcurrentHedges',
        'must be >= 0',
      );
    }
  }
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
/// final usersApi = Resource(
///   'users-api',
///   config: ResourceConfig(
///     circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 3),
///   ),
/// );
///
/// final getUserOp = Operation('getUser', usersApi);
///
/// // Execute operation
/// try {
///   final user = await context.execute(getUserOp, () async {
///     return await fetchUser(123);
///   });
/// } catch (e) {
///   print('Operation failed or was throttled: $e');
/// }
/// ```
final class ResilienceContext {
  /// Gets the current [CancellationToken] from the environment.
  static CancellationToken? get currentCancellationToken =>
      Zone.current[#_cancellationToken] as CancellationToken?;

  /// Gets the current deadline from the environment.
  static DateTime? get currentDeadline => Zone.current[#_deadline] as DateTime?;

  /// Runs [action] within a zone that has the specified [deadline].
  static R runWithDeadline<R>(DateTime deadline, R Function() action) {
    return runZoned(action, zoneValues: {#_deadline: deadline});
  }

  /// Runs [action] within a zone that has the specified [token].
  static R runWithCancellationToken<R>(
    CancellationToken token,
    R Function() action,
  ) {
    return runZoned(action, zoneValues: {#_cancellationToken: token});
  }

  final Map<String, ResourceState> _states = {};

  /// Gets the states for all resources.
  Map<String, ResourceState> get states => _states;

  /// Gets or creates the state for a specific resource.
  ResourceState _getState(Resource resource) {
    final state = _states.putIfAbsent(resource.name, () {
      return ResourceState(resource.config);
    });
    state.config = resource.config;
    return state;
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

    // 1. Circuit Breaker Check (First)
    if (!circuitBreaker.isAllowed) {
      // DO NOT record request in throttling history when blocked by CB.
      throw CircuitBreakerOpenException(
        'Circuit breaker is open for ${resource.name}',
      );
    }

    // 2. Adaptive Throttling Check (Second)
    // Bypass throttling if the Circuit Breaker is in Half-Open state (trial request).
    final isHalfOpen = state.circuitState == CircuitState.halfOpen;
    if (!isHalfOpen && throttler.shouldThrottle(operation.criticality)) {
      state.recordRequest(false, operation.criticality);
      throw ThrottledException('Request throttled for ${resource.name}');
    }

    // --- Deadline & Cancellation Setup ---
    final parentDeadline = ResilienceContext.currentDeadline;
    final DateTime? localDeadline = execConfig.timeout != null
        ? DateTime.now().add(execConfig.timeout!)
        : null;

    final DateTime? effectiveDeadline = _mergeDeadlines(
      parentDeadline,
      localDeadline,
    );

    // Check if deadline is already exceeded
    if (effectiveDeadline != null &&
        DateTime.now().isAfter(effectiveDeadline)) {
      circuitBreaker.recordFailure();
      state.recordRequest(false, operation.criticality);
      throw ResilienceTimeoutException('Deadline exceeded before execution');
    }

    final parentToken = ResilienceContext.currentCancellationToken;
    final executionToken = CancellationToken();
    if (parentToken != null) {
      executionToken.attach(parentToken);
    }

    // Check if already cancelled
    if (executionToken.isCancelled) {
      throw const OperationCancelledException();
    }
    // --------------------------------------

    final topLevelCancel = Completer<void>();
    unawaited(
      executionToken.onCancelled.then((_) {
        if (!topLevelCancel.isCompleted) {
          topLevelCancel.complete();
        }
      }),
    );

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

      final attemptToken = CancellationToken();
      attemptToken.attach(executionToken);
      unawaited(cancel.future.then((_) => attemptToken.cancel()));

      if (state.circuitState == CircuitState.open) {
        throw CircuitBreakerOpenException(
          'Circuit breaker is open for ${resource.name}',
        );
      }

      try {
        final result = await runZoned(
          () async {
            if (attemptToken.isCancelled) {
              throw const OperationCancelledException();
            }
            if (effectiveDeadline != null &&
                DateTime.now().isAfter(effectiveDeadline)) {
              throw ResilienceTimeoutException(
                'Deadline exceeded during execution',
              );
            }
            return await action(combinedCancel);
          },
          zoneValues: {
            #_cancellationToken: attemptToken,
            #_deadline: effectiveDeadline,
          },
        );

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
          rethrow;
        } else {
          throw const OperationCancelledException();
        }
      }
    }

    final executionFuture = runZoned(
      () => executeWithRetry(
        () => executeWithHedging(
          instrumentedAction,
          config: execConfig,
          state: state,
        ),
        config: execConfig,
        state: state,
        retryOn: (e) {
          if (e is OperationCancelledException) return false;
          if (e is CircuitBreakerOpenException) return false;
          return retryOn?.call(e) ?? true;
        },
      ),
      zoneValues: {
        #_cancellationToken: executionToken,
        #_deadline: effectiveDeadline,
      },
    );

    if (effectiveDeadline != null) {
      final remaining = effectiveDeadline.difference(DateTime.now());
      final timer = Timer(
        remaining > Duration.zero ? remaining : Duration.zero,
        () {
          if (!topLevelCancel.isCompleted) {
            topLevelCancel.complete();
          }
          executionToken.cancel();
        },
      );

      try {
        final result = await Future.any([
          executionFuture,
          topLevelCancel.future.then(
            (_) => throw ResilienceTimeoutException(
              'Operation timed out (deadline exceeded)',
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
final class ResourceState {
  /// The active configuration for the resource.
  ResourceConfig _config;

  /// The active configuration for the resource.
  ///
  /// Can be updated dynamically.
  ResourceConfig get config => _config;
  set config(ResourceConfig newConfig) {
    _config = newConfig;
    hedgingTokens = hedgingTokens.clamp(0.0, _config.hedging.maxOverloadTokens);
  }

  /// The number of consecutive failures for the resource.
  ///
  /// Should only be mutated by the library.
  int failureCount = 0;

  /// The timestamp of the last recorded failure.
  ///
  /// Should only be mutated by the library.
  DateTime? lastFailureTime;

  CircuitState _circuitState = CircuitState.closed;

  /// The timestamp of the last circuit state change.
  DateTime lastStateChange = DateTime.now();

  /// The current state of the circuit breaker.
  ///
  /// Should only be mutated by the library.
  CircuitState get circuitState => _circuitState;
  set circuitState(CircuitState newState) {
    if (_circuitState != newState) {
      _circuitState = newState;
      lastStateChange = DateTime.now();
    }
  }

  /// The history of requests, isolated by criticality.
  ///
  /// Should only be mutated by the library.
  final Map<Criticality, List<RequestRecord>> requestHistory = {
    Criticality.criticalPlus: [],
    Criticality.critical: [],
    Criticality.sheddablePlus: [],
    Criticality.sheddable: [],
  };

  /// The history of retry attempts.
  ///
  /// Should only be mutated by the library.
  final List<RetryAttemptRecord> retryHistory = [];

  /// Current tokens in the hedging token bucket.
  ///
  /// Should only be mutated by the library.
  late double hedgingTokens;

  /// Current number of active hedges.
  ///
  /// Should only be mutated by the library.
  int activeHedges = 0;

  Duration? _dynamicDelayEstimate;

  /// The current estimate for the hedging delay.
  ///
  /// If dynamic hedging is disabled, returns the static delay.
  Duration get dynamicDelayEstimate =>
      _dynamicDelayEstimate ?? config.hedging.delay;

  /// Creates a [ResourceState] with the initial configuration.
  ResourceState(this._config) {
    hedgingTokens = _config.hedging.maxOverloadTokens;
  }

  /// Refills the hedging token bucket based on a new logical request.
  ///
  /// **Internal use only.**
  void recordLogicalRequest() {
    final hedgingConfig = config.hedging;
    hedgingTokens = min(
      hedgingConfig.maxOverloadTokens,
      hedgingTokens + (1.0 - hedgingConfig.overloadPercentile),
    );
  }

  /// Attempts to start a hedge, checking concurrency and token limits.
  ///
  /// Returns true if the hedge is allowed to start, and consumes one token.
  /// **Internal use only.**
  bool tryStartHedge() {
    final hedgingConfig = config.hedging;
    if (activeHedges >= hedgingConfig.maxConcurrentHedges) {
      return false;
    }
    if (hedgingTokens < 1.0) {
      return false;
    }
    activeHedges++;
    hedgingTokens -= 1.0;
    return true;
  }

  /// Records that a hedge has completed, decrementing the active count.
  ///
  /// **Internal use only.**
  void hedgeCompleted() {
    activeHedges = max(0, activeHedges - 1);
  }

  /// Records a hedging latency sample to update the dynamic delay estimate.
  ///
  /// **Internal use only.**
  void recordHedgingSample({required bool isSlow}) {
    final hedgingConfig = config.hedging;
    if (hedgingConfig.dynamicPercentile == null) return;

    final p = hedgingConfig.dynamicPercentile!;
    final r = hedgingConfig.adaptationRate;
    final currentUs = dynamicDelayEstimate.inMicroseconds.toDouble();

    double newUs;
    if (isSlow) {
      newUs = currentUs * (1.0 + (p / r));
    } else {
      newUs = currentUs * (1.0 - ((1.0 - p) / r));
    }

    final minUs = hedgingConfig.minDelay.inMicroseconds.toDouble();
    final maxUs = hedgingConfig.maxDelay.inMicroseconds.toDouble();
    newUs = newUs.clamp(minUs, maxUs);

    _dynamicDelayEstimate = Duration(microseconds: newUs.round());
  }

  /// Records a request outcome (accepted or not) for throttling.
  ///
  /// **Internal use only.**
  void recordRequest(bool accepted, Criticality criticality) {
    requestHistory[criticality]!.add(RequestRecord(DateTime.now(), accepted));
  }

  /// Cleans up history records that are older than the configured windows.
  ///
  /// **Internal use only.**
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

  /// Returns the number of requests in the retry budget window.
  int getRetryBudgetRequests() {
    cleanHistory(DateTime.now());
    return retryHistory.length;
  }

  /// Returns the number of retries in the retry budget window.
  int getRetryBudgetRetries() {
    cleanHistory(DateTime.now());
    return retryHistory.where((r) => r.isRetry).length;
  }

  /// Returns the ratio of retries to total requests in the retry budget window.
  double getRetryBudgetRatio() {
    final requests = getRetryBudgetRequests();
    if (requests == 0) return 0.0;
    return getRetryBudgetRetries() / requests;
  }

  /// Returns the number of request records for that criticality in the throttling window.
  int getThrottlingRequests(Criticality criticality) {
    cleanHistory(DateTime.now());
    return requestHistory[criticality]?.length ?? 0;
  }

  /// Returns the number of accepted request records for that criticality in the throttling window.
  int getThrottlingAccepts(Criticality criticality) {
    cleanHistory(DateTime.now());
    return requestHistory[criticality]?.where((r) => r.accepted).length ?? 0;
  }

  /// Returns the calculated rejection probability for that criticality.
  double getThrottlingRejectionProbability(Criticality criticality) {
    cleanHistory(DateTime.now());
    final requests = getThrottlingRequests(criticality);
    if (requests == 0) return 0.0;
    final accepts = getThrottlingAccepts(criticality);
    final kVal = config.throttling.getK(criticality);
    return max(0.0, (requests - kVal * accepts) / (requests + 1));
  }
}

/// Represents the state of a circuit breaker.
enum CircuitState { closed, open, halfOpen }

/// Records a request attempt for throttling calculations.
final class RequestRecord {
  /// The timestamp when the request was attempted.
  final DateTime timestamp;

  /// Whether the request was accepted (successful) by the backend.
  final bool accepted;

  /// Creates a [RequestRecord].
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

DateTime? _mergeDeadlines(DateTime? d1, DateTime? d2) {
  if (d1 == null) return d2;
  if (d2 == null) return d1;
  return d1.isBefore(d2) ? d1 : d2;
}
