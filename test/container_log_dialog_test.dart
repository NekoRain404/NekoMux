import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/pages/containers/container_log_dialog.dart';

/// A stand-in for the container page.
/// 容器页的替身。
///
/// The log viewer needs nothing but a context, a container name and a loader,
/// so it can be driven here without an SSH connection: the loader is a
/// [Completer] the test releases when it wants the logs to "arrive".
/// 日志查看器只需要 context、容器名和一个加载函数，因此这里无需 SSH 连接即可驱动：
/// 加载函数是一个 [Completer]，由测试决定日志何时「到达」。
class _HostPage extends StatelessWidget {
  const _HostPage({required this.loadLogs});

  final ContainerLogLoader loadLogs;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            /// Present exactly while this route is on the stack: the whole
            /// point of the test below is that it survives.
            /// 该路由在栈上时才存在：下面测试的全部意义就是它能存活。
            const Text('host-page'),
            TextButton(
              onPressed: () => showContainerLogsDialog(
                context,
                containerName: 'error-logger',
                loadLogs: loadLogs,
                onCopied: () {},
              ),
              child: Text(t('logs')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pushes [_HostPage] as a second route, so "the page was popped" is
/// observable rather than indistinguishable from an empty navigator.
/// 以第二个路由压入 [_HostPage]，这样「页面被 pop 掉」才是可观测的，
/// 而不是与空导航器无法区分。
Future<void> _pumpHostPage(
  WidgetTester tester,
  ContainerLogLoader loadLogs,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _HostPage(loadLogs: loadLogs),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  expect(find.text('host-page'), findsOneWidget);
}

/// The Android back button, as `WidgetsApp` receives it.
/// Android 返回键，即 `WidgetsApp` 实际收到的那个事件。
Future<void> _pressBack(WidgetTester tester) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    const MethodCall('popRoute'),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
  // The spinner animates forever, so settle only once the dialog is gone.
  // spinner 会一直动画，因此只在对话框消失之后再 settle。
  await tester.pumpAndSettle();
}

/// Opens the viewer and waits for its spinner.
/// 打开查看器并等待其 spinner 出现。
Future<void> _openLogs(WidgetTester tester) async {
  await tester.tap(find.text(t('logs')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => AppStrings.setLang('en'));
  tearDown(() => AppStrings.setLang('zh'));

  testWidgets('back during loading does not pop the page that asked for the '
      'logs', (tester) async {
    final gate = Completer<String>();
    await _pumpHostPage(tester, () => gate.future);
    await _openLogs(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // The user gives up waiting and presses back. `barrierDismissible: false`
    // does not stop this, which is why the loading dialog's own route is held
    // and taken down instead of "whatever is on top".
    // 用户等不下去按了返回。`barrierDismissible: false` 挡不住它，因此这里持有加载
    // 对话框自己的路由并撤下它，而不是去 pop「栈顶的那一个」。
    await _pressBack(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    gate.complete('log line one');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    /// The defect: the page context's `Navigator.pop` removed the container
    /// page itself, bouncing the user back to the host console.
    /// 缺陷所在：使用页面 context 的 `Navigator.pop` 把容器页本身移除了，
    /// 用户被弹回主机控制台。
    expect(find.text('host-page'), findsOneWidget);

    /// And a dismissed spinner does not turn into a dialog the user did not ask
    /// for any more.
    /// 被关掉的 spinner 也不该变成用户已经不再想要的对话框。
    expect(find.text('log line one'), findsNothing);
  });

  testWidgets('the spinner is replaced by the logs when they arrive', (
    tester,
  ) async {
    final gate = Completer<String>();
    await _pumpHostPage(tester, () => gate.future);
    await _openLogs(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete('log line one');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('log line one'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('host-page'), findsOneWidget);
  });

  testWidgets('the loader failing turns into text, not a stranded spinner', (
    tester,
  ) async {
    final gate = Completer<String>();
    await _pumpHostPage(tester, () => gate.future);
    await _openLogs(tester);

    gate.completeError(Exception('ssh went away'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The viewer stays usable: the failure is shown where the logs would be.
    // 查看器仍然可用：失败信息显示在日志本该出现的位置。
    expect(find.textContaining('ssh went away'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('host-page'), findsOneWidget);
  });
}
