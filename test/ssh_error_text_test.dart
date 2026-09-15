import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/pages/console/ssh_error_text.dart';
import 'package:neko_mux/services/ssh_service.dart';

/// CJK text and CJK/full-width punctuation — the script the SSH service used to
/// write its error messages in, whatever language the app was set to.
/// 中日韩文字与 CJK／全角标点——SSH 服务此前书写错误消息所用的字符，无论应用被设成
/// 哪种语言。
/// Written with escapes rather than literal characters so the ranges stay
/// readable: U+3000–U+303F CJK punctuation, U+4E00–U+9FFF ideographs,
/// U+FF00–U+FFEF full-width forms.
/// 以转义而非字面字符书写，便于阅读区间含义：U+3000–U+303F CJK 标点、
/// U+4E00–U+9FFF 表意文字、U+FF00–U+FFEF 全角形式。
final cjk = RegExp('[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]');

/// Languages that never use CJK, so any CJK in their output is a leak.
/// 从不使用中日韩文字的语言，因此其中出现的任何 CJK 都是泄漏。
const nonCjkLanguages = ['en', 'fr', 'de', 'ru', 'es'];

/// The connection family, whose sentence is complete on its own.
/// 连接类失败，其句子本身已完整。
const connectionFailures = [
  SshFailure.notConnected,
  SshFailure.connTimeout,
  SshFailure.authFailed,
  SshFailure.connRefused,
  SshFailure.hostUnreachable,
  SshFailure.hostKeyVerify,
];

/// The table key each failure kind must resolve to when there is no detail.
/// 无细节时每种失败所必须解析到的表键。
///
/// Stated here rather than derived from the function under test: the point of
/// the assertion is *which* sentence a kind produces, and a test that reads the
/// mapping out of `sshFailureText` cannot disagree with it.
/// 在此明确列出，而不是从被测函数推导：断言要问的正是「某种失败产生哪一句」，而从
/// `sshFailureText` 里读出映射的测试不可能与它不一致。
const expectedKeys = <SshFailure, String>{
  SshFailure.notConnected: 'ssh_not_connected',
  SshFailure.connTimeout: 'conn_timeout',
  SshFailure.authFailed: 'auth_failed',
  SshFailure.connRefused: 'conn_refused',
  SshFailure.hostUnreachable: 'host_unreachable',
  SshFailure.hostKeyVerify: 'cannot_verify_host_key',
  SshFailure.connect: 'connection_failed',
};

