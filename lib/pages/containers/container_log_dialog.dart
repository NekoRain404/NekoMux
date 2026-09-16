// The container log viewer: a loading dialog, then the logs.
// 容器日志查看器：先显示加载对话框，再显示日志。
//
// This is where the "logs close the whole page" defect lived, so the rule is
// spelled out here rather than implied: the loading dialog is pushed as a route
// we hold a reference to, and it is *that* route we take down — never "whatever
// is on top of the page's navigator", which is what `Navigator.pop(context)`
// meant once the back button had already dismissed the spinner.
// 「日志把整个页面关掉」的缺陷就出在这里，因此这条规则在此写明而不是隐含：加载
// 对话框以一条我们持有引用的路由压栈，我们撤下的正是**那一条**——而不是「页面
// 导航器栈顶的那一条」；后者正是返回键已经关掉 spinner 之后
// `Navigator.pop(context)` 的含义。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_fonts.dart';
import '../../core/i18n/strings.dart';

/// Fetches the log text to display; owned by the page, which holds the
/// connection.
/// 取回要展示的日志文本；由持有连接的页面提供。
typedef LogTextLoader = Future<String> Function();

/// The container viewer's old name for [LogTextLoader].
typedef ContainerLogLoader = LogTextLoader;

/// Shows a container's logs. Thin wrapper over [showLogViewer], kept so the
/// container page reads the same as it did.
Future<void> showContainerLogsDialog(
  BuildContext context, {
  required String containerName,
  required ContainerLogLoader loadLogs,
  required VoidCallback onCopied,
}) => showLogViewer(
  context,
  sourceName: containerName,
  loadLogs: loadLogs,
  onCopied: onCopied,
);

/// Shows a loading dialog, loads the text, then replaces it with a log view.
///
/// Used for `docker logs` and for `journalctl` alike: what differs between them
/// is the command the caller runs and the name shown in the title, and both of
/// those are arguments. The behaviour that must not differ — the loading route
/// being the one taken down, the text being selectable and copyable — is
/// therefore written once.
/// 显示加载对话框、载入日志，然后用日志视图替换它。
///
/// [loadLogs] is expected to report its own failures as text (the page turns a
/// missing connection and a failed `docker logs` into a readable line), so the
/// viewer never has to render an exception; the `try` below only keeps the
/// spinner from being stranded if it throws anyway.
/// [loadLogs] 应自行把失败转成文本（页面会把连接缺失与 `docker logs` 失败变成
/// 可读的一行），因此查看器无需渲染异常；下面的 `try` 只是防止它万一抛出时把
/// spinner 永远留在屏幕上。
Future<void> showLogViewer(
  BuildContext context, {
  required String sourceName,
  required LogTextLoader loadLogs,
  required VoidCallback onCopied,
}) async {
  final cs = Theme.of(context).colorScheme;

  final terminalBg = cs.onSurface.withValues(alpha: 0.06);

  // Pushed on the root navigator, exactly where `showDialog` would have put it,
  // with the page's inherited themes captured so the dialog looks the same.
  // 压入根导航器——`showDialog` 原本也会放在那里——并捕获页面继承的主题，
  // 使对话框外观保持不变。
  final navigator = Navigator.of(context, rootNavigator: true);
  final loadingRoute = DialogRoute<void>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: cs.surface,
      title: Text(
        '$sourceName - ${t('logs')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppFonts.monoText(color: cs.onSurface, fontSize: 15),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 300,
        child: Center(child: CircularProgressIndicator(color: cs.primary)),
      ),
    ),
  );

  // Not awaited: the route completes when it is taken down, and this function
  // has to keep running until then.
  // 不等待：该路由在被撤下时才完成，而本函数必须一直运行到那时。
  unawaited(navigator.push(loadingRoute));

  String logText;
  try {
    logText = await loadLogs();
  } catch (e) {
    logText = '${t('error')}: $e';
  }

  // `isActive` is true only while the route is installed *and not already
  // popping*, so this one check covers both cases: the spinner is still up (we
  // take it down, using its own reference, and then show the logs), or the user
  // pressed back and dismissed it (we touch nothing — least of all the page,
  // which a page-context pop would have removed instead).
  // `isActive` 仅在路由仍在栈中**且未处于退出动画**时为真，因此这一个判断同时
  // 覆盖两种情况：spinner 还在（我们用自己持有的引用撤下它，然后展示日志），
  // 或者用户按了返回已经关掉它（我们什么都不碰——尤其是页面本身，而使用页面
  // context 的 pop 恰好会把它一并关掉）。
  final spinnerStillShowing = loadingRoute.isActive;
  if (spinnerStillShowing) {
    loadingRoute.navigator?.removeRoute(loadingRoute);
  }
  if (!spinnerStillShowing || !context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: cs.surface,
      title: Row(
        children: [
          Expanded(
            child: Text(
              '$sourceName - ${t('logs')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.monoText(color: cs.onSurface, fontSize: 15),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.copy,
              color: cs.onSurface.withValues(alpha: 0.6),
              size: 18,
            ),
            tooltip: t('copy'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: logText));
              onCopied();
            },
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 300,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: terminalBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.7),
            ),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              logText,
              style: AppFonts.monoText(
                color: cs.onSurface,
                fontSize: 11,
                height: 1.6,
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t('close'), style: TextStyle(color: cs.secondary)),
        ),
      ],
    ),
  );
}
