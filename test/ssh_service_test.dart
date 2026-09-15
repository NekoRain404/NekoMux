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

      // Asserted on the tear-off's *runtime type*, which carries the declared
      // return type — so this fails the moment `runCommand` is changed back to
      // handing out a bare string. The previous assertion was `isNotNull` on a
      // non-nullable tear-off: it could not fail, because the only way to make
      // it fail is to stop the file compiling.
      // 断言的是 tear-off 的**运行期类型**，它携带了声明的返回类型——因此一旦
      // `runCommand` 改回返回裸字符串，本测试立刻失败。此前的断言是对非空 tear-off
      // 做 `isNotNull`：它不可能失败，因为唯一能让它失败的办法是让本文件无法编译。
      expect(
        conn.runCommand,
        isA<Future<CommandResult> Function(String)>(),
        reason:
            'runCommand must hand back a CommandResult: the exit status it '
            'carries is what lets a caller judge whether the command worked',
      );
    });

    test('runCommand reports the not-connected state as an exception', () async {
      final conn = newConnection();
      addTearDown(conn.dispose);

      // Asserted on the code rather than on the text. The failure used to carry
      // the Chinese sentence "SSH 未连接" as its message: every user got Chinese
      // whatever language the app was set to, and a caller could not tell this
      // failure from any other `Exception`. The sentence a user reads is now
      // chosen by the presentation layer from the code (`sshFailureText`).
      // 断言的是编码而不是文本。该失败过去把中文句子「SSH 未连接」当作消息：无论应用
      // 设成哪种语言，所有用户看到的都是中文，调用方也无法把它与其它 `Exception` 区分
      // 开。用户读到的句子现在由展示层根据该编码选择（`sshFailureText`）。
      await expectLater(
        conn.runCommand('true'),
        throwsA(
          isA<SshException>().having(
            (e) => e.kind,
            'kind',
            SshFailure.notConnected,
          ),
        ),
      );
    });

    test(
      'executeCommand still reports the same exception when not connected',
      () async {
        // The legacy path and the new one share one guard, so a caller that
        // catches the old error keeps catching it — now with a code attached.
        // 旧路径与新路径共用同一个守卫，因此捕获旧错误的调用方仍能捕获到它——只是现在
        // 附带了编码。
        final conn = newConnection();
        addTearDown(conn.dispose);

        await expectLater(
          conn.executeCommand('true'),
          throwsA(
            isA<SshException>().having(
              (e) => e.kind,
              'kind',
              SshFailure.notConnected,
            ),
          ),
        );
      },
    );

    test('a disposed connection is still not connected', () async {
      final conn = newConnection();
      conn.dispose();

      // Pinned to the code the guard actually raises. `throwsA(isA<Exception>())`
      // accepted *any* exception — including the `TypeError` a disposed field
      // being dereferenced throws — so it would have stayed green if dispose()
      // had left the object in a state the command path cannot handle. Callers
      // distinguish "no session" from everything else by this code, so the code
      // is what is asserted.
      // 固定在守卫实际抛出的编码上。`throwsA(isA<Exception>())` 接受**任何**异常
      // ——包括解引用已释放字段所抛的 `TypeError`——因此若 dispose() 让对象进入了
      // 命令路径无法处理的状态，它照样通过。调用方正是靠这个编码把「没有会话」与其它
      // 一切区分开，所以要断言的就是这个编码。
      await expectLater(
        conn.runCommand('true'),
        throwsA(
          isA<SshException>().having(
            (e) => e.kind,
            'kind',
            SshFailure.notConnected,
          ),
        ),
      );
      await expectLater(
        conn.executeCommand('true'),
        throwsA(
          isA<SshException>().having(
            (e) => e.kind,
            'kind',
            SshFailure.notConnected,
          ),
        ),
      );
    });
  });

  group('teardown without a session', () {
    test(
      'disconnect and dispose are safe on a never-connected instance',
      () async {
        final conn = newConnection();

        await conn.disconnect();
        expect(conn.state, SshConnectionState.disconnected);
        conn.dispose();

        // dispose() is idempotent.
        conn.dispose();
        expect(conn.state, SshConnectionState.disconnected);
      },
    );

    test('connect is a no-op once disposed', () async {
      final conn = newConnection();
      conn.dispose();

      // Must return without opening a socket nobody is left to close.
      await conn.connect();
      expect(conn.state, SshConnectionState.disconnected);
    });
  });
}