void main() {
  // The active language is global mutable state; every test here picks its own
  // and leaves the default behind.
  setUp(() => AppStrings.setLang('zh'));
  tearDown(() => AppStrings.setLang('zh'));

  group('every failure kind is translated', () {
    test('in all eight shipped languages', () {
      for (final lang in AppStrings.supportedLanguages.keys) {
        AppStrings.setLang(lang);
        for (final kind in SshFailure.values) {
          final text = sshFailureText(kind, 'boom');
          expect(text.trim(), isNotEmpty, reason: '$lang / $kind');
          // A key missing from the table comes back as the key name itself.
          // 表中缺失的键会以键名本身返回。
          expect(
            text,
            isNot(startsWith(kind.name)),
            reason: '$lang / $kind fell back to an identifier',
          );
        }
      }
    });

    test('in English with no CJK anywhere in the sentence', () {
      AppStrings.setLang('en');
      for (final kind in SshFailure.values) {
        final text = sshFailureText(kind, 'boom');
        final hit = cjk.firstMatch(text);
        expect(
          hit,
          isNull,
          reason: '$kind leaked "${hit?.group(0)}" in: $text',
        );
      }
    });

    test('with no CJK in any language that does not use it', () {
      // The old messages were Chinese for everyone; this is the regression that
      // covers every language at once rather than English alone.
      // 旧的错误消息对所有人都用中文；这条断言一次覆盖全部语言，而不只是英文。
      for (final lang in nonCjkLanguages) {
        AppStrings.setLang(lang);
        for (final kind in SshFailure.values) {
          final hit = cjk.firstMatch(sshFailureText(kind, 'boom'));
          expect(hit, isNull, reason: '$lang / $kind: "${hit?.group(0)}"');
        }
      }
    });

    test('in Chinese, which really is Chinese', () {
      // The mirror of the check above: if the mapping silently fell through to
      // English, the English test would pass and nobody would notice.
      // 与上一条互为镜像：如果映射悄然退化成英文，上面那条断言照样通过，没人会发现。
      AppStrings.setLang('zh');
      for (final kind in SshFailure.values) {
        expect(
          cjk.hasMatch(sshFailureText(kind)),
          isTrue,
          reason: '$kind is not translated into Chinese',
        );
      }
    });
  });

  group('the raw detail is placed where it helps', () {
    test('the catch-all appends it after a language-neutral separator', () {
      final text = sshFailureText(
        SshFailure.connect,
        'SSHStateError(Transport is closed)',
      );
      expect(text, endsWith('SSHStateError(Transport is closed)'));
      // A plain colon, never the full-width '：' the old messages used.
      // 普通冒号，绝不是旧消息使用的全角「：」。
      expect(text, contains(': SSHStateError'));
      expect(text.contains('：'), isFalse);
    });

    test('connection failures do not, because they already say what to do', () {
      for (final kind in connectionFailures) {
        final text = sshFailureText(kind, 'SocketException: broken pipe');
        expect(text.contains('broken pipe'), isFalse, reason: '$kind');
        expect(text, sshFailureText(kind), reason: '$kind');
      }
    });

    test('a missing or empty detail leaves the sentence alone', () {
      // Compared against each kind's own sentence, looked up from the table by
      // key. The previous version compared `sshFailureText(kind)` with
      // `sshFailureText(kind, null)` — the same call twice, since `detail`
      // defaults to null — and with `sshFailureText(kind, '')`, which the one
      // implementation that ignores both cannot tell apart.
      // 逐项与该失败自己的句子比对，句子按键从表中查出。此前那条用的是
      // `sshFailureText(kind, null)`——由于 `detail` 默认即 null，那是同一次调用；
      // 以及与 `sshFailureText(kind, '')` 相比——一个把两者都忽略的实现同样能通过。
      expect(
        expectedKeys.keys.toSet(),
        SshFailure.values.toSet(),
        reason: 'every failure kind needs a sentence pinned here',
      );

      for (final kind in SshFailure.values) {
        final label = t(expectedKeys[kind]!);
        expect(sshFailureText(kind), label, reason: '$kind / no detail');
        expect(sshFailureText(kind, ''), label, reason: '$kind / empty detail');
        expect(sshFailureText(kind, null), label, reason: '$kind / null detail');
        expect(
          label.contains(': '),
          isFalse,
          reason: 'the bare sentence for $kind must carry no separator',
        );
      }
    });
  });

  group('the connection-shaped helpers', () {
    test('SshException is read for both of its halves', () {
      AppStrings.setLang('en');
      const error = SshException(SshFailure.authFailed, 'denied');
      expect(sshErrorText(error), sshFailureText(SshFailure.authFailed));
      expect(sshCaughtErrorText(error), sshErrorText(error));
    });

    test('an error that is not an SshException is passed through as text', () {
      // Whatever else a command path throws is not ours to word; it must still
      // arrive somewhere, and unchanged.
      // 命令路径抛出的其它东西不属于我们措辞的范围；它仍须原样抵达，且不得被改写。
      expect(
        sshCaughtErrorText(StateError('bad state')),
        'Bad state: bad state',
      );
      expect(sshCaughtErrorText('boom'), 'boom');
    });

    test('a connection with no classified failure still gets a sentence', () {
      // The fallback covers a combination that cannot happen today (state
      // `error` always sets a code), so it must never be the place a user sees a
      // null or an identifier.
      // 兜底值针对的是今天不可能出现的组合（`error` 状态必定写入编码），因此它绝不能
      // 成为用户看到 null 或标识符的地方。
      final conn = SshConnection(
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
      addTearDown(conn.dispose);

      AppStrings.setLang('en');
      expect(sshConnectErrorText(conn), t('connection_failed'));
      AppStrings.setLang('zh');
      expect(sshConnectErrorText(conn), t('connection_failed'));
      expect(sshConnectErrorText(conn).trim(), isNotEmpty);
    });
  });
}
