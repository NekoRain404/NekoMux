import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// Guards the pure half of the SSH error path: given the text a transport error
/// arrives as, which code does the presentation layer get?
/// 守护 SSH 错误路径中纯函数的那一半：给定传输层错误的文本，展示层会拿到哪个编码？
///
/// The strings are the ones the failures actually produce, not invented samples —
/// `dart:io`'s socket layer (`Socket.connect`) and `dartssh2`'s transport
/// (`SSHHostkeyError`, `SSHAuthFailError`) are where they come from, so a change
/// in either package that alters its wording shows up here as a failing
/// classification rather than as an English sentence on a user's screen.
/// 下面的字符串是这些失败真实产生的文本，而非编造的例子——它们来自 `dart:io` 的套接字层
/// （`Socket.connect`）与 `dartssh2` 的传输层（`SSHHostkeyError`、
/// `SSHAuthFailError`）；任一依赖改变措辞，都会在这里表现为分类失败，而不是在用户屏幕上
/// 表现为一句英文。
/// CJK text and CJK/full-width punctuation: the script the SSH service used to
/// write its error messages in, whatever language the app was set to.
/// 中日韩文字与 CJK／全角标点——SSH 服务此前书写错误消息所用的字符，无论应用被设成哪
/// 种语言。
final cjk = RegExp('[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]');

/// `Socket.connect`'s own timeout, and the variants around it.
/// `Socket.connect` 自身的超时，以及它附近的几种写法。
const timeoutErrors = [
  'SocketException: Connection timed out, host: 10.0.0.1, port: 22 '
      '(OS Error: Connection timed out, errno = 110)',
  'Connection timeout',
  'TimeoutException after 0:00:10.000000: Future not completed',
];

/// What the verifier's refusal turns into: `SSHHostkeyError` in the transport.
/// 验证回调拒绝后变成的东西：传输层里的 `SSHHostkeyError`。
const hostKeyErrors = [
  'SSHHostkeyError(Hostkey verification failed)',
  'Handshake error: Host key verification failed',
];

/// Authentication rejections.
/// 认证被拒绝。
const authErrors = [
  'SSHAuthFailError(All authentication methods failed)',
  'SSHAuthAbortError(No more authentication methods available)',
  'Permission denied (password,publickey).',
];

/// The server answered, and said no.
/// 服务器有应答，但拒绝了。
const refusedErrors = [
  'SocketException: Connection refused (OS Error: Connection refused, '
      'errno = 111), address = 10.0.0.1, port = 22',
];

