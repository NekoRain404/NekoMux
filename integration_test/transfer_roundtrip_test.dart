import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/sftp_service.dart';
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
