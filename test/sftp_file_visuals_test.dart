import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/file_item.dart';
import 'package:neko_mux/pages/sftp/sftp_file_visuals.dart';

/// CJK text and CJK/full-width punctuation.
/// 中日韩文字与 CJK／全角标点。
/// Written with escapes rather than literal characters so the ranges stay
/// readable: U+3000–U+303F CJK punctuation, U+4E00–U+9FFF ideographs,
/// U+FF00–U+FFEF full-width forms (which is where '：' lives).
/// 以转义而非字面字符书写，便于阅读区间含义：U+3000–U+303F CJK 标点、
/// U+4E00–U+9FFF 表意文字、U+FF00–U+FFEF 全角形式（'：' 就在这里）。
final cjk = RegExp('[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]');

FileItem item(String name, {bool isDirectory = false, int size = 0}) =>
    FileItem(
      name: name,
      path: '/tmp/$name',
      isDirectory: isDirectory,
      size: size,
      modifiedDate: DateTime(2026, 1, 1),
    );

void main() {
  setUp(() => AppStrings.setLang('zh'));
  tearDown(() => AppStrings.setLang('zh'));

  group('sftpFileTypeLabel', () {
    test('translates every category, with no CJK outside Chinese', () {
      const samples = [
        ('logs', true),
        ('index.html', false),
        ('index.php', false),
        ('deploy.py', false),
        ('app.js', false),
        ('style.css', false),
        ('backup.zip', false),
        ('photo.png', false),
        ('syslog.log', false),
        ('nginx.conf', false),
      ];

      for (final lang in ['en', 'fr', 'de', 'ru', 'es']) {
        AppStrings.setLang(lang);
        for (final (name, isDirectory) in samples) {
          final label = sftpFileTypeLabel(item(name, isDirectory: isDirectory));
          final hit = cjk.firstMatch(label);
          expect(hit, isNull, reason: '$lang / $name: "${hit?.group(0)}"');
        }
      }
    });

    test('reads as the translation table says, in each language', () {
      final file = item('index.html');

      AppStrings.setLang('en');
      expect(sftpFileTypeLabel(file), 'HTML document');
      expect(sftpFileTypeLabel(item('logs', isDirectory: true)), 'Folder');

      AppStrings.setLang('zh');
      expect(sftpFileTypeLabel(file), 'HTML 文档');
      expect(sftpFileTypeLabel(item('logs', isDirectory: true)), '文件夹');
    });

    test('shows an unknown extension as itself, upper-cased', () {
      // Not a missing translation: `RS` and `MAKEFILE` read the same in all
      // eight languages, which is exactly why the label is built here and not
      // in the model.
      // 这不是翻译缺失：`RS` 与 `MAKEFILE` 在八种语言下读起来都一样，这正是标签在
      // 这里而不是在模型里生成的原因。
      for (final lang in AppStrings.supportedLanguages.keys) {
        AppStrings.setLang(lang);
        expect(sftpFileTypeLabel(item('lib.rs')), 'RS', reason: lang);
        expect(sftpFileTypeLabel(item('lib.RS')), 'RS', reason: lang);
        expect(sftpFileTypeLabel(item('Makefile')), 'MAKEFILE', reason: lang);
      }
    });
  });

  group('sftpFileSubtitle', () {
    test('lists size, type and permissions for a file', () {
      AppStrings.setLang('en');
      expect(
        sftpFileSubtitle(item('lib.rs', size: 12)),
        '12 B · RS · rw-r--r--',
      );
      expect(
        sftpFileSubtitle(item('index.html', size: 2048)),
        '2.0 KB · HTML document · rw-r--r--',
      );
    });

    test('shows the permissions alone for a directory', () {
      AppStrings.setLang('en');
      expect(sftpFileSubtitle(item('logs', isDirectory: true)), 'rw-r--r--');
    });

    test('carries no CJK in English', () {
      AppStrings.setLang('en');
      expect(
        cjk.hasMatch(sftpFileSubtitle(item('index.html', size: 2048))),
        isFalse,
      );
      expect(
        cjk.hasMatch(sftpFileSubtitle(item('logs', isDirectory: true))),
        isFalse,
      );
    });
  });
}
