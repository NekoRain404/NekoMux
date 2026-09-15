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
import 'package:flutter/material.dart';

import '../../core/theme/app_fonts.dart';

import '../../core/i18n/strings.dart';

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
