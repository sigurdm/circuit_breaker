import 'dart:async';
import 'dart:math';
import 'package:meta/meta.dart';
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
bool _defaultFailureClassifier(Object e) {
  if (e is OperationCancelledException ||
      e is CircuitBreakerOpenException ||
      e is ThrottledException) {
    return false;
  }
  if (e is ArgumentError ||
      e is RangeError ||
      e is FormatException ||
      e is TypeError ||
      e is AssertionError) {
    return false;
  }
  return true;
}

/// Safely evaluates [classifier] on [e], falling back to [_defaultFailureClassifier]
/// if [classifier] throws.
bool safeClassify(bool Function(Object) classifier, Object e) {
  try {
    return classifier(e);
  } catch (_) {
    return _defaultFailureClassifier(e);
  }
}

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
  /// By default, client programmer errors (such as [ArgumentError], [RangeError],
  /// [FormatException], [TypeError], [AssertionError]) and [OperationCancelledException]
  /// are ignored and not considered failures; all other exceptions are considered failures.
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
    bool Function(Object)? failureClassifier,
  }) : circuitBreaker = circuitBreaker ?? CircuitBreakerConfig(),
       retry = retry ?? RetryConfig(),
       throttling = throttling ?? ThrottlingConfig(),
       hedging = hedging ?? HedgingConfig(),
       failureClassifier = failureClassifier ?? _defaultFailureClassifier {
    if (timeout != null && timeout! <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
  }

  /// Creates a default configuration.
  factory ResourceConfig.defaultConfig() => ResourceConfig();
}

/// Represents an execution target for resilience policies.
///
/// Implemented by [Resource], [Operation], and [BoundResource].
abstract interface class ResilienceTarget {
  /// The underlying [Resource] for this target.
  Resource get resource;

  /// The criticality of operations targeting this resource.
  Criticality get criticality;

  /// Optional override for hedging configuration.
  HedgingConfig? get hedgingOverride;

  /// Optional override for retry configuration.
  RetryConfig? get retryOverride;
}

/// Represents a remote service or component.
///
/// Resources hold shared state like circuit breakers and throttling history.
final class Resource implements ResilienceTarget {
  /// The name of the resource (e.g., 'users-api').
  final String name;

  /// The base configuration for this resource.
  final ResourceConfig config;

  /// The parent resource, if any.
  final Resource? parent;

  @override
  Resource get resource => this;

  @override
  Criticality get criticality => Criticality.critical;

  @override
  HedgingConfig? get hedgingOverride => null;

  @override
  RetryConfig? get retryOverride => null;

  /// Creates a [Resource].
  ///
  /// Configuration can be supplied either as a complete [ResourceConfig] object via [config],
  /// or using individual policy parameters ([circuitBreaker], [retry], [throttling],
  /// [hedging], [timeout], [failureClassifier]).
  ///
  /// It is an error if:
  /// - [name] is empty.
  /// - There is a cycle in the parent hierarchy.
  /// - Both [config] and individual policy configurations are provided.
  Resource(
    this.name, {
    ResourceConfig? config,
    this.parent,
    CircuitBreakerConfig? circuitBreaker,
    RetryConfig? retry,
    ThrottlingConfig? throttling,
    HedgingConfig? hedging,
    Duration? timeout,
    bool Function(Object)? failureClassifier,
  }) : config = _resolveConfig(
         config: config,
         circuitBreaker: circuitBreaker,
         retry: retry,
         throttling: throttling,
         hedging: hedging,
         timeout: timeout,
         failureClassifier: failureClassifier,
       ) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'must be non-empty');
    }
    var current = parent;
    while (current != null) {
      if (current.name == name) {
        throw ArgumentError(
          'Cycle detected in resource hierarchy: $name is a parent of itself.',
        );
      }
      current = current.parent;
    }
  }

  static ResourceConfig _resolveConfig({
    ResourceConfig? config,
    CircuitBreakerConfig? circuitBreaker,
    RetryConfig? retry,
    ThrottlingConfig? throttling,
    HedgingConfig? hedging,
    Duration? timeout,
    bool Function(Object)? failureClassifier,
  }) {
    final hasIndividual =
        circuitBreaker != null ||
        retry != null ||
        throttling != null ||
        hedging != null ||
        timeout != null ||
        failureClassifier != null;
    if (config != null && hasIndividual) {
      throw ArgumentError(
        'Cannot specify both config and individual policy configurations',
      );
    }
    if (config != null) return config;
    return ResourceConfig(
      circuitBreaker: circuitBreaker,
      retry: retry,
      throttling: throttling,
      hedging: hedging,
      timeout: timeout,
      failureClassifier: failureClassifier,
    );
  }

  /// Creates an [Operation] targeting this resource.
  Operation operation(
    String name, {
    HedgingConfig? hedgingOverride,
    RetryConfig? retryOverride,
    Criticality criticality = Criticality.critical,
  }) => Operation(
    name,
    this,
    hedgingOverride: hedgingOverride,
    retryOverride: retryOverride,
    criticality: criticality,
  );
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
final class Operation implements ResilienceTarget {
  /// The name of the operation (e.g., 'get-user').
  final String name;

