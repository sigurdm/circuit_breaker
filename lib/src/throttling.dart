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
/// This is an internal implementation detail and is not exported in the public API.
class AdaptiveThrottler {
  final ResourceConfig config;
  final ResourceState state;

  AdaptiveThrottler(this.config, this.state);

  /// Checks if the request should be throttled.
  /// Returns true if it should be throttled (rejected).
  bool shouldThrottle(Criticality criticality) {
    final now = DateTime.now();
    state.cleanHistory(now);

    final history = state.requestHistory[criticality]!;
    final requests = history.length;
    final accepts = history.where((r) => r.accepted).length;

    final k = config.throttling.getK(criticality);

    // Formula: P = max(0, (requests - K * accepts) / (requests + 1))
    final p = max(0.0, (requests - k * accepts) / (requests + 1));

    if (p == 0.0) {
      return false;
    }

    final random = Random();
    return random.nextDouble() < p;
  }
}

/// Exception thrown when a request is throttled by the client.
///
/// This occurs when the adaptive throttling mechanism determines that the
/// backend is overloaded based on recent success/failure history, and
/// proactively rejects the request to avoid adding load.
///
/// Example:
/// ```dart
/// try {
///   await context.execute('resource', (_) async => ...);
/// } on ThrottledException catch (e) {
///   print('Request was throttled: ${e.message}');
///   // Fallback or wait and retry
/// }
/// ```
class ThrottledException implements Exception {
  /// Message describing the reason for throttling.
  final String message;

  /// Creates a [ThrottledException].
  ThrottledException(this.message);

  @override
  String toString() => 'ThrottledException: $message';
}
