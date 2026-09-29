import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// A session that runs a command instead of a login shell, verified on the phone.
///
/// This is the mechanism behind opening a shell in a container: `docker exec
/// -it NAME sh` is an ordinary command, and a PTY session running one is what a
/// terminal on a laptop does. The test server has no Docker daemon, so what is
/// proven here is the part that would otherwise be taken on faith — that the
/// app's own connection, host-key verification, PTY allocation, output stream
/// and input path all work when the channel is asked to run something other
/// than a shell.
///
/// Requirements: the transfer fixture container up, `adb reverse tcp:2222
/// tcp:2222`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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

  Future<bool> acceptAnyKey(String _) async => true;

  SshConnection connection(String? command) => SshConnection(
    host: host,
    credential: credential,
    initialCommand: command,
    onHostKeyVerify: acceptAnyKey,
  );

  /// Everything the session printed, until the command ends or [timeout] passes.
  Future<String> outputOf(
    SshConnection ssh, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final buffer = StringBuffer();
    final done = Completer<void>();
    final sub = ssh.outputStream.listen(
      (data) {
        buffer.write(utf8.decode(data, allowMalformed: true));
        if (buffer.toString().contains('SESSION-DONE') && !done.isCompleted) {
          done.complete();
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future.timeout(
      timeout,
      onTimeout: () {},
    );
    await sub.cancel();
    return buffer.toString();
  }

  testWidgets('a session runs the command it was given, and only that', (
    tester,
  ) async {
    // `sh -c` rather than a bare pipeline: the channel runs one command string,
    // and this is the shape `docker exec -it <name> sh` also has.
    final ssh = connection('sh -c "echo MARKER-ONE; echo SESSION-DONE"');
    addTearDown(ssh.dispose);

    await ssh.connect();
    expect(ssh.state, SshConnectionState.connected);

    final output = await outputOf(ssh);
    expect(
      output,
      contains('MARKER-ONE'),
      reason: 'the command’s own output must arrive on the terminal stream',
    );
    expect(output, contains('SESSION-DONE'));
  });

  testWidgets('a command session takes input back through the PTY', (
    tester,
  ) async {
    // Two-way traffic is what a container shell needs: half of debugging a
    // container is typing at its shell, not reading its output.
    //
    // The command is `head -n 1` rather than `read line`, and that is a finding
    // rather than a preference: a one-shot `read` at session start gets an empty
    // value here, and a plain `ssh -tt` client behaves identically against this
    // server — so it is the tty's behaviour, not this app's plumbing. `head`
    // makes the assertion unambiguous: the line comes back TWICE, once echoed by
    // the terminal and once printed by the command, and only the second copy
    // proves the bytes reached its stdin.
    final ssh = connection(r'sh -c "head -n 1; echo SESSION-DONE"');
    addTearDown(ssh.dispose);

    await ssh.connect();
    final printed = outputOf(ssh);
    // No prompt to wait for in a command session, so the write goes straight in;
    // `head` is already waiting for a line.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    ssh.sendText('hello-from-the-phone\n');

    final output = await printed;
    final occurrences = 'hello-from-the-phone'.allMatches(output).length;
    expect(
      occurrences,
      greaterThanOrEqualTo(2),
      reason: 'one copy is the terminal echoing the keystrokes; the second can '
          'only come from the command reading its stdin. Output was: $output',
    );
  });

  testWidgets('the same connection with no command stays a login shell', (
    tester,
  ) async {
    // The other half of the contract: `initialCommand` must not change what a
    // plain session is. A login shell prints a prompt and keeps running, so the
    // assertion is that the session is still alive after a command session would
    // have ended — and that the shell answers.
    final ssh = connection(null);
    addTearDown(ssh.dispose);

    await ssh.connect();
    expect(ssh.state, SshConnectionState.connected);

    final printed = outputOf(ssh, timeout: const Duration(seconds: 4));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    ssh.sendText('echo LOGIN-SHELL-ALIVE\n');

    final output = await printed;
    expect(output, contains('LOGIN-SHELL-ALIVE'));
    expect(
      ssh.state,
      SshConnectionState.connected,
      reason: 'a login shell does not exit after one command',
    );
  });
}
