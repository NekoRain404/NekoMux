import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/sftp/sftp_dialogs.dart';

/// `showSftpNameDialog` documents one contract and relies on it: **null covers
/// cancelled, blank and unchanged**.
/// `showSftpNameDialog` 记录了一条约定并依赖它：**null 覆盖取消、留空与未修改**。
///
/// The last of the three is the one with teeth — the callers are rename and
/// new-entry paths, and a name equal to the one the file already has would be
/// issued as a rename onto itself. Nothing tested it: the dialog is a widget,
/// so the rule could only be checked through the dialog itself, which is what
/// these tests do.
/// 三者中的最后一条最有分量——调用方是重命名与新建条目的路径，而与被操作文件同名的
/// 名称会被当作一次「重命名到自己身上」执行。此前无人测试它：该对话框是一个 widget，
/// 因此这条规则只能经由对话框本身来检查，这正是下面这些测试所做的。

/// Opens the dialog from a plain button and collects the value it pops with.
/// 从一个普通按钮打开对话框，并收集它弹出时带出的值。
///
/// The dialog outlives this call, so the result cannot be returned by value.
/// 对话框比本次调用存活得更久，因此结果无法按值返回。
Future<List<String?>> _openDialog(
  WidgetTester tester, {
  String initial = '',
}) async {
  final popped = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              popped.add(
                await showSftpNameDialog(
                  context,
                  title: 'Name',
                  hint: 'name',
                  confirmLabel: 'OK',
                  initial: initial,
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return popped;
}

/// Types [text] into the dialog's field and presses its confirm button.
/// 在对话框的输入框中键入 [text]，然后按下确认按钮。
Future<void> _confirmWith(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  testWidgets('returns the name the user typed', (tester) async {
    final popped = await _openDialog(tester);

    await _confirmWith(tester, 'notes.txt');

    expect(popped, ['notes.txt']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('trims what it returns', (tester) async {
    // The callers join the name onto a path, so a stray space would become part
    // of the remote file name.
    // 调用方会把该名称拼到路径上，因此多余的空格会变成远端文件名的一部分。
    final popped = await _openDialog(tester);

    await _confirmWith(tester, '  notes.txt  ');

    expect(popped, ['notes.txt']);
  });

  testWidgets('returns null when the user cancels', (tester) async {
    final popped = await _openDialog(tester, initial: 'old.txt');

    await tester.tap(find.text(t('cancel')));
    await tester.pumpAndSettle();

    expect(popped, [null]);
  });

  testWidgets('returns null for a blank name', (tester) async {
    // Blank means "nothing to do", not "create a file called ''".
    // 留空表示「无事可做」，而不是「创建一个名为 '' 的文件」。
    final popped = await _openDialog(tester);

    await _confirmWith(tester, '   ');

    expect(popped, [null]);
  });

  testWidgets('returns null for an unchanged name', (tester) async {
    // The rename path would otherwise rewrite the file onto itself — and the
    // user gets no dialog saying nothing happened, so the only evidence would
    // be a file that briefly stopped existing.
    // 否则重命名路径会把文件覆盖到它自己身上——而用户不会看到任何「什么也没发生」的
    // 提示，唯一的迹象会是一个短暂消失过的文件。
    final popped = await _openDialog(tester, initial: 'old.txt');

    await _confirmWith(tester, 'old.txt');

    expect(popped, [null]);
  });

  testWidgets('returns null for an unchanged name with stray whitespace', (
    tester,
  ) async {
    // The comparison has to be against the same trimmed text the return value
    // would use; comparing the raw text would treat `old.txt ` as a rename.
    // 比较必须使用与返回值相同的、已去空白的文本；比较原始文本会把 `old.txt ` 当成
    // 一次重命名。
    final popped = await _openDialog(tester, initial: 'old.txt');

    await _confirmWith(tester, '  old.txt ');

    expect(popped, [null]);
  });

  testWidgets('returns a genuinely different name', (tester) async {
    final popped = await _openDialog(tester, initial: 'old.txt');

    await _confirmWith(tester, 'new.txt');

    expect(popped, ['new.txt']);
  });
}
