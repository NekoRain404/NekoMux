import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';

/// What the file manager shows when it is not showing a listing.
/// 文件管理器在不显示列表时所显示的内容。
///
/// Two states, and the page decides which one it is in: the spinner while the
/// session opens, and the full-page error for a page that has nothing to list —
/// a credential the user deleted, a host that refused the connection.
/// 两种状态，由页面判断自己处在哪一种：会话打开时的转圈，以及对一个无内容可列出的页面
/// （用户删掉的凭据、拒绝连接的主机）显示的整页错误。
///
/// Extracted from the page because it is the one part of it that owns no state and
/// calls no service: it renders the two facts it is handed and reports the one tap
/// that leaves them. The page keeps the decision of *when* a listing is missing,
/// which is the part that needs the listing.
/// 它之所以从页面中抽出，是因为它是页面里唯一既不持有状态、也不调用服务的部分：它只渲染
/// 收到的两个事实，并上报唯一一个能离开这两个状态的点击。「何时算没有列表」的判断仍留在
/// 页面里，那才是需要列表的那一半。
class SftpStatusView extends StatelessWidget {
  /// Whether the session is still opening.
  /// 会话是否仍在打开中。
  final bool isConnecting;

  /// Why there is no listing, when that is the state being shown.
  /// 为什么没有列表——在显示的正是这个状态时。
  final String? errorMessage;

  /// Retrying from the error state: drop the old session, connect again.
  /// 从错误状态重试：断开旧会话，重新连接。
  final VoidCallback onRetry;

  const SftpStatusView({
    super.key,
    required this.isConnecting,
    required this.errorMessage,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final message = errorMessage;
    if (!isConnecting && message == null) return const SizedBox.shrink();

    return isConnecting ? _connecting(cs) : _failed(context, cs, message!);
  }

  /// The spinner, with the one word that says what is being waited on.
  /// 转圈，以及说明在等什么的那一个词。
  Widget _connecting(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: cs.secondary),
          const SizedBox(height: 16),
          Text(
            t('connecting'),
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  /// The reason, with the way out of it underneath.
  /// 给出原因，其下是离开它的出口。
  ///
  /// Scrollable, with a six-line cap on the text: a server's own complaint can be
  /// longer than the screen, and a long message in a fixed box would otherwise be
  /// an overflow error raised over the very page that was reporting a failure.
  /// 可滚动，文字上限六行：服务器自己的抱怨可能比屏幕还长，而长消息放在固定框里，否则
  /// 会在正报告失败的页面上抛出溢出错误。
  Widget _failed(BuildContext context, ColorScheme cs, String message) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 56, color: cs.error),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(
                t('retry'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: cs.secondary,
                foregroundColor: Theme.of(context).scaffoldBackgroundColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