  /// The resource this operation belongs to.
  @override
  final Resource resource;

  /// Optional override for hedging configuration.
  @override
  final HedgingConfig? hedgingOverride;

  /// Optional override for retry configuration.
  @override
  final RetryConfig? retryOverride;

  /// The criticality of this operation.
  @override
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
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'must be non-empty');
    }
  }
}

/// A [Resource] bound to a specific [ResilienceContext].
///
/// This provides direct execution methods ([execute], [executeCancelable],
/// [wrap], [wrapUnary]) without needing to pass the resource to the context explicitly.
final class BoundResource implements ResilienceTarget {
  /// The context this resource is bound to.
  final ResilienceContext context;

  /// The underlying [Resource].
  @override
  final Resource resource;

  /// Creates a [BoundResource] binding [resource] to [context].
  BoundResource(this.context, this.resource);

  /// The name of the underlying resource.
  String get name => resource.name;

  /// The configuration of the underlying resource.
  ResourceConfig get config => resource.config;

  /// The parent of the underlying resource, if any.
  Resource? get parent => resource.parent;

  @override
  Criticality get criticality => resource.criticality;

  @override
  HedgingConfig? get hedgingOverride => resource.hedgingOverride;

  @override
  RetryConfig? get retryOverride => resource.retryOverride;

  /// The state of this resource in the bound context.
  ResourceState get state => context._getState(resource);

