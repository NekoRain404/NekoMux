import 'package:flutter/material.dart';

import '../../core/theme/app_fonts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/i18n/strings.dart';
import '../../models/snippet.dart';
import '../../providers/providers.dart';
import '../../widgets/app_ui.dart';

/// Content of the snippet sheet opened by the terminal's `{}` key.
/// 终端 `{}` 键打开的代码片段面板内容。
///
/// This is a [ConsumerWidget] on purpose. The provider has to be watched *by
/// the sheet*, not read once in the tap callback that opens it:
/// `showModalBottomSheet`'s builder is a plain function, so anything captured
/// before the sheet is pushed is a snapshot that can never change again. On a
/// cold start (launch → hosts → terminal → first tap of `{}`) the snippet list
/// has not been read by anything yet, so that snapshot is `AsyncLoading` — and
/// the sheet then sat on a spinner forever until it was closed and reopened.
/// 这里必须用 [ConsumerWidget]：provider 要由**面板自己**监听，而不是在打开面板的
/// 点击回调里读一次——`showModalBottomSheet` 的 builder 是普通函数，推入面板之前
/// 捕获到的值只是一份永不再变的快照。冷启动路径（启动 → 主机 → 终端 → 第一次点
/// `{}`）中还没有任何代码读过片段列表，因此这份快照就是 `AsyncLoading`，面板也就
/// 永远停在转圈上，直到关掉再打开一次。
class SnippetsSheet extends ConsumerWidget {
  /// Height the sheet occupies, resolved by the caller from the viewport.
  /// 面板占用的高度，由调用方依据视口解析。
  final double height;

  /// Called after the sheet has popped itself, with the snippet the user picked.
  /// 面板自行关闭之后调用，参数为用户选中的片段。
  ///
  /// The caller runs this from its own context: the dialog it opens next must
  /// outlive the sheet, whose context is already defunct at that point.
  /// 调用方用自己的 context 执行：随后打开的对话框必须比面板活得更久，而那一刻
  /// 面板的 context 已经失效。
  final void Function(Snippet snippet) onSnippetTap;

  /// Called after the sheet has popped itself, when the user asks for the
  /// snippet manager.
  /// 面板自行关闭之后调用，表示用户要求打开片段管理页。
  final VoidCallback onManageTap;

  const SnippetsSheet({
    super.key,
    required this.height,
    required this.onSnippetTap,
    required this.onManageTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    final snippetsAsync = ref.watch(snippetListProvider);

    return SafeArea(
      child: SizedBox(
        height: height,
        child: snippetsAsync.when(
          loading: () =>
              Center(child: CircularProgressIndicator(color: cs.primary)),
          error: (e, _) => Center(
            child: Text(
              t('error'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ),
          data: (snippets) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        t('snippets'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        onManageTap();
                      },
                      child: Text(
                        '${t('manage_snippets')} →',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: cs.secondary, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              if (snippets.isEmpty)
                Expanded(
                  child: AppEmptyState(
                    icon: Icons.description_outlined,
                    title: t('empty_snippets'),
                    message: t('empty_snippets_hint'),
                    color: cs.primary,
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: snippets.length,
                    itemBuilder: (_, i) {
                      final snippet = snippets[i];
                      return AppCard(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        borderColor: dividerColor,
                        onTap: () {
                          Navigator.pop(context);
                          onSnippetTap(snippet);
                        },
                        child: Row(
                          children: [
                            AppIconBox(
                              icon: Icons.code,
                              color: cs.primary,
                              size: 36,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    snippet.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: cs.onSurface,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    snippet.command,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: cs.onSurface.withValues(
                                        alpha: 0.6,
                                      ),
                                      fontSize: 11,
                                      fontFamily: AppFonts.mono,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.send_outlined,
                              color: cs.secondary,
                              size: 18,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
