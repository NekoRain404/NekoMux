// The two questions Settings → Export / Restore asks the user.
// 设置 → 导出 / 恢复向用户提出的两个问题。
//
// Free functions rather than methods, in the style of `pages/sftp/sftp_dialogs.dart`:
// each one asks and returns the answer, and the page — which holds the database
// and the providers — acts on it. Neither of them touches a service, so the
// distinction that matters for a backup (asking vs. writing) stays visible at
// the call site.
// 采用与 `pages/sftp/sftp_dialogs.dart` 相同的风格，写成自由函数而非方法：每个函数
// 只负责提问并返回答案，由持有数据库与 provider 的页面去执行。它们都不接触 service，
// 因此「询问」与「写入」这一对备份中至关重要的区别在调用处一目了然。
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_fonts.dart';

import '../../core/i18n/strings.dart';
import '../../services/backup_service.dart';

/// Asks what an outgoing backup may carry, before any of it is built.
/// 在生成备份内容之前，询问它允许携带什么。
///
/// Returns `null` when the dialog is dismissed, `false` for the default export
/// (no credentials) and `true` only when the user ticked the opt-in box
/// themselves. The caller must treat `null` as "do not export": an accidental
/// tap outside the dialog must never be read as consent to write passwords to
/// the clipboard.
/// 对话框被关闭时返回 `null`；默认导出（不含凭据）返回 `false`；只有当用户亲自勾选
/// 选项时才返回 `true`。调用方必须把 `null` 当作「不导出」：误点对话框外部绝不能被
/// 理解为同意把密码写入剪贴板。
///
/// What that default export carries is the caller's half, defined once in
/// `services/backup_service.dart`: every section of the payload, with
/// `BackupSection.settings` — the theme, the language, the font size, the
/// connect timeout — gathered by the caller from `tb_settings` and handed to
/// `buildExportPayload`. Passing those rows is what makes this dialog's promise
/// — and the "export all data as JSON" tile that opens it — true; the parameter
/// has an empty default only so that a caller without a database still
/// compiles, and an export that uses it silently leaves the settings behind.
/// 默认导出携带什么，是调用方的那一半，且只在 `services/backup_service.dart` 中定义：
/// 载荷的每一个分节，其中 `BackupSection.settings`——主题、语言、字号、连接超时——
/// 由调用方从 `tb_settings` 收集后交给 `buildExportPayload`。传入这些行，本对话框的
/// 承诺——以及打开它的那块「导出所有数据为 JSON」磁贴——才成立；该参数的默认值为空，
/// 只是为了让没有数据库的调用方仍能编译，而采用了那个默认值的导出会悄悄丢下设置。
///
/// The checkbox is the explicit, informed opt-in the export needs: the text next
/// to it names what would be included, and the note below it switches from what
/// is left out to the warning that the result will hold usable credentials.
/// 复选框即导出所需的显式知情选择：其旁的文字说明将包含什么，其下的说明会在勾选后
/// 由「省略了什么」切换为「结果将含可用凭据」的警告。
Future<bool?> showExportSecretsDialog(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  var includeSecrets = false;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        backgroundColor: cs.surfaceContainerHighest,
        title: Text(
          t('export_backup'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: cs.onSurface),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setLocal(() => includeSecrets = !includeSecrets),
              child: Row(
                children: [
                  Checkbox(
                    value: includeSecrets,
                    activeColor: cs.error,
                    onChanged: (v) =>
                        setLocal(() => includeSecrets = v ?? false),
                  ),
                  Expanded(
                    child: Text(
                      t('export_include_secrets'),
                      style: TextStyle(color: cs.onSurface, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              includeSecrets
                  ? t('export_secrets_warning')
                  : t('export_secrets_omitted'),
              style: TextStyle(
                color: includeSecrets
                    ? cs.error
                    : cs.onSurface.withValues(alpha: 0.62),
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              t('cancel'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, includeSecrets),
            child: Text(
              t('confirm'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: includeSecrets ? cs.error : cs.primary),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Collects the JSON text pasted into Settings → Restore Backup.
/// 收集「设置 → 恢复备份」中粘贴的 JSON 文本。
///
/// Returns `null` when the dialog is dismissed. It only asks: parsing,
/// validating and writing are the caller's, so nothing here can half-restore.
/// 对话框被关闭时返回 `null`。它只负责询问：解析、校验与写入都由调用方完成，因此
/// 这里不可能出现恢复一半的情况。
Future<String?> showRestoreBackupDialog(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (ctx) => const _RestoreBackupDialog(),
    );

/// The paste field and its two buttons.
/// 粘贴框及其两个按钮。
///
/// Stateful so the text field's controller has an owner: the dialog keeps its
/// own editing session and releases it when the route — not the moment the
/// button is tapped — is disposed.
/// 之所以是有状态控件，只是为了让输入框控制器有明确归属：对话框持有自己的编辑会话，
/// 并在路由（而不是按钮被点击的那一刻）销毁时才释放它。
class _RestoreBackupDialog extends StatefulWidget {
  const _RestoreBackupDialog();

  @override
  State<_RestoreBackupDialog> createState() => _RestoreBackupDialogState();
}

class _RestoreBackupDialogState extends State<_RestoreBackupDialog> {
  final _ctrl = TextEditingController();

  void _fill(String text) {
    _ctrl.text = text;
    _ctrl.selection = TextSelection.collapsed(offset: text.length);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _fill(text);
  }

  /// Loads a backup file into the field.
  ///
  /// The text lands in the same editable box rather than being parsed straight
  /// away, so the user sees exactly what is about to be restored — and the
  /// confirmation that follows counts what is in the box, not what was on disk.
  Future<void> _pickFile() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final file = picked.firstOrNull;
      if (file == null) return;
      // Read through the file itself rather than `withData`: a backup carrying
      // every host and credential is not small, and asking the picker to hold it
      // in memory only to hand it straight back is a second copy of it.
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      // `allowMalformed` for the same reason the SFTP preview uses it: a file
      // that picked up a stray byte should still open far enough to be read,
      // and the parse that follows is what rejects a payload that is not JSON.
      _fill(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('load_failed_msg').replaceAll('{0}', '$e')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    return AlertDialog(
      backgroundColor: cs.surfaceContainerHighest,
      title: Text(
        t('restore_backup'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: cs.onSurface),
      ),
      content: TextField(
        controller: _ctrl,
        maxLines: 8,
        style: TextStyle(
          color: cs.onSurface,
          fontSize: 12,
          fontFamily: AppFonts.mono,
        ),
        decoration: InputDecoration(
          hintText: t('paste_json_hint'),
          hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.42)),
          // The other half of export, which ends in `Clipboard.setData`. Without
          // this button the only way to fill the field is the keyboard's own
          // paste, which on a phone means a long-press on an empty box — the
          // one gesture a field with no text in it gives no hint about.
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Opening a file is the other half of an export that carried
              // secrets: those are written to a file rather than the clipboard
              // (see CLAUDE.md, Secrets), so without this button such a backup
              // could be produced and never restored.
              IconButton(
                icon: Icon(Icons.folder_open, size: 18, color: cs.secondary),
                tooltip: t('restore_from_file'),
                onPressed: _pickFile,
              ),
              IconButton(
                icon: Icon(Icons.content_paste, size: 18, color: cs.secondary),
                tooltip: t('paste'),
                onPressed: _pasteFromClipboard,
              ),
            ],
          ),
          filled: true,
          fillColor: Theme.of(context).scaffoldBackgroundColor,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: dividerColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: cs.secondary),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            t('cancel'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: Text(
            t('restore'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.primary),
          ),
        ),
      ],
    );
  }
}

/// Asks whether to go ahead with a restore whose contents are already parsed.
///
/// Returns true only when the user confirmed. `null` (dismissed by tapping
/// outside) is false, like every other confirmation in this app.
///
/// The counts are the whole point. "Data restored successfully" used to be the
/// first and only thing said about a restore that had already happened: the
/// dialog that collected the payload said nothing about what restoring it
/// means, and the operation replaces any row whose id the payload also carries.
/// Pasting last month's backup therefore discarded today's edits to those rows
/// with no question asked — while "Clear Data", which destroys strictly less,
/// has always confirmed. Naming per-section counts is what turns the question
/// from a formality into one the user can actually answer: they can see that
/// this payload holds 3 hosts when they have 12.
Future<bool> showRestoreConfirmDialog(
  BuildContext context, {
  required Map<BackupSection, int> counts,
  required bool carriesSecrets,
}) async {
  final cs = Theme.of(context).colorScheme;

  // Built from the section labels the rest of the app already translates, so a
  // new section cannot arrive untranslated — the same reason `readBackupRows`
  // takes the section rather than the table name.
  String labelOf(BackupSection section) => switch (section) {
    BackupSection.hosts => t('my_hosts'),
    BackupSection.credentials => t('credentials'),
    BackupSection.snippets => t('snippets'),
    BackupSection.settings => t('settings'),
  };

  final summary = counts.entries
      .where((e) => e.value > 0)
      .map((e) => '${labelOf(e.key)} ${e.value}')
      .join(' · ');

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: cs.surfaceContainerHighest,
      title: Text(
        t('restore_confirm_title'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: cs.onSurface),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('restore_confirm_body'),
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.72),
              fontSize: 13,
              height: 1.45,
            ),
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(ctx).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(ctx).dividerColor),
              ),
              child: Text(
                summary,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 12,
                  fontFamily: AppFonts.mono,
                ),
              ),
            ),
          ],
          if (carriesSecrets) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.key_outlined, size: 16, color: cs.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t('restore_confirm_secrets'),
                    style: TextStyle(color: cs.error, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(
            t('cancel'),
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            t('restore'),
            style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