  /// Executes an operation on this resource.
  Future<T> execute<T>(
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
  }) => context.execute(this, action, retryOn: retryOn);

  /// Executes a cancelable operation on this resource.
  Future<T> executeCancelable<T>(
    Future<T> Function(Completer<void> cancelCompleter) action, {
    bool Function(Object)? retryOn,
  }) => context.executeCancelable(this, action, retryOn: retryOn);

  /// Wraps a nullary function with this resource's resilience policies.
  Future<T> Function() wrap<T>(
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
  }) => context.wrap(this, action, retryOn: retryOn);

  /// Wraps a unary function with this resource's resilience policies.
  Future<T> Function(A) wrapUnary<T, A>(
    Future<T> Function(A) action, {
    bool Function(Object)? retryOn,
  }) => context.wrapUnary(this, action, retryOn: retryOn);

  /// Creates an [Operation] on this bound resource.
  Operation operation(
    String name, {
    HedgingConfig? hedgingOverride,
    RetryConfig? retryOverride,
    Criticality criticality = Criticality.critical,
  }) => Operation(
    name,
    resource,
    hedgingOverride: hedgingOverride,
    retryOverride: retryOverride,
    criticality: criticality,
  );
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

  /// The number of successful requests required in Half-Open state
  /// before the circuit transitions back to Closed.
  final int halfOpenSuccessThreshold;

  /// Creates a [CircuitBreakerConfig].
  ///
  /// It is an error if:
  /// - [consecutiveFailuresThreshold] is < 1
  /// - [resetTimeout] is not positive
  /// - [halfOpenSuccessThreshold] is < 1
  CircuitBreakerConfig({
    this.consecutiveFailuresThreshold = 5,
    this.resetTimeout = const Duration(seconds: 30),
    this.halfOpenSuccessThreshold = 3,
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
    if (halfOpenSuccessThreshold < 1) {
      throw ArgumentError.value(
        halfOpenSuccessThreshold,
        'halfOpenSuccessThreshold',
        'must be >= 1',
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
  /// - [backoffFactor] is < 1.0 or not finite
  /// - [retryBudgetRatio] is not in `[0.0, 1.0]` or not finite
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
    if (!backoffFactor.isFinite || backoffFactor < 1.0) {
      throw ArgumentError.value(
        backoffFactor,
        'backoffFactor',
        'must be a finite number >= 1.0',
      );
    }
    if (!retryBudgetRatio.isFinite ||
        retryBudgetRatio < 0.0 ||
        retryBudgetRatio > 1.0) {
      throw ArgumentError.value(
        retryBudgetRatio,
        'retryBudgetRatio',
        'must be a finite number in [0.0, 1.0]',
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

  /// The minimum number of requests before adaptive throttling is enforced.
  /// Helps avoid throttling requests on startup or in low-traffic scenarios.
  /// Defaults to 0.
  final int minRequests;

  /// Creates a [ThrottlingConfig] with a base [k] and a [spread] factor.
  ///
  /// Preconditions:
  /// - [k] is the base multiplier. Must be >= 1.0. Defaults to 2.0.
  /// - [spread] must be non-negative (greater than or equal to 0.0). Defaults to 1.0.
  /// - [windowDuration] must be positive.
  /// - [minRequests] must be non-negative. Defaults to 0.
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
    this.minRequests = 0,
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
    if (!k.isFinite || k < 1.0) {
      throw ArgumentError.value(k, 'k', 'must be a finite number >= 1.0');
    }
    if (!spread.isFinite || spread < 0.0) {
      throw ArgumentError.value(
        spread,
        'spread',
        'must be a finite number >= 0.0',
      );
    }
    if (windowDuration <= Duration.zero) {
      throw ArgumentError.value(
        windowDuration,
        'windowDuration',
        'must be positive',
      );
    }
    if (minRequests < 0) {
      throw ArgumentError.value(minRequests, 'minRequests', 'must be >= 0');
    }
  }

  /// Creates a [ThrottlingConfig] with explicit K values for each criticality.
  ///
  /// Throws [ArgumentError] if any K value is < 1.0 or not finite,
  /// [windowDuration] is not positive, or [minRequests] is < 0.
  ThrottlingConfig.withCriticality({
    required this.k,
    this.windowDuration = const Duration(minutes: 2),
    this.minRequests = 0,
  }) {
    if (!k.criticalPlus.isFinite || k.criticalPlus < 1.0) {
      throw ArgumentError.value(
        k.criticalPlus,
        'k.criticalPlus',
        'must be a finite number >= 1.0',
      );
    }
    if (!k.critical.isFinite || k.critical < 1.0) {
      throw ArgumentError.value(
        k.critical,
        'k.critical',
        'must be a finite number >= 1.0',
      );
    }
    if (!k.sheddablePlus.isFinite || k.sheddablePlus < 1.0) {
      throw ArgumentError.value(
        k.sheddablePlus,
        'k.sheddablePlus',
        'must be a finite number >= 1.0',
      );
    }
    if (!k.sheddable.isFinite || k.sheddable < 1.0) {
      throw ArgumentError.value(
        k.sheddable,
        'k.sheddable',
        'must be a finite number >= 1.0',
      );
    }
    if (windowDuration <= Duration.zero) {
      throw ArgumentError.value(
        windowDuration,
        'windowDuration',
        'must be positive',
      );
    }
    if (minRequests < 0) {
      throw ArgumentError.value(minRequests, 'minRequests', 'must be >= 0');
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
  /// Used if [dynamicPercentile] is null. Defaults to 500ms.
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
  /// - [delay] is negative
  /// - [delay] is not between [minDelay] and [maxDelay] when [dynamicPercentile] is non-null
  /// - [minDelay] is not positive
  /// - [maxDelay] is less than [minDelay]
  /// - [dynamicPercentile] is non-null and not a finite number in (0.0, 1.0)
  /// - [delayMultiplier] is not positive or not finite
  /// - [adaptationRate] is not positive, not finite, or not > `1.0 - dynamicPercentile`
  /// - [overloadPercentile] is not a finite number in `[0.0, 1.0)`
  /// - [maxOverloadTokens] is < 1.0 or not finite
  /// - [maxConcurrentHedges] is < 1
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
    if (minDelay <= Duration.zero) {
      throw ArgumentError.value(
        minDelay,
        'minDelay',
        'must be > Duration.zero',
      );
    }
    if (maxDelay < minDelay) {
      throw ArgumentError.value(
        maxDelay,
        'maxDelay',
        'must be >= minDelay ($minDelay)',
      );
    }
    if (dynamicPercentile != null &&
        (!dynamicPercentile!.isFinite ||
            dynamicPercentile! <= 0.0 ||
            dynamicPercentile! >= 1.0)) {
      throw ArgumentError.value(
        dynamicPercentile,
        'dynamicPercentile',
        'must be a finite number in (0.0, 1.0)',
      );
    }
    if (dynamicPercentile != null && (delay < minDelay || delay > maxDelay)) {
      throw ArgumentError.value(
        delay,
        'delay',
        'must be between minDelay ($minDelay) and maxDelay ($maxDelay) when dynamicPercentile is enabled',
      );
    }
    if (!delayMultiplier.isFinite || delayMultiplier <= 0.0) {
      throw ArgumentError.value(
        delayMultiplier,
        'delayMultiplier',
        'must be a finite positive number',
      );
    }
    if (!adaptationRate.isFinite ||
        adaptationRate <= 0.0 ||
        (dynamicPercentile != null &&
            adaptationRate <= (1.0 - dynamicPercentile!))) {
      throw ArgumentError.value(
        adaptationRate,
        'adaptationRate',
        'must be a finite positive number > (1.0 - dynamicPercentile) to ensure stochastic convergence',
      );
    }
    if (!overloadPercentile.isFinite ||
        overloadPercentile < 0.0 ||
        overloadPercentile >= 1.0) {
      throw ArgumentError.value(
        overloadPercentile,
        'overloadPercentile',
        'must be a finite number in [0.0, 1.0)',
      );
    }
    if (!maxOverloadTokens.isFinite || maxOverloadTokens < 1.0) {
      throw ArgumentError.value(
        maxOverloadTokens,
        'maxOverloadTokens',
        'must be a finite number >= 1.0',
      );
    }
    if (maxConcurrentHedges < 1) {
      throw ArgumentError.value(
        maxConcurrentHedges,
        'maxConcurrentHedges',
        'must be >= 1',
      );
    }
  }
}

/// The result of checking a resource's circuit breaker state.
enum _CheckResult {
  /// The circuit breaker is closed, request is allowed.
  allowedClosed,

  /// The circuit breaker is open but reset timeout has expired,
  /// so we are allowed to start a new trial request.
  allowedStartTrial,

  /// The circuit breaker is half-open and we are the active trial request,
  /// so we are allowed to continue (e.g. for hedges or retries of the trial).
  allowedContinueTrial,

  /// The circuit breaker is open and reset timeout has not expired,
  /// request is blocked.
  blockedOpen,

  /// The circuit breaker is half-open and another trial request is already
  /// in progress, request is blocked.
  blockedTrialInProgress,
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
  /// The ambient default [ResilienceContext] instance.
  ///
  /// Can be used for zero-setup resilience without explicitly creating
  /// and passing a [ResilienceContext].
  static final ResilienceContext defaultContext = ResilienceContext();

  /// Runs [action] protected by the policies of [target] using [defaultContext]
  /// (or `target.context` if [target] is a [BoundResource]).
  static Future<T> run<T>(
    ResilienceTarget target,
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
  }) {
    final ctx = target is BoundResource ? target.context : defaultContext;
    return ctx.execute(target, action, retryOn: retryOn);
  }

  /// Runs [action] with cancellation support protected by the policies of [target]
  /// using [defaultContext] (or `target.context` if [target] is a [BoundResource]).
  static Future<T> runCancelable<T>(
    ResilienceTarget target,
    Future<T> Function(Completer<void> cancelCompleter) action, {
    bool Function(Object)? retryOn,
  }) {
    final ctx = target is BoundResource ? target.context : defaultContext;
    return ctx.executeCancelable(target, action, retryOn: retryOn);
  }

  /// **Internal use only.**
  @internal
  static const Object cancellationTokenZoneKey = #_cancellationToken;

  /// **Internal use only.**
  @internal
  static const Object deadlineZoneKey = #_deadline;

  /// Gets the current [CancellationToken] from the environment.
  static CancellationToken? get currentCancellationToken =>
      Zone.current[cancellationTokenZoneKey] as CancellationToken?;

  /// Gets the current deadline from the environment.
  static DateTime? get currentDeadline =>
      Zone.current[deadlineZoneKey] as DateTime?;

  /// Runs [action] within a zone that has the specified [deadline].
  ///
  /// If an outer deadline already exists, the earlier of the two deadlines is used.
  static R runWithDeadline<R>(DateTime deadline, R Function() action) {
    final parent = currentDeadline;
    final effective = _mergeDeadlines(parent, deadline)!;
    return runZoned(action, zoneValues: {deadlineZoneKey: effective});
  }

  /// Runs [action] within a zone that has the specified [token].
  static R runWithCancellationToken<R>(
    CancellationToken token,
    R Function() action,
  ) {
    final parent = currentCancellationToken;
    if (parent != null) {
      token.attach(parent);
    }
    return runZoned(action, zoneValues: {cancellationTokenZoneKey: token});
  }

  final Map<String, ResourceState> _states = {};

  /// Gets the states for all resources.
  Map<String, ResourceState> get states => _states;

  /// The total number of tracked resource states.
  int get resourceCount => _states.length;

  /// Returns whether a state exists for [resourceName].
  bool containsResource(String resourceName) =>
      _states.containsKey(resourceName);

  /// Removes and evicts the state for [resourceName].
  ///
  /// Returns `true` if a state was removed, or `false` if none existed.
  bool removeResource(String resourceName) =>
      _states.remove(resourceName) != null;

  /// Clears all tracked resource states.
  void clearResources() => _states.clear();

  /// Gets or creates the state for a specific resource.
  ResourceState _getState(Resource resource) {
    final state = _states.putIfAbsent(resource.name, () {
      return ResourceState(resource.config);
    });
    state.config = resource.config;
    return state;
  }

  _CheckResult _checkResource(
    ResourceState state,
    CircuitBreakerConfig config,
    CancellationToken? token,
  ) {
    if (state.circuitState == CircuitState.closed) {
      return _CheckResult.allowedClosed;
    }
    if (state.circuitState == CircuitState.open) {
      final now = DateTime.now();
      var failureTime = state.lastFailureTime ?? state.lastStateChange;
      if (now.isBefore(failureTime)) {
        failureTime = now;
        if (state.lastFailureTime != null) state.lastFailureTime = now;
        state.lastStateChange = now;
      }
      if (now.difference(failureTime) > config.resetTimeout) {
        return _CheckResult.allowedStartTrial;
      }
      return _CheckResult.blockedOpen;
    }
    if (state.circuitState == CircuitState.halfOpen) {
      if (!state.trialRequestInProgress || state.activeTrialToken == token) {
        return _CheckResult.allowedContinueTrial;
      }
      return _CheckResult.blockedTrialInProgress;
    }
    return _CheckResult.blockedOpen;
  }

  void _checkCircuitBreakerChainFailFast(
    Resource resource,
    CancellationToken? token,
  ) {
    Resource? current = resource;
    while (current != null) {
      final s = _getState(current);
      final res = _checkResource(s, current.config.circuitBreaker, token);
      if (res == _CheckResult.blockedOpen ||
          res == _CheckResult.blockedTrialInProgress) {
        final stateStr = s.circuitState == CircuitState.halfOpen
            ? 'half-open'
            : 'open';
        throw CircuitBreakerOpenException(
          'Circuit breaker is $stateStr for ${current.name}',
        );
      }
      current = current.parent;
    }
  }

  void _checkAndTransitionCircuitBreakerChain(
    Resource resource,
    Set<ResourceState> statesToRecord,
    CancellationToken token,
  ) {
    Resource? current = resource;
    final statesToTransition = <ResourceState>[];
    final pendingStatesToRecord = <ResourceState>[];
    bool allowed = true;
    String? blockedReason;

    while (current != null) {
      final s = _getState(current);
      final res = _checkResource(s, current.config.circuitBreaker, token);
      if (res == _CheckResult.blockedOpen ||
          res == _CheckResult.blockedTrialInProgress) {
        final stateStr = s.circuitState == CircuitState.halfOpen
            ? 'half-open'
            : 'open';
        allowed = false;
        blockedReason = 'Circuit breaker is $stateStr for ${current.name}';
        break;
      }
      if (res == _CheckResult.allowedStartTrial) {
        statesToTransition.add(s);
        pendingStatesToRecord.add(s);
      } else if (res == _CheckResult.allowedContinueTrial) {
        pendingStatesToRecord.add(s);
      }
      current = current.parent;
    }

    if (!allowed) {
      throw CircuitBreakerOpenException(blockedReason!);
    }

    // Commit transitions
    for (final s in statesToTransition) {
      s.circuitState = CircuitState.halfOpen;
    }
    for (final s in pendingStatesToRecord) {
      s.activeTrialToken = token;
      statesToRecord.add(s);
    }
  }

  /// Creates and binds a [Resource] to this context.
  BoundResource resource(
    String name, {
    ResourceConfig? config,
    Resource? parent,
    CircuitBreakerConfig? circuitBreaker,
    RetryConfig? retry,
    ThrottlingConfig? throttling,
    HedgingConfig? hedging,
    Duration? timeout,
    bool Function(Object)? failureClassifier,
  }) {
    final res = Resource(
      name,
      config: config,
      parent: parent,
      circuitBreaker: circuitBreaker,
      retry: retry,
      throttling: throttling,
      hedging: hedging,
      timeout: timeout,
      failureClassifier: failureClassifier,
    );
    return BoundResource(this, res);
  }

  /// Binds an existing [Resource] to this context.
  BoundResource bind(Resource resource) {
    return BoundResource(this, resource);
  }

  /// Wraps [action] with the resilience policies configured for [target].
  Future<T> Function() wrap<T>(
    ResilienceTarget target,
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
  }) {
    return () => execute(target, action, retryOn: retryOn);
  }

  /// Wraps a unary function [action] with the resilience policies configured for [target].
  Future<T> Function(A) wrapUnary<T, A>(
    ResilienceTarget target,
    Future<T> Function(A) action, {
    bool Function(Object)? retryOn,
  }) {
    return (A arg) => execute(target, () => action(arg), retryOn: retryOn);
  }

  /// Executes an operation with the configured resilience policies.
  ///
  /// Use this version for operations that DO NOT support cancellation.
  /// See [executeCancelable] for operations that support cancellation.
  Future<T> execute<T>(
    ResilienceTarget target,
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
  }) {
    return executeCancelable(target, (_) => action(), retryOn: retryOn);
  }

  /// Executes an operation with the configured resilience policies.
  ///
  /// The [target] defines which resource this call belongs to and any
  /// overrides for this specific call.
  ///
  /// The [action] is the async function to execute. It receives a `Completer<void>`
  /// named `cancelCompleter` as an argument. If request hedging is enabled and
  /// a faster request completes first, this completer will be completed to signal
  /// that the operation should be aborted if possible.
  ///
  /// The [retryOn] parameter allows specifying an optional callback to determine
  /// whether a specific error should trigger a retry. If omitted, all exceptions
  /// will trigger retries (up to max attempts) except for [OperationCancelledException],
  /// [CircuitBreakerOpenException], and [ResilienceTimeoutException].
  ///
  /// Throws [ThrottledException] if the request is rejected by adaptive throttling.
  /// Throws [CircuitBreakerOpenException] if the circuit breaker is open.
  /// Throws [ResilienceTimeoutException] if the operation times out.
  /// Rethrows the last exception if all retries fail.
  Future<T> executeCancelable<T>(
    ResilienceTarget target,
    Future<T> Function(Completer<void> cancelCompleter) action, {
    bool Function(Object)? retryOn,
  }) async {
    final resource = target.resource;
    final state = _getState(resource);

    // Fallback chain for configs: Target Override -> Resource Config -> Default
    final hedgingConfig = target.hedgingOverride ?? resource.config.hedging;
    final retryConfig = target.retryOverride ?? resource.config.retry;

    // We create a temporary config for this execution if there are overrides
    final execConfig = ResourceConfig(
      circuitBreaker: resource.config.circuitBreaker,
      throttling: resource.config.throttling,
      retry: retryConfig,
      hedging: hedgingConfig,
      timeout: resource.config.timeout,
      failureClassifier: resource.config.failureClassifier,
    );

    final parentToken = ResilienceContext.currentCancellationToken;
    if (parentToken != null && parentToken.isCancelled) {
      throw const OperationCancelledException();
    }

    final executionToken = CancellationToken();
    if (parentToken != null) {
      executionToken.attach(parentToken);
    }

    final statesToRecord = <ResourceState>{};
    Timer? timeoutTimer;
    bool recordedTimeoutFailure = false;

    try {
      if (executionToken.isCancelled) {
        throw const OperationCancelledException();
      }

      final throttler = AdaptiveThrottler(execConfig, state);

      // 1. Circuit Breaker Check (Fail-Fast Dry Run)
      _checkCircuitBreakerChainFailFast(resource, executionToken);

      // 2. Adaptive Throttling Check (Second)
      final leafRes = _checkResource(
        state,
        execConfig.circuitBreaker,
        executionToken,
      );
      final isHalfOpen =
          state.circuitState == CircuitState.halfOpen ||
          leafRes == _CheckResult.allowedStartTrial;

      if (!isHalfOpen && throttler.shouldThrottle(target.criticality)) {
        throw ThrottledException('Request throttled for ${resource.name}');
      }

      // --- Deadline Setup ---
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
        throw ResilienceTimeoutException('Deadline exceeded before execution');
      }

      // 3. Commit Circuit Breaker Transitions
      _checkAndTransitionCircuitBreakerChain(
        resource,
        statesToRecord,
        executionToken,
      );
      statesToRecord.add(state);

      final topLevelCancel = Completer<Exception>();
      unawaited(
        executionToken.onCancelled
            .then((_) {
              if (!topLevelCancel.isCompleted) {
                topLevelCancel.complete(const OperationCancelledException());
              }
            })
            .catchError((_, __) {}),
      );

      Future<T> singleAttempt(Completer<void> cancel) async {
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

        try {
          return await runZoned(
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
              ResilienceContext.cancellationTokenZoneKey: attemptToken,
              ResilienceContext.deadlineZoneKey: effectiveDeadline,
            },
          );
        } finally {
          attemptToken.detach();
        }
      }

      Future<T> hedgedAttempt() async {
        final attemptStatesToRecord = <ResourceState>{};
        _checkAndTransitionCircuitBreakerChain(
          resource,
          attemptStatesToRecord,
          executionToken,
        );
        attemptStatesToRecord.add(state);
        statesToRecord.addAll(attemptStatesToRecord);

        try {
          final result = await executeWithHedging(
            singleAttempt,
            config: execConfig,
            state: state,
          );

          if (!topLevelCancel.isCompleted && !executionToken.isCancelled) {
            for (final s in attemptStatesToRecord) {
              final cb = CircuitBreaker(s.config, s);
              cb.recordSuccess();
            }
            state.recordRequest(true, target.criticality);
          }
          return result;
        } catch (e) {
          final isCancelled =
              executionToken.isCancelled || topLevelCancel.isCompleted;
          if (!isCancelled && e is! OperationCancelledException) {
            if (safeClassify(execConfig.failureClassifier, e)) {
              if (e is ResilienceTimeoutException) {
                recordedTimeoutFailure = true;
              }
              for (final s in attemptStatesToRecord) {
                final cb = CircuitBreaker(s.config, s);
                cb.recordFailure();
              }
              state.recordRequest(false, target.criticality);
            }
          }
          rethrow;
        }
      }

      final executionCompleter = Completer<T>();
      runZonedGuarded(
        () async {
          try {
            final val = await executeWithRetry(
              hedgedAttempt,
              config: execConfig,
              state: state,
              retryOn: (e) {
                if (e is OperationCancelledException) return false;
                if (e is CircuitBreakerOpenException) return false;
                if (e is ResilienceTimeoutException) return false;
                return retryOn?.call(e) ?? true;
              },
            );
            if (!executionCompleter.isCompleted) {
              executionCompleter.complete(val);
            }
          } catch (e, st) {
            if (!executionCompleter.isCompleted) {
              executionCompleter.completeError(e, st);
            }
          }
        },
        (error, stack) {
          // Isolate uncaught asynchronous errors in background tasks from escaping to root zone.
          if (!executionCompleter.isCompleted) {
            executionCompleter.completeError(error, stack);
          }
        },
        zoneValues: {
          ResilienceContext.cancellationTokenZoneKey: executionToken,
          ResilienceContext.deadlineZoneKey: effectiveDeadline,
        },
      );
      final executionFuture = executionCompleter.future;
      executionFuture.ignore();

      if (effectiveDeadline != null) {
        final remaining = effectiveDeadline.difference(DateTime.now());
        timeoutTimer = Timer(
          remaining > Duration.zero ? remaining : Duration.zero,
          () {
            if (!topLevelCancel.isCompleted) {
              topLevelCancel.complete(
                ResilienceTimeoutException(
                  'Operation timed out (deadline exceeded)',
                ),
              );
            }
            executionToken.cancel();
          },
        );
      }

      final result = await Future.any([
        executionFuture,
        topLevelCancel.future.then((e) => throw e),
      ]);
      return result;
    } catch (e) {
      if (e is ResilienceTimeoutException &&
          !recordedTimeoutFailure &&
          safeClassify(execConfig.failureClassifier, e)) {
        for (final s in statesToRecord) {
          final cb = CircuitBreaker(s.config, s);
          cb.recordFailure();
        }
        state.recordRequest(false, target.criticality);
      }
      rethrow;
    } finally {
      timeoutTimer?.cancel();
      executionToken.detach();
      for (final s in statesToRecord) {
        if (s.activeTrialToken == executionToken) {
          s.activeTrialToken = null;
        }
      }
    }
  }
}

