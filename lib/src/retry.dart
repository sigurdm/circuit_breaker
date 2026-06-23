import 'dart:async';
import 'dart:math';
import 'context.dart';
import 'cancellation.dart';
import 'exceptions.dart';

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
      return await operation();
    } catch (e) {
      if (attempts >= retryConfig.maxAttempts) {
        rethrow;
      }

      // Check retry budget.
      state.cleanHistory(DateTime.now());
      final totalRequests = state.retryHistory.length;
      final totalRetries = state.retryHistory.where((r) => r.isRetry).length;

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
  final random = Random();

  // Exponential backoff: base * 2^attempt
  // attempt starts at 1, so we use attempt - 1 for the exponent to start at base delay.
  final double exp = pow(config.backoffFactor, attempt - 1).toDouble();
  final double maxAttemptDelay = config.baseDelay.inMilliseconds * exp;

  final double cappedDelay = min(
    config.maxDelay.inMilliseconds.toDouble(),
    maxAttemptDelay,
  );

  if (config.enableJitter) {
    // Full Jitter: random between 0 and cappedDelay
    final int jitterDelay = random.nextInt(cappedDelay.toInt() + 1);
    return Duration(milliseconds: jitterDelay);
  } else {
    return Duration(milliseconds: cappedDelay.toInt());
  }
}
