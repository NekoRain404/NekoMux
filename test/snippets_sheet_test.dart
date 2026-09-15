import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/snippet.dart';
import 'package:neko_mux/pages/terminal/snippets_sheet.dart';
import 'package:neko_mux/providers/providers.dart';
import 'package:neko_mux/widgets/app_ui.dart';

/// Snippet notifier whose [build] stays pending until the test releases it,
/// which is what a cold start looks like: nothing has read the provider yet.
/// 片段通知器：其 [build] 会一直挂起直到测试释放，这正是冷启动的样子——
/// 还没有任何代码读过该 provider。
class _PendingSnippets extends SnippetListNotifier {
  _PendingSnippets(this.gate);

  final Completer<List<Snippet>> gate;

  @override
  Future<List<Snippet>> build() => gate.future;
}

/// Notifier that resolves immediately with [snippets].
/// 立即以 [snippets] 解析的通知器。
class _FixedSnippets extends SnippetListNotifier {
  _FixedSnippets(this.snippets);

  final List<Snippet> snippets;

  @override
  Future<List<Snippet>> build() async => snippets;
}

const _nginx = Snippet(
  id: 's1',
  title: 'Restart nginx',
  command: 'systemctl restart nginx',
);

void main() {
  /// Pumps [SnippetsSheet] the way the terminal page shows it — inside a modal
  /// bottom sheet pushed from another route — so the pop in its tap handlers
  /// has a route to pop.
  /// 按终端页面的方式渲染 [SnippetsSheet]——由另一个路由推入的模态底部面板——
  /// 使其点击处理函数里的 pop 有路由可关。
  Future<void> pumpSheet(
    WidgetTester tester, {
    required SnippetListNotifier Function() notifier,
    required void Function(Snippet) onSnippetTap,
    required VoidCallback onManageTap,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [snippetListProvider.overrideWith(notifier)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => SnippetsSheet(
                    height: 400,
                    onSnippetTap: onSnippetTap,
                    onManageTap: onManageTap,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // Not `pumpAndSettle`: while the list is still pending the sheet shows a
    // spinner, and a spinner never settles.
    // 不能用 `pumpAndSettle`：列表仍挂起时面板显示的是转圈指示器，而转圈永远不会
    // 安定下来。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the sheet leaves its spinner behind once the list resolves', (
    tester,
  ) async {
    final gate = Completer<List<Snippet>>();

    await pumpSheet(
      tester,
      notifier: () => _PendingSnippets(gate),
      onSnippetTap: (_) {},
      onManageTap: () {},
    );

    // The state the first tap of `{}` on a cold start used to freeze on: the
    // provider has not resolved, and the sheet must still be able to react when
    // it does — a snapshot taken by the caller could not.
    // 冷启动时第一次点 `{}` 会冻结住的状态：provider 尚未解析，而面板必须在它
    // 解析后仍能反应——调用方抓取的快照做不到这一点。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete(const <Snippet>[_nginx]);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Restart nginx'), findsOneWidget);
    expect(find.text('systemctl restart nginx'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty list shows the empty state, not a spinner', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      notifier: () => _FixedSnippets(const []),
      onSnippetTap: (_) {},
      onManageTap: () {},
    );

    expect(find.byType(AppEmptyState), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('tapping a snippet closes the sheet and hands it to the page', (
    tester,
  ) async {
    Snippet? picked;

    await pumpSheet(
      tester,
      notifier: () => _FixedSnippets(const [_nginx]),
      onSnippetTap: (snippet) => picked = snippet,
      onManageTap: () {},
    );

    await tester.tap(find.text('Restart nginx'));
    await tester.pumpAndSettle();

    expect(picked?.id, 's1');
    expect(find.byType(SnippetsSheet), findsNothing);
  });

  testWidgets('the manage button closes the sheet before opening the manager', (
    tester,
  ) async {
    var managed = 0;

    await pumpSheet(
      tester,
      notifier: () => _FixedSnippets(const [_nginx]),
      onSnippetTap: (_) {},
      onManageTap: () => managed++,
    );

    await tester.tap(find.textContaining('→'));
    await tester.pumpAndSettle();

    expect(managed, 1);
    expect(find.byType(SnippetsSheet), findsNothing);
  });
}
