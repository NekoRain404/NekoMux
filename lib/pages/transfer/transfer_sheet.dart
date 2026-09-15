// The transfer list: every queued, running and finished task, one row each.
// 传输列表：每个排队中、进行中和已结束的任务各一行。
//
// It is a modal sheet rather than a page because it is opened *over* whatever
// the user was doing and is expected to be dismissed again — the file manager
// keeps its place underneath, and a transfer does not need the screen to itself.
// 它是模态面板而不是页面，因为它是**叠加**在用户当时所做的事情之上打开的，并且预期会
// 被关掉——文件管理器在下方保持原位，而一次传输不需要独占屏幕。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/strings.dart';
import '../../models/transfer_task.dart';
import '../../providers/transfer_provider.dart';
import '../../widgets/app_ui.dart';
import 'transfer_format.dart';
import 'transfer_io.dart';

/// Shows the transfer list over the current page.
/// 在当前页面之上显示传输列表。
Future<void> showTransferSheet(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: cs.surface,
    showDragHandle: true,
    // A queue can be longer than half a screen; without this the sheet is capped
    // at half the screen's height whatever its content asks for.
    // 队列可能比半屏更长；没有这一项，无论内容想要多高，面板都会被压在半屏以内。
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (_) => const TransferSheet(),
  );
}

/// What the sheet's skeleton depends on: which rows exist, and whether anything
/// can be cleared.
/// 面板骨架所依赖的东西：存在哪些行，以及是否有内容可清除。
///
/// A value type so `select` can compare two of them: watching the task list
/// directly would rebuild the whole sheet on every progress tick of every task,
/// which is exactly what the per-row `transferTaskProvider` exists to avoid.
/// 值类型，使 `select` 能对两个实例做比较：直接监听任务列表会让每个任务的每一次进度
/// 跳动都重建整个面板，而这正是逐行的 `transferTaskProvider` 所要避免的。
@immutable
class TransferSheetView {
  /// Ids of the rows to draw, in queue order.
  /// 要绘制的行的 id，按队列顺序。
  final List<String> taskIds;

  /// Whether at least one task has stopped, so "clear finished" has work to do.
  /// 是否至少有一个任务已停止，即「清除已结束」有活可干。
  final bool hasFinished;

  const TransferSheetView(this.taskIds, this.hasFinished);

  /// The view of [tasks].
  /// [tasks] 对应的视图。
  factory TransferSheetView.of(List<TransferTask> tasks) => TransferSheetView([
    for (final task in tasks) task.id,
  ], tasks.any((task) => task.isTerminal));

  @override
  bool operator ==(Object other) =>
      other is TransferSheetView &&
      other.hasFinished == hasFinished &&
      listEquals(other.taskIds, taskIds);

  @override
  int get hashCode => Object.hash(Object.hashAll(taskIds), hasFinished);
}

