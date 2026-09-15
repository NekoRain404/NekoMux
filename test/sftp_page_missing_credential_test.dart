import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/pages/sftp_page.dart';
import 'package:neko_mux/providers/providers.dart';

/// What the file manager does when the credential behind its host is gone.
/// 当主机背后的凭据已经不存在时，文件管理器会怎么做。
///
/// The page reaches its error state without ever holding a service, and the app
/// bar still draws refresh over that state. Tapping it used to throw a `TypeError`
/// from the null check inside `_loadDirectory`, which the page's own `catch`
/// turned into "List failed: Null check operator used on a null value" — the one
/// message that told the user what to fix, replaced by one that says nothing.
/// 页面进入错误状态时根本没有持有服务，而应用栏在那张错误页上照样画着刷新按钮。点击它
/// 此前会让 `_loadDirectory` 里的空检查抛出 `TypeError`，再由页面自己的 `catch` 变成
/// 「列举失败: Null check operator used on a null value」——唯一告诉用户该修什么的那句话，
/// 被一句什么都没说的替代了。

/// A credential list that never has anything in it: the host below points at a
/// credential the user has deleted.
/// 永远为空的凭据列表：下面这台主机指向一个已被用户删除的凭据。
class _NoCredentials extends CredentialListNotifier {
  @override
  Future<List<Credential>> build() async => const <Credential>[];
}

final _host = Host(
  id: 'h1',
  alias: 'alpha',
  ipAddress: '10.0.0.1',
  port: 22,
  credentialId: 'deleted-credential',
);

Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [credentialListProvider.overrideWith(_NoCredentials.new)],
      child: MaterialApp(home: SftpPage(host: _host)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  testWidgets('the error page names the missing credential', (tester) async {
    await _pumpPage(tester);

    expect(find.text(t('credential_not_found')), findsOneWidget);
  });

  testWidgets('tapping refresh keeps that diagnosis', (tester) async {
    await _pumpPage(tester);

    // The app bar's refresh, which is the one drawn over the error page (the
    // button inside the page is Retry, and carries no tooltip).
    // 应用栏上的刷新，也就是画在错误页上的那一个（页面里的按钮是「重试」，没有 tooltip）。
    await tester.tap(find.byTooltip(t('refresh')));
    await tester.pumpAndSettle();

    expect(
      find.text(t('credential_not_found')),
      findsOneWidget,
      reason: 'the user still has to be told which credential to fix',
    );
    expect(find.textContaining('Null check'), findsNothing);
  });
}
