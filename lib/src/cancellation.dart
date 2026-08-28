import 'dart:async';

/// A token that can be used to signal cancellation down a call chain.
///
/// Can be attached to a parent token to propagate cancellation.
final class CancellationToken {
  final Completer<void> _completer = Completer<void>();
  bool _isCancelled = false;
  CancellationToken? _parent;
  final Set<CancellationToken> _children = {};

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

    // Cancel all children. We copy the set to avoid concurrent modification
    // because child.cancel() will call child.detach() which modifies _children.
    final childrenToCancel = List.of(_children);
    for (final child in childrenToCancel) {
      child.cancel();
    }
    _children.clear();

    detach();
  }

  /// Attaches this token to a [parent] token.
  ///
  /// When [parent] is cancelled, this token will automatically be cancelled.
  void attach(CancellationToken parent) {
    if (identical(this, parent)) {
      throw ArgumentError('Cannot attach a CancellationToken to itself');
    }
    if (_isCancelled) return;
    if (parent.isCancelled) {
      cancel();
      return;
    }
    detach();
    _parent = parent;
    parent._children.add(this);
  }

  /// Detaches this token from its parent token.
  void detach() {
    _parent?._children.remove(this);
    _parent = null;
  }
}
