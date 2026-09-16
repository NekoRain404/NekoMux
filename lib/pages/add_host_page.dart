import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/haptics.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../providers/settings_provider.dart';
import '../providers/ssh_provider.dart';
import '../widgets/app_ui.dart';
import 'hosts/host_list_model.dart';
import 'credential_list_page.dart';

/// Page for adding a new host or editing an existing one. / 新增主机或编辑已有主机的页面。
class AddHostPage extends ConsumerStatefulWidget {
  final Host? existingHost;
  const AddHostPage({super.key, this.existingHost});

  @override
  ConsumerState<AddHostPage> createState() => _AddHostPageState();
}

class _AddHostPageState extends ConsumerState<AddHostPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _aliasController;
  late final TextEditingController _ipController;
  late final TextEditingController _portController;

  /// Optional group, so hosts can be grouped by role or environment on the home
  /// list. Blank means no group — normalized on save through the model's own
  /// rule, so the form and the database cannot disagree about what blank means.
  /// 可选分组，让主机在首页按角色或环境归类。留空表示不分组——保存时经由模型自身的
  /// 规则归一化，因此表单与数据库不可能对「留空」有不同理解。
  late final TextEditingController _groupController;
  late int _osType;
  String? _selectedCredentialId;
  bool _isTesting = false;
  bool _isHandlingBack = false;

  /// Fallback used while the settings are still loading. Equal to
  /// `AppSettings.defaultPort`'s own default, so a cold start behaves exactly
  /// as the app did before this setting was honoured at all.
  /// 设置仍在加载时的兜底值，与 `AppSettings.defaultPort` 自身的默认值一致，使冷
  /// 启动与本设置尚未被遵循时的行为完全相同。
  static const int _kFallbackDefaultPort = 22;

  /// Port a *new* host form is pre-filled with.
  /// 新增主机表单预填的端口。
  ///
  /// Settings → default port used to persist a number that nothing outside the
  /// settings page read: the field was seeded from a literal `22`, so a user
  /// who chose 2222 was still shown 22 (audit: settings that lie).
  /// 「设置 → 默认端口」此前持久化了一个除设置页外无人读取的数字：输入框以字面量
  /// `22` 预填，因此选了 2222 的用户看到的仍然是 22（审计：会撒谎的设置）。
  ///
  /// Resolved **once**, into a field, rather than re-read wherever it is needed.
  /// [_hasChanges] judges the port field against this same value, and a default
  /// that could shift underneath it — the settings finishing their load while
  /// this page is open — would make an untouched new-host form call itself
  /// modified and nag about discarding changes.
  /// 只解析**一次**并存为字段，而不是在各使用处重复读取。[_hasChanges] 用同一个值
  /// 判断端口输入框，而一个可能在其脚下变化的默认值（本页打开期间设置加载完成）会让
  /// 未经改动的新建表单自认为已被修改，并弹出「丢弃更改」的唠叨提示。
  late final int _defaultPort;

  /// Group names already in use, offered as one-tap chips.
  /// 已在使用的分组名，做成一点即填的标签。
  ///
  /// Read from the live host list so a group created on another screen is
  /// offered here without reopening the form.
  /// 取自实时主机列表，因此在别的界面新建的分组无需重开表单即可出现在这里。
  List<String> get _existingGroups =>
      existingGroupNames(ref.watch(hostListProvider).value ?? const []);

  bool get _isEditing => widget.existingHost != null;
  bool get _hasChanges {
    final h = widget.existingHost;
    if (h == null) {
      return _aliasController.text.trim().isNotEmpty ||
          _ipController.text.trim().isNotEmpty ||
          // Compared against the *same* default the field was seeded with: a
          // hardcoded '22' here would brand every new-host form as dirty the
          // moment the user's default port is anything else.
          // 与输入框预填所用的**同一个**默认值比较：此处若写死 '22'，只要用户的默认
          // 端口不是 22，任何新建表单一打开就会被判定为已修改。
          _portController.text.trim() != _defaultPort.toString() ||
          _osType != 0 ||
          Host.normalizeGroupName(_groupController.text) != null ||
          _selectedCredentialId != null;
    }
    return _aliasController.text.trim() != h.alias ||
        _ipController.text.trim() != h.ipAddress ||
        _portController.text.trim() != h.port.toString() ||
        _osType != h.osType ||
        // Compared through the model's normalizer, not against the raw text: a
        // user who types a space into an otherwise untouched form has not
        // modified anything, and should not be asked to confirm discarding it.
        // 经由模型的归一化比较，而不是原始文本：用户在一个未改动过的表单里敲了个空格，
        // 并没有修改任何东西，不该被要求确认丢弃。
        Host.normalizeGroupName(_groupController.text) != h.groupName ||
        _selectedCredentialId != h.credentialId;
  }

  @override
  void initState() {
    super.initState();
    final h = widget.existingHost;
    _defaultPort =
        ref.read(settingsProvider).value?.defaultPort ?? _kFallbackDefaultPort;
    _aliasController = TextEditingController(text: h?.alias ?? '');
    _ipController = TextEditingController(text: h?.ipAddress ?? '');
    _portController = TextEditingController(
      text: (h?.port ?? _defaultPort).toString(),
    );
    _groupController = TextEditingController(text: h?.groupName ?? '');
    _osType = h?.osType ?? 0;
    _selectedCredentialId = h?.credentialId;
  }

  @override
  void dispose() {
    _aliasController.dispose();
    _ipController.dispose();
    _portController.dispose();
    _groupController.dispose();
    super.dispose();
  }

  InputDecoration _inputDecoration(
    String label, {
    String? hint,
    String? error,
  }) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: error,
      labelStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
      hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.36)),
      errorStyle: TextStyle(color: cs.error, fontSize: 12),
      filled: true,
      fillColor: cs.surface,
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: dividerColor),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: cs.secondary, width: 1.5),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      errorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: cs.error),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: cs.error, width: 1.5),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  Future<void> _testConnection() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (_selectedCredentialId == null) {
      _showResult(t('select_credential_first'), isError: true);
      return;
    }
    if (ip.isEmpty) {
      _showResult(t('enter_ip_first'), isError: true);
      return;
    }
    if (port == null || port <= 0 || port > 65535) {
      _showResult(t('invalid_port'), isError: true);
      return;
    }

    setState(() => _isTesting = true);
    hapticIf(
      ref.read(settingsProvider).value?.hapticEnabled,
      HapticKind.medium,
    );

    final creds = ref.read(credentialListProvider).value ?? [];
    final cred = creds.where((c) => c.id == _selectedCredentialId).firstOrNull;

    if (cred == null) {
      setState(() => _isTesting = false);
      _showResult(t('credential_not_found'), isError: true);
      return;
    }

    final testHost = Host(
      id: '',
      alias: _aliasController.text.trim(),
      ipAddress: ip,
      port: port,
      credentialId: cred.id,
      credentialName: cred.name,
      credentialUsername: cred.username,
    );

    // The test obeys the same connect timeout the real session will: it is the
    // very handshake being measured, so a shorter default here would report a
    // failure for a host that actually connects.
    // 测试遵循与真实会话相同的连接超时：它测量的正是握手本身，此处若用更短的默认值，
    // 会把实际能连上的主机报成失败。
    final result = await testConnection(
      host: testHost,
      credential: cred,
      connectTimeout: ref.read(connectTimeoutProvider),
    );

    if (!mounted) return;
    setState(() => _isTesting = false);

    if (result == 'ok') {
      _showResult(t('conn_success_detail'), isError: false);
      hapticIf(
        ref.read(settingsProvider).value?.hapticEnabled,
        HapticKind.heavy,
      );
    } else {
      _showResult('❌ $result', isError: true);
      hapticIf(
        ref.read(settingsProvider).value?.hapticEnabled,
        HapticKind.heavy,
      );
    }
  }

  void _showResult(String message, {required bool isError}) {
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        backgroundColor: isError ? cs.error : cs.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCredentialId == null) {
      _showResult(t('must_select_credential'), isError: true);
      return;
    }

    // The credential must still exist *now*, not merely have been chosen once.
    // The dropdown clears a stale selection, but only on its own branch: with
    // every credential deleted — or with the list still in its error state —
    // that branch never runs, no dropdown is drawn, so its validator never runs
    // either, and the id below was written back to the database. The host then
    // could never connect again and nothing on screen said why.
    final creds = ref.read(credentialListProvider).value ?? [];
    final matched = creds
        .where((c) => c.id == _selectedCredentialId)
        .firstOrNull;
    if (matched == null) {
      _showResult(t('credential_not_found'), isError: true);
      return;
    }

    final host = Host(
      id: _isEditing ? widget.existingHost!.id : const Uuid().v4(),
      alias: _aliasController.text.trim(),
      ipAddress: _ipController.text.trim(),
      port: int.parse(_portController.text.trim()),
      credentialId: matched.id,
      credentialName: matched.name,
      credentialUsername: matched.username,
      osType: _osType,
      groupName: Host.normalizeGroupName(_groupController.text),
      isOnline: widget.existingHost?.isOnline ?? false,
    );

    hapticIf(ref.read(settingsProvider).value?.hapticEnabled, HapticKind.light);

    // Awaited, so the confirmation cannot precede the write. Un-awaited, a
    // storage failure showed "saved", popped the page, and surfaced only as an
    // unhandled async error — the user lost the host and was told it worked.
    // 必须 await，否则确认提示可能早于落库。此前未 await：写盘失败时界面显示
    // 「已保存」并关闭页面，只有一个未捕获的异步错误——用户丢了主机却被告知成功。
    try {
      final notifier = ref.read(hostListProvider.notifier);
      if (_isEditing) {
        await notifier.updateItem(host);
      } else {
        await notifier.addItem(host);
      }
    } catch (e) {
      if (mounted) _showResult('${t('load_failed_msg')}: $e', isError: true);
      return;
    }
    if (!mounted) return;
    _showResult(
      _isEditing ? t('host_updated') : t('host_added'),
      isError: false,
    );

    Navigator.pop(context, true);
  }

  Future<void> _handleBack() async {
    if (_isHandlingBack) return;
    _isHandlingBack = true;
    if (_hasChanges) {
      final discard = await showAppConfirmDialog(
        context,
        title: t('discard_changes_title'),
        message: t('discard_changes_body'),
        cancelLabel: t('cancel'),
        confirmLabel: t('discard'),
        destructive: true,
      );
      if (!discard) {
        _isHandlingBack = false;
        return;
      }
    }
    if (mounted) Navigator.pop(context);
    _isHandlingBack = false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final credsAsync = ref.watch(credentialListProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(
            _isEditing ? t('edit_host') : t('add_host'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: cs.onSurface),
            onPressed: _handleBack,
          ),
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              AppCard(
                margin: const EdgeInsets.only(bottom: 20),
                padding: const EdgeInsets.all(14),
                color: cs.secondary.withValues(alpha: 0.06),
                borderColor: cs.secondary.withValues(alpha: 0.18),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: cs.secondary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        t('help_text_add_host'),
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.48),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              TextFormField(
                controller: _aliasController,
                style: TextStyle(color: cs.onSurface),
                decoration: _inputDecoration(
                  t('host_alias'),
                  hint: t('host_alias_hint'),
                ),
                textInputAction: TextInputAction.next,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? t('must_enter_alias')
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _ipController,
                style: TextStyle(color: cs.onSurface),
                decoration: _inputDecoration(
                  t('ip_address'),
                  hint: t('ip_address_hint'),
                ),
                textInputAction: TextInputAction.next,
                keyboardType: TextInputType.url,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? t('must_enter_ip') : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _portController,
                style: TextStyle(color: cs.onSurface),
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  t('port'),
                  hint: t('default_port'),
                ),
                validator: (v) {
                  final port = int.tryParse((v ?? '').trim());
                  return port == null || port <= 0 || port > 65535
                      ? t('invalid_port')
                      : null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _osType,
                dropdownColor: cs.surface,
                style: TextStyle(color: cs.onSurface),
                decoration: _inputDecoration(t('os_type')),
                items: [
                  DropdownMenuItem(
                    value: 0,
                    child: _OsOption(
                      icon: Icons.terminal,
                      label: 'Linux',
                      color: cs.primary,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 1,
                    child: _OsOption(
                      icon: Icons.desktop_windows_outlined,
                      label: 'Windows',
                      color: cs.secondary,
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _osType = v ?? 0),
              ),
              const SizedBox(height: 16),
              credsAsync.when(
                loading: () => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    '${t('error')}: $e',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.error),
                  ),
                ),
                data: (creds) {
                  if (creds.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: TextButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CredentialListPage(),
                          ),
                        ),
                        icon: Icon(Icons.vpn_key, color: cs.secondary),
                        label: Text(
                          t('add_credential_first'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: cs.secondary),
                        ),
                      ),
                    );
                  }

                  if (_selectedCredentialId != null &&
                      !creds.any((c) => c.id == _selectedCredentialId)) {
                    _selectedCredentialId = null;
                  }
                  return DropdownButtonFormField<String>(
                    initialValue: _selectedCredentialId,
                    dropdownColor: cs.surface,
                    style: TextStyle(color: cs.onSurface),
                    decoration: _inputDecoration(t('credential')),
                    hint: Text(
                      t('select_credential'),
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    items: creds
                        .map(
                          (c) => DropdownMenuItem(
                            value: c.id,
                            child: Text(
                              '${c.name} (${c.username})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: cs.onSurface),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _selectedCredentialId = v),
                    validator: (_) => _selectedCredentialId == null
                        ? t('must_select_credential')
                        : null,
                  );
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _groupController,
                style: TextStyle(color: cs.onSurface),
                decoration: _inputDecoration(
                  t('host_group'),
                  hint: t('host_group_hint'),
                ),
              ),
              // Existing groups as one-tap chips. Retyping a name is how one
              // group quietly becomes two: "prod" and "prod " are the same
              // intent and different strings, and only one of them lands in the
              // group the user meant.
              // 已有分组做成一点即填的标签。重新输入一个名字，正是分组悄悄变成两个的
              // 方式：「prod」与「prod 」是同一意图、不同字符串，而只有其中一个会落进
              // 用户想要的那个分组。
              if (_existingGroups.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final name in _existingGroups)
                      ActionChip(
                        label: Text(name),
                        onPressed: () =>
                            setState(() => _groupController.text = name),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              _ActionBar(
                isTesting: _isTesting,
                onTest: _testConnection,
                onSave: _save,
                saveLabel: _isEditing ? t('update_host') : t('save_host'),
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const CredentialListPage(),
                    ),
                  ),
                  icon: Icon(Icons.key, color: cs.secondary),
                  label: Text(
                    t('manage_credentials_link'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.secondary),
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class _OsOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _OsOption({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurface),
          ),
        ),
      ],
    );
  }
}

class _ActionBar extends StatelessWidget {
  final bool isTesting;
  final VoidCallback onTest;
  final VoidCallback onSave;
  final String saveLabel;

  const _ActionBar({
    required this.isTesting,
    required this.onTest,
    required this.onSave,
    required this.saveLabel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 46,
            child: OutlinedButton.icon(
              onPressed: isTesting ? null : onTest,
              icon: isTesting
                  ? SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.secondary,
                      ),
                    )
                  : const Icon(Icons.wifi_tethering, size: 18),
              label: Text(
                isTesting ? t('testing') : t('test_conn'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.secondary,
                side: BorderSide(color: cs.secondary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 46,
            child: FilledButton.icon(
              onPressed: onSave,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(
                saveLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
