import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../models/file_item.dart';
import '../../widgets/app_ui.dart';
import 'sftp_file_visuals.dart';
import 'sftp_path.dart';

/// The dialogs and sheets the SFTP page uses to name, create and delete files.
/// SFTP 页面用于命名、新建、删除文件的对话框与面板。
///
/// They are free functions rather than methods: each one asks the question and
/// returns the answer, and the page — the only thing holding an SSH connection —
/// acts on it. None of them touches a service or keeps state between calls.
/// 它们是自由函数而非方法：每个函数只负责提问并返回答案，由唯一持有 SSH 连接的
/// 页面去执行。它们都不接触 service，也不在调用之间保存状态。

/// Which kind of entry the "new" chooser was asked to create.
/// 「新建」选择框要求创建哪种条目。
enum SftpNewEntryKind {
  /// A regular file.
  /// 普通文件。
  file,

  /// A directory.
  /// 目录。
  folder,
}

/// Offers "new file" and "new folder"; returns null when dismissed.
/// 提供「新建文件」与「新建文件夹」；被关闭时返回 null。
Future<SftpNewEntryKind?> showSftpNewEntryChooser(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return showDialog<SftpNewEntryKind>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: cs.surface,
      title: Text(t('new_file'), style: TextStyle(color: cs.onSurface)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            onTap: () => Navigator.pop(ctx, SftpNewEntryKind.file),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined, color: cs.secondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t('new_file_item'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurface),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          AppCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            onTap: () => Navigator.pop(ctx, SftpNewEntryKind.folder),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, color: cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t('new_folder'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Asks for a name and returns it, or null when nothing usable was entered.
/// 询问一个名称并返回它；没有输入可用内容时返回 null。
///
/// Null covers all three no-ops the callers care about: cancelled, left blank,
/// and unchanged — an unchanged name means the caller has nothing to do, and
/// treating it as a rename would rewrite a file onto itself.
/// null 覆盖调用方关心的三种空操作：取消、留空、未修改——名称未变意味着调用方无事可做，
/// 若当作重命名处理就会把文件覆盖到它自己身上。
Future<String?> showSftpNameDialog(
  BuildContext context, {
  required String title,
  required String hint,
  required String confirmLabel,
  String initial = '',
}) {
  final cs = Theme.of(context).colorScheme;
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: cs.surface,
      title: Text(title, style: TextStyle(color: cs.onSurface)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: TextStyle(color: cs.onSurface),
        cursorColor: cs.secondary,
        decoration: _dialogInputDecoration(context, hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(
            t('cancel'),
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
          ),
        ),
        TextButton(
          onPressed: () {
            final name = controller.text.trim();
            if (name.isEmpty || name == initial) {
              Navigator.pop(ctx);
              return;
            }
            Navigator.pop(ctx, name);
          },
          child: Text(confirmLabel, style: TextStyle(color: cs.secondary)),
        ),
      ],
    ),
  );
}

/// Confirms deleting a single entry by [name].
/// 确认删除名为 [name] 的单个条目。
Future<bool> confirmSftpDelete(BuildContext context, String name) {
  return showAppConfirmDialog(
    context,
    title: t('confirm_delete'),
    message: t('confirm_delete_file').replaceAll('{0}', name),
    cancelLabel: t('cancel'),
    confirmLabel: t('delete'),
    destructive: true,
  );
}

/// Confirms deleting every path in [paths], naming them in the message.
/// 确认删除 [paths] 中的每一个路径，并在正文中列出名称。
Future<bool> confirmSftpBatchDelete(BuildContext context, List<String> paths) {
  final names = sftpJoinedNames(paths);
  return showAppConfirmDialog(
    context,
    title: t('batch_delete'),
    message: t(
      'batch_delete_confirm',
    ).replaceAll('{0}', paths.length.toString()).replaceAll('{1}', names),
    cancelLabel: t('cancel'),
    confirmLabel: t('delete'),
    destructive: true,
  );
}

/// What the user picked in the file actions sheet.
/// 用户在文件操作面板中选择的操作。
enum SftpFileAction {
  /// Preview / edit the file.
  /// 预览或编辑文件。
  open,

  /// Rename or move it.
  /// 重命名或移动。
  rename,

  /// Start selecting it for a batch action.
  /// 选中它以执行批量操作。
  select,

  /// Delete it.
  /// 删除。
  delete,
}

/// Bottom sheet with the per-file actions; returns null when dismissed.
/// 单文件操作面板；关闭时返回 null。
///
/// [canOpenFile] only dims the preview entry for a binary file — the choice is
/// still reported, so the page can explain why nothing was opened instead of
/// leaving a dead tap behind.
/// [canOpenFile] 只负责把二进制文件的预览项显示为灰色——选择仍会上报，让页面能
/// 解释为什么没有打开，而不是留下一次毫无反应的点击。
Future<SftpFileAction?> showSftpFileActions(
  BuildContext context,
  FileItem file, {
  required bool canOpenFile,
}) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<SftpFileAction>(
    context: context,
    backgroundColor: cs.surface,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppCard(
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  AppIconBox(
                    icon: sftpFileIcon(file),
                    color: sftpFileIconColor(file, cs),
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          file.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          sftpFileSubtitle(file),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.55),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (!file.isDirectory)
              _ActionTile(
                icon: Icons.open_in_new,
                label: t('open_file'),
                color: canOpenFile
                    ? cs.secondary
                    : cs.onSurface.withValues(alpha: 0.38),
                onTap: () => Navigator.pop(ctx, SftpFileAction.open),
              ),
            _ActionTile(
              icon: Icons.drive_file_rename_outline,
              label: t('rename'),
              color: cs.primary,
              onTap: () => Navigator.pop(ctx, SftpFileAction.rename),
            ),
            _ActionTile(
              icon: Icons.check_box_outlined,
              label: t('selected'),
              color: cs.secondary,
              onTap: () => Navigator.pop(ctx, SftpFileAction.select),
            ),
            _ActionTile(
              icon: Icons.delete_outline,
              label: t('delete'),
              color: cs.error,
              onTap: () => Navigator.pop(ctx, SftpFileAction.delete),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One tappable row inside the file actions sheet.
/// 文件操作面板中一行可点击的操作项。
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: color, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Text field styling shared by the naming dialogs.
/// 命名对话框共用的输入框样式。
InputDecoration _dialogInputDecoration(BuildContext context, String hint) {
  final cs = Theme.of(context).colorScheme;
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
    filled: true,
    fillColor: Theme.of(context).scaffoldBackgroundColor,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: Theme.of(context).dividerColor),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: cs.secondary, width: 1.5),
    ),
  );
}
