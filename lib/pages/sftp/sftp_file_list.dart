import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../models/file_item.dart';
import '../../widgets/app_ui.dart';
import 'sftp_file_visuals.dart';

/// The scrolling list of entries in the current remote directory.
/// 当前远程目录条目的滚动列表。
///
/// Presentation only: it decides what a tap *means* from the state it is handed,
/// but every operation behind those taps stays in the page that owns the
/// connection.
/// 纯展示层：它依据收到的状态决定一次点击意味着什么，但点击背后的操作都留在
/// 持有连接的那个页面里。
class SftpFileList extends StatelessWidget {
  /// Entries to render, already sorted by the service.
  /// 待渲染的条目，已由 service 排序。
  final List<FileItem> files;

  /// Whether a listing is in flight; the list is replaced by a spinner.
  /// 是否有列举正在进行；此时列表位置显示转圈。
  final bool isLoading;

  /// Whether the checkboxes and selection behaviour are active.
  /// 是否启用复选框与多选行为。
  final bool isSelectionMode;

  /// Paths currently ticked.
  /// 当前已勾选的路径。
  final Set<String> selectedPaths;

  /// Tapping a directory row.
  /// 点击目录行。
  final ValueChanged<FileItem> onOpenDirectory;

  /// Tapping a file row; the page decides preview versus actions sheet.
  /// 点击文件行；由页面决定是预览还是弹出操作菜单。
  final ValueChanged<FileItem> onTapFile;

  /// Tapping the trailing "more" button of a file row.
  /// 点击文件行尾部的「更多」按钮。
  final ValueChanged<FileItem> onShowFileActions;

  /// Ticking or unticking an entry.
  /// 勾选或取消勾选一个条目。
  final ValueChanged<String> onToggleSelection;

  /// Long-pressing an entry to start selecting.
  /// 长按条目开始多选。
  final ValueChanged<String> onEnterSelectionMode;

  /// The empty-directory action that offers to create something.
  /// 空目录下「新建」动作。
  final VoidCallback onCreateEntry;

  const SftpFileList({
    super.key,
    required this.files,
    required this.isLoading,
    required this.isSelectionMode,
    required this.selectedPaths,
    required this.onOpenDirectory,
    required this.onTapFile,
    required this.onShowFileActions,
    required this.onToggleSelection,
    required this.onEnterSelectionMode,
    required this.onCreateEntry,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;

    if (isLoading) {
      return Center(child: CircularProgressIndicator(color: cs.secondary));
    }

    if (files.isEmpty) {
      return AppEmptyState(
        icon: Icons.folder_open_outlined,
        title: t('empty_dir'),
        message: t('empty_dir_hint'),
        actionLabel: t('new_file'),
        onAction: onCreateEntry,
        color: cs.primary,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final isSelected = selectedPaths.contains(file.path);

        final VoidCallback? onTap;
        if (isSelectionMode) {
          onTap = () => onToggleSelection(file.path);
        } else if (file.isDirectory) {
          onTap = () => onOpenDirectory(file);
        } else {
          onTap = () => onTapFile(file);
        }

        return AppCard(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: isSelected ? cs.secondary.withValues(alpha: 0.08) : cs.surface,
          borderColor: isSelected
              ? cs.secondary.withValues(alpha: 0.28)
              : dividerColor.withValues(alpha: 0.72),
          onTap: onTap,
          onLongPress: isSelectionMode
              ? null
              : () => onEnterSelectionMode(file.path),
          child: Row(
            children: [
              if (isSelectionMode)
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Checkbox(
                    value: isSelected,
                    onChanged: (_) => onToggleSelection(file.path),
                    activeColor: cs.secondary,
                    checkColor: Theme.of(context).scaffoldBackgroundColor,
                    side: BorderSide(
                      color: cs.onSurface.withValues(alpha: 0.24),
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                )
              else
                AppIconBox(
                  icon: sftpFileIcon(file),
                  color: sftpFileIconColor(file, cs),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            file.isDirectory ? '--' : file.displaySize,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.6),
                              fontSize: 11,
                            ),
                          ),
                        ),
                        if (!file.isDirectory) ...[
                          const SizedBox(width: 8),
                          AppBadge(
                            label: file.fileType,
                            color: cs.onSurface.withValues(alpha: 0.42),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 72),
                child: Text(
                  file.permissions,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.36),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (isSelectionMode)
                const SizedBox(width: 18)
              else
                IconButton(
                  icon: Icon(
                    file.isDirectory ? Icons.chevron_right : Icons.more_vert,
                    size: 18,
                    color: cs.onSurface.withValues(alpha: 0.34),
                  ),
                  tooltip: file.isDirectory ? t('open_file') : t('tools'),
                  onPressed: file.isDirectory
                      ? () => onOpenDirectory(file)
                      : () => onShowFileActions(file),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
