import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/file_item.dart';
import 'package:neko_mux/pages/sftp/sftp_file_visuals.dart';

/// A [FileItem] that only carries the fields the category depends on.
/// 只携带类别判断所需字段的 [FileItem]。
FileItem item(String name, {bool isDirectory = false}) => FileItem(
  name: name,
  path: '/tmp/$name',
  isDirectory: isDirectory,
  modifiedDate: DateTime(2026, 1, 1),
);

/// Characters that belong to Chinese, Japanese or Korean text, plus the CJK
/// punctuation block. Used to prove the model stopped naming file types.
/// 属于中日韩文字以及 CJK 标点区的字符。用于证明模型不再自行命名文件类型。
/// Written with escapes rather than literal characters so the ranges stay
/// readable: U+3000–U+303F CJK punctuation, U+4E00–U+9FFF ideographs,
/// U+FF00–U+FFEF full-width forms (which is where '：' lives).
/// 以转义而非字面字符书写，便于阅读区间含义：U+3000–U+303F CJK 标点、
/// U+4E00–U+9FFF 表意文字、U+FF00–U+FFEF 全角形式（'：' 就在这里）。
final cjk = RegExp('[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]');

void main() {
  group('FileItem.category', () {
    test('a directory is a folder whatever it is called', () {
      expect(item('logs', isDirectory: true).category, FileCategory.folder);
      expect(
        item('archive.zip', isDirectory: true).category,
        FileCategory.folder,
      );
    });

    test('maps every extension group the badge has always shown', () {
      const cases = <FileCategory, List<String>>{
        FileCategory.html: ['index.html', 'page.htm'],
        FileCategory.php: ['index.php'],
        FileCategory.python: ['deploy.py'],
        FileCategory.js: ['app.js'],
        FileCategory.css: ['style.css'],
        FileCategory.archive: ['a.tar', 'b.gz', 'c.zip', 'd.rar'],
        FileCategory.image: ['i.png', 'i.jpg', 'i.jpeg', 'i.gif'],
        FileCategory.log: ['syslog.log'],
        FileCategory.config: ['nginx.conf', 'app.cfg'],
      };

      var checked = 0;
      cases.forEach((category, names) {
        for (final name in names) {
          checked++;
          expect(item(name).category, category, reason: name);
        }
      });
      // Guards the table above against silently becoming empty.
      expect(checked, 17);
    });

    test('matches the extension case-insensitively', () {
      expect(item('INDEX.HTML').category, FileCategory.html);
      expect(item('Photo.JPG').category, FileCategory.image);
      expect(item('Deploy.PY').category, FileCategory.python);
    });

    test('leaves an unrecognised name uncategorised', () {
      for (final name in [
        'lib.rs',
        'Makefile',
        '.gitignore',
        'trailing.',
        '',
      ]) {
        expect(item(name).category, FileCategory.other, reason: '"$name"');
      }
    });

    test('keeps the historical whole-name rule for a name with no dot', () {
      // The extension is whatever follows the last dot, or the whole name when
      // there is none — so a file literally called `log` is a log file, exactly
      // as it was before the label moved out of the model.
      expect(item('log').category, FileCategory.log);
      expect(item('conf').category, FileCategory.config);
    });
  });

  group('the model names no file type itself', () {
    test('declares no string literal containing CJK', () {
      // `fileType` used to return '文件夹', '压缩包', '日志文件', … straight from
      // the model, which is what put Chinese in the file list of every language
      // but one. Comments are bilingual by convention, so they are stripped
      // before the scan; what must stay free of CJK is the code.
      // `fileType` 曾直接从模型返回「文件夹」「压缩包」「日志文件」等中文词，正是
      // 它把中文塞进了除中文外每一种语言的文件列表。注释按约定是中英双语的，因此扫描
      // 前先剥离注释；必须不含中文的是代码本身。
      final source = File('lib/models/file_item.dart').readAsStringSync();
      expect(
        source,
        contains('class FileItem'),
        reason: 'the scan is reading the wrong file',
      );

      final code = source
          .split('\n')
          .map((line) => line.split('//').first)
          .join('\n');
      final hit = cjk.firstMatch(code);
      expect(hit, isNull, reason: 'CJK in code: "${hit?.group(0)}"');
    });

    test('no longer exposes a fileType label', () {
      // The getter is gone rather than deprecated: it could only ever answer in
      // one language, and every caller now goes through
      // `sftpFileTypeLabel` in the presentation layer.
      // 该 getter 是删除而非标记弃用：它只能以一种语言作答，而所有调用方现在都走
      // 展示层的 `sftpFileTypeLabel`。
      //
      // The scan is for the *identifier*, not for the spelling `get fileType`:
      // `String fileType()` — the same member without a getter keyword — and a
      // field called `fileType` would each be the defect this guards, and each
      // passed the old check. Comments are stripped first for the same reason
      // as in the CJK scan above: the file's own doc comments name the member
      // they removed.
      // 扫描针对的是**标识符**，而不是 `get fileType` 这个写法：去掉 getter 关键字的
      // `String fileType()`，以及名为 `fileType` 的字段，都是本条要防的缺陷，而它们
      // 都能通过旧断言。先剥离注释的原因与上面的 CJK 扫描相同：文件自己的文档注释里
      // 就写着它删掉的那个成员名。
      final source = File('lib/models/file_item.dart').readAsStringSync();
      expect(
        source,
        contains('class FileItem'),
        reason: 'the scan is reading the wrong file',
      );

      final code = source
          .split('\n')
          .map((line) => line.split('//').first)
          .join('\n');
      final hit = RegExp(r'\bfileType\b').firstMatch(code);
      expect(
        hit,
        isNull,
        reason:
            'the model declares a file-type label again — a label composed in '
            'the model can only be written in one language, which is the bug '
            'sftpFileTypeLabel exists to prevent',
      );
    });
  });

  group('the label a user reads is chosen by the view', () {
    /// One file per category, named so the category follows from the name.
    /// 每个类别一个文件，名称决定其类别。
    final samples = <String, bool>{
      'logs': true, // folder
      'index.html': false,
      'index.php': false,
      'deploy.py': false,
      'app.js': false,
      'style.css': false,
      'backup.zip': false,
      'photo.png': false,
      'syslog.log': false,
      'nginx.conf': false,
    };

    setUp(() => AppStrings.setLang('zh'));
    tearDown(() => AppStrings.setLang('zh'));

    test('the same file reads as its own language, not as one fixed one', () {
      // This is the claim the model change was for. A label composed inside the
      // model answered in one language for all eight; the view's answer has to
      // follow the active language, and only a test that changes the language
      // can tell the two apart.
      // 这正是模型改动所要达成的目标。在模型内部组装的标签对八种语言一视同仁地只以
      // 一种作答；视图的回答必须随当前语言变化，而只有切换语言的测试才能区分两者。
      final folder = item('logs', isDirectory: true);

      AppStrings.setLang('en');
      expect(sftpFileTypeLabel(folder), 'Folder');
      expect(sftpFileTypeLabel(item('backup.zip')), 'Archive');

      AppStrings.setLang('zh');
      expect(sftpFileTypeLabel(folder), '文件夹');
      expect(sftpFileTypeLabel(item('backup.zip')), '压缩包');
    });

    test('every category is answered, in every language, never by a key', () {
      // A key with no entry comes back as the key itself, which is what a user
      // would then see in the badge. This links the view's key references to
      // the tables — the i18n test can only check the tables against each
      // other.
      // 表中缺失的键会以键名本身返回，而那正是用户会在徽标里看到的东西。本条把视图
      // 引用的键与翻译表联系起来——i18n 测试只能让各表互相比对。
      for (final lang in AppStrings.supportedLanguages.keys) {
        AppStrings.setLang(lang);
        samples.forEach((name, isDirectory) {
          final label = sftpFileTypeLabel(
            item(name, isDirectory: isDirectory),
          );
          expect(label.trim(), isNotEmpty, reason: '$lang / $name');
          expect(
            label,
            isNot(startsWith('file_type_')),
            reason: '$lang / $name fell back to its key',
          );
        });
      }
    });
  });
}