/// Name resolution failures — three spellings, because the platforms disagree:
/// `dart:io`'s wrapper text, glibc's, and the messages older stacks produced.
/// 名称解析失败——三种写法，因为各平台并不一致：`dart:io` 的包装文本、glibc 的文本，
/// 以及更旧实现产生的消息。
const unreachableErrors = [
  "SocketException: Failed host lookup: 'nope.invalid' "
      '(OS Error: Name or service not known, errno = -2)',
  'SocketException: Unknown host',
  'SocketException: No address associated with hostname',
];

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

  group('classifySshFailure', () {
    test('every listed failure gets its own code', () {
      for (final error in timeoutErrors) {
        expect(
          classifySshFailure(error),
          SshFailure.connTimeout,
          reason: error,
        );
      }
      for (final error in hostKeyErrors) {
        expect(
          classifySshFailure(error),
          SshFailure.hostKeyVerify,
          reason: error,
        );
      }
      for (final error in authErrors) {
        expect(classifySshFailure(error), SshFailure.authFailed, reason: error);
      }
      for (final error in refusedErrors) {
        expect(
          classifySshFailure(error),
          SshFailure.connRefused,
          reason: error,
        );
      }
      for (final error in unreachableErrors) {
        expect(
          classifySshFailure(error),
          SshFailure.hostUnreachable,
          reason: error,
        );
      }
    });

    test('every code but notConnected is reachable from some real text', () {
      // `notConnected` is never classified — it is thrown directly when a
      // command is issued on a session that is not up — but every other code has
      // to be produced by something, or the sentence behind it could never be
      // shown.
      // `notConnected` 从不参与分类——它是在会话未就绪时直接抛出的编码——但其它每个
      // 编码都必须有真实文本能产生，否则其背后的句子永远不会出现。
      final produced = <SshFailure>{
        for (final error in [
          ...timeoutErrors,
          ...hostKeyErrors,
          ...authErrors,
          ...refusedErrors,
          ...unreachableErrors,
          'SSHStateError(Transport is closed)',
        ])
          classifySshFailure(error),
      };
      expect(
        produced,
        containsAll(<SshFailure>[
          SshFailure.connTimeout,
          SshFailure.hostKeyVerify,
          SshFailure.authFailed,
          SshFailure.connRefused,
          SshFailure.hostUnreachable,
          SshFailure.connect,
        ]),
      );
    });

    test('host key is tested before the broader credential match', () {
      // "host key" contains "key", which the authentication branch matches; were
      // the order reversed, a refused host key would be reported as a credential
      // problem and the user would go and check the one thing that is correct.
      // 「host key」含有「key」，认证分支会命中它；若顺序颠倒，被拒绝的主机密钥会被
      // 报成凭据问题，用户就会去检查唯一没有问题的东西。
      expect(
        classifySshFailure('Host key verification failed: key rejected'),
        SshFailure.hostKeyVerify,
      );
      expect(classifySshFailure('private key invalid'), SshFailure.authFailed);
    });

    test('the refusal wins over the address in a message that names both', () {
      // The order is the one the old message-based translation used; pinning it
      // keeps the code a given failure yields from changing.
      // 顺序与旧的基于消息的翻译一致；把它固定下来，某种失败得到的编码就不会变。
      expect(
        classifySshFailure('Connection refused: failed to resolve 10.0.0.1'),
        SshFailure.connRefused,
      );
    });

    test('matching is case-insensitive', () {
      expect(
        classifySshFailure('CONNECTION TIMED OUT'),
        SshFailure.connTimeout,
      );
      expect(
        classifySshFailure('SSHHOSTKEYERROR(HOSTKEY VERIFICATION FAILED)'),
        SshFailure.hostKeyVerify,
      );
    });

    test('an unrecognised error is still a code, not a throw', () {
      // The failure the user must never see is "the app crashed while reporting
      // a crash". Anything the classifier has never met — a new library message,
      // an empty string, a serialized error object — comes back as `connect`,
      // which the presentation layer words as the generic failure plus the raw
      // detail.
      // 用户最不该看到的失败是「应用在报告失败时自己崩了」。分类器从未见过的任何东西
      // ——新版本的库消息、空字符串、被序列化的错误对象——都会返回 `connect`，展示层把
      // 它写成通用失败文案加上原始细节。
      for (final error in [
        'SSHStateError(Transport is closed)',
        'SomeError the classifier has never seen',
        '',
        '   ',
        '{"type":"error","code":42}',
      ]) {
        expect(classifySshFailure(error), SshFailure.connect, reason: error);
      }
    });
  });

  group('SshException', () {
    test('carries a code and the raw detail, and no prose', () {
      const error = SshException(
        SshFailure.connRefused,
        'SocketException: Connection refused',
      );
      expect(error.kind, SshFailure.connRefused);
      expect(error.detail, 'SocketException: Connection refused');
      expect(cjk.hasMatch(error.toString()), isFalse);
      expect(cjk.hasMatch(error.message), isFalse);
    });

    test('prints something for every kind, with or without a detail', () {
      for (final kind in SshFailure.values) {
        expect(SshException(kind).toString(), kind.name);
        expect(SshException(kind).message, kind.name);
        expect(SshException(kind, 'boom').toString(), '${kind.name}: boom');
      }
    });

    test(
      'the not-connected failure is distinguishable, and not Chinese',
      () async {
        // The regression this exists for: every caller used to get a bare
        // `Exception('SSH 未连接')` — a Chinese sentence in an app that may be
        // running in any of eight languages, and indistinguishable from any other
        // exception the transport might throw.
        // 这条回归针对的是：调用方过去拿到的是裸的 `Exception('SSH 未连接')`——一句在可能
        // 运行于八种语言中任一语言的应用里的中文，且与传输层可能抛出的任何其它异常无从
        // 区分。
        final conn = newConnection();
        addTearDown(conn.dispose);

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
            isA<SshException>()
                .having((e) => e.kind, 'kind', SshFailure.notConnected)
                .having((e) => cjk.hasMatch(e.toString()), 'CJK leak', isFalse),
          ),
        );
      },
    );
  });

  group('SshConnection.failure', () {
    test('is null while nothing has failed', () {
      final conn = newConnection();
      addTearDown(conn.dispose);

      expect(conn.failure, isNull);
      expect(conn.lastError, isNull);
      expect(conn.state, SshConnectionState.disconnected);
    });

    test('stays null across teardown that was not a failure', () async {
      // disconnect() and dispose() leave `state` at `disconnected`, not `error`:
      // a session the user closed is not a failure, and the code must not
      // outlive the reason it was set for.
      // disconnect() 与 dispose() 让 `state` 停在 `disconnected` 而非 `error`：用户
      // 主动关闭的会话不是失败，编码也不得比它所对应的原因活得更久。
      final conn = newConnection();

      await conn.disconnect();
      expect(conn.failure, isNull);
      conn.dispose();
      expect(conn.failure, isNull);
      expect(conn.lastError, isNull);
    });
  });
}
