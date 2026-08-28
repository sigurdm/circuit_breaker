import 'dart:async';
import 'dart:math';
import 'context.dart';
import 'exceptions.dart';
import 'cancellation.dart';

/// Executes an operation with request hedging.
/// The operation function receives a `Completer` that will be completed if the operation should be cancelled.
Future<T> executeWithHedging<T>(
  Future<T> Function(Completer<void> cancelCompleter) operation, {
  required ResourceConfig config,
  required ResourceState state,
}) async {
  final hedgingConfig = config.hedging;

  if (!hedgingConfig.enabled || state.circuitState == CircuitState.halfOpen) {
    return await operation(Completer<void>());
  }

  final currentToken = ResilienceContext.currentCancellationToken;
  if (currentToken != null && currentToken.isCancelled) {
    throw const OperationCancelledException();
  }

  state.recordLogicalRequest();

  final c1 = Completer<void>();
  final c2 = Completer<void>();

  final stopwatch = Stopwatch()..start();
  final Future<T> f1;
  try {
    f1 = operation(c1);
  } catch (e) {
    if (!c1.isCompleted) c1.complete();
    if (!c2.isCompleted) c2.complete();
    rethrow;
  }

  final rawV = state.dynamicDelayEstimate;
  final actualHedgingDelay = hedgingConfig.dynamicPercentile != null
      ? Duration(
          microseconds: (rawV.inMicroseconds * hedgingConfig.delayMultiplier)
              .round(),
        )
      : hedgingConfig.delay;

  bool sampleRegistered = false;

  void registerSample({required bool isSlow}) {
    if (sampleRegistered) return;
    sampleRegistered = true;
    state.recordHedgingSample(isSlow: isSlow);
  }

  Timer? earlyRegTimer;
  if (hedgingConfig.dynamicPercentile != null) {
    earlyRegTimer = Timer(rawV, () {
      registerSample(isSlow: true);
    });
  }

  final delayCompleter = Completer<void>();
  final hedgingTimer = Timer(actualHedgingDelay, () {
    if (!delayCompleter.isCompleted) delayCompleter.complete();
  });

  if (currentToken != null) {
    if (currentToken.isCancelled) {
      if (!delayCompleter.isCompleted) delayCompleter.complete();
    } else {
      unawaited(
        currentToken.onCancelled
            .then((_) {
              if (!delayCompleter.isCompleted) delayCompleter.complete();
            })
            .catchError((_, __) {}),
      );
    }
  }

  bool f1Done = false;
  bool f1Succeeded = false;
  f1
      .then((_) {
        f1Done = true;
        f1Succeeded = true;
        if (!delayCompleter.isCompleted) delayCompleter.complete();
      })
      .catchError((_) {
        f1Done = true;
        f1Succeeded = false;
        if (!delayCompleter.isCompleted) delayCompleter.complete();
      });

  try {
    await delayCompleter.future;
  } finally {
    hedgingTimer.cancel();
  }

  if (currentToken != null && currentToken.isCancelled) {
    earlyRegTimer?.cancel();
    if (!c1.isCompleted) c1.complete();
    throw const OperationCancelledException();
  }

  if (f1Done) {
    earlyRegTimer?.cancel();
    if (f1Succeeded) {
      final elapsed = stopwatch.elapsed;
      registerSample(isSlow: elapsed > rawV);
    }
    return await f1;
  }

  if (stopwatch.elapsed >= rawV) {
    registerSample(isSlow: true);
    earlyRegTimer?.cancel();
  }

  bool startedHedge = false;
  Future<T>? f2;
  Duration f2StartTime = Duration.zero;
  if (state.tryStartHedge()) {
    startedHedge = true;
    try {
      f2StartTime = stopwatch.elapsed;
      f2 = operation(c2);
    } catch (e) {
      state.hedgeCompleted();
      state.hedgingTokens = min(
        hedgingConfig.maxOverloadTokens,
        state.hedgingTokens + 1.0,
      );
      earlyRegTimer?.cancel();
      if (!c1.isCompleted) c1.complete();
      if (!c2.isCompleted) c2.complete();
      rethrow;
    }
  }

  if (!startedHedge) {
    // Blocked by token bucket or concurrency limit.
    // We still wait for the primary request to finish.
    try {
      return await f1;
    } finally {
      earlyRegTimer?.cancel();
    }
  }

  final resultCompleter = Completer<T>();
  if (currentToken != null) {
    unawaited(
      currentToken.onCancelled
          .then((_) {
            earlyRegTimer?.cancel();
            if (!c1.isCompleted) c1.complete();
            if (!c2.isCompleted) c2.complete();
            if (!resultCompleter.isCompleted) {
              resultCompleter.completeError(
                const OperationCancelledException(),
              );
            }
          })
          .catchError((_, __) {}),
    );
  }
  int failures = 0;
  Object? lastError;
  StackTrace? lastStackTrace;

  void handleResult(
    Future<T> source,
    Completer<void> otherCancel, {
    required bool isHedge,
    required Duration startTime,
  }) {
    source
        .then((value) {
          if (!resultCompleter.isCompleted) {
            earlyRegTimer?.cancel();
            final elapsed = stopwatch.elapsed;

            if (!isHedge) {
              registerSample(isSlow: elapsed > rawV);
            } else {
              // Hedged request won. If total elapsed time >= rawV, f1 definitely exceeded rawV.
              // If total elapsed time < rawV, f1 was right-censored; do not record false sample.
              if (elapsed >= rawV) {
                registerSample(isSlow: true);
              }
            }

            if (!otherCancel.isCompleted) {
              otherCancel.complete();
            }
            resultCompleter.complete(value);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          failures++;
          lastError = error;
          lastStackTrace = stackTrace;
          if (failures == 2 && !resultCompleter.isCompleted) {
            earlyRegTimer?.cancel();
            resultCompleter.completeError(lastError!, lastStackTrace);
          }
        })
        .whenComplete(() {
          if (isHedge) {
            state.hedgeCompleted();
          }
        });
  }

  handleResult(f1, c2, isHedge: false, startTime: Duration.zero);
  handleResult(f2!, c1, isHedge: true, startTime: f2StartTime);

  try {
    return await resultCompleter.future;
  } finally {
    earlyRegTimer?.cancel();
  }
}

/// Implements Request Hedging (Speculative Retries).
///
/// Improves tail latency by sending a second, identical request in parallel
/// if the primary request takes longer than a threshold.
final class RequestHedger {
  /// The resource configuration for hedging.
  final ResourceConfig config;

  /// The underlying resource state for hedging tokens and delay estimates.
  final ResourceState state;

  /// Creates a [RequestHedger] wrapping [config] and [state].
  RequestHedger(this.config, this.state);

  /// Creates a standalone [RequestHedger] instance without requiring a full [ResilienceContext].
  factory RequestHedger.standalone({
    HedgingConfig? config,
    Duration? delay,
    Duration? timeout,
    bool Function(Object)? failureClassifier,
  }) {
    final HedgingConfig hedgingConfig;
    if (config != null) {
      hedgingConfig = config.enabled
          ? config
          : HedgingConfig(
              delay: config.delay,
              enabled: true,
              dynamicPercentile: config.dynamicPercentile,
              delayMultiplier: config.delayMultiplier,
              minDelay: config.minDelay,
              maxDelay: config.maxDelay,
              adaptationRate: config.adaptationRate,
              overloadPercentile: config.overloadPercentile,
              maxOverloadTokens: config.maxOverloadTokens,
              maxConcurrentHedges: config.maxConcurrentHedges,
            );
    } else {
      hedgingConfig = HedgingConfig(
        enabled: true,
        delay: delay ?? const Duration(milliseconds: 500),
      );
    }
    final cfg = ResourceConfig(
      hedging: hedgingConfig,
      timeout: timeout,
      failureClassifier: failureClassifier,
    );
    return RequestHedger(cfg, ResourceState(cfg));
  }

  /// Executes [action] with request hedging.
  Future<T> execute<T>(Future<T> Function() action) {
    return executeCancelable((_) => action());
  }

  /// Executes [action] with request hedging and cancellation support.
  Future<T> executeCancelable<T>(
    Future<T> Function(Completer<void> cancelCompleter) action,
  ) async {
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

    Future<T> wrappedAction(Completer<void> cancel) {
      final combinedCancel = Completer<void>();
      void onCancel() {
        if (!combinedCancel.isCompleted) combinedCancel.complete();
      }

      unawaited(cancel.future.then((_) => onCancel()));
      unawaited(topLevelCancel.future.then((_) => onCancel()));
      return action(combinedCancel);
    }

    final executionCompleter = Completer<T>();
    runZonedGuarded(
      () async {
        try {
          final val = await executeWithHedging(
            wrappedAction,
            config: config,
            state: state,
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

  /// Wraps [action] returning a function protected by request hedging.
  Future<T> Function() wrap<T>(Future<T> Function() action) =>
      () => execute(action);

  /// Wraps a unary function [action] returning a function protected by request hedging.
  Future<T> Function(A) wrapUnary<T, A>(Future<T> Function(A) action) =>
      (A arg) => execute(() => action(arg));
}
