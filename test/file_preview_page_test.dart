import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/file_preview_page.dart';
import 'package:neko_mux/widgets/app_ui.dart';

/// Guards the two ways this page used to fall over on a real file: it handed
/// any size to a single `SelectableText`, and its metadata bar re-derived the
/// line and character counts from the whole text on every keystroke.
/// 守护本页面曾在真实文件上倒下的两个地方：它把任意大小的内容交给单个
/// `SelectableText`，并且元信息栏每次按键都要从整个文本重新推导行数与字符数。
///
/// The expected values are hand-computed rather than produced by a second
/// implementation, so a passing test is evidence the numbers are right rather
/// than evidence that two pieces of code agree with each other.
/// 期望值是手工算出来的，而不是由另一份实现生成的；测试通过因此证明数值正确，
/// 而不是证明两段代码彼此一致。
Widget _app(Widget child) => MaterialApp(home: child);

/// The page's editor, once edit mode has been entered.
/// 进入编辑模式后页面上的编辑器。
Finder get _editor => find.byType(TextField);

/// The metadata badges for [lines] lines / [chars] characters, read through the
/// translation table so the test tracks the strings rather than restating them.
/// 行数 / 字符数徽标，经翻译表取值，使测试跟随文案而不是复述文案。
Finder _lines(int lines) =>
    find.text(t('file_lines').replaceAll('{0}', '$lines'));
Finder _chars(int chars) =>
    find.text(t('file_chars').replaceAll('{0}', '$chars'));

Future<void> _openEditor(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.edit_outlined));
  await tester.pumpAndSettle();
}

/// Replaces the editor's text, which is what a keystroke, a paste or an IME
/// commit ultimately does to the controller.
/// 替换编辑器文本——按键、粘贴、输入法上屏最终对控制器所做的正是这件事。
Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_editor, text);
  await tester.pump();
}

