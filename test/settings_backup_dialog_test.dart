// Tests for the question Settings → Export Backup asks before it copies
// anything, and for the answer it hands back to the page.
// 「设置 → 导出备份」在复制任何内容之前所提问题、以及它交还页面的答案的测试。
//
// The page acts on this answer alone, so the three cases below are the whole
// difference between a backup that holds no credential and one that holds every
// password in clear:
//   * dismissed  → null  → the page exports nothing;
//   * confirmed  → false → the default, secret-free export;
//   * ticked     → true  → the opt-in export, offered only with the warning on
//                          screen.
// 页面完全依据这个答案行事，因此下面三种情形就决定了备份是不含任何凭据，还是把所有
// 密码明文装进去：
//   * 关闭对话框 → null  → 页面不导出任何内容；
//   * 直接确认   → false → 默认的不含密钥导出；
//   * 勾选后确认 → true  → 显式导出，且只有屏幕上出现警告时才能这样选。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/settings/backup_dialogs.dart';

/// Pumps a button that opens the export dialog, and returns the future the page
/// would be awaiting.
/// 构建一个打开导出对话框的按钮，并返回页面将会等待的那个 future。
Future<Future<bool?>> _openExportDialog(WidgetTester tester) async {
  Future<bool?>? pending;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => pending = showExportSecretsDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(pending, isNotNull, reason: 'the dialog was never opened');
  return pending!;
}

/// The checkbox the user has to tick for an export to carry credentials.
/// 用户必须勾选才能让导出携带凭据的复选框。
Finder _secretsCheckbox() => find.byType(Checkbox);

void main() {
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  testWidgets('the opt-in box starts unticked and the default is spelled out', (
    tester,
  ) async {
    await _openExportDialog(tester);

    expect(find.text(t('export_include_secrets')), findsOneWidget);
    expect(tester.widget<Checkbox>(_secretsCheckbox()).value, isFalse);
    // Before it is ticked the dialog says what the export will *not* contain.
    // 勾选之前，对话框说明导出中*不会*包含什么。
    expect(find.text(t('export_secrets_omitted')), findsOneWidget);
    expect(find.text(t('export_secrets_warning')), findsNothing);
  });

  testWidgets('confirming without ticking exports without credentials', (
    tester,
  ) async {
    final answer = await _openExportDialog(tester);

    await tester.tap(find.text(t('confirm')));
    await tester.pumpAndSettle();

    expect(await answer, isFalse);
  });

  testWidgets('ticking the box swaps in the warning and opts into secrets', (
    tester,
  ) async {
    final answer = await _openExportDialog(tester);

    await tester.tap(_secretsCheckbox());
    await tester.pumpAndSettle();

    expect(tester.widget<Checkbox>(_secretsCheckbox()).value, isTrue);
    expect(find.text(t('export_secrets_warning')), findsOneWidget);
    expect(find.text(t('export_secrets_omitted')), findsNothing);

    await tester.tap(find.text(t('confirm')));
    await tester.pumpAndSettle();

    expect(await answer, isTrue);
  });

  testWidgets('the box can be unticked again before confirming', (
    tester,
  ) async {
    final answer = await _openExportDialog(tester);

    await tester.tap(_secretsCheckbox());
    await tester.pumpAndSettle();
    await tester.tap(_secretsCheckbox());
    await tester.pumpAndSettle();

    expect(find.text(t('export_secrets_omitted')), findsOneWidget);

    await tester.tap(find.text(t('confirm')));
    await tester.pumpAndSettle();

    expect(await answer, isFalse);
  });

  testWidgets('cancelling reports no answer, so nothing is exported', (
    tester,
  ) async {
    final answer = await _openExportDialog(tester);

    await tester.tap(find.text(t('cancel')));
    await tester.pumpAndSettle();

    expect(await answer, isNull);
  });

  testWidgets('dismissing the dialog by tapping outside exports nothing', (
    tester,
  ) async {
    final answer = await _openExportDialog(tester);

    // The barrier — the easy accident this must not read as consent.
    // 点击遮罩——这种最容易发生的误触绝不能被当作同意。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(await answer, isNull);
  });

  testWidgets('the restore dialog returns the pasted text, page parses it', (
    tester,
  ) async {
    Future<String?>? pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => pending = showRestoreBackupDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '{"hosts": []}');
    await tester.tap(find.text(t('restore')));
    await tester.pumpAndSettle();

    expect(await pending, '{"hosts": []}');
  });

  testWidgets('cancelling the restore dialog reports no text', (tester) async {
    Future<String?>? pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => pending = showRestoreBackupDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('cancel')));
    await tester.pumpAndSettle();

    expect(await pending, isNull);
  });
}
