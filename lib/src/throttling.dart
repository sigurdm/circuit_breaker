import 'dart:math';
import 'context.dart';

/// Implements Adaptive Throttling.
///
/// This technique is described in the Google SRE Book, Chapter 21 ("Handling Overload").
/// See: https://sre.google/sre-book/handling-overload/#eq2101
///
/// This class calculates the probability of throttling a request based on the
/// Google SRE adaptive throttling formula.
final class AdaptiveThrottler {
  final ResourceConfig config;
  final ResourceState state;

  /// Creates an [AdaptiveThrottler] with the given [config] and [state].
  AdaptiveThrottler(this.config, this.state);

  /// Creates a standalone [AdaptiveThrottler] with optional [config] and [failureClassifier].
  factory AdaptiveThrottler.standalone({
    ThrottlingConfig? config,
    bool Function(Object)? failureClassifier,
  }) {
    final cfg = ResourceConfig(
      throttling: config ?? ThrottlingConfig(),
      failureClassifier: failureClassifier,
    );
    return AdaptiveThrottler(cfg, ResourceState(cfg));
  }

  static final Random _random = Random();

  /// Checks if the request should be throttled.
  /// Returns true if it should be throttled (rejected).
  bool shouldThrottle(Criticality criticality) {
    final p = rejectionProbability(criticality);
    if (p <= 0.0) {
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

  /// Executes [action] protected by adaptive throttling.
  ///
  /// Throws [ThrottledException] if the request is throttled.
  Future<T> execute<T>(
    Future<T> Function() action, {
    Criticality criticality = Criticality.critical,
  }) async {
    if (shouldThrottle(criticality)) {
      throw const ThrottledException('Request was throttled');
    }
    try {
      final result = await action();
      recordRequest(true, criticality);
      return result;
    } catch (e) {
      if (safeClassify(config.failureClassifier, e)) {
        recordRequest(false, criticality);
      }
      rethrow;
    }
  }

  /// Wraps [action] returning a function protected by adaptive throttling.
  Future<T> Function() wrap<T>(
    Future<T> Function() action, {
    Criticality criticality = Criticality.critical,
  }) =>
      () => execute(action, criticality: criticality);

  /// Wraps a unary function [action] returning a function protected by adaptive throttling.
  Future<T> Function(A) wrapUnary<T, A>(
    Future<T> Function(A) action, {
    Criticality criticality = Criticality.critical,
  }) =>
      (A arg) => execute(() => action(arg), criticality: criticality);

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
