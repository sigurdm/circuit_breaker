import 'dart:async';
import 'context.dart';

/// Executes an operation with request hedging.
/// The operation function receives a `Completer` that will be completed if the operation should be cancelled.
Future<T> executeWithHedging<T>(
  Future<T> Function(Completer<void> cancelCompleter) operation, {
  required ResourceConfig config,
  required ResourceState state,
}) async {
  final hedgingConfig = config.hedging;

  if (!hedgingConfig.enabled) {
    return await operation(Completer<void>());
  }

  final c1 = Completer<void>();
  final c2 = Completer<void>();

  final f1 = operation(c1);

  final delayCompleter = Completer<void>();
  final timer = Timer(hedgingConfig.delay, () {
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

  // Wait until f1 completes or the hedging delay expires
  await delayCompleter.future;
  timer.cancel();

  if (f1Done) {
    return await f1; // Return f1 result directly
  }

  // Timer expired and f1 is not done. Start the hedged request.
  final f2 = operation(c2);

  final resultCompleter = Completer<T>();
  int failures = 0;
  Object? lastError;

  void handleResult(Future<T> source, Completer<void> otherCancel) {
    source
        .then((value) {
          if (!resultCompleter.isCompleted) {
            if (!otherCancel.isCompleted)
              otherCancel.complete(); // Signal cancellation
            resultCompleter.complete(value);
          }
        })
        .catchError((error) {
          failures++;
          lastError = error;
          if (failures == 2 && !resultCompleter.isCompleted) {
            resultCompleter.completeError(lastError!);
          }
        });
  }

  handleResult(f1, c2);
  handleResult(f2, c1);

  return resultCompleter.future;
}
