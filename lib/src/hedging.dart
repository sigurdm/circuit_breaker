import 'dart:async';
import 'dart:math';
import 'context.dart';

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
  final f1 = operation(c1);

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

  bool f1Done = false;
  f1
      .then((_) {
        f1Done = true;
        if (!delayCompleter.isCompleted) delayCompleter.complete();
      })
      .catchError((_) {
        f1Done = true;
        if (!delayCompleter.isCompleted) delayCompleter.complete();
      });

  await delayCompleter.future;
  hedgingTimer.cancel();

  if (f1Done) {
    earlyRegTimer?.cancel();
    final elapsed = stopwatch.elapsed;
    registerSample(isSlow: elapsed > rawV);
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
    try {
      f2 = operation(c2);
    } catch (e) {
      state.hedgeCompleted();
      state.hedgingTokens = min(
        hedgingConfig.maxOverloadTokens,
        state.hedgingTokens + 1.0,
      );
      rethrow;
    }
  }

  if (!startedHedge) {
    // Blocked by token bucket or concurrency limit.
    // We still wait for the primary request to finish.
    return await f1;
  }

  final resultCompleter = Completer<T>();
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
            final latency = elapsed - startTime;
            registerSample(isSlow: latency > rawV);

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
  handleResult(f2!, c1, isHedge: true, startTime: actualHedgingDelay);

  return resultCompleter.future;
}
