import 'dart:async';
import 'package:clock/clock.dart';

import 'context.dart';
import 'exceptions.dart';

/// Implements the Circuit Breaker pattern.
///
/// This pattern was popularized by Michael Nygard in his book "Release It!" (2007).
/// For a detailed online description, see Martin Fowler's article:
/// https://martinfowler.com/bliki/CircuitBreaker.html
final class CircuitBreaker {
  /// The resource configuration for this circuit breaker.
  final ResourceConfig config;

  /// The underlying resource state for this circuit breaker.
  final ResourceState state;

  /// Creates a [CircuitBreaker] wrapping [config] and [state].
  CircuitBreaker(this.config, this.state);

  /// Creates a standalone [CircuitBreaker] instance without requiring a full
  /// [ResilienceContext].
  factory CircuitBreaker.standalone({
    CircuitBreakerConfig? config,
    bool Function(Object)? failureClassifier,
  }) {
    final cfg = ResourceConfig(
      circuitBreaker: config ?? CircuitBreakerConfig(),
      failureClassifier: failureClassifier,
    );
    return CircuitBreaker(cfg, ResourceState(cfg));
  }

  static final Object _trialZoneKey = Object();

  /// Executes [action] protected by this circuit breaker.
  ///
  /// Throws [CircuitBreakerOpenException] if the circuit is open.
  Future<T> execute<T>(Future<T> Function() action) async {
    final isReentrantTrial =
        state.circuitState == CircuitState.halfOpen &&
        Zone.current[_trialZoneKey] == state;

    if (isReentrantTrial) {
      // Allow re-entrant execution within the same trial without consuming extra permits.
      return await action();
    }

    final cbConfig = config.circuitBreaker;
    final bool allowed;

    if (state.circuitState == CircuitState.closed) {
      allowed = true;
    } else if (state.circuitState == CircuitState.open) {
      final now = clock.now();
      var failureTime = state.lastFailureTime ?? state.lastStateChange;
      if (now.isBefore(failureTime)) {
        failureTime = now;
        if (state.lastFailureTime != null) state.lastFailureTime = now;
        state.lastStateChange = now;
      }
      if (now.difference(failureTime) > cbConfig.resetTimeout) {
        state.circuitState = CircuitState.halfOpen;
        state.trialRequestInProgress = true;
        allowed = true;
      } else {
        allowed = false;
      }
    } else if (state.circuitState == CircuitState.halfOpen) {
      if (state.isTrialExpired(cbConfig.resetTimeout)) {
        state.trialRequestInProgress = false;
        state.isExecutingTrial = false;
        state.trialRequestInProgress = true;
        allowed = true;
      } else if (state.isExecutingTrial) {
        // Another trial is actively executing: block concurrent requests!
        allowed = false;
      } else if (state.trialRequestInProgress) {
        // Trial permit was already claimed (e.g. by tryAcquireTrial())
        allowed = true;
      } else {
        state.trialRequestInProgress = true;
        allowed = true;
      }
    } else {
      allowed = false;
    }

    if (!allowed) {
      throw CircuitBreakerOpenException(
        'Circuit breaker is open',
        resetTimeout: config.circuitBreaker.resetTimeout,
        state: state.circuitState,
      );
    }

    final isRootTrial = state.circuitState == CircuitState.halfOpen;
    if (isRootTrial) {
      state.isExecutingTrial = true;
      state.trialStartTime = clock.now();
    }

    try {
      final result = await (isRootTrial
          ? runZoned(action, zoneValues: {_trialZoneKey: state})
          : action());
      recordSuccess();
      return result;
    } catch (e) {
      if (safeClassify(config.failureClassifier, e)) {
        recordFailure();
      } else if (state.circuitState == CircuitState.halfOpen) {
        state.trialRequestInProgress = false;
      }
      rethrow;
    } finally {
      if (isRootTrial) {
        state.isExecutingTrial = false;
      }
    }
  }

  /// Wraps [action] returning a function protected by this circuit breaker.
  Future<T> Function() wrap<T>(Future<T> Function() action) =>
      () => execute(action);

  /// Wraps a unary function [action] returning a function protected by this circuit breaker.
  Future<T> Function(A) wrapUnary<T, A>(Future<T> Function(A) action) =>
      (A arg) => execute(() => action(arg));

