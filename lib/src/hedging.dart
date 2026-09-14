import 'dart:async';
import 'package:clock/clock.dart';
import 'dart:math';
import 'context.dart';
import 'exceptions.dart';
import 'cancellation.dart';
import 'events.dart';

/// Calculates the effective hedge delay for [config] and [state].
///
/// If dynamic hedging is disabled ([HedgingConfig.dynamicPercentile] is null),
/// returns [HedgingConfig.delay].
///
/// When dynamic hedging is enabled, multiplies the tracked dynamic delay estimate
/// by [HedgingConfig.delayMultiplier], and clamps the final result strictly
/// within `[config.minDelay, config.maxDelay]`.
Duration calculateHedgeDelay(HedgingConfig config, ResourceState state) {
  if (config.dynamicPercentile == null) {
    return config.delay;
  }
  final baseEstimate = state.dynamicDelayEstimate;
  final calculatedUs = (baseEstimate.inMicroseconds * config.delayMultiplier)
      .round();
  final minUs = config.minDelay.inMicroseconds;
  final maxUs = config.maxDelay.inMicroseconds;
  return Duration(microseconds: calculatedUs.clamp(minUs, maxUs));
}

/// Executes an operation with request hedging.
/// The operation function receives a `Completer` that will be completed if the operation should be cancelled.
Future<T> executeWithHedging<T>(
  Future<T> Function(Completer<void> cancelCompleter) operation, {
  required ResourceConfig config,
  required ResourceState state,
  Resource? resource,
  ResilienceContext? context,
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
  final actualHedgingDelay = calculateHedgeDelay(hedgingConfig, state);

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
    unawaited(
      currentToken.onCancelled
          .then((_) {
            if (!delayCompleter.isCompleted) delayCompleter.complete();
          })
          .catchError((_, __) {}),
    );
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
  if (state.tryStartHedge()) {
    startedHedge = true;
    final res = resource;
    if (res != null) {
      final elapsed = stopwatch.elapsed;
      final event = HedgeFiredEvent(
        resource: res,
        timestamp: clock.now(),
        delay: elapsed,
        activeHedges: state.activeHedges,
      );
      if (context != null) {
        context.emitEvent(event);
      } else {
        res.emitEvent(event);
      }
    }
    try {
      f2 = operation(c2);
    } catch (e) {
      state.hedgeCompleted();
      state.refundHedgingToken();
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

  bool hedgeSlotCompleted = false;
  Timer? hedgeReclaimTimer;

  void completeHedgeSlot() {
    if (!hedgeSlotCompleted) {
      hedgeSlotCompleted = true;
      hedgeReclaimTimer?.cancel();
      state.hedgeCompleted();
    }
  }

  void startHedgeReclaimTimerIfNeeded() {
    if (startedHedge && !hedgeSlotCompleted && hedgeReclaimTimer == null) {
      final Duration graceDuration;
      if (hedgingConfig.gracePeriod != null) {
        graceDuration = hedgingConfig.gracePeriod!;
      } else {
        final deadline = ResilienceContext.currentDeadline;
        final timeoutRemaining = config.timeout != null
            ? config.timeout! - stopwatch.elapsed
            : null;
        final deadlineRemaining = deadline?.difference(clock.now());

        Duration? effectiveRemaining;
        if (timeoutRemaining != null && deadlineRemaining != null) {
          effectiveRemaining = timeoutRemaining < deadlineRemaining
              ? timeoutRemaining
              : deadlineRemaining;
        } else {
          effectiveRemaining = timeoutRemaining ?? deadlineRemaining;
        }

        if (effectiveRemaining != null) {
          final nonNegative = effectiveRemaining > Duration.zero
              ? effectiveRemaining
              : Duration.zero;
          graceDuration = nonNegative < const Duration(seconds: 5)
              ? nonNegative
              : const Duration(seconds: 5);
        } else {
          graceDuration = const Duration(seconds: 5);
        }
      }

      if (graceDuration == Duration.zero) {
        completeHedgeSlot();
      } else {
        hedgeReclaimTimer = Timer(graceDuration, () {
          completeHedgeSlot();
        });
      }
    }
  }

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
            startHedgeReclaimTimerIfNeeded();
          })
          .catchError((_, __) {}),
    );
  }
  int failures = 0;
  Object? primaryError;
  StackTrace? primaryStackTrace;
  Object? hedgeError;
  StackTrace? hedgeStackTrace;

  void handleResult(
    Future<T> source,
    Completer<void> otherCancel, {
    required bool isHedge,
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
            if (!isHedge) {
              startHedgeReclaimTimerIfNeeded();
            }
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          failures++;
          if (isHedge) {
            hedgeError = error;
            hedgeStackTrace = stackTrace;
          } else {
            primaryError = error;
            primaryStackTrace = stackTrace;
          }
          if (failures == 2 && !resultCompleter.isCompleted) {
            earlyRegTimer?.cancel();
            final errorToSurface = primaryError ?? hedgeError!;
            final stackToSurface = primaryStackTrace ?? hedgeStackTrace;
            resultCompleter.completeError(errorToSurface, stackToSurface);
          }
        })
        .whenComplete(() {
          if (isHedge) {
            completeHedgeSlot();
          }
        });
  }

  handleResult(f1, c2, isHedge: false);
  handleResult(f2!, c1, isHedge: true);

  try {
    return await resultCompleter.future;
  } finally {
    earlyRegTimer?.cancel();
    startHedgeReclaimTimerIfNeeded();
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

  /// The resource associated with this hedger, if any.
  final Resource? resource;

  /// Creates a [RequestHedger] wrapping [config] and [state].
  RequestHedger(this.config, this.state, {this.resource});

  /// Creates a standalone [RequestHedger] instance without requiring a full [ResilienceContext].
  factory RequestHedger.standalone({
    HedgingConfig? config,
    Duration? delay,
    Duration? timeout,
    bool Function(Object)? failureClassifier,
    Duration? gracePeriod,
    ResourceState? state,
  }) {
    final HedgingConfig hedgingConfig;
    if (config != null) {
      final effectiveDelay = delay ?? config.delay;
      hedgingConfig = (delay != null || gracePeriod != null)
          ? HedgingConfig(
              delay: effectiveDelay,
              enabled: config.enabled,
              dynamicPercentile: config.dynamicPercentile,
              delayMultiplier: config.delayMultiplier,
              minDelay: config.minDelay,
              maxDelay: config.maxDelay,
              adaptationRate: config.adaptationRate,
              overloadPercentile: config.overloadPercentile,
              maxOverloadTokens: config.maxOverloadTokens,
              maxConcurrentHedges: config.maxConcurrentHedges,
              gracePeriod: gracePeriod ?? config.gracePeriod,
            )
          : config;
    } else {
      hedgingConfig = HedgingConfig(
        enabled: true,
        delay: delay ?? const Duration(milliseconds: 500),
        gracePeriod: gracePeriod,
      );
    }
    final cfg = ResourceConfig(
      hedging: hedgingConfig,
      timeout: timeout,
      failureClassifier: failureClassifier,
    );
    final res = Resource('standalone_hedger', config: cfg);
    return RequestHedger(cfg, state ?? ResourceState(cfg), resource: res);
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
        ? clock.now().add(config.timeout!)
        : null;
    final effectiveDeadline = parentDeadline == null
        ? localDeadline
        : (localDeadline == null
              ? parentDeadline
              : (parentDeadline.isBefore(localDeadline)
                    ? parentDeadline
                    : localDeadline));

    if (effectiveDeadline != null && clock.now().isAfter(effectiveDeadline)) {
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
      final remaining = effectiveDeadline.difference(clock.now());
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

    Future<T> wrappedAction(Completer<void> cancel) async {
      final combinedCancel = Completer<void>();
      void onCancel() {
        if (!combinedCancel.isCompleted) combinedCancel.complete();
      }

      unawaited(cancel.future.then((_) => onCancel()).catchError((_, __) {}));
      unawaited(
        topLevelCancel.future.then((_) => onCancel()).catchError((_, __) {}),
      );

      final attemptToken = CancellationToken();
      attemptToken.attach(executionToken);
      unawaited(
        cancel.future.then((_) => attemptToken.cancel()).catchError((_, __) {}),
      );

      try {
        return await runZoned(
          () async {
            if (attemptToken.isCancelled) {
              throw const OperationCancelledException();
            }
            if (effectiveDeadline != null &&
                clock.now().isAfter(effectiveDeadline)) {
              throw ResilienceTimeoutException(
                'Deadline exceeded during execution',
              );
            }
            return await action(combinedCancel);
          },
          zoneValues: {
            ResilienceContext.cancellationTokenZoneKey: attemptToken,
            ResilienceContext.deadlineZoneKey: effectiveDeadline,
          },
        );
      } finally {
        attemptToken.detach();
      }
    }

    final executionCompleter = Completer<T>();
    runZonedGuarded(
      () async {
        try {
          final val = await executeWithHedging(
            wrappedAction,
            config: config,
            state: state,
            resource: resource,
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
        // Isolate uncaught asynchronous errors in background tasks from escaping to root zone,
        // preventing unrelated background errors from hijacking the primary execution.
      },
      zoneValues: {
        ResilienceContext.cancellationTokenZoneKey: executionToken,
        ResilienceContext.deadlineZoneKey: effectiveDeadline,
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

/// Executes [action] with request hedging.
///
/// This convenience function provides an ad-hoc, one-liner way to execute an operation
/// with speculative hedging without manually instantiating a [RequestHedger].
///
/// Shares resilience state (including token bucket overload protection, concurrency
/// counters, and dynamic latency estimates) across calls via [context] (defaulting to
/// [ResilienceContext.defaultContext]) keyed by [resourceName] (defaulting to
/// `'__adhoc_hedge__'`).
///
/// Throws [ResilienceTimeoutException] if the operation exceeds the deadline or configured [timeout].
/// Throws [OperationCancelledException] if cancelled via the ambient cancellation token.
/// Rethrows any failure thrown by [action] if hedging does not succeed.
Future<T> hedge<T>(
  Future<T> Function() action, {
  Duration delay = const Duration(milliseconds: 500),
  Duration? timeout,
  bool Function(Object)? failureClassifier,
  HedgingConfig? config,
  Duration? gracePeriod,
  ResilienceContext? context,
  String? resourceName,
}) {
  final targetName = resourceName ?? '__adhoc_hedge__';
  final ctx = context ?? ResilienceContext.defaultContext;
  final existingState = ctx.states[targetName];

  final HedgingConfig hedgingConfig;
  if (config != null) {
    final effectiveDelay =
        delay != const Duration(milliseconds: 500) ? delay : config.delay;
    hedgingConfig = (delay != const Duration(milliseconds: 500) ||
            gracePeriod != null)
        ? HedgingConfig(
            delay: effectiveDelay,
            enabled: config.enabled,
            dynamicPercentile: config.dynamicPercentile,
            delayMultiplier: config.delayMultiplier,
            minDelay: config.minDelay,
            maxDelay: config.maxDelay,
            adaptationRate: config.adaptationRate,
            overloadPercentile: config.overloadPercentile,
            maxOverloadTokens: config.maxOverloadTokens,
            maxConcurrentHedges: config.maxConcurrentHedges,
            gracePeriod: gracePeriod ?? config.gracePeriod,
          )
        : config;
  } else if (existingState != null) {
    hedgingConfig = delay != const Duration(milliseconds: 500)
        ? HedgingConfig(
            delay: delay,
            enabled: true,
            dynamicPercentile: existingState.config.hedging.dynamicPercentile,
            delayMultiplier: existingState.config.hedging.delayMultiplier,
            minDelay: existingState.config.hedging.minDelay,
            maxDelay: existingState.config.hedging.maxDelay,
            adaptationRate: existingState.config.hedging.adaptationRate,
            overloadPercentile: existingState.config.hedging.overloadPercentile,
            maxOverloadTokens: existingState.config.hedging.maxOverloadTokens,
            maxConcurrentHedges:
                existingState.config.hedging.maxConcurrentHedges,
            gracePeriod:
                gracePeriod ?? existingState.config.hedging.gracePeriod,
          )
        : (gracePeriod != null
              ? HedgingConfig(
                  delay: existingState.config.hedging.delay,
                  enabled: existingState.config.hedging.enabled,
                  dynamicPercentile:
                      existingState.config.hedging.dynamicPercentile,
                  delayMultiplier: existingState.config.hedging.delayMultiplier,
                  minDelay: existingState.config.hedging.minDelay,
                  maxDelay: existingState.config.hedging.maxDelay,
                  adaptationRate: existingState.config.hedging.adaptationRate,
                  overloadPercentile:
                      existingState.config.hedging.overloadPercentile,
                  maxOverloadTokens:
                      existingState.config.hedging.maxOverloadTokens,
                  maxConcurrentHedges:
                      existingState.config.hedging.maxConcurrentHedges,
                  gracePeriod: gracePeriod,
                )
              : existingState.config.hedging);
  } else {
    hedgingConfig = HedgingConfig(
      enabled: true,
      delay: delay,
      gracePeriod: gracePeriod,
    );
  }

  final ResourceConfig cfg;
  if (existingState != null) {
    cfg = ResourceConfig(
      circuitBreaker: existingState.config.circuitBreaker,
      throttling: existingState.config.throttling,
      hedging: hedgingConfig,
      retry: existingState.config.retry,
      timeout: timeout ?? existingState.config.timeout,
      failureClassifier:
          failureClassifier ?? existingState.config.failureClassifier,
    );
  } else {
    cfg = ResourceConfig(
      hedging: hedgingConfig,
      timeout: timeout,
      failureClassifier: failureClassifier,
    );
  }

  final ResourceState state;
  if (existingState != null) {
    if (config != null) {
      ctx.getOrCreateState(targetName, cfg);
    }
    state = existingState;
    state.touch();
  } else {
    state = ctx.getOrCreateState(targetName, cfg);
  }
  final h = RequestHedger(cfg, state);
  return h.execute(action);
}
