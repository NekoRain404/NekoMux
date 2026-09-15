import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/snippet_injection_dialog.dart';

/// [SnippetInjectionDialog] builds its `TextEditingController`s up front and
/// releases them once `showDialog`'s future completes. That placement is what
/// the add/edit snippet dialog got wrong — it released the controllers too
/// early and the fields rebuilt into them as the dialog animated out. These
/// tests check the path the injection dialog actually takes, so its release
/// point is verified rather than assumed.
/// [SnippetInjectionDialog] 先建好 `TextEditingController`，再在 `showDialog` 的
/// future 完成时释放它们。新增/编辑快捷指令的对话框恰恰是在这里出的错——它释放得太
/// 早，退场动画期间输入框重建时又碰到了它们。下面的测试走的是注入对话框实际的路径，
/// 因此它的释放时机是被验证过的，而不是被假定的。

/// Opens the dialog from a plain button. The list returned is filled in with
/// the value the dialog pops with, once it does — the dialog outlives this
/// call, so the result cannot be returned by value.
/// 从一个普通按钮打开对话框。返回的列表会在对话框弹出后填入其结果——对话框比本次
/// 调用存活得更久，因此结果无法按值返回。
Future<List<String?>> _openDialog(
  WidgetTester tester, {
  required String command,
}) async {
  final injected = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              injected.add(await SnippetInjectionDialog.show(context, command));
            },
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return injected;
}

void main() {
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  testWidgets('substitutes the typed values into the command', (tester) async {
    final injected = await _openDialog(tester, command: 'ls [dir] [user]');
    expect(find.text('dir'), findsOneWidget);
    expect(find.text('user'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, '/tmp');
    await tester.enterText(find.byType(TextFormField).last, 'root');
    await tester.pump();

    await tester.tap(find.text(t('inject')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(injected, ['ls /tmp root']);
  });

  testWidgets('returns the command unchanged when it has no placeholders', (
    tester,
  ) async {
    final injected = await _openDialog(tester, command: 'uptime');
    expect(find.byType(TextFormField), findsNothing);
    expect(injected, ['uptime']);
  });

  testWidgets('closes cleanly when the user cancels', (tester) async {
    await _openDialog(tester, command: 'ls [dir] [user]');

    /// Type into the fields first: an untouched field never exercises the
    /// controller on the way out.
    /// 先往输入框里输内容：从未被碰过的输入框在退场时不会走到控制器。
    await tester.enterText(find.byType(TextFormField).first, '/tmp');
    await tester.enterText(find.byType(TextFormField).last, 'root');
    await tester.pump();

    await tester.tap(find.text(t('cancel')));
    await tester.pumpAndSettle();

    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