  /// Whether the circuit breaker is open and failing fast.
  bool get isOpen {
    if (state.circuitState == CircuitState.open) {
      final now = clock.now();
      var failureTime = state.lastFailureTime ?? state.lastStateChange;
      if (now.isBefore(failureTime)) {
        failureTime = now;
      }
      if (now.difference(failureTime) > config.circuitBreaker.resetTimeout) {
        state.circuitState = CircuitState.halfOpen;
        return false;
      }
      return true;
    }
    return false;
  }

  /// Whether the circuit breaker is half-open and testing recovery.
  bool get isHalfOpen {
    if (state.circuitState == CircuitState.open) {
      final now = clock.now();
      var failureTime = state.lastFailureTime ?? state.lastStateChange;
      if (now.isBefore(failureTime)) {
        failureTime = now;
      }
      if (now.difference(failureTime) > config.circuitBreaker.resetTimeout) {
        state.circuitState = CircuitState.halfOpen;
        return true;
      }
    }
    return state.circuitState == CircuitState.halfOpen;
  }

  /// Whether the circuit breaker is closed and functioning normally.
  bool get isClosed => state.circuitState == CircuitState.closed;

  /// Checks if a request is allowed to proceed without claiming a trial permit
  /// or mutating trial execution state.
  bool get isAllowed {
    final cbConfig = config.circuitBreaker;

    if (state.circuitState == CircuitState.closed) {
      return true;
    }

    if (state.circuitState == CircuitState.open) {
      final now = clock.now();
      var failureTime = state.lastFailureTime ?? state.lastStateChange;
      if (now.isBefore(failureTime)) {
        failureTime = now;
        if (state.lastFailureTime != null) state.lastFailureTime = now;
        state.lastStateChange = now;
      }
      if (now.difference(failureTime) > cbConfig.resetTimeout) {
        state.circuitState = CircuitState.halfOpen;
        return true;
      }
      return false;
    }

    if (state.circuitState == CircuitState.halfOpen) {
      if (state.isTrialExpired(cbConfig.resetTimeout)) {
        return true;
      }
      if (state.isExecutingTrial || state.trialRequestInProgress) {
        return false;
      }
      return true;
    }

    return false;
  }

  /// Attempts to acquire a permit to execute a trial request.
  ///
  /// If the circuit is in [CircuitState.open] and the reset timeout has elapsed,
  /// transitions the circuit to [CircuitState.halfOpen] and claims the trial permit.
  /// If the circuit is in [CircuitState.halfOpen] and no trial is currently in
  /// progress (or the active trial has expired), claims the trial permit.
  ///
  /// Returns  if the trial permit was successfully acquired,  otherwise.
  bool tryAcquireTrial() {
    final cbConfig = config.circuitBreaker;
    final now = clock.now();

    if (state.circuitState == CircuitState.open) {
      var failureTime = state.lastFailureTime ?? state.lastStateChange;
      if (now.isBefore(failureTime)) {
        failureTime = now;
        if (state.lastFailureTime != null) state.lastFailureTime = now;
        state.lastStateChange = now;
      }
      if (now.difference(failureTime) > cbConfig.resetTimeout) {
        state.circuitState = CircuitState.halfOpen;
        state.trialRequestInProgress = true;
        return true;
      }
      return false;
    }

    if (state.circuitState == CircuitState.halfOpen) {
      if (state.isTrialExpired(cbConfig.resetTimeout)) {
        state.trialRequestInProgress = false;
        state.isExecutingTrial = false;
      } else if (state.isExecutingTrial || state.trialRequestInProgress) {
        return false;
      }
      state.trialRequestInProgress = true;
      return true;
    }

    return false;
  }

  /// Records a successful operation.
  void recordSuccess() {
    if (state.circuitState == CircuitState.halfOpen) {
      state.trialRequestInProgress = false;
      state.halfOpenSuccessCount++;
      if (state.halfOpenSuccessCount >=
          config.circuitBreaker.halfOpenSuccessThreshold) {
        state.circuitState = CircuitState.closed;
        state.failureCount = 0;
        state.halfOpenSuccessCount = 0;
      }
    } else if (state.circuitState == CircuitState.closed) {
      state.failureCount = 0; // Reset count on success
    }
  }

  /// Records a failed operation.
  void recordFailure() {
    state.failureCount++;
    state.lastFailureTime = clock.now();

    final cbConfig = config.circuitBreaker;

    if (state.circuitState == CircuitState.halfOpen) {
      state.trialRequestInProgress = false;
      state.halfOpenSuccessCount = 0;
      state.circuitState = CircuitState.open;
    } else if (state.failureCount >= cbConfig.consecutiveFailuresThreshold) {
      state.circuitState = CircuitState.open;
    }
  }
}
