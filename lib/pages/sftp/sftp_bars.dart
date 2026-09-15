import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../widgets/app_ui.dart';

/// Path bar showing where the page is, and how to get back up.
/// 路径栏：显示页面所在位置，以及如何回到上层。
///
/// It renders the labels it is given and reports the index that was tapped; it
/// keeps no path state of its own, so it cannot show a directory the page is not
/// actually in.
/// 它只渲染传入的标签并回传被点击的下标，自身不保存任何路径状态，因此不可能显示
/// 页面并不真正所在的目录。
class SftpBreadcrumbBar extends StatelessWidget {
  /// One label per segment, root first, current directory last.
  /// 每个片段一个标签，根目录在前，当前目录在最后。
  final List<String> labels;

  /// Whether the trailing cancel chip for selection mode is shown.
  /// 是否显示多选模式的取消按钮。
  final bool isSelectionMode;

  /// Leaving selection mode from the cancel chip.
  /// 通过取消按钮退出多选模式。
  final VoidCallback onCancelSelection;

  /// Tapping segment [index]; the last segment is the current directory.
  /// 点击第 [index] 个片段；最后一个是当前目录。
  final ValueChanged<int> onCrumbTap;

  const SftpBreadcrumbBar({
    super.key,
    required this.labels,
    required this.isSelectionMode,
    required this.onCancelSelection,
    required this.onCrumbTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (isSelectionMode)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: onCancelSelection,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: cs.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      t('cancel'),
                      style: TextStyle(
                        color: cs.error,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            for (int i = 0; i < labels.length; i++) ...[
              if (i > 0)
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: cs.onSurface.withValues(alpha: 0.3),
                ),
              GestureDetector(
                onTap: () => onCrumbTap(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: i == labels.length - 1
                        ? cs.secondary.withValues(alpha: 0.1)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      labels[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: i == labels.length - 1
                            ? cs.secondary
                            : cs.onSurface.withValues(alpha: 0.6),
                        fontSize: 13,
                        fontWeight: i == labels.length - 1
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bottom bar shown while entries are selected: the count and the batch actions.
/// 有条目被选中时显示的底栏：选中数量与批量操作。
class SftpSelectionBar extends StatelessWidget {
  /// How many entries are ticked.
  /// 已勾选的条目数量。
  final int selectedCount;

  /// How many of them are files — everything a batch download can carry.
  /// 其中有多少是文件——批量下载能承载的全部。
  ///
  /// It is passed in rather than derived, because only the page knows which
  /// entries the ticked paths point at. A directory is not part of a batch
  /// download: the queue moves one remote path to one local path and walks
  /// nothing, so the button states how many files it will queue instead of
  /// promising the whole selection.
  /// 它由外部传入而不是自行推导，因为只有页面知道已勾选的路径指向哪些条目。目录不属于批量
  /// 下载：队列只把一条远程路径搬到一条本地路径，不做任何遍历，因此按钮说出它将入队多少个
  /// 文件，而不是承诺整个选择集。
  final int fileCount;

  /// Running the batch download.
  /// 执行批量下载。
  final VoidCallback onDownload;

  /// Running the batch delete.
  /// 执行批量删除。
  final VoidCallback onDelete;

  /// Leaving selection mode.
  /// 退出多选模式。
  final VoidCallback onCancel;

  const SftpSelectionBar({
    super.key,
    required this.selectedCount,
    required this.fileCount,
    required this.onDownload,
    required this.onDelete,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    // The same weight a Material button's own disabled label gets, so an
    // unavailable action reads as unavailable rather than as a different colour
    // this bar invented.
    // 与 Material 按钮自身禁用标签相同的分量，使不可用的操作读起来就是不可用，而不是本栏
    // 自己发明的一种颜色。
    final disabledColor = cs.onSurface.withValues(alpha: 0.38);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              t('selected_count').replaceAll('{0}', selectedCount.toString()),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.secondary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  // A selection with no file in it is not a tap that does
                  // nothing: the action is unavailable, and the disabled colour
                  // says so before the user taps it rather than after.
                  // 一个不含文件的选择集不该是一次「点了也没反应」的点击：该操作不可用，
                  // 而禁用色让用户在点击之前、而不是之后就知道这一点。
                  onPressed: fileCount == 0 ? null : onDownload,
                  icon: Icon(
                    Icons.download_outlined,
                    color: fileCount == 0 ? disabledColor : cs.secondary,
                    size: 18,
                  ),
                  label: Text(
                    // The count is on the label at all times, not only when
                    // something is left out: a number that appears and
                    // disappears is one the user has to notice, while a number
                    // that is always there is one they can check.
                    // 计数始终带在标签上，而不是只在有东西被落下时才出现：一个忽隐忽现的
                    // 数字需要用户去察觉，而一个一直在那里的数字是可以对照的。
                    '${t('download')} ($fileCount)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fileCount == 0 ? disabledColor : cs.secondary,
                      fontSize: 13,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline, color: cs.error, size: 18),
                  label: Text(
                    t('batch_delete'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.error, fontSize: 13),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: Text(
                    t('cancel'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom bar shown the rest of the time: the upload entry.
/// 其余时间显示的底栏：上传入口。
///
/// It reports the tap and nothing else. Which directory the file belongs in is a
/// decision about the *page's* state, and the page is the only thing that has
/// it; a bar that guessed would be the second copy of a rule this codebase has
/// already had to fix once.
/// 它只上报点击，别的什么都不做。文件该放进哪个目录是关于**页面**状态的判断，而只有
/// 页面拥有那份状态；一个自行猜测的底栏会成为这条规则的第二个副本，而本代码库已经为
/// 此修复过一次。
class SftpUploadBar extends StatelessWidget {
  /// Starts the upload flow: pick a file, then queue it.
  /// 启动上传流程：挑选文件，然后入队。
  final VoidCallback onUpload;

  const SftpUploadBar({super.key, required this.onUpload});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    return Material(
      color: cs.surface,
      child: InkWell(
        onTap: onUpload,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
            16,
            10,
            16,
            10 + MediaQuery.of(context).padding.bottom,
          ),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
          ),
          child: Row(
            children: [
              AppIconBox(
                icon: Icons.upload_file,
                color: cs.secondary,
                size: 36,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t('upload'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.78),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.add,
                size: 20,
                color: cs.secondary.withValues(alpha: 0.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
