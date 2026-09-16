import 'dart:async';

/// Whether the transport under a session is still there.
///
/// A separate object rather than two fields on the service because the value it
/// carries is the one thing a page cannot infer from failures: once a transport
/// is gone, *every* operation fails the same way, so a screen that watches
/// failures alone shows an endless run of them and never learns that the session
/// it is retrying on is over. This is the difference between "that listing
/// failed" and "this connection is finished".
///
/// Testable on its own: [track] takes the transport's own completion future, so
/// a test hands it a `Completer` instead of a socket.
class SftpLiveness {
  bool _closed = false;
  Completer<void>? _closedSignal;
  Future<void>? _transportDone;
  int _generation = 0;

  /// Whether the tracked transport has completed.
  bool get isClosed => _closed;

  /// Completes when the tracked transport goes away, or null before [track].
  ///
  /// Awaiting it after the fact is safe: a completed signal stays completed, so
  /// a page that subscribes late still learns immediately.
  Future<void>? get closed => _closedSignal?.future;

  /// Starts watching [done], replacing whatever was watched before.
  ///
  /// The generation guard is what makes a reconnect safe: the old transport's
  /// completion arrives after the new session has been established — a socket
  /// does not always die before its replacement is up — and without the guard
  /// that late arrival would mark the *new* session dead, which is precisely the
  /// state that makes a page offer to reconnect to a connection that is fine.
  void track(Future<void> done) {
    _generation++;
    final generation = _generation;
    _closed = false;
    _closedSignal = Completer<void>();
    _transportDone = done;

    void markClosed() {
      if (generation != _generation) return;
      _closed = true;
      final signal = _closedSignal;
      if (signal != null && !signal.isCompleted) signal.complete();
    }

    // `whenComplete`, not `then`: a transport that ends by throwing is just as
    // gone as one that ends cleanly.
    unawaited(done.whenComplete(markClosed).catchError((_) {}));
  }

  /// Forgets the tracked transport, so [isClosed] is false again until the next
  /// [track].
  void reset() {
    _generation++;
    _closed = false;
    _closedSignal = null;
    _transportDone = null;
  }

  /// The future handed to [track], for callers that need to await it directly.
  Future<void>? get transportDone => _transportDone;
}
