import 'dart:async';

/// A token that can be used to signal cancellation down a call chain.
///
/// Can be attached to a parent token to propagate cancellation.
final class CancellationToken {
  final Completer<void> _completer = Completer<void>();
  bool _isCancelled = false;

  /// Creates a new [CancellationToken].
  CancellationToken();

  /// Whether this token has been cancelled.
  bool get isCancelled => _isCancelled;

  /// A future that completes when this token is cancelled.
  Future<void> get onCancelled => _completer.future;

  /// Cancels this token.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _completer.complete();
  }

  /// Attaches this token to a [parent] token.
  ///
  /// When [parent] is cancelled, this token will automatically be cancelled.
  void attach(CancellationToken parent) {
    if (parent.isCancelled) {
      cancel();
    } else {
      // Use unawaited to avoid lint warnings if we don't wait for it
      unawaited(parent.onCancelled.then((_) => cancel()));
    }
  }
}
