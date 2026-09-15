import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/command_result.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// Guards the part of [SshConnection] that can be exercised without a server.
///
/// Six pages plus several services depend on this class while it is being
/// refactored, so the point of these tests is not behaviour under a live
/// session (that needs a real host) but the *shape* of the API: the members and
/// signatures that callers compile against, and the one error path that is
/// reachable with no connection at all.
void main() {
  SshConnection newConnection() => SshConnection(
    host: Host(
      id: 'h1',
      alias: 'test',
      ipAddress: '127.0.0.1',
      credentialId: 'c1',
    ),
    credential: const Credential(
      id: 'c1',
      name: 'test',
      authType: 0,
      username: 'root',
      secretData: 'secret',
    ),
  );

  group('frozen public API', () {
    test('every member old callers use still has its original signature', () {
      final conn = newConnection();
      addTearDown(conn.dispose);

      // Assigning each member to an explicitly typed variable is a
      // compile-time assertion on its signature: if a later change alters one,
      // this file stops compiling rather than silently breaking a call site.
      final Host host = conn.host;
      final Credential credential = conn.credential;
      final Future<String> Function(String) executeCommand =
          conn.executeCommand;
      final void Function(String) sendText = conn.sendText;
      final void Function(int, int) resizeTerminal = conn.resizeTerminal;
      final Future<void> Function() connect = conn.connect;
      final Future<void> Function() disconnect = conn.disconnect;
      final void Function() dispose = conn.dispose;
      final SshConnectionState state = conn.state;
      final Stream<SshConnectionState> stateStream = conn.stateStream;
      final Duration connectTimeout = conn.connectTimeout;
      final String? lastError = conn.lastError;
      final Future<bool> Function(String)? onHostKeyVerify =
          conn.onHostKeyVerify;

      expect(host.ipAddress, '127.0.0.1');
      expect(credential.username, 'root');
      expect(executeCommand, isNotNull);
      expect(sendText, isNotNull);
      expect(resizeTerminal, isNotNull);
      expect(connect, isNotNull);
      expect(disconnect, isNotNull);
      expect(dispose, isNotNull);
      expect(state, SshConnectionState.disconnected);
      expect(stateStream, isNotNull);
      expect(connectTimeout, const Duration(seconds: 10));
      expect(lastError, isNull);
      expect(onHostKeyVerify, isNull);
    });

    test('outputStream stays a Stream of raw bytes', () {
      final conn = newConnection();
      addTearDown(conn.dispose);

      expect(conn.outputStream, isA<Stream<List<int>>>());
    });

    test('the typed host key callback is optional and defaults to null', () {
      final conn = newConnection();
      addTearDown(conn.dispose);

      expect(conn.onHostKeyVerifyTyped, isNull);
    });
  });

  group('the new command API', () {
    test('runCommand returns a CommandResult, not a string', () {
      final conn = newConnection();
      addTearDown(conn.dispose);

      final Future<CommandResult> Function(String) run = conn.runCommand;
      expect(run, isNotNull);
    });

    test('runCommand reports the not-connected state as an exception', () async {
      final conn = newConnection();
      addTearDown(conn.dispose);

      await expectLater(
        conn.runCommand('true'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('SSH 未连接'),
          ),
        ),
      );
    });

    test('executeCommand still reports the same exception when not connected',
        () async {
      // The legacy path and the new one share one guard, so a caller that
      // catches the old error keeps catching it.
      final conn = newConnection();
      addTearDown(conn.dispose);

      await expectLater(
        conn.executeCommand('true'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('SSH 未连接'),
          ),
        ),
      );
    });

    test('a disposed connection is still not connected', () async {
      final conn = newConnection();
      conn.dispose();

      await expectLater(conn.runCommand('true'), throwsA(isA<Exception>()));
    });
  });

  group('teardown without a session', () {
    test('disconnect and dispose are safe on a never-connected instance',
        () async {
      final conn = newConnection();

      await conn.disconnect();
      expect(conn.state, SshConnectionState.disconnected);
      conn.dispose();

      // dispose() is idempotent.
      conn.dispose();
      expect(conn.state, SshConnectionState.disconnected);
    });

    test('connect is a no-op once disposed', () async {
      final conn = newConnection();
      conn.dispose();

      // Must return without opening a socket nobody is left to close.
      await conn.connect();
      expect(conn.state, SshConnectionState.disconnected);
    });
  });
}
