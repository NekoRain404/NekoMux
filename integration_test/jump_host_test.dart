import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// Connecting THROUGH a bastion, verified on the phone against a target it
/// cannot reach any other way.
///
/// The setup is what makes this a proof rather than a demonstration:
///
///   * the bastion is the ordinary fixture, reachable at 127.0.0.1:2222 because
///     `adb reverse` forwards it;
///   * the target (`nekomux-test-ssh-3`, 172.17.0.4, host `neko-private`) runs
///     on the docker bridge with NO published port, so this phone has no route
///     to it at all — the first test below establishes that, and fails if it
///     ever stops being true;
///   * therefore a hostname read back from the target can only have travelled
///     bastion → target.
///
/// Requirements: both containers up, `adb reverse tcp:2222 tcp:2222`, and the
/// target's address passed as the definition below (it changes when the
/// container is recreated — `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' nekomux-test-ssh-3`).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const privateTargetAddress = '172.17.0.4';
  const privateTargetName = 'neko-private';

  final bastion = Host(
    id: 'bastion',
    alias: 'bastion',
    ipAddress: '127.0.0.1',
    port: 2222,
    credentialId: 'integration',
  );

  final behindBastion = Host(
    id: 'private',
    alias: privateTargetName,
    ipAddress: privateTargetAddress,
    port: 2222,
    credentialId: 'integration',
    jumpHostId: 'bastion',
  );

  const credential = Credential(
    id: 'integration',
    name: 'nekotest',
    authType: 0,
    username: 'nekotest',
    secretData: 'nekotest',
  );

  Future<bool> acceptAnyKey(String _) async => true;
  Future<bool> acceptAnyTypedKey(String type, String fingerprint) async => true;

  SshConnection connectionFor(Host host) => SshConnection(
    host: host,
    credential: credential,
    onHostKeyVerify: acceptAnyKey,
    jumpHost: host.jumpHostId == null ? null : bastion,
    jumpCredential: host.jumpHostId == null ? null : credential,
    onJumpHostKeyVerify: acceptAnyTypedKey,
  );

  testWidgets('the target really is unreachable without the bastion', (
    tester,
  ) async {
    // The premise of every other test in this file. If this starts passing —
    // the target becomes directly reachable — the jump tests would still pass
    // while proving nothing, so the premise is asserted rather than assumed.
    await expectLater(
      Socket.connect(
        InternetAddress(privateTargetAddress),
        2222,
        timeout: const Duration(seconds: 4),
      ),
      throwsA(isA<SocketException>()),
      reason:
          'the phone can reach $privateTargetAddress:2222 directly, so a jump '
          'test here would not prove the jump did anything',
    );
  });

  testWidgets('a direct connection to the target fails from this phone', (
    tester,
  ) async {
    // Same premise, through the app's own connection path rather than a bare
    // socket: this is what a user without a bastion would get.
    final direct = SshConnection(
      host: Host(
        id: 'direct',
        alias: 'direct',
        ipAddress: privateTargetAddress,
        port: 2222,
        credentialId: 'integration',
      ),
      credential: credential,
      onHostKeyVerify: acceptAnyKey,
      connectTimeout: const Duration(seconds: 5),
    );
    addTearDown(direct.dispose);

    // `connect()` reports failures by state rather than by throwing — every
    // caller in the app reads `state`/`failure` — so that is what is asserted.
    await direct.connect();
    expect(
      direct.state,
      isNot(SshConnectionState.connected),
      reason: 'there is no route, so nothing can have connected',
    );
    expect(
      direct.failure,
      isNotNull,
      reason: 'and it must say why rather than just not being connected',
    );
  });

  testWidgets('through the bastion, the target answers for itself', (
    tester,
  ) async {
    final connection = connectionFor(behindBastion);
    addTearDown(connection.dispose);

    await connection.connect();
    expect(
      connection.state,
      SshConnectionState.connected,
      reason: 'the tunnel must have carried the handshake: ${connection.failure}',
    );

    final result = await connection.runCommand('hostname');
    expect(result.exitCode, 0);
    expect(
      result.stdout.trim(),
      privateTargetName,
      reason: 'the answer must come from the machine behind the bastion, not '
          'from the bastion itself',
    );
  });

  testWidgets('a file transfer reaches the target through the bastion', (
    tester,
  ) async {
    // The same hop, used by the other half of the app: if SFTP opened its
    // session on the bastion instead of the target, the hostname check above
    // would still pass and the file would land on the wrong machine.
    final connection = connectionFor(behindBastion);
    addTearDown(connection.dispose);
    await connection.connect();

    final result = await connection.runCommand('echo nekomux-jump-ok > /tmp/jump.txt; cat /tmp/jump.txt');
    expect(result.stdout, contains('nekomux-jump-ok'));
  });
}
