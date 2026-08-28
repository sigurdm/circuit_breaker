import 'dart:async';

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

  /// Executes [action] protected by this circuit breaker.
  ///
  /// Throws [CircuitBreakerOpenException] if the circuit is open.
  Future<T> execute<T>(Future<T> Function() action) async {
    final bool allowed;
    if (state.circuitState == CircuitState.halfOpen) {
      if (state.isExecutingTrial) {
        // Another trial is actively executing: block concurrent requests!
        allowed = false;
      } else if (state.trialRequestInProgress) {
        // Trial permit was already claimed (e.g. by a preceding cb.isAllowed check)
        allowed = true;
      } else {
        allowed = isAllowed;
      }
    } else {
      allowed = isAllowed;
    }

    if (!allowed) {
      throw CircuitBreakerOpenException('Circuit breaker is open');
    }

    if (state.circuitState == CircuitState.halfOpen) {
      state.isExecutingTrial = true;
    }

    try {
      final result = await action();
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
      state.isExecutingTrial = false;
    }
  }

  /// Checks if the request is allowed to proceed.
  bool get isAllowed {
    final cbConfig = config.circuitBreaker;

    if (state.circuitState == CircuitState.closed) {
      return true;
    }

    if (state.circuitState == CircuitState.open) {
      final now = DateTime.now();
      var failureTime = state.lastFailureTime ?? state.lastStateChange;
      if (now.isBefore(failureTime)) {
        failureTime = now;
        if (state.lastFailureTime != null) state.lastFailureTime = now;
        state.lastStateChange = now;
      }
      if (now.difference(failureTime) > cbConfig.resetTimeout) {
        // Transition to half-open and start trial
        state.circuitState = CircuitState.halfOpen;
        state.trialRequestInProgress = true;
        return true;
      }
      return false;
    }

    if (state.circuitState == CircuitState.halfOpen) {
      if (!state.trialRequestInProgress) {
        state.trialRequestInProgress = true;
        return true;
      }
      return false;
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
    state.lastFailureTime = DateTime.now();

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
