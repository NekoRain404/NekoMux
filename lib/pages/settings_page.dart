import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../core/app_info.dart';
import '../core/i18n/strings.dart';
import '../core/haptics.dart';
import '../providers/providers.dart';
import '../providers/settings_provider.dart';
import '../providers/theme_provider.dart';
import '../services/backup_service.dart';
import '../services/secure_storage.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';
import 'known_hosts_page.dart';
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
        // A retry, like every other table-backed screen in the app. Settings
        // had a dead end: a read that failed left the user with a message and
        // nothing to press, on the one screen whose rows are the app's own
        // preferences — including the connection timeout they might have set
        // because the network is slow, which is often the same network that
        // just failed this read.
        error: (e, _) => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t('load_failed_msg').replaceAll('{0}', e.toString()),
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.62)),
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: () => ref.invalidate(settingsProvider),
                  icon: Icon(Icons.refresh, color: cs.secondary, size: 18),
                  label: Text(
                    t('retry'),
                    style: TextStyle(color: cs.secondary),
                  ),
                ),
              ],
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
              format: (v) => '${v.round()} px',
              onChangeEnd: (v) =>
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
              format: (v) => '${v.round()} ${t('sec')}',
              onChangeEnd: (v) =>
                  _update(s.copyWith(connectTimeout: v.round())),
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
            SettingsSectionHeader(title: t('system')),
            SettingsListTile(
              icon: Icons.verified_user_outlined,
              title: t('known_hosts_title'),
              sub: t('known_hosts_sub'),
              onTap: () => _openKnownHosts(),
            ),

            Divider(height: 1, color: Theme.of(context).dividerColor),
            SettingsSectionHeader(title: t('about_label')),
            const SettingsInfoTile(
              icon: Icons.info_outline,
              title: appName,
              sub: 'v$appVersion',
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

  /// Persists [s], confirms it, and reports a write that failed.
  ///
  /// The future used to be discarded, which made a failed write invisible: the
  /// row had already moved to its new position (the tiles render from the value
  /// the user just chose) while `tb_settings` still held the old one, so the
  /// screen and the database disagreed until the next restart silently reverted
  /// it — the exact shape of a preference that "does not stick".
  ///
  /// The haptic fires from the *new* value, not the stored one: the toggle that
  /// turns haptics on is the one case where the old setting cannot confirm
  /// itself, so enabling it would otherwise stay silent until the next change.
  Future<void> _update(AppSettings s) async {
    hapticIf(s.hapticEnabled, HapticKind.light);
    try {
      await ref.read(settingsProvider.notifier).updateSettings(s);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('setting_save_failed').replaceAll('{0}', '$e')),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  /// Opens the list of host keys the app has accepted.
  /// 打开应用已接受的主机密钥列表。
  ///
  /// The row sits under "System", not inside the "About" block below it: what it
  /// opens is not information about the app but the record of what the app will
  /// trust on the next connection — and the one place in the app where that
  /// trust can be taken back. Nothing on either side of this navigation can
  /// relax host-key verification; see the page itself for why that is
  /// deliberate.
  /// 该行位于「系统」分节，而不是其下方的「关于」之中：它打开的不是应用自身的信息，
  /// 而是应用在下次连接时会信任什么的记录——也是全应用唯一能收回这份信任的地方。
  /// 这次跳转的两端都没有放松主机密钥校验的入口；为何刻意如此，见该页面本身。
  Future<void> _openKnownHosts() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const KnownHostsPage()),
    );
  }

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
  ///
  /// Everything after the dialog can fail — the credential list reads secrets
  /// out of secure storage, and the clipboard is a platform channel — so the
  /// build-and-copy runs guarded and reports what went wrong. It used to run
  /// bare: the future it returned was discarded by the tile's `onTap`, so a
  /// user whose secure storage was unavailable got no clipboard write, no
  /// snackbar and no error, however many times they tapped (audit finding).
  /// 对话框之后的每一步都可能失败——凭据列表要从安全存储读取密钥，剪贴板也是平台
  /// 通道——因此「构建并复制」整体置于保护之下，并报告失败原因。此前它没有任何保护：
  /// 它返回的 future 被该行的 `onTap` 丢弃，于是安全存储不可用的用户无论点多少次，
  /// 都既没有剪贴板内容、也没有提示，更看不到错误（审计问题）。
  Future<void> _exportData() async {
    final includeSecrets = await showExportSecretsDialog(context);
    if (includeSecrets == null || !mounted) return;

    try {
      final db = await ref.read(databaseProvider.future);
      final hosts = await db.query(BackupSection.hosts.table);
      // The one step here that can fail on its own: `CredentialListNotifier`
      // builds by reading every secret out of secure storage, which throws
      // whenever the platform store is unavailable (the post-restore /
      // invalidated-keystore case). It sits inside the guard for that reason.
      // 这里唯一会自行失败的一步：`CredentialListNotifier` 构建时会从安全存储读取每
      // 一条密钥，平台存储不可用（恢复之后 / 密钥库失效）时必然抛出。它之所以被放进
      // 保护范围内，正是因为这个。
      final creds = await ref.read(credentialListProvider.future);
      final snippets = await db.query(BackupSection.snippets.table);
      // Settings ride along: the tile says "export all data as JSON" and the
      // dialog's default is described as covering settings, hosts and
      // snippets, yet tb_settings used to be left behind — restoring on a new
      // phone brought back every host but not the theme, language, font size
      // or connect timeout (audit finding). Added as a section of its own so
      // nothing already written changes meaning.
      // 设置一同导出：该行写着「导出所有数据为 JSON」，对话框也把默认导出描述为涵盖
      // 设置、主机与快捷指令，但 tb_settings 过去被落下——在新手机上恢复会带回全部
      // 主机，却带不回主题、语言、字号与连接超时（审计问题）。它作为独立分节加入，
      // 已有内容的含义因此没有任何改变。
      final settings = await db.query(BackupSection.settings.table);
      // Key names live in backup_service.dart so export and restore agree, and
      // what a credential row may carry lives in backup_credentials.dart.
      // 键名统一定义在 backup_service.dart，保证导出与恢复一致；凭据行允许携带什么
      // 则定义在 backup_credentials.dart。
      final payload = buildExportPayload(
        hosts: hosts,
        credentials: backupCredentialRows(
          creds,
          includeSecrets: includeSecrets,
        ),
        snippets: snippets,
        settings: settings,
      );

      final json = const JsonEncoder.withIndent('  ').convert(payload);

      // Two destinations, chosen by what the payload carries. The clipboard is
      // where a secret-free export belongs: it is how the JSON reaches the
      // restore field on another phone, and there is nothing in it to leak. An
      // export that carries real passwords and keys is written to a file the
      // user picks instead, because the system clipboard is readable by every
      // other app on the device and by anything that syncs it — which is what
      // this project's own rule forbids (see CLAUDE.md, Secrets).
      if (includeSecrets) {
        await _exportToFile(json);
        return;
      }

      await Clipboard.setData(ClipboardData(text: json));
      if (mounted) {
        _showSnack('${t('export_success')} · ${t('export_secrets_omitted')}');
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          t('service_action_failed')
              .replaceAll('{0}', t('export_backup'))
              .replaceAll('{1}', e.toString()),
          isError: true,
        );
      }
    }
  }

  /// Writes the export to a file the user chooses.
  ///
  /// `FilePicker.saveFile` is the one mechanism Android offers for "the user
  /// picks where this goes"; this app declares only `INTERNET`, so it cannot
  /// write into shared storage itself (the same reason downloads stage first
  /// and are published from the finished row).
  Future<void> _exportToFile(String json) async {
    final Uint8List bytes = Uint8List.fromList(utf8.encode(json));
    final Uri? saved;
    try {
      saved = await FilePicker.saveFile(
        fileName: 'nekomux-backup.json',
        bytes: bytes,
        dialogTitle: t('export_backup'),
      );
    } catch (e) {
      if (mounted) {
        _showSnack(
          t('service_action_failed')
              .replaceAll('{0}', t('export_backup'))
              .replaceAll('{1}', '$e'),
          isError: true,
        );
      }
      return;
    }
    if (!mounted) return;
    // Null is the documented "the user cancelled" and the only other answer.
    if (saved == null) return;
    _showSnack('${t('export_success')} · ${t('export_secrets_warning')}');
  }

  /// Show dialog to paste JSON and restore data.
  /// 弹出对话框以粘贴 JSON 并恢复数据。
  ///
  /// The database half of a restore is one transaction; secure storage has no
  /// transactions at all, and the only safe order is the database first and the
  /// secrets after it commits.
  /// 恢复的数据库部分是一个事务，安全存储则根本没有事务可言；唯一安全的顺序是先
  /// 数据库、待其提交后再写密钥。
  ///
  /// Secrets used to be written *inside* the transaction, so a later row the
  /// schema rejected — a host missing its `NOT NULL` alias, say — rolled the
  /// rows back while the passwords stayed overwritten: the page said "restore
  /// failed" although every credential whose id was in the backup had already
  /// lost its original password, and an id with no row left a secret nothing
  /// would ever clean up (audit finding). Collecting the pairs while the
  /// transaction runs and applying them only once it has committed makes that
  /// sequence impossible: a rollback now means no secret was written, and no
  /// applied secret can exist without the row that points at it.
  /// 密钥过去是在事务*内部*写入的，于是之后但凡有一行被 schema 拒绝——例如主机缺少
  /// `NOT NULL` 的 alias——数据行会回滚，密码却已被覆写：页面显示「恢复失败」，可
  /// 备份中出现过的每个凭据都已丢失原密码，而没有对应行的 id 更留下永远无人清理的
  /// 密钥（审计问题）。在事务进行期间只收集这些 (id, 密钥) 对、等它提交之后才写入，
  /// 这一连串后果便不可能再发生：回滚即意味着一个密钥都没写，而任何已写入的密钥都
  /// 必然有指向它的行。
  ///
  /// The reverse failure — committed rows, then a secret write fails — is
  /// deliberately *not* compensated by deleting the secrets already written.
  /// Such a delete cannot bring back the value those writes overwrote; it only
  /// destroys the one secret that now matches the committed row, turning a
  /// working credential into a dead one. What could not be written is reported
  /// instead.
  /// 反向的失败——行已提交、随后某个密钥写入失败——刻意*不*用删除已写密钥来补偿。
  /// 删除找不回那些写入所覆写的值；它只会销毁当下与已提交行相符的那一个密钥，把还能
  /// 用的凭据变成废的。这里的做法是如实报告没能写入的部分。
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
      // The one section that may legitimately be absent — a payload written
      // before settings were exported has none and must still restore — which is
      // why the reader has to be told the section rather than assume every one
      // is mandatory.
      // 唯一可以合法缺席的分节——设置被导出之前写出的载荷没有它，且必须仍能恢复——这
      // 正是读取时必须指明分节、而不能假定每一节都必需的原因。
      final settings = readBackupRows(payload, BackupSection.settings);

      // Asked BEFORE the transaction, with the parsed contents in hand: this is
      // the last moment at which the user can still say no, and the counts are
      // the only way the question can be answered rather than waved through.
      final confirmed = await showRestoreConfirmDialog(
        context,
        counts: {
          BackupSection.hosts: hosts.length,
          BackupSection.credentials: credentials.length,
          BackupSection.snippets: snippets.length,
          BackupSection.settings: settings.length,
        },
        // A payload exported without secrets carries the placeholder instead, so
        // this is exactly the question "will real credentials be written".
        carriesSecrets: credentials.any(
          (row) => backupSecretToStore(row) != null,
        ),
      );
      if (!confirmed || !mounted) return;

      final db = await ref.read(databaseProvider.future);
      // Secrets asked for by this payload, gathered here and written only after
      // the transaction below has committed. Nothing in this map is touched if
      // it rolls back.
      // 本载荷要求的密钥，在此收集，只有下面的事务提交之后才写入。若事务回滚，这个
      // map 中的内容不会被任何代码用到。
      final pendingSecrets = <String, String>{};
      // One transaction for every table, settings included: either the whole
      // restore commits, or nothing does.
      // 所有数据表共用同一事务（设置表也在内）：要么全部写入，要么全部回滚。
      await db.transaction((txn) async {
        for (final row in credentials) {
          final id = row['id'] as String?;
          if (id == null || id.isEmpty) {
            throw const FormatException('Invalid credential id');
          }
          // A row from an export without secrets carries the placeholder, not a
          // password, so it restores the metadata and leaves whatever secret
          // the device already holds untouched — the placeholder is never
          // written over a real credential.
          // 不含密钥的导出的凭据行携带占位值而非密码，因此只恢复元数据，设备上已有的
          // 密钥保持不变——占位值绝不会覆盖真正的凭据。
          final secret = backupSecretToStore(row);
          if (secret != null) {
            pendingSecrets[id] = secret;
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
        // Merged key by key, exactly like the sections above: rows the backup
        // does not carry are left alone, so restoring an old backup cannot
        // silently wipe a setting it never knew about.
        // 与上面各分节一样逐键合并：备份没有携带的行保持原样，因此恢复一份旧备份不会
        // 悄悄抹掉它根本不知道的设置。
        for (final row in settings) {
          await txn.insert(
            BackupSection.settings.table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });

      // Committed: the rows are on disk and every one of them points at the
      // placeholder. Only now may the secrets be written, and a failure here
      // leaves the already-written ones alone (see above) while the rest are
      // reported.
      // 已提交：数据行已经落盘，且每一行都指向占位值。此刻才允许写入密钥；这里失败时，
      // 已写入的密钥保持原样（原因见上），其余部分如实报告。
      var failedSecrets = 0;
      var secretError = '';
      for (final entry in pendingSecrets.entries) {
        try {
          await SecureStorage.saveCredential(entry.key, entry.value);
        } catch (e) {
          failedSecrets++;
          secretError = secretError.isEmpty ? e.toString() : secretError;
        }
      }

      ref.invalidate(hostListProvider);
      ref.invalidate(credentialListProvider);
      ref.invalidate(snippetListProvider);
      // Theme, language, font size and connect timeout all come from this
      // provider, and the theme and language notifiers watch it, so one
      // invalidation carries the restored values through the whole app.
      // 主题、语言、字号与连接超时都来自这个 provider，而主题与语言通知器都 watch
      // 它，因此一次失效即可把恢复出来的取值带到整个应用。
      if (settings.isNotEmpty) {
        ref.invalidate(settingsProvider);
      }
      if (!mounted) return;
      if (failedSecrets == 0) {
        _showSnack(t('restore_success'));
      } else {
        // The rows are in place and some secrets are not: saying only
        // "restored" would hide credentials that cannot connect, and saying
        // only "failed" would hide that everything else came back.
        // 数据行已经就位，但有一部分密钥没有写进去：只说「已恢复」会掩盖连不上的凭据，
        // 只说「失败」则会掩盖其余全部已经回来的事实。
        final unwritten = t('service_action_failed')
            .replaceAll('{0}', t('credentials'))
            .replaceAll(
              '{1}',
              '$failedSecrets/${pendingSecrets.length} — $secretError',
            );
        _showSnack('${t('restore_success')} · $unwritten', isError: true);
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
    //
    // Each list is cleared on its own and its outcome is kept, because this
    // wipe is irreversible and the dialog promises all three. Credential
    // clearing deletes secrets through `SecureStorage`, which throws rather
    // than reports — and nothing above catches it. Unguarded, that throw left
    // the hosts gone, the credentials and every snippet alive, no success
    // snackbar, and an unhandled async error: the user got neither a success
    // nor a failure message for an irreversible action (audit finding). The
    // restore path reported on exactly this kind of failure; this one did not.
    // 每个列表单独清理并记下各自结果，因为这次清空不可撤销，而对话框承诺的是三样都
    // 清掉。凭据清理会经由 `SecureStorage` 删除密钥，它是抛出异常而不是报告失败——且
    // 上层无人捕获。没有保护时，那次抛出会让主机已经没了、凭据与全部快捷指令却还在、
    // 成功提示不出现，还留下一个未处理的异步错误：用户对一个不可撤销的操作既没看到成功
    // 也没看到失败（审计问题）。恢复流程对同类失败是有报告的，这里此前没有。
    final failed = <String>[];
    var errorDetail = '';
    Future<void> wipe(String label, Future<void> Function() clear) async {
      try {
        await clear();
      } catch (e) {
        // Keep going: the user asked for everything to go, and a failure in
        // one list is no reason to abandon the others. Report the first
        // detail, which is the one that explains the earliest failure.
        // 继续往下清：用户要的是全部清掉，其中一个列表失败并不构成放弃其余列表的
        // 理由。只保留第一条细节——它解释的是最早那次失败。
        failed.add(label);
        if (errorDetail.isEmpty) errorDetail = e.toString();
      }
    }

    await wipe(
      t('my_hosts'),
      () => ref.read(hostListProvider.notifier).clearAll(),
    );
    await wipe(
      t('credentials'),
      () => ref.read(credentialListProvider.notifier).clearAll(),
    );
    await wipe(
      t('snippets'),
      () => ref.read(snippetListProvider.notifier).clearAll(),
    );
    if (!mounted) return;
    if (failed.isEmpty) {
      _showSnack(t('all_data_cleared'));
    } else {
      // Names the lists that survived instead of claiming a clean sweep: a
      // partial wipe must not read like a complete one.
      // 点明幸存下来的是哪些列表，而不是宣称已经清干净：清了一半不能读起来像全清了。
      final failure = t(
        'service_action_failed',
      ).replaceAll('{0}', failed.join(', ')).replaceAll('{1}', errorDetail);
      _showSnack(failure, isError: true);
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
