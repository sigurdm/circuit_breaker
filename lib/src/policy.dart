import 'dart:async';

import 'context.dart';
import 'circuit_breaker.dart';
import 'throttling.dart';

final class _PolicyTarget implements ResilienceTarget {
  @override
  final Resource resource;

  @override
  final Criticality criticality;

  _PolicyTarget(this.resource, this.criticality);

  @override
  HedgingConfig? get hedgingOverride => null;

  @override
  RetryConfig? get retryOverride => null;
}

/// A standalone composite resilience policy.
///
/// Combines Circuit Breaker, Retry with backoff, Adaptive Throttling,
/// Request Hedging, and Timeout into a single self-contained object without
/// requiring an explicit [ResilienceContext] or named [Resource].
final class ResiliencePolicy {
  static int _nextPolicyId = 0;

  final ResilienceContext _context;
  final Resource _resource;

  /// Creates a [ResiliencePolicy] with the specified pattern configurations.
  ResiliencePolicy({
    CircuitBreakerConfig? circuitBreaker,
    RetryConfig? retry,
    ThrottlingConfig? throttling,
    HedgingConfig? hedging,
    Duration? timeout,
    bool Function(Object)? failureClassifier,
  }) : _context = ResilienceContext(),
       _resource = Resource(
         'policy_${_nextPolicyId++}',
         circuitBreaker: circuitBreaker,
         retry: retry,
         throttling: throttling,
         hedging: hedging,
         timeout: timeout,
         failureClassifier: failureClassifier,
       );

  /// The underlying resource for this policy.
  Resource get resource => _resource;

  /// The underlying resource configuration.
  ResourceConfig get config => _resource.config;

  /// The underlying resource state.
  ResourceState get state =>
      _context.states.putIfAbsent(_resource.name, () => ResourceState(config));

  /// The circuit breaker view for this policy.
  CircuitBreaker get circuitBreaker => CircuitBreaker(config, state);

  /// The current state of the circuit breaker.
  CircuitState get circuitState => state.circuitState;

  /// The current failure count of the resource.
  int get failureCount => state.failureCount;

  /// The adaptive throttler view for this policy.
  AdaptiveThrottler get throttler => AdaptiveThrottler(config, state);

  /// Executes [action] protected by this resilience policy.
  Future<T> execute<T>(
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
    Criticality criticality = Criticality.critical,
  }) {
    if (criticality == Criticality.critical) {
      return _context.execute(_resource, action, retryOn: retryOn);
    }
    return _context.execute(
      _PolicyTarget(_resource, criticality),
      action,
      retryOn: retryOn,
    );
  }

  /// Executes [action] with cancellation support protected by this resilience policy.
  Future<T> executeCancelable<T>(
    Future<T> Function(Completer<void> cancelCompleter) action, {
    bool Function(Object)? retryOn,
    Criticality criticality = Criticality.critical,
  }) {
    if (criticality == Criticality.critical) {
      return _context.executeCancelable(_resource, action, retryOn: retryOn);
    }
    return _context.executeCancelable(
      _PolicyTarget(_resource, criticality),
      action,
      retryOn: retryOn,
    );
  }

  /// Wraps [action] returning a function protected by this resilience policy.
  Future<T> Function() wrap<T>(
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
    Criticality criticality = Criticality.critical,
  }) {
    return () => execute(action, retryOn: retryOn, criticality: criticality);
  }

  /// Wraps a unary function [action] returning a function protected by this resilience policy.
  Future<T> Function(A) wrapUnary<T, A>(
    Future<T> Function(A) action, {
    bool Function(Object)? retryOn,
    Criticality criticality = Criticality.critical,
  }) {
    return (A arg) =>
        execute(() => action(arg), retryOn: retryOn, criticality: criticality);
  }
}
