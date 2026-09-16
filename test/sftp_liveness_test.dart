import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/sftp_liveness.dart';

/// Guards the signal that tells a page its session is over.
///
/// Everything downstream of this is a judgement call the page makes on its own:
/// one failed listing is a snackbar, a dead transport is the full-page reconnect
/// view. Getting it wrong in one direction leaves the user tapping retry on a
/// connection that ended minutes ago; getting it wrong in the other tears down a
/// working session.
void main() {
  test('a tracked transport starts alive and closes when it ends', () async {
    final liveness = SftpLiveness();
    final done = Completer<void>();

    liveness.track(done.future);
    expect(liveness.isClosed, isFalse);
    expect(liveness.closed, isNotNull);

    done.complete();
    await pumpEventQueue();
    expect(liveness.isClosed, isTrue);
  });

  test('a transport that ends by throwing is just as closed', () async {
    // A dropped socket does not complete cleanly; treating only the clean case
    // as "closed" would leave a dead session looking alive forever.
    final liveness = SftpLiveness();
    final done = Completer<void>();

    liveness.track(done.future);
    done.completeError(StateError('connection reset'));
    await pumpEventQueue();

    expect(liveness.isClosed, isTrue);
  });

  test('the signal completes once, and stays completed', () async {
    // A page may subscribe after the fact — it connects, then subscribes — and
    // an already-completed signal is how it learns immediately instead of
    // waiting for an event that has been and gone.
    final liveness = SftpLiveness();
    final done = Completer<void>();
    liveness.track(done.future);

    done.complete();
    await pumpEventQueue();

    await expectLater(liveness.closed, completes);
    var completed = false;
    unawaited(liveness.closed!.then((_) => completed = true));
    await pumpEventQueue();
    expect(completed, isTrue);
  });

  test('reset makes it alive again, for a reconnect', () {
    final liveness = SftpLiveness();
    final first = Completer<void>();
    liveness.track(first.future);

    liveness.reset();

    expect(liveness.isClosed, isFalse);
    expect(
      liveness.closed,
      isNull,
      reason: 'nothing is being watched until the next connect',
    );
  });

  test('a late arrival from the old transport cannot kill the new one', () async {
    // The case the generation guard exists for: a socket does not always die
    // before its replacement is up, so the old transport's completion can land
    // *after* the new session was established. Without the guard it would mark
    // the new, working session dead — and the page would offer to reconnect to a
    // connection that is fine.
    final liveness = SftpLiveness();
    final oldTransport = Completer<void>();
    final newTransport = Completer<void>();

    liveness.track(oldTransport.future);
    liveness.track(newTransport.future);
    expect(liveness.isClosed, isFalse);

    oldTransport.complete();
    await pumpEventQueue();

    expect(
      liveness.isClosed,
      isFalse,
      reason: 'the old transport is not the one being watched',
    );

    newTransport.complete();
    await pumpEventQueue();
    expect(liveness.isClosed, isTrue);
  });
}
