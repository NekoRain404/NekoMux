import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/port_forward_service.dart';
import 'package:neko_mux/models/transfer_task.dart';
import 'package:neko_mux/services/sftp_service.dart';
import 'package:neko_mux/services/transfer_runner.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// End-to-end transfer verification, run ON THE PHONE against a real SSH
/// server.
///
/// Every other test in `test/` fakes the session, which is what makes them fast
/// and deterministic — and also what makes them unable to answer the one
/// question that matters before shipping a transfer change: does a file survive
/// the trip through the device's network stack, the real `dartssh2` client and
/// a real `sftp-server`, byte for byte? This suite answers exactly that, and
/// nothing else. It is deliberately thin: no UI, no database, no credentials
/// store.
///
/// Requirements (see integration_test/README.md):
///   * `nekomux-test-ssh` running, publishing 127.0.0.1:2222;
///   * `adb reverse tcp:2222 tcp:2222` so the phone reaches it on localhost.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Where the docker fixture and the round-trip file live. The container's
  /// user home is `/config`; both paths are writable by `nekotest`.
  const remoteDir = '/config';
  const roundTripPath = '$remoteDir/nekotest-roundtrip.bin';
  const fixturePath = '$remoteDir/fixtures/rand200k.bin';
  const fixtureSize = 200000;

  final host = Host(
    id: 'integration',
    alias: 'docker-test-ssh',
    ipAddress: '127.0.0.1',
    port: 2222,
    credentialId: 'integration',
  );
  const credential = Credential(
    id: 'integration',
    name: 'nekotest',
    authType: 0,
    username: 'nekotest',
    secretData: 'nekotest',
  );

  /// Accepts the test server's key unconditionally. The trust decision has its
  /// own unit tests against a real database; here a prompt would only add a
  /// dependency on a UI that this suite deliberately does not have.
  Future<bool> acceptAnyKey(String _) async => true;

  late SftpService sftp;

  setUp(() async {
    sftp = SftpService(
      host: host,
      credential: credential,
      onHostKeyVerify: acceptAnyKey,
    );
    await sftp.connect();
  });

  tearDown(() async {
    await sftp.disconnect();
  });

  testWidgets('the connection actually reaches the test server', (
    tester,
  ) async {
    // The cheapest possible proof that the tunnel is up, so a broken
    // `adb reverse` fails here with a clear message instead of surfacing later
    // as an unexplained transfer error.
    final ssh = SshConnection(
      host: host,
      credential: credential,
      onHostKeyVerify: acceptAnyKey,
    );
    addTearDown(ssh.dispose);
    await ssh.connect();
    final result = await ssh.runCommand('echo nekomux-integration-ok');
    expect(result.stdout, contains('nekomux-integration-ok'));
  });

  testWidgets('a file the app never wrote downloads intact', (tester) async {
    // Downloaded twice on purpose. Without an md5 dependency the strongest
    // local check available is that the bytes the server holds arrive the same
    // way every time and are the size the server reports — and a truncating
    // read, the failure this path can realistically suffer, fails both.
    expect(await sftp.fileSize(fixturePath), fixtureSize);

    final first = await _collect(sftp.downloadStream(fixturePath));
    expect(first, hasLength(fixtureSize));

    final second = await _collect(sftp.downloadStream(fixturePath));
    expect(second, equals(first));
  });

  testWidgets('upload then download returns byte-identical content', (
    tester,
  ) async {
    // Upload and download are one assertion here because either half alone is
    // satisfied by a plausible-looking bug: an upload that writes zeros passes
    // a size check, and so does a download of the wrong file. Comparing the
    // bytes that come back against the bytes that went out is the only check
    // that covers the pair.
    final payload = _deterministicPayload(200 * 1024);
    expect(payload, hasLength(200 * 1024));

    await sftp.uploadStream(roundTripPath, Stream.value(payload));

    expect(
      await sftp.fileSize(roundTripPath),
      payload.length,
      reason: 'the server must hold exactly what was sent',
    );

    final returned = await _collect(sftp.downloadStream(roundTripPath));
    expect(
      returned,
      equals(payload),
      reason: 'a byte-level difference means the transfer corrupted the file',
    );
  });

  testWidgets('a local forward carries bytes to the server and back', (
    tester,
  ) async {
    // A tunnel is only real if traffic goes through it, so this does not stop at
    // "the socket bound": it asks the server for the one thing the server always
    // answers with — its SSH banner — and reads it from a plain local socket on
    // the phone. The bytes therefore went phone → app → SSH channel → sshd, and
    // back.
    final ssh = SshConnection(
      host: host,
      credential: credential,
      onHostKeyVerify: acceptAnyKey,
    );
    addTearDown(ssh.dispose);
    await ssh.connect();

    final tunnels = PortForwardService(ssh);
    addTearDown(tunnels.close);

    // The server's own port, as the server sees it.
    final forward = await tunnels.start(remoteHost: '127.0.0.1', remotePort: 2222);
    expect(forward.localPort, greaterThan(0));

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      forward.localPort,
    );
    addTearDown(socket.destroy);

    final banner = StringBuffer();
    final done = Completer<void>();
    final sub = socket.listen(
      (chunk) {
        banner.write(String.fromCharCodes(chunk));
        if (banner.toString().contains('SSH-2.0') && !done.isCompleted) {
          done.complete();
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('no banner came back through the tunnel'),
    );
    await sub.cancel();

    expect(
      banner.toString(),
      contains('SSH-2.0'),
      reason: 'the server answered through the forward',
    );
  });

  testWidgets('an interrupted download resumes and lands byte-identical', (
    tester,
  ) async {
    // What a resume is worth is decided by its worst case: a file of exactly the
    // right length holding bytes from two different versions of it. So this
    // stops a real download part-way through a 3 MB file, resumes it through the
    // runner, and compares the result with a download that was never
    // interrupted — byte for byte, not by size.
    const fixture = '$remoteDir/fixtures/big3m.bin';

    final reference = await _collect(sftp.downloadStream(fixture));
    expect(reference, hasLength(3000000));

    final local = File('${Directory.systemTemp.path}/nekomux-resume.bin');
    addTearDown(() {
      if (local.existsSync()) local.deleteSync();
    });
    if (local.existsSync()) local.deleteSync();

    // Interrupt on purpose: take the first few chunks, then hang up the way a
    // dropped link does.
    final sink = local.openWrite();
    var taken = 0;
    final partial = sftp.downloadStream(fixture);
    final stopped = Completer<void>();
    final subscription = partial.listen(
      (chunk) {
        sink.add(chunk);
        taken += chunk.length;
        if (taken >= 400000 && !stopped.isCompleted) stopped.complete();
      },
      onError: (Object e) => stopped.completeError(e),
      onDone: () {
        if (!stopped.isCompleted) stopped.complete();
      },
    );
    await stopped.future;
    await subscription.cancel();
    await sink.close();

    final partialLength = await local.length();
    expect(
      partialLength,
      greaterThan(0),
      reason: 'the interruption must leave something to resume from',
    );
    expect(
      partialLength,
      lessThan(reference.length),
      reason: 'and it must not be the whole file',
    );

    // Now the resume, through the same runner the queue uses.
    final runner = TransferRunner(SftpTransferSession(sftp));
    final task = TransferTask(
      id: 'resume',
      hostId: 'integration',
      name: 'big3m.bin',
      remotePath: fixture,
      localPath: local.path,
      direction: TransferDirection.download,
      totalBytes: reference.length,
    );
    final reported = <int>[];
    final outcome = await runner.download(
      task,
      TransferCancelSignal(),
      reported.add,
      resume: true,
    );

    expect(outcome, TransferOutcome.completed);
    expect(
      reported.first,
      greaterThanOrEqualTo(partialLength),
      reason: 'the resumed run must report progress for the whole file, not '
          'from zero',
    );
    expect(
      await local.readAsBytes(),
      reference,
      reason: 'a byte-level difference means the resume spliced two versions',
    );
  });

  testWidgets('an empty file survives both directions', (tester) async {
    // Zero bytes is the boundary a chunked reader is most likely to get wrong —
    // it is the input that produces no progress callbacks at all, so a
    // completion path that waits for "some bytes" never finishes.
    final empty = Uint8List(0);
    await sftp.uploadStream(roundTripPath, Stream.value(empty));
    expect(await sftp.fileSize(roundTripPath), 0);

    final returned = await _collect(sftp.downloadStream(roundTripPath));
    expect(returned, isEmpty);
  });
}

/// Drains [stream] into one buffer, in arrival order.
Future<Uint8List> _collect(Stream<Uint8List> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// [length] bytes from a fixed seed, so the payload is reproducible and any
/// difference the transfer introduces is a real one rather than a difference
/// between two runs of the test.
Uint8List _deterministicPayload(int length) {
  final bytes = Uint8List(length);
  var state = 0x12345678;
  for (var i = 0; i < length; i++) {
    // Numerical Recipes LCG, masked to 31 bits to stay in int range.
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = (state >> 16) & 0xff;
  }
  return bytes;
}