/// The list of transfers, with the action that clears what has stopped.
/// 传输列表，以及清除已结束任务的操作。
class TransferSheet extends ConsumerWidget {
  const TransferSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(transferQueueProvider.select(TransferSheetView.of));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t('transfer_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: view.hasFinished
                      ? () => _clearFinished(ref)
                      : null,
                  icon: const Icon(Icons.playlist_remove, size: 18),
                  label: Text(
                    t('transfer_clear_finished'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: view.taskIds.isEmpty
                  ? const _EmptyQueue()
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 4),
                      itemCount: view.taskIds.length,
                      itemBuilder: (_, index) =>
                          TransferTaskRow(taskId: view.taskIds[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Clears every stopped row, and releases the staged bytes those rows were the
  /// only handle on.
  /// 清除所有已停止的行，并释放那些行曾是其唯一把手的暂存字节。
  ///
  /// A row is the only place that offers to save its staged file, so dismissing
  /// the row and keeping the file would leave bytes on the user's storage that
  /// nothing in this app can reach again — and a batch download is exactly the
  /// case where that adds up. Read before clearing, because afterwards nothing
  /// names those files any more.
  /// 行是唯一提供保存其暂存文件的地方，因此关闭行却留着文件，只会在用户的存储上留下本应用
  /// 再也够不着的字节——而批量下载正是这种事情会累积起来的情形。先读后清，因为清除之后
  /// 就再没有东西指向那些文件了。
  void _clearFinished(WidgetRef ref) {
    final finished = ref
        .read(transferQueueProvider)
        .where((task) => task.isTerminal)
        .toList();
    ref.read(transferQueueProvider.notifier).clearFinished();
    unawaited(discardStagedFiles(finished));
  }
}

/// Shown when nothing has been queued, or after everything has been cleared.
/// 没有任何任务入队时显示，或清空之后显示。
///
/// Deliberately not the app's full empty state: the sheet already carries the
/// title `transfer_title` in its header, and a second copy of it a centimetre
/// below would read as a rendering fault rather than as an empty list. What is
/// left to say is that there is nothing here.
/// 刻意不用应用完整的空状态：面板顶部已经有 `transfer_title` 这个标题，再在下方一厘米处
/// 重复一遍会被读成渲染故障，而不是空列表。剩下要说的只有「这里什么都没有」。
class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.swap_vert,
            size: 40,
            color: cs.onSurface.withValues(alpha: 0.24),
          ),
          const SizedBox(height: 10),
          Text(
            t('no_data'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.56),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// One task, watching only itself so that another task's progress cannot make
/// this row rebuild.
/// 单个任务，只监听自身，因此别的任务的进度不会让本行重建。
class TransferTaskRow extends ConsumerWidget {
  /// Id of the task this row draws.
  /// 本行绘制的任务的 id。
  final String taskId;

  const TransferTaskRow({super.key, required this.taskId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Null once the task is removed: the row is then gone too, which is what
    // makes removing a running task take effect immediately instead of at the
    // next publication.
    // 任务被移除后为 null：此时整行也随之消失，这正是移除一个进行中的任务能立即生效，
    // 而不是等到下一次发布的原因。
    final task = ref.watch(transferTaskProvider(taskId));
    if (task == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final notifier = ref.read(transferQueueProvider.notifier);
    final isMoving =
        task.status == TransferStatus.queued ||
        task.status == TransferStatus.running;

    return AppCard(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIconBox(
                icon: transferTaskIcon(task),
                color: transferStatusColor(task.status, cs),
                size: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${transferDirectionLabel(task.direction)} · '
                      '${transferStatusLabel(task.status)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: transferStatusColor(task.status, cs),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              // `progress` is null exactly when the size is unknown, and null is
              // what Flutter draws as the indeterminate animation. Passing 0
              // instead would show a stuck bar that claims to know how far along
              // the transfer is.
              // `progress` 恰在大小未知时为 null，而 null 正是 Flutter 绘制为不确定
              // 动画的取值。若传 0，就会显示一根卡住的进度条，声称自己知道传输走到了哪。
              value: task.progress,
              minHeight: 4,
              backgroundColor: cs.onSurface.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(
                transferStatusColor(task.status, cs),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // The byte line has a line of its own rather than sharing the top row
          // with the name: an inflexible line ending in "· Unknown size" is
          // wider than a narrow phone in some of this app's eight languages, and
          // a `Row` whose inflexible children do not fit overflows instead of
          // ellipsizing. Here it is the only thing on its line, so it can only
          // ever be truncated, never fatal.
          // 字节行独占一行，而不是与名称共用顶行：以「· 大小未知」结尾的不可伸缩文本，
          // 在本应用支持的八种语言里，有些比窄屏手机还宽；而 `Row` 中不可伸缩的子项放不下
          // 时是溢出，不是省略号。放在这里它独占一行，最多被截断，绝不会成为错误。
          Text(
            transferProgressLine(task),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.55),
              fontSize: 11.5,
            ),
          ),
          if (task.status == TransferStatus.failed) ...[
            const SizedBox(height: 4),
            Text(
              transferFailureText(task),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.error, fontSize: 11.5),
            ),
          ],
          const SizedBox(height: 4),
          // A wrapping row rather than a fixed one: a finished download carries
          // three actions, and three labels do not fit on one phone-width line
          // in every language this app ships.
          // 用可换行的行，而不是固定的一行：已完成的下载带三个操作，而在这个应用支持的
          // 每一种语言里，三个标签都塞不进手机宽度的一行。
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 2,
              runSpacing: 2,
              children: [
                if (isMoving)
                  _RowAction(
                    icon: Icons.close,
                    label: t('cancel'),
                    color: cs.onSurface.withValues(alpha: 0.62),
                    onTap: () => notifier.cancel(task.id),
                  )
                else ...[
                  _RowAction(
                    icon: Icons.refresh,
                    label: t('transfer_retry'),
                    color: cs.secondary,
                    onTap: () => notifier.retry(task.id),
                  ),
                  _RowAction(
                    icon: Icons.delete_outline,
                    label: t('delete'),
                    color: cs.error,
                    onTap: () {
                      notifier.remove(task.id);
                      // Dismissing the row is also what lets go of the file it
                      // was the only handle on; fire-and-forget, so the row
                      // disappears on the tap rather than on the unlink.
                      // 关闭这一行，同时也是放掉那个只有它才指向的文件；即发即忘，
                      // 因此行在点击时消失，而不是等到文件被删除。
                      unawaited(discardStagedFile(task));
                    },
                  ),
                  // Only a download that finished has something to hand to the
                  // save dialog. An upload's bytes are already on the server and
                  // a failed or cancelled one has no complete file to publish.
                  // 只有已完成的下载才有东西可以交给保存对话框。上传的字节已经在服务器
                  // 上，而失败或取消的任务没有完整文件可供交付。
                  if (task.status == TransferStatus.done &&
                      task.direction == TransferDirection.download &&
                      task.localPath != null)
                    _RowAction(
                      icon: Icons.save_alt,
                      label: t('save'),
                      color: cs.primary,
                      onTap: () => _saveToDevice(context, task),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Asks where to put [task]'s staged file and reports what happened.
  /// 询问 [task] 的暂存文件放在哪里，并报告结果。
  Future<void> _saveToDevice(BuildContext context, TransferTask task) async {
    final outcome = await saveTransferToDevice(task);
    // The save dialog is the platform's, so this row can be gone by the time it
    // closes — the user is free to dismiss the sheet behind it. `context.mounted`
    // is the same guard `mounted` is, for a context that a State does not own.
    // 保存对话框属于平台，因此它关闭时本行可能已经不存在——用户完全可以在它背后关掉
    // 面板。`context.mounted` 就是 `mounted` 那道守卫，只是针对不属于 State 的 context。
    if (!context.mounted) return;

    switch (outcome) {
      case TransferSaveOutcome.saved:
        _snack(context, t('file_saved'));
      case TransferSaveOutcome.cancelled:
        // The user closed the dialog. Saying so would be noise.
        // 用户关掉了对话框。再说一句只是噪音。
        break;
      case TransferSaveOutcome.tooLarge:
        _snack(context, t('file_too_large'), isError: true);
      case TransferSaveOutcome.missing:
      case TransferSaveOutcome.failed:
        _snack(context, t('transfer_error_local_io'), isError: true);
    }
  }
}

/// One small text action inside a transfer row.
/// 传输行内的小型文字操作。
class _RowAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _RowAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: color),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// A one-line report over whatever is on screen.
/// 屏幕内容之上的一行提示。
///
/// Deliberately the same shape the file manager's own snackbars have, so a
/// report about a transfer does not look like it came from a different app.
/// 刻意与文件管理器自身的浮层提示保持相同形态，使关于传输的提示不会看起来像是来自另一个
/// 应用。
void _snack(BuildContext context, String message, {bool isError = false}) {
  final cs = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: isError ? cs.error : cs.primary,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}