/// Holds the runtime state for a resource.
/// This is internal state used by the resilience patterns.
class ResourceState {
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

  /// The number of consecutive successes in Half-Open state.
  int halfOpenSuccessCount = 0;

  CancellationToken? _activeTrialToken;

  /// The cancellation token of the active trial request, if any.
  CancellationToken? get activeTrialToken => _activeTrialToken;
  set activeTrialToken(CancellationToken? token) {
    _activeTrialToken = token;
  }

  /// Whether a trial request is currently in progress in Half-Open state.
  bool get trialRequestInProgress => _activeTrialToken != null;
  set trialRequestInProgress(bool value) {
    if (value) {
      _activeTrialToken ??= CancellationToken();
    } else {
      _activeTrialToken = null;
    }
  }

  /// Whether an active trial action is currently executing in Half-Open state.
  @internal
  bool isExecutingTrial = false;

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
  Duration get dynamicDelayEstimate {
    final h = config.hedging;
    if (h.dynamicPercentile == null) {
      return h.delay;
    }
    final raw = _dynamicDelayEstimate ?? h.delay;
    if (raw < h.minDelay) return h.minDelay;
    if (raw > h.maxDelay) return h.maxDelay;
    return raw;
  }

  /// Creates a [ResourceState] with the initial configuration.
  ResourceState(this._config) {
    hedgingTokens = _config.hedging.maxOverloadTokens;
  }