void main() {
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  group('size limit', () {
    test('is 1 MiB, and inclusive', () {
      expect(FilePreviewPage.maxContentLength, 1024 * 1024);
      expect(
        FilePreviewPage.isTooLarge('x' * FilePreviewPage.maxContentLength),
        isFalse,
      );
      expect(
        FilePreviewPage.isTooLarge(
          'x' * (FilePreviewPage.maxContentLength + 1),
        ),
        isTrue,
      );
    });

    testWidgets('refuses to render content past the limit', (tester) async {
      final huge = 'x' * (FilePreviewPage.maxContentLength + 1);
      await tester.pumpWidget(
        _app(
          FilePreviewPage(filename: 'huge.log', content: huge, onSave: (_) {}),
        ),
      );

      expect(find.text(t('file_too_large')), findsOneWidget);

      /// None of the affordances that would have to hold the whole file.
      /// 任何需要持有整个文件的操作都不再出现。
      expect(find.byType(SelectableText), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);

      /// Filling in the metadata bar would mean scanning the same content.
      /// 要显示元信息栏就得扫描同一份内容，因此它也不出现。
      expect(find.byType(AppBadge), findsNothing);
    });

    testWidgets('renders a file below the limit', (tester) async {
      final content = 'x' * 4096;
      await tester.pumpWidget(
        _app(FilePreviewPage(filename: 'big.txt', content: content)),
      );

      expect(find.text(t('file_too_large')), findsNothing);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(_chars(content.length), findsOneWidget);
      expect(_lines(1), findsOneWidget);
    });
  });

  group('metadata bar', () {
    testWidgets('counts lines and characters', (tester) async {
      await tester.pumpWidget(
        _app(const FilePreviewPage(filename: 'a.conf', content: 'one\ntwo')),
      );

      expect(_lines(2), findsOneWidget);
      expect(_chars(7), findsOneWidget);
    });

    testWidgets('counts an empty file as having no lines', (tester) async {
      await tester.pumpWidget(
        _app(const FilePreviewPage(filename: 'empty.conf', content: '')),
      );

      expect(_lines(0), findsOneWidget);
      expect(_chars(0), findsOneWidget);
    });

    testWidgets('keeps the counts exact across edits', (tester) async {
      await tester.pumpWidget(
        _app(
          FilePreviewPage(
            filename: 'a.conf',
            content: 'one\ntwo',
            onSave: (_) {},
          ),
        ),
      );
      await _openEditor(tester);

      /// Append a line: one newline and five characters.
      /// 追加一行：一个换行、五个字符。
      await _type(tester, 'one\ntwo\nthree');
      expect(_lines(3), findsOneWidget);
      expect(_chars(13), findsOneWidget);

      /// Type in the middle of a line.
      /// 在行中间输入。
      await _type(tester, 'one\ntwo\nthrXee');
      expect(_lines(3), findsOneWidget);
      expect(_chars(14), findsOneWidget);

      /// Delete the first line and its newline.
      /// 删掉第一行及其换行。
      await _type(tester, 'two\nthrXee');
      expect(_lines(2), findsOneWidget);
      expect(_chars(10), findsOneWidget);

      /// Characters count as grapheme clusters, not as UTF-16 code units.
      /// 字符按字素簇计，而不是按 UTF-16 码元计。
      await _type(tester, '一二三\n😀');
      expect(_lines(2), findsOneWidget);
      expect(_chars(5), findsOneWidget);

      /// A newline inserted at the very front.
      /// 在开头插入一个换行。
      await _type(tester, '\n一二三\n😀');
      expect(_lines(3), findsOneWidget);
      expect(_chars(6), findsOneWidget);

      /// A character appended to the emoji sequence.
      /// 在 emoji 序列后面再追加一个字符。
      await _type(tester, '\n一二三\n😀x');
      expect(_lines(3), findsOneWidget);
      expect(_chars(7), findsOneWidget);

      /// Everything removed.
      /// 全部删光。
      await _type(tester, '');
      expect(_lines(0), findsOneWidget);
      expect(_chars(0), findsOneWidget);
    });

    testWidgets('stays exact across a long run of edits to a large file', (
      tester,
    ) async {
      final content = List.generate(2000, (i) => 'log line $i').join('\n');
      await tester.pumpWidget(
        _app(
          FilePreviewPage(
            filename: 'server.log',
            content: content,
            onSave: (_) {},
          ),
        ),
      );
      await _openEditor(tester);

      var text = content;
      for (var i = 0; i < 20; i++) {
        text = '$text ';
        await _type(tester, text);
      }

      expect(_lines(2000), findsOneWidget);
      expect(_chars(text.length), findsOneWidget);

      /// A newline at the end of the file, after all of those edits.
      /// 在所有上述编辑之后，在文件末尾插入一个换行。
      text = '$text\n';
      await _type(tester, text);
      expect(_lines(2001), findsOneWidget);
      expect(_chars(text.length), findsOneWidget);
    });

    testWidgets('recounts the saved text when edits are discarded', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          FilePreviewPage(
            filename: 'a.conf',
            content: 'one\ntwo',
            onSave: (_) {},
          ),
        ),
      );
      await _openEditor(tester);
      await _type(tester, 'one\ntwo\nthree');
      expect(_lines(3), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t('discard')));
      await tester.pumpAndSettle();

      expect(_lines(2), findsOneWidget);
      expect(_chars(7), findsOneWidget);
    });
  });

  group('unsaved badge', () {
    testWidgets('reads as a state, not as the verb "edit"', (tester) async {
      await tester.pumpWidget(
        _app(
          FilePreviewPage(
            filename: 'a.conf',
            content: 'one\ntwo',
            onSave: (_) {},
          ),
        ),
      );
      await _openEditor(tester);

      /// Nothing is unsaved until the text actually changes.
      /// 文本真正改变之前不属于未保存状态。
      expect(find.text(t('unsaved_changes')), findsNothing);

      await _type(tester, 'one\ntwo\nthree');
      expect(find.text(t('unsaved_changes')), findsOneWidget);

      /// The badge used to carry `t('edit')`, which in edit mode read as the
      /// name of the action performed by the button beside it.
      /// 该徽标此前使用 `t('edit')`，在编辑模式下读起来像是旁边按钮的动作名。
      expect(find.text(t('edit')), findsNothing);

      /// Saving clears it.
      /// 保存后徽标消失。
      await tester.tap(find.byIcon(Icons.save_outlined));
      await tester.pumpAndSettle();
      expect(find.text(t('unsaved_changes')), findsNothing);
    });
  });
}
