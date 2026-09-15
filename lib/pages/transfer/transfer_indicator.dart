// The two small surfaces that say "a transfer is happening" without the list.
// 两个小界面，用来在列表之外说明「有传输正在进行」。
//
// Both are entry points to the transfer sheet, and neither owns a transfer: what
// they show is read from the queue, which outlives the page they are drawn on.
// 两者都是传输面板的入口，也都拥有不了任何传输：它们显示的内容来自队列，而队列比绘制
// 它们的页面更长寿。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/strings.dart';
import '../../providers/transfer_provider.dart';
import '../../widgets/app_ui.dart';
import 'transfer_format.dart';

/// The app-bar entry point: how many tasks the queue holds, or nothing at all.
/// 应用栏入口：队列中有多少任务；一个都没有时什么都不显示。
///
/// It watches the *count* rather than the list, so the icon is not rebuilt on
/// every progress tick — the bar below is where movement belongs, and the app
/// bar is not a progress indicator.
/// 它监听的是**数量**而不是列表，因此图标不会因为每一次进度跳动而重建——变化属于下方
/// 的那根条，应用栏不是进度指示器。
class TransferQueueButton extends ConsumerWidget {
  /// Opening the transfer list.
  /// 打开传输列表。
  final VoidCallback onOpen;

  const TransferQueueButton({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final count = ref.watch(
      transferQueueProvider.select((tasks) => tasks.length),
    );
    if (count == 0) return const SizedBox.shrink();

    return IconButton(
      tooltip: t('transfer_title'),
      onPressed: onOpen,
      icon: Badge.count(
        count: count,
        backgroundColor: cs.secondary,
        textColor: Theme.of(context).scaffoldBackgroundColor,
        child: Icon(
          Icons.swap_vert,
          color: cs.onSurface.withValues(alpha: 0.72),
          size: 22,
        ),
      ),
    );
  }
}

/// A slim bar above the file list, shown only while a transfer is moving bytes.
/// 文件列表上方的细条，仅在有传输正在搬运字节时显示。
///
/// It exists because the file list is not the only place the user goes: a
/// transfer started here keeps running while they browse elsewhere in the app,
/// and this is the part of the file manager that keeps saying so. It is also the
/// way back to the list, hence the whole bar being tappable rather than a button
/// inside it.
/// 它存在的理由：文件列表不是用户唯一会去的地方；在这里发起的传输会在他们浏览应用
/// 其它部分时继续运行，而文件管理器中一直说明这一点的就是这根条。它同时也是回到列表
/// 的路径，因此整根条都可点击，而不是在条里放一个按钮。
///
/// Watching the whole queue here is deliberate: this widget's single job is to
/// move, and it rebuilds only itself — the page and the file list around it are
/// not listening to the queue at all.
/// 这里监听整条队列是有意的：本控件唯一的职责就是动起来，而它只重建自己——它周围的
/// 页面与文件列表根本没有监听队列。
class TransferActivityBar extends ConsumerWidget {
  /// Opening the transfer list.
  /// 打开传输列表。
  final VoidCallback onOpen;

  const TransferActivityBar({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final tasks = ref.watch(transferQueueProvider);
    final active = activeTransfers(tasks);
    if (active.isEmpty) return const SizedBox.shrink();

    final first = active.first;
    final progress = activeTransferProgress(tasks);
    // The name of the task that started first, so the bar names something the
    // user can recognise rather than just counting.
    // 最先开始的那个任务的名字，让这根条说出用户认得出的东西，而不只是在计数。
    final label = first.name.isEmpty
        ? t('transfer_title')
        : '${t('transfer_title')} · ${first.name}';

    return Material(
      color: cs.secondary.withValues(alpha: 0.08),
      child: InkWell(
        onTap: onOpen,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIconBox(
                    icon: transferTaskIcon(first),
                    color: cs.secondary,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.78),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (active.length > 1) ...[
                    const SizedBox(width: 8),
                    AppBadge(label: '${active.length}', color: cs.secondary),
                  ],
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  // Null is the indeterminate case and Flutter renders it as
                  // such; a 0 here would claim the transfer has moved nothing.
                  // null 即不确定态，Flutter 会据此渲染；填 0 等于宣称传输一字节未动。
                  value: progress,
                  minHeight: 3,
                  backgroundColor: cs.onSurface.withValues(alpha: 0.08),
                  valueColor: AlwaysStoppedAnimation<Color>(cs.secondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
