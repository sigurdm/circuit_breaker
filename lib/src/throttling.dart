import 'dart:math';
import 'context.dart';

/// Implements Adaptive Throttling.
///
/// This technique is described in the Google SRE Book, Chapter 21 ("Handling Overload").
/// See: https://sre.google/sre-book/handling-overload/#eq2101
///
/// This class calculates the probability of throttling a request based on the
/// Google SRE adaptive throttling formula.
///
/// Implements Adaptive Throttling based on the Google SRE adaptive throttling algorithm.
final class AdaptiveThrottler {
  final ResourceConfig config;
  final ResourceState state;

  /// Creates an [AdaptiveThrottler] with the given [config] and [state].
  AdaptiveThrottler(this.config, this.state);

  /// Creates a standalone [AdaptiveThrottler] with optional [config].
  factory AdaptiveThrottler.standalone({ThrottlingConfig? config}) {
    final cfg = ResourceConfig(throttling: config ?? ThrottlingConfig());
    return AdaptiveThrottler(cfg, ResourceState(cfg));
  }

  static final Random _random = Random();

  /// Checks if the request should be throttled.
  /// Returns true if it should be throttled (rejected).
  bool shouldThrottle(Criticality criticality) {
    final requests = state.getThrottlingRequests(criticality);
    if (requests < config.throttling.minRequests) {
      return false;
    }
    final accepts = state.getThrottlingAccepts(criticality);

    final k = config.throttling.getK(criticality);

    // Formula: P = max(0, (requests - K * accepts) / (requests + 1))
    final p = max(0.0, (requests - k * accepts) / (requests + 1));

    if (p == 0.0) {
      return false;
    }

    return _random.nextDouble() < p;
  }

  /// Records a request outcome (accepted or failed) for adaptive throttling metrics.
  void recordRequest(
    bool accepted, [
    Criticality criticality = Criticality.critical,
  ]) {
    state.recordRequest(accepted, criticality);
  }

  /// Returns the current rejection probability for [criticality].
  double rejectionProbability(Criticality criticality) {
    return state.getThrottlingRejectionProbability(criticality);
  }
}

/// Exception thrown when a request is throttled by the client.
///
/// This occurs when the adaptive throttling mechanism determines that the
/// backend is overloaded based on recent success/failure history, and
/// proactively rejects the request to avoid adding load.
final class ThrottledException implements Exception {
  /// Message describing the reason for throttling.
  final String message;

  /// Creates a [ThrottledException].
  const ThrottledException(this.message);

  @override
  String toString() => 'ThrottledException: $message';
}
