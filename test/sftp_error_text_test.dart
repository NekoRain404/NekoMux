import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/sftp/sftp_error_text.dart';
import 'package:neko_mux/services/sftp_service.dart';

/// CJK text and CJK/full-width punctuation — the script the SFTP service used
/// to write its error messages in, whatever language the app was set to.
/// 中日韩文字与 CJK／全角标点——SFTP 服务此前书写错误消息所用的字符，无论应用被设成
/// 哪种语言。
/// Written with escapes rather than literal characters so the ranges stay
/// readable: U+3000–U+303F CJK punctuation, U+4E00–U+9FFF ideographs,
/// U+FF00–U+FFEF full-width forms (which is where '：' lives).
/// 以转义而非字面字符书写，便于阅读区间含义：U+3000–U+303F CJK 标点、
/// U+4E00–U+9FFF 表意文字、U+FF00–U+FFEF 全角形式（'：' 就在这里）。
final cjk = RegExp('[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]');

/// Languages that never use CJK, so any CJK in their output is a leak.
/// 从不使用中日韩文字的语言，因此其中出现的任何 CJK 都是泄漏。
const nonCjkLanguages = ['en', 'fr', 'de', 'ru', 'es'];

/// The six operation failures, which append the server's own complaint.
/// 六个操作类失败，会附上服务器自身的报错。
const operationFailures = [
  SftpFailure.connect,
  SftpFailure.list,
  SftpFailure.read,
  SftpFailure.write,
  SftpFailure.delete,
  SftpFailure.rename,
  SftpFailure.mkdir,
];

/// The connection family, whose sentence is complete on its own.
/// 连接类失败，其句子本身已完整。
const connectionFailures = [
  SftpFailure.notConnected,
  SftpFailure.connTimeout,
  SftpFailure.authFailed,
  SftpFailure.connRefused,
  SftpFailure.hostUnreachable,
];

/// The table key each failure kind must resolve to when there is no detail.
/// 无细节时每种失败所必须解析到的表键。
///
/// Stated here rather than derived from the function under test: the point of
/// the assertion is *which* sentence a kind produces, and a test that reads the
/// mapping out of `sftpFailureText` cannot disagree with it.
/// 在此明确列出，而不是从被测函数推导：断言要问的正是「某种失败产生哪一句」，而从
/// `sftpFailureText` 里读出映射的测试不可能与它不一致。
const expectedKeys = <SftpFailure, String>{
  SftpFailure.notConnected: 'ssh_not_connected',
  SftpFailure.connTimeout: 'conn_timeout',
  SftpFailure.authFailed: 'auth_failed',
  SftpFailure.connRefused: 'conn_refused',
  SftpFailure.hostUnreachable: 'host_unreachable',
  SftpFailure.connect: 'connection_failed',
  SftpFailure.list: 'list_failed',
  SftpFailure.read: 'read_failed',
  SftpFailure.write: 'write_failed',
  SftpFailure.delete: 'delete_failed',
  SftpFailure.rename: 'rename_failed',
  SftpFailure.mkdir: 'mkdir_failed',
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
        for (final kind in SftpFailure.values) {
          final text = sftpFailureText(kind, 'boom');
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
      for (final kind in SftpFailure.values) {
        final text = sftpFailureText(kind, 'boom');
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
        for (final kind in SftpFailure.values) {
          final hit = cjk.firstMatch(sftpFailureText(kind, 'boom'));
          expect(hit, isNull, reason: '$lang / $kind: "${hit?.group(0)}"');
        }
      }
    });

    test('in Chinese, which really is Chinese', () {
      // The mirror of the check above: if the mapping silently fell through to
      // English, the English test would pass and nobody would notice.
      // 与上一条互为镜像：如果映射悄然退化成英文，上面那条断言照样通过，没人会发现。
      AppStrings.setLang('zh');
      for (final kind in SftpFailure.values) {
        expect(
          cjk.hasMatch(sftpFailureText(kind)),
          isTrue,
          reason: '$kind is not translated into Chinese',
        );
      }
    });
  });

  group('the raw detail is placed where it helps', () {
    test('operation failures append it after a language-neutral separator', () {
      for (final kind in operationFailures) {
        final text = sftpFailureText(kind, 'SocketException: broken pipe');
        expect(
          text,
          endsWith('SocketException: broken pipe'),
          reason: '$kind dropped the detail',
        );
        // A plain colon, never the full-width '：' that used to be appended.
        // 普通冒号，绝不是此前追加的全角「：」。
        expect(text, contains(': SocketException'), reason: '$kind');
        expect(text.contains('：'), isFalse, reason: '$kind');
      }
    });

    test('connection failures do not, because they already say what to do', () {
      for (final kind in connectionFailures) {
        final text = sftpFailureText(kind, 'SocketException: broken pipe');
        expect(text.contains('broken pipe'), isFalse, reason: '$kind');
        expect(text, sftpFailureText(kind), reason: '$kind');
      }
    });

    test('a missing or empty detail leaves the sentence alone', () {
      // Compared against each kind's own sentence, looked up from the table by
      // key. The previous version compared `sftpFailureText(kind)` with
      // `sftpFailureText(kind, null)` — the same call twice, since `detail`
      // defaults to null — and with `sftpFailureText(kind, '')`, which the one
      // implementation that ignores both cannot tell apart.
      // 逐项与该失败自己的句子比对，句子按键从表中查出。此前那条用的是
      // `sftpFailureText(kind, null)`——由于 `detail` 默认即 null，那是同一次调用；
      // 以及与 `sftpFailureText(kind, '')` 相比——一个把两者都忽略的实现同样能通过。
      expect(
        expectedKeys.keys.toSet(),
        SftpFailure.values.toSet(),
        reason: 'every failure kind needs a sentence pinned here',
      );

      for (final kind in SftpFailure.values) {
        final label = t(expectedKeys[kind]!);
        expect(sftpFailureText(kind), label, reason: '$kind / no detail');
        expect(
          sftpFailureText(kind, ''),
          label,
          reason: '$kind / empty detail',
        );
        expect(
          sftpFailureText(kind, null),
          label,
          reason: '$kind / null detail',
        );
        expect(
          label.contains(': '),
          isFalse,
          reason: 'the bare sentence for $kind must carry no separator',
        );
      }
    });
  });

  group('SftpException', () {
    test('carries a code and the raw detail, and no prose', () {
      const error = SftpException(
        SftpFailure.list,
        'SftpStatusError: permission denied',
      );
      expect(error.kind, SftpFailure.list);
      expect(error.detail, 'SftpStatusError: permission denied');
      expect(cjk.hasMatch(error.toString()), isFalse);
      expect(cjk.hasMatch(error.message), isFalse);
    });

    test('prints something for every kind, with or without a detail', () {
      for (final kind in SftpFailure.values) {
        expect(SftpException(kind).toString(), kind.name);
        expect(SftpException(kind).message, kind.name);
        expect(SftpException(kind, 'boom').toString(), '${kind.name}: boom');
      }
    });

    test('sftpErrorText reads the exception it was handed', () {
      AppStrings.setLang('en');
      const error = SftpException(SftpFailure.read, 'denied');
      expect(sftpErrorText(error), sftpFailureText(SftpFailure.read, 'denied'));
    });
  });
}
