import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../core/i18n/strings.dart';
import '../core/haptics.dart';
import '../providers/providers.dart';
import '../providers/settings_provider.dart';
import '../providers/theme_provider.dart';
import '../services/backup_service.dart';
import '../services/secure_storage.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';
import 'settings/backup_credentials.dart';
import 'settings/backup_dialogs.dart';
import 'settings/language_picker.dart';
import 'settings/settings_tiles.dart';
import 'settings/theme_picker.dart';

/// Full settings page: appearance, connection, data, system.
/// 完整设置页：外观、连接、数据、系统。
///
/// The page owns the flows — what a tap does, which provider or table it
/// touches, what the user is told afterwards. The rows it lays out live in
/// `settings/settings_tiles.dart`, the theme and language choosers in their own
/// files, and the two backup rules that matter for safety — what an export may
/// carry and what a restore may write to secure storage — in
/// `settings/backup_credentials.dart`, where they can be tested on their own.
/// 本页面持有各个流程——一次点击做什么、读写哪个 provider 或数据表、事后告诉用户
/// 什么；它排布的行控件在 `settings/settings_tiles.dart`，主题与语言选择器在各自
/// 文件中，而两条关乎安全的备份规则——导出允许携带什么、恢复允许向安全存储写入
/// 什么——在 `settings/backup_credentials.dart`，可以单独测试。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  void _showSnack(String message, {bool isError = false}) {
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? cs.error : cs.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      drawer: const AppDrawer(currentModule: 'settings', isTopLevel: true),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: Icon(Icons.menu, color: cs.onSurface),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Text(
          t('settings_title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: async.when(
        loading: () =>
            Center(child: CircularProgressIndicator(color: cs.primary)),
        error: (e, _) => SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: Text(
              t('load_failed_msg').replaceAll('{0}', e.toString()),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
            ),
          ),
        ),
        data: (s) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            SettingsSectionHeader(title: t('appearance_label')),
            SettingsSliderTile(
              icon: Icons.text_fields,
              title: t('terminal_font_size'),
              sub: t('terminal_font_sub'),
              value: s.terminalFontSize.toDouble(),
              min: 10,
              max: 20,
              div: 10,
              display: '${s.terminalFontSize} px',
              onChanged: (v) =>
                  _update(s.copyWith(terminalFontSize: v.round())),
            ),
            const SizedBox(height: 8),
            const SettingsThemePicker(),
            SettingsSwitchTile(
              icon: Icons.brightness_6,
              title: t('dark_mode'),
              sub: t('light_mode'),
              value: ref.watch(isDarkProvider),
              onChanged: (v) {
                ref.read(isDarkProvider.notifier).set(v);
                _update(s.copyWith(isDarkMode: v));
              },
            ),

            Divider(height: 1, color: Theme.of(context).dividerColor),
            SettingsSectionHeader(title: t('connection_label')),
            SettingsSliderTile(
              icon: Icons.timer_outlined,
              title: t('conn_timeout_label'),
              sub: t('conn_timeout_sub'),
              value: s.connectTimeout.toDouble(),
              min: 3,
              max: 30,
              div: 27,
              display: '${s.connectTimeout} ${t('sec')}',
              onChanged: (v) => _update(s.copyWith(connectTimeout: v.round())),
            ),
            SettingsInputTile(
              icon: Icons.settings_ethernet,
              title: t('default_ssh_port'),
              sub: t('default_port_sub'),
              init: s.defaultPort.toString(),
              type: TextInputType.number,
              errorText: t('invalid_port'),
              onSubmit: (v) {
                final p = int.tryParse(v);
                if (p != null && p > 0 && p <= 65535) {
                  _update(s.copyWith(defaultPort: p));
                  return true;
                }
                return false;
              },
            ),

            Divider(height: 1, color: Theme.of(context).dividerColor),
            SettingsSectionHeader(title: t('interaction_label')),
            SettingsSwitchTile(
              icon: Icons.vibration,
              title: t('haptic_feedback'),
              sub: t('haptic_feedback_sub'),
              value: s.hapticEnabled,
              onChanged: (v) => _update(s.copyWith(hapticEnabled: v)),
            ),
            SettingsListTile(
              icon: Icons.language,
              title: t('language_label'),
              sub: AppStrings.supportedLanguages[s.language] ?? s.language,
              onTap: () => _showLanguagePicker(),
            ),

            Divider(height: 1, color: Theme.of(context).dividerColor),
            SettingsSectionHeader(title: t('data_label')),
            SettingsActionTile(
              icon: Icons.upload_file,
              title: t('export_backup'),
              sub: t('export_backup_sub'),
              color: cs.secondary,
              onTap: () => _exportData(),
            ),
            SettingsActionTile(
              icon: Icons.download,
              title: t('restore_backup'),
              sub: t('restore_backup_sub'),
              color: cs.primary,
              onTap: () => _restoreData(),
            ),
            SettingsActionTile(
              icon: Icons.delete_sweep_outlined,
              title: t('clear_data'),
              sub: t('clear_data_sub'),
              color: cs.error,
              onTap: () => _clearAllConfirm(),
            ),

            Divider(height: 1, color: Theme.of(context).dividerColor),
            SettingsSectionHeader(title: t('about_label')),
            const SettingsInfoTile(
              icon: Icons.info_outline,
              title: 'NekoMux',
              sub: 'v1.0.0',
            ),
            SettingsInfoTile(
              icon: Icons.code,
              title: t('tech_stack'),
              sub: 'Flutter · dartssh2 · xterm · Riverpod · SQLite',
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  void _update(AppSettings s) =>
      ref.read(settingsProvider.notifier).updateSettings(s);

  /// Export all data as JSON and copy it to the clipboard.
  /// 导出全部数据为 JSON 并复制到剪贴板。
  ///
  /// Credentials are excluded unless the user ticks the opt-in box in the
  /// export dialog, and the payload then carries the same `'secure_storage'`
  /// placeholder the database holds — no password and no private key ever
  /// reaches the clipboard by default (audit finding sec-2). Dismissing the
  /// dialog exports nothing: only an explicit choice can start an export.
  /// 除非用户在导出对话框中勾选显式选项，否则凭据不会包含在内；此时载荷携带的只是
  /// 数据库中那个 `'secure_storage'` 占位值——默认情况下密码与私钥都不会进入剪贴板
  /// （审计问题 sec-2）。关闭对话框即不导出：只有明确的选择才会开始导出。
  Future<void> _exportData() async {
    final includeSecrets = await showExportSecretsDialog(context);
    if (includeSecrets == null || !mounted) return;

    final db = await ref.read(databaseProvider.future);
    final hosts = await db.query('tb_hosts');
    final creds = await ref.read(credentialListProvider.future);
    final snippets = await db.query('tb_snippets');
    // Key names live in backup_service.dart so export and restore agree, and
    // what a credential row may carry lives in backup_credentials.dart.
    // 键名统一定义在 backup_service.dart，保证导出与恢复一致；凭据行允许携带什么
    // 则定义在 backup_credentials.dart。
    final json = const JsonEncoder.withIndent('  ').convert(
      buildExportPayload(
        hosts: hosts,
        credentials: backupCredentialRows(
          creds,
          includeSecrets: includeSecrets,
        ),
        snippets: snippets,
      ),
    );
    await Clipboard.setData(ClipboardData(text: json));
    if (mounted) {
      // Say which of the two exports this was, so a user who walks away from
      // the snackbar still knows whether the clipboard can get them back in.
      // 说明这次是两种导出中的哪一种，即使用户没看到提示，也知道剪贴板里的内容
      // 能否让自己直接登录回去。
      _showSnack(
        includeSecrets
            ? '${t('export_success')} · ${t('export_secrets_warning')}'
            : '${t('export_success')} · ${t('export_secrets_omitted')}',
      );
    }
  }

  /// Show dialog to paste JSON and restore data.
  /// 弹出对话框以粘贴 JSON 并恢复数据。
  Future<void> _restoreData() async {
    final raw = await showRestoreBackupDialog(context);
    if (raw == null || !mounted) return;
    try {
      // Parse and validate every section BEFORE touching the database, so a
      // malformed payload cannot half-restore.
      // 先解析并校验全部分节，再动数据库，避免恢复中途失败。
      final payload = parseBackupPayload(raw);
      final credentials = readBackupRows(payload, BackupSection.credentials);
      final hosts = readBackupRows(payload, BackupSection.hosts);
      final snippets = readBackupRows(payload, BackupSection.snippets);

      final db = await ref.read(databaseProvider.future);
      // One transaction for all three tables: either the whole restore
      // commits, or nothing does.
      // 三张表共用同一事务：要么全部写入，要么全部回滚。
      await db.transaction((txn) async {
        for (final row in credentials) {
          final id = row['id'] as String?;
          if (id == null || id.isEmpty) {
            throw FormatException('Invalid credential id');
          }
          // A row from an export without secrets carries the placeholder, not a
          // password, so it restores the metadata and leaves whatever secret
          // the device already holds untouched — the placeholder is never
          // written over a real credential.
          // 不含密钥的导出的凭据行携带占位值而非密码，因此只恢复元数据，设备上已有的
          // 密钥保持不变——占位值绝不会覆盖真正的凭据。
          final secret = backupSecretToStore(row);
          if (secret != null) {
            await SecureStorage.saveCredential(id, secret);
          }
          await txn.insert(
            BackupSection.credentials.table,
            {...row, 'secret_data': secretStoragePlaceholder},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        // Merges by id, replacing duplicates; existing rows that are
        // not in the backup are left untouched.
        // 按 id 合并并覆盖重复项，备份中不存在的数据不会被删除。
        for (final row in hosts) {
          await txn.insert(
            BackupSection.hosts.table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final row in snippets) {
          await txn.insert(
            BackupSection.snippets.table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });

      ref.invalidate(hostListProvider);
      ref.invalidate(credentialListProvider);
      ref.invalidate(snippetListProvider);
      if (mounted) {
        _showSnack(t('restore_success'));
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          t('restore_failed').replaceAll('{0}', e.toString()),
          isError: true,
        );
      }
    }
  }

  Future<void> _clearAllConfirm() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('clear_data'),
      message: t('clear_all_confirm_content'),
      cancelLabel: t('cancel'),
      confirmLabel: t('confirm_clear'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    // Honours the switch this very page renders. It used to be the one call in
    // the app that ignored it — a settings screen whose own feedback contradicted
    // its own toggle.
    // 遵守本页自己渲染的那个开关。它曾经是全应用唯一无视该开关的调用——一个设置页，
    // 自身的反馈却与自身的开关相矛盾。
    hapticIf(ref.read(settingsProvider).value?.hapticEnabled, HapticKind.heavy);
    // One bulk delete per list, not a loop over deleteItem: each per-item call
    // refreshes on its own, and the host notifier watches the credential
    // notifier, so clearing N credentials used to rebuild the host list N times
    // (audit finding rob-7). Secrets are handled inside the credential clear.
    // 每个列表做一次批量删除，而不是循环 deleteItem：逐条调用各自刷新，而主机
    // 通知器又 watch 凭据通知器，于是清空 N 条凭据会让主机列表重建 N 次
    // （审计问题 rob-7）。密钥的清理在凭据的批量方法内部完成。
    await ref.read(hostListProvider.notifier).clearAll();
    await ref.read(credentialListProvider.notifier).clearAll();
    await ref.read(snippetListProvider.notifier).clearAll();
    if (mounted) {
      _showSnack(t('all_data_cleared'));
    }
  }

  /// Ask for a language and apply it, if it is a change.
  /// 询问语言并在确有变化时应用。
  Future<void> _showLanguagePicker() async {
    final current = ref.read(languageProvider);
    final selected = await showLanguagePickerDialog(context, current: current);
    if (selected == null || selected == current || !mounted) return;
    ref.read(languageProvider.notifier).set(selected);
  }
}
