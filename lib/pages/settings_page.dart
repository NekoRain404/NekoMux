import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../core/i18n/strings.dart';
import '../core/theme/app_theme.dart';
import '../providers/providers.dart';
import '../providers/settings_provider.dart';
import '../providers/theme_provider.dart';
import '../services/backup_service.dart';
import '../services/secure_storage.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_ui.dart';

/// Full settings page: appearance, connection, data, system.
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
            _Hdr(title: t('appearance_label')),
            _SliderT(
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
            _ThemePicker(),
            _SwitchT(
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
            _Hdr(title: t('connection_label')),
            _SliderT(
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
            _InputT(
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
            _Hdr(title: t('interaction_label')),
            _SwitchT(
              icon: Icons.vibration,
              title: t('haptic_feedback'),
              sub: t('haptic_feedback_sub'),
              value: s.hapticEnabled,
              onChanged: (v) => _update(s.copyWith(hapticEnabled: v)),
            ),
            _ListT(
              icon: Icons.language,
              title: t('language_label'),
              sub: AppStrings.supportedLanguages[s.language] ?? s.language,
              onTap: () => _showLanguagePicker(),
            ),

            Divider(height: 1, color: Theme.of(context).dividerColor),
            _Hdr(title: t('data_label')),
            _ActionT(
              icon: Icons.upload_file,
              title: t('export_backup'),
              sub: t('export_backup_sub'),
              color: cs.secondary,
              onTap: () => _exportData(),
            ),
            _ActionT(
              icon: Icons.download,
              title: t('restore_backup'),
              sub: t('restore_backup_sub'),
              color: cs.primary,
              onTap: () => _showRestoreDialog(),
            ),
            _ActionT(
              icon: Icons.delete_sweep_outlined,
              title: t('clear_data'),
              sub: t('clear_data_sub'),
              color: cs.error,
              onTap: () => _clearAllConfirm(),
            ),

            Divider(height: 1, color: Theme.of(context).dividerColor),
            _Hdr(title: t('about_label')),
            const _InfoT(
              icon: Icons.info_outline,
              title: 'NekoMux',
              sub: 'v1.0.0',
            ),
            _InfoT(
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

  /// Export all data to JSON and copy to clipboard.
  Future<void> _exportData() async {
    final db = await ref.read(databaseProvider.future);
    final hosts = await db.query('tb_hosts');
    final creds = await ref.read(credentialListProvider.future);
    final snippets = await db.query('tb_snippets');
    // Key names live in backup_service.dart so export and restore agree.
    // 键名统一定义在 backup_service.dart，保证导出与恢复一致。
    final json = const JsonEncoder.withIndent('  ').convert(
      buildExportPayload(
        hosts: hosts,
        credentials: creds.map((c) => c.toBackupMap()).toList(),
        snippets: snippets,
      ),
    );
    await Clipboard.setData(ClipboardData(text: json));
    if (mounted) {
      _showSnack(t('export_success'));
    }
  }

  /// Show dialog to paste JSON and restore data.
  void _showRestoreDialog() {
    final cs = Theme.of(context).colorScheme;
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surfaceContainerHighest,
        title: Text(
          t('restore_backup'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: cs.onSurface),
        ),
        content: TextField(
          controller: ctrl,
          maxLines: 8,
          style: TextStyle(
            color: cs.onSurface,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
          decoration: InputDecoration(
            hintText: t('paste_json_hint'),
            hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.42)),
            filled: true,
            fillColor: Theme.of(context).scaffoldBackgroundColor,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Theme.of(context).dividerColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: cs.secondary),
            ),
          ),
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
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                // Parse and validate every section BEFORE touching the
                // database, so a malformed payload cannot half-restore.
                // 先解析并校验全部分节，再动数据库，避免恢复中途失败。
                final payload = parseBackupPayload(ctrl.text);
                final credentials = readBackupRows(
                  payload,
                  BackupSection.credentials,
                );
                final hosts = readBackupRows(payload, BackupSection.hosts);
                final snippets = readBackupRows(
                  payload,
                  BackupSection.snippets,
                );

                final db = await ref.read(databaseProvider.future);
                // One transaction for all three tables: either the whole
                // restore commits, or nothing does.
                // 三张表共用同一事务：要么全部写入，要么全部回滚。
                await db.transaction((txn) async {
                  for (final row in credentials) {
                    final id = row['id'] as String?;
                    final secret = row['secret_data'] as String?;
                    if (id == null || id.isEmpty) {
                      throw FormatException('Invalid credential id');
                    }
                    if (secret != null &&
                        secret.isNotEmpty &&
                        secret != 'secure_storage') {
                      await SecureStorage.saveCredential(id, secret);
                    }
                    await txn.insert(
                      BackupSection.credentials.table,
                      {...row, 'secret_data': 'secure_storage'},
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
            },
            child: Text(
              t('restore'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.primary),
            ),
          ),
        ],
      ),
    );
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

    HapticFeedback.heavyImpact();
    final hNotifier = ref.read(hostListProvider.notifier);
    for (final h in await ref.read(hostListProvider.future)) {
      await hNotifier.deleteItem(h.id);
    }
    final cNotifier = ref.read(credentialListProvider.notifier);
    for (final c in await ref.read(credentialListProvider.future)) {
      await cNotifier.deleteItem(c.id);
      await SecureStorage.deleteCredential(c.id);
    }
    final sNotifier = ref.read(snippetListProvider.notifier);
    for (final s in await ref.read(snippetListProvider.future)) {
      await sNotifier.deleteItem(s.id);
    }
    if (mounted) {
      _showSnack(t('all_data_cleared'));
    }
  }

  void _showLanguagePicker() {
    final current = ref.read(languageProvider);
    final languages = AppStrings.supportedLanguages;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.62;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(
          t('language'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 360, maxHeight: maxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: languages.entries.map((e) {
                final selected = e.key == current;
                return _LanguageOption(
                  label: e.value,
                  selected: selected,
                  onTap: () {
                    if (selected) {
                      Navigator.pop(ctx);
                      return;
                    }
                    ref.read(languageProvider.notifier).set(e.key);
                    Navigator.pop(ctx);
                  },
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}

class _LanguageOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LanguageOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = selected ? cs.primary : cs.onSurface.withValues(alpha: 0.46);
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      borderColor: selected ? cs.primary : Theme.of(context).dividerColor,
      color: selected ? cs.primary.withValues(alpha: 0.08) : cs.surface,
      onTap: onTap,
      child: Row(
        children: [
          Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            color: accent,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? cs.primary : cs.onSurface,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Theme picker widget — shows all 5 themes as tappable color preview cards.
class _ThemePicker extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentId = ref.watch(themeIdProvider);
    final presets = AppThemeDef.presets;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 8, top: 4),
            child: Text(
              t('theme'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.8),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: presets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final preset = presets[i];
                final selected = preset.id == currentId;
                return GestureDetector(
                  onTap: () =>
                      ref.read(themeIdProvider.notifier).set(preset.id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 100,
                    decoration: BoxDecoration(
                      color: preset.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : preset.border,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _ColorDot(color: preset.accent),
                            const SizedBox(width: 4),
                            _ColorDot(color: preset.accent2),
                            const SizedBox(width: 4),
                            _ColorDot(color: preset.danger),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          preset.nameZh,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: preset.text1,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  const _ColorDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _Hdr extends StatelessWidget {
  final String title;
  const _Hdr({required this.title});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: cs.onSurface.withValues(alpha: 0.48),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SliderT extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final String display;
  final double value;
  final double min;
  final double max;
  final int div;
  final ValueChanged<double> onChanged;

  const _SliderT({
    required this.icon,
    required this.title,
    required this.sub,
    required this.display,
    required this.value,
    required this.min,
    required this.max,
    required this.div,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SettingShell(
      child: Row(
        children: [
          Icon(icon, color: cs.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.48),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          Text(
            display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cs.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: MediaQuery.sizeOf(context).width < 380 ? 92 : 120,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: cs.secondary,
                inactiveTrackColor: cs.onSurface.withValues(alpha: 0.1),
                thumbColor: cs.secondary,
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: div,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchT extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchT({
    required this.icon,
    required this.title,
    required this.sub,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SettingShell(
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Icon(icon, color: cs.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.48),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: cs.secondary,
          ),
        ],
      ),
    );
  }
}

class _InputT extends StatefulWidget {
  final IconData icon;
  final String title;
  final String sub;
  final String init;
  final TextInputType type;
  final String errorText;
  final bool Function(String) onSubmit;

  const _InputT({
    required this.icon,
    required this.title,
    required this.sub,
    required this.init,
    required this.type,
    required this.errorText,
    required this.onSubmit,
  });

  @override
  State<_InputT> createState() => _InputTState();
}

class _InputTState extends State<_InputT> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.init);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(_InputT oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus &&
        oldWidget.init != widget.init &&
        _controller.text != widget.init) {
      _controller.text = widget.init;
      _hasError = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final ok = widget.onSubmit(_controller.text.trim());
    setState(() => _hasError = !ok);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SettingShell(
      child: Row(
        children: [
          Icon(widget.icon, color: _hasError ? cs.error : cs.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                ),
                Text(
                  _hasError ? widget.errorText : widget.sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hasError
                        ? cs.error
                        : cs.onSurface.withValues(alpha: 0.48),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              keyboardType: widget.type,
              style: TextStyle(color: cs.onSurface, fontSize: 12),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Theme.of(context).dividerColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: _hasError
                        ? cs.error
                        : Theme.of(context).dividerColor,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: _hasError ? cs.error : cs.secondary,
                  ),
                ),
              ),
              onSubmitted: (_) => _submit(),
              onEditingComplete: _submit,
            ),
          ),
        ],
      ),
    );
  }
}

class _ListT extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;

  const _ListT({
    required this.icon,
    required this.title,
    required this.sub,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SettingShell(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: cs.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface, fontSize: 14),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.48),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right,
            color: cs.onSurface.withValues(alpha: 0.3),
            size: 20,
          ),
        ],
      ),
    );
  }
}

class _ActionT extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final Color color;
  final VoidCallback onTap;

  const _ActionT({
    required this.icon,
    required this.title,
    required this.sub,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SettingShell(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.48),
                    fontSize: 10,
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

class _InfoT extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;

  const _InfoT({required this.icon, required this.title, required this.sub});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SettingShell(
      child: Row(
        children: [
          Icon(icon, color: cs.primary.withValues(alpha: 0.6), size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.48),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingShell extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _SettingShell({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onTap,
      child: child,
    );
  }
}
