import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/file_item.dart';

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
      final source = File('lib/models/file_item.dart').readAsStringSync();
      expect(source, isNot(contains('get fileType')));
    });
  });
}
