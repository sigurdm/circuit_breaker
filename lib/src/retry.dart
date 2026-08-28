import 'dart:async';
import 'dart:math';
import 'context.dart';
import 'cancellation.dart';
import 'exceptions.dart';

final Random _random = Random();

/// Executes an operation with retry logic, exponential backoff, and jitter.
Future<T> executeWithRetry<T>(
  Future<T> Function() operation, {
  required ResourceConfig config,
  required ResourceState state,
  bool Function(Object)? retryOn,
}) async {
  final retryConfig = config.retry;
  int attempts = 0;

  while (true) {
    try {
      attempts++;
      state.retryHistory.add(
        RetryAttemptRecord(DateTime.now(), isRetry: attempts > 1),
      );
      state.cleanHistory(DateTime.now());
      return await operation();
    } catch (e) {
      if (attempts >= retryConfig.maxAttempts) {
        rethrow;
      }

      // Check retry budget.
      final totalRequests = state.getRetryBudgetRequests();
      final totalRetries = state.getRetryBudgetRetries();

      if (totalRequests > retryConfig.minRequestsForBudget &&
          (totalRetries + 1) >
              (totalRequests + 1) * retryConfig.retryBudgetRatio) {
        rethrow; // Budget exceeded
      }

      // Check if we should retry on this specific error
      if (retryOn != null && !retryOn(e)) {
        rethrow;
      }

      // Check if deadline is already exceeded
      final currentDeadline = ResilienceContext.currentDeadline;
      if (currentDeadline != null && DateTime.now().isAfter(currentDeadline)) {
        throw ResilienceTimeoutException(
          'Deadline exceeded before retry attempt',
        );
      }

      // Calculate delay with exponential backoff and full jitter
      final delay = _calculateDelay(attempts, retryConfig);

      final CancellationToken? cancelToken =
          ResilienceContext.currentCancellationToken;
      if (cancelToken != null) {
        if (cancelToken.isCancelled) {
          throw const OperationCancelledException();
        }

        final delayCompleter = Completer<void>();
        final timer = Timer(delay, () {
          if (!delayCompleter.isCompleted) {
            delayCompleter.complete();
          }
        });

        unawaited(
          cancelToken.onCancelled.then((_) {
            if (!delayCompleter.isCompleted) {
              delayCompleter.completeError(const OperationCancelledException());
            }
          }),
        );

        try {
          await delayCompleter.future;
          timer.cancel();
        } catch (e) {
          timer.cancel();
          rethrow;
        }
      } else {
        await Future.delayed(delay);
      }
    }
  }
}

Duration _calculateDelay(int attempt, RetryConfig config) {
  if (config.baseDelay == Duration.zero) {
    return Duration.zero;
  }
  // Exponential backoff: base * factor^(attempt - 1)
  // attempt starts at 1, so we use attempt - 1 for the exponent to start at base delay.
  final safeExponent = max(0, min(attempt - 1, 62));
  final double exp = pow(config.backoffFactor, safeExponent).toDouble();
  final double maxAttemptDelayUs =
      config.baseDelay.inMicroseconds.toDouble() * exp;

  final double cappedDelayUs = min(
    config.maxDelay.inMicroseconds.toDouble(),
    maxAttemptDelayUs,
  );

  if (config.enableJitter) {
    // Cap to 0x7FFFFFFF ms to prevent Random.nextInt RangeError
    final int safeCappedDelayMs = min(
      (cappedDelayUs / 1000.0).round(),
      0x7FFFFFFF,
    );
    final int jitterDelayMs = safeCappedDelayMs > 0
        ? _random.nextInt(safeCappedDelayMs + 1)
        : 0;
    return Duration(milliseconds: jitterDelayMs);
  } else {
    return Duration(microseconds: cappedDelayUs.round());
  }
}