  /// Refills the hedging token bucket based on a new logical request.
  ///
  /// **Internal use only.**
  @internal
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
  @internal
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
  @internal
  void hedgeCompleted() {
    activeHedges = max(0, activeHedges - 1);
  }

  /// Records a hedging latency sample to update the dynamic delay estimate.
  ///
  /// **Internal use only.**
  @internal
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

    final minUs = max(hedgingConfig.minDelay.inMicroseconds.toDouble(), 1.0);
    final maxUs = hedgingConfig.maxDelay.inMicroseconds.toDouble();
    newUs = newUs.clamp(minUs, maxUs);

    _dynamicDelayEstimate = Duration(microseconds: newUs.round());
  }

  /// Records a request outcome (accepted or not) for throttling.
  ///
  /// **Internal use only.**
  @internal
  void recordRequest(bool accepted, Criticality criticality) {
    requestHistory[criticality]!.add(RequestRecord(DateTime.now(), accepted));
  }

  /// Cleans up history records that are older than the configured windows.
  ///
  /// **Internal use only.**
  @internal
  void cleanHistory(DateTime now) {
    final cutoff = now.subtract(config.throttling.windowDuration);
    for (final history in requestHistory.values) {
      if (history.isEmpty) continue;
      history.removeWhere(
        (record) =>
            record.timestamp.isBefore(cutoff) || record.timestamp.isAfter(now),
      );
    }

    final retryCutoff = now.subtract(config.retry.budgetWindow);
    if (retryHistory.isNotEmpty) {
      retryHistory.removeWhere(
        (record) =>
            record.timestamp.isBefore(retryCutoff) ||
            record.timestamp.isAfter(now),
      );
    }
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
    cleanHistory(DateTime.now());
    final requests = retryHistory.length;
    if (requests == 0) return 0.0;
    int retries = 0;
    for (final r in retryHistory) {
      if (r.isRetry) retries++;
    }
    return retries / requests;
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
    final list = requestHistory[criticality];
    final requests = list?.length ?? 0;
    if (requests < config.throttling.minRequests || requests == 0) return 0.0;
    int accepts = 0;
    if (list != null) {
      for (final r in list) {
        if (r.accepted) accepts++;
      }
    }
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
