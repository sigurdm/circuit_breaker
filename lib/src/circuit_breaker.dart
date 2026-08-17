import 'context.dart';

/// Implements the Circuit Breaker pattern.
///
/// This pattern was popularized by Michael Nygard in his book "Release It!" (2007).
/// For a detailed online description, see Martin Fowler's article:
/// https://martinfowler.com/bliki/CircuitBreaker.html
final class CircuitBreaker {
  final ResourceConfig config;
  final ResourceState state;

  CircuitBreaker(this.config, this.state);

  /// Checks if the request is allowed to proceed.
  bool get isAllowed {
    final cbConfig = config.circuitBreaker;

    if (state.circuitState == CircuitState.closed) {
      return true;
    }

    if (state.circuitState == CircuitState.open) {
      final now = DateTime.now();
      if (state.lastFailureTime != null &&
          now.difference(state.lastFailureTime!) > cbConfig.resetTimeout) {
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
