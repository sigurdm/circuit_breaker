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
    final currentToken = ResilienceContext.currentCancellationToken;
    if (currentToken != null && currentToken.isCancelled) {
      throw const OperationCancelledException();
    }

    final initialDeadline = ResilienceContext.currentDeadline;
    if (initialDeadline != null && DateTime.now().isAfter(initialDeadline)) {
      throw ResilienceTimeoutException('Deadline exceeded before attempt');
    }

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

      // Non-retryable exceptions should never be retried
      if (e is OperationCancelledException ||
          e is CircuitBreakerOpenException ||
          e is ResilienceTimeoutException) {
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
          cancelToken.onCancelled
              .then((_) {
                if (!delayCompleter.isCompleted) {
                  delayCompleter.completeError(
                    const OperationCancelledException(),
                  );
                }
              })
              .catchError((_, __) {}),
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

/// Implements Retry with exponential backoff and jitter.
final class Retry {
  /// The resource configuration for retry logic.
  final ResourceConfig config;

  /// The underlying resource state for retry tracking and budgets.
  final ResourceState state;

  /// Optional default predicate determining whether an error should be retried.
  final bool Function(Object)? retryOn;

  /// Creates a [Retry] wrapping [config] and [state].
  Retry(this.config, this.state, {this.retryOn});

  /// Creates a standalone [Retry] instance without requiring a full [ResilienceContext].
  factory Retry.standalone({
    RetryConfig? config,
    int? maxAttempts,
    Duration? baseDelay,
    Duration? maxDelay,
    double? backoffFactor,
    bool? enableJitter,
    Duration? timeout,
    bool Function(Object)? failureClassifier,
    bool Function(Object)? retryOn,
  }) {
    final retryConfig =
        config ??
        RetryConfig(
          maxAttempts: maxAttempts ?? 3,
          baseDelay: baseDelay ?? const Duration(milliseconds: 100),
          maxDelay: maxDelay ?? const Duration(seconds: 10),
          backoffFactor: backoffFactor ?? 2.0,
          enableJitter: enableJitter ?? true,
        );
    final cfg = ResourceConfig(
      retry: retryConfig,
      timeout: timeout,
      failureClassifier: failureClassifier,
    );
    final effectiveRetryOn = retryOn ?? failureClassifier;
    return Retry(cfg, ResourceState(cfg), retryOn: effectiveRetryOn);
  }

  /// Executes [action] with retry logic, exponential backoff, and jitter.
  Future<T> execute<T>(
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
  }) async {
    final parentToken = ResilienceContext.currentCancellationToken;
    if (parentToken != null && parentToken.isCancelled) {
      throw const OperationCancelledException();
    }

    final parentDeadline = ResilienceContext.currentDeadline;
    final localDeadline = config.timeout != null
        ? DateTime.now().add(config.timeout!)
        : null;
    final effectiveDeadline = parentDeadline == null
        ? localDeadline
        : (localDeadline == null
              ? parentDeadline
              : (parentDeadline.isBefore(localDeadline)
                    ? parentDeadline
                    : localDeadline));

    if (effectiveDeadline != null &&
        DateTime.now().isAfter(effectiveDeadline)) {
      throw ResilienceTimeoutException('Deadline exceeded before execution');
    }

    final executionToken = CancellationToken();
    if (parentToken != null) {
      executionToken.attach(parentToken);
    }

    final topLevelCancel = Completer<Exception>();
    unawaited(
      executionToken.onCancelled
          .then((_) {
            if (!topLevelCancel.isCompleted) {
              topLevelCancel.complete(const OperationCancelledException());
            }
          })
          .catchError((_, __) {}),
    );

    Timer? timeoutTimer;
    if (effectiveDeadline != null) {
      final remaining = effectiveDeadline.difference(DateTime.now());
      timeoutTimer = Timer(
        remaining > Duration.zero ? remaining : Duration.zero,
        () {
          if (!topLevelCancel.isCompleted) {
            topLevelCancel.complete(
              ResilienceTimeoutException(
                'Operation timed out (deadline exceeded)',
              ),
            );
          }
          executionToken.cancel();
        },
      );
    }

    final executionCompleter = Completer<T>();
    runZonedGuarded(
      () async {
        try {
          final val = await executeWithRetry(
            action,
            config: config,
            state: state,
            retryOn: retryOn ?? this.retryOn,
          );
          if (!executionCompleter.isCompleted) {
            executionCompleter.complete(val);
          }
        } catch (e, st) {
          if (!executionCompleter.isCompleted) {
            executionCompleter.completeError(e, st);
          }
        }
      },
      (error, stack) {
        if (!executionCompleter.isCompleted) {
          executionCompleter.completeError(error, stack);
        }
      },
      zoneValues: {
        #_cancellationToken: executionToken,
        #_deadline: effectiveDeadline,
      },
    );

    final executionFuture = executionCompleter.future;
    executionFuture.ignore();

    try {
      return await Future.any([
        executionFuture,
        topLevelCancel.future.then((e) => throw e),
      ]);
    } finally {
      timeoutTimer?.cancel();
      executionToken.detach();
    }
  }

  /// Wraps [action] returning a function protected by retry logic.
  Future<T> Function() wrap<T>(
    Future<T> Function() action, {
    bool Function(Object)? retryOn,
  }) {
    return () => execute(action, retryOn: retryOn);
  }

  /// Wraps a unary function [action] returning a function protected by retry logic.
  Future<T> Function(A) wrapUnary<T, A>(
    Future<T> Function(A) action, {
    bool Function(Object)? retryOn,
  }) {
    return (A arg) => execute(() => action(arg), retryOn: retryOn);
  }
}

/// Executes [action] with retry logic, exponential backoff, and jitter.
///
/// This convenience function provides an ad-hoc, one-liner way to retry an operation
/// without instantiating a [Retry] object.
Future<T> retry<T>(
  Future<T> Function() action, {
  int maxAttempts = 3,
  Duration baseDelay = const Duration(milliseconds: 100),
  Duration maxDelay = const Duration(seconds: 10),
  double backoffFactor = 2.0,
  bool enableJitter = true,
  bool Function(Object)? retryOn,
  Duration? timeout,
  bool Function(Object)? failureClassifier,
  RetryConfig? config,
}) {
  final effectiveConfig =
      config ??
      RetryConfig(
        maxAttempts: maxAttempts,
        baseDelay: baseDelay,
        maxDelay: maxDelay,
        backoffFactor: backoffFactor,
        enableJitter: enableJitter,
      );
  final r = Retry.standalone(
    config: effectiveConfig,
    timeout: timeout,
    failureClassifier: failureClassifier,
    retryOn: retryOn,
  );
  return r.execute(action);
}
