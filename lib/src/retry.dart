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
  final safeExponent = min(attempt - 1, 62);
  final double exp = pow(config.backoffFactor, safeExponent).toDouble();
  final double maxAttemptDelay = config.baseDelay.inMilliseconds * exp;

  final double cappedDelay = min(
    config.maxDelay.inMilliseconds.toDouble(),
    maxAttemptDelay,
  );

  // Cap to 0x7FFFFFFF (max positive 32-bit int) to prevent Random.nextInt RangeError
  final int safeCappedDelay = min(cappedDelay.toInt(), 0x7FFFFFFF);

  if (config.enableJitter) {
    // Full Jitter: random between 0 and safeCappedDelay
    final int jitterDelay = safeCappedDelay > 0
        ? _random.nextInt(safeCappedDelay + 1)
        : 0;
    return Duration(milliseconds: jitterDelay);
  } else {
    return Duration(milliseconds: safeCappedDelay);
  }
}
