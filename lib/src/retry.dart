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

      // Check if we should retry on this specific error first
      if (retryOn != null && !retryOn(e)) {
        rethrow;
      }

      // Check retry budget.
      final totalRequests = state.getRetryBudgetRequests();
      final totalRetries = state.getRetryBudgetRetries();

      if (totalRequests >= retryConfig.minRequestsForBudget &&
          (totalRetries + 1) >
              (totalRequests + 1) * retryConfig.retryBudgetRatio) {
        rethrow; // Budget exceeded
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
  final maxDelayUs = config.maxDelay.inMicroseconds;
  // Exponential backoff: base * factor^(attempt - 1)
  // attempt starts at 1, so we use attempt - 1 for the exponent to start at base delay.
  final safeExponent = max(0, min(attempt - 1, 62));
  final double exp = pow(config.backoffFactor, safeExponent).toDouble();
  final double maxAttemptDelayUs =
      config.baseDelay.inMicroseconds.toDouble() * exp;

  if (!maxAttemptDelayUs.isFinite ||
      maxAttemptDelayUs >= maxDelayUs.toDouble()) {
    if (config.enableJitter) {
      final int jitterDelayUs = (_random.nextDouble() * maxDelayUs).round();
      return Duration(microseconds: jitterDelayUs);
    } else {
      return config.maxDelay;
    }
  }

  final int cappedDelayUs = min(maxDelayUs, maxAttemptDelayUs.round());

  if (config.enableJitter) {
    final int jitterDelayUs = (_random.nextDouble() * cappedDelayUs).round();
    return Duration(microseconds: jitterDelayUs);
  } else {
    return Duration(microseconds: cappedDelayUs);
  }
}
