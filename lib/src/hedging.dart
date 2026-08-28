import 'dart:async';
import 'dart:math';
import 'context.dart';
import 'exceptions.dart';

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

  final currentToken = ResilienceContext.currentCancellationToken;
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
