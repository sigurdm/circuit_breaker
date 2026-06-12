import 'context.dart';

/// Implements the Circuit Breaker pattern.
///
/// This pattern was popularized by Michael Nygard in his book "Release It!" (2007).
/// For a detailed online description, see Martin Fowler's article:
/// https://martinfowler.com/bliki/CircuitBreaker.html
class CircuitBreaker {
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
      if (now.difference(state.lastFailureTime!) > cbConfig.resetTimeout) {
        // Transition to half-open
        state.circuitState = CircuitState.halfOpen;
        state.halfOpenRequests = 1; // Count this request
        return true;
      }
      return false;
    }

    // Half-open: allow a limited number of requests to test the service.
    // We limit to 1 concurrent request in half-open state to avoid flooding.
    if (state.halfOpenRequests >= 1) {
      return false;
    }

    state.halfOpenRequests++;
    return true;
  }

  /// Records a successful operation.
  void recordSuccess() {
    if (state.circuitState == CircuitState.halfOpen) {
      state.circuitState = CircuitState.closed;
      state.failureCount = 0;
      state.halfOpenRequests = 0; // Reset
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
      state.circuitState = CircuitState.open;
      state.halfOpenRequests = 0; // Reset
    } else if (state.failureCount >= cbConfig.failureThreshold) {
      state.circuitState = CircuitState.open;
    }
  }
}
