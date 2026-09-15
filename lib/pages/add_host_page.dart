import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../providers/providers.dart';
import '../providers/ssh_provider.dart';
import '../widgets/app_ui.dart';
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
  late int _osType;
  String? _selectedCredentialId;
  bool _isTesting = false;
  bool _isHandlingBack = false;

  bool get _isEditing => widget.existingHost != null;
  bool get _hasChanges {
    final h = widget.existingHost;
    if (h == null) {
      return _aliasController.text.trim().isNotEmpty ||
          _ipController.text.trim().isNotEmpty ||
          _portController.text.trim() != '22' ||
          _osType != 0 ||
          _selectedCredentialId != null;
    }
    return _aliasController.text.trim() != h.alias ||
        _ipController.text.trim() != h.ipAddress ||
        _portController.text.trim() != h.port.toString() ||
        _osType != h.osType ||
        _selectedCredentialId != h.credentialId;
  }

  @override
  void initState() {
    super.initState();
    final h = widget.existingHost;
    _aliasController = TextEditingController(text: h?.alias ?? '');
    _ipController = TextEditingController(text: h?.ipAddress ?? '');
    _portController = TextEditingController(text: (h?.port ?? 22).toString());
    _osType = h?.osType ?? 0;
    _selectedCredentialId = h?.credentialId;
  }

  @override
  void dispose() {
    _aliasController.dispose();
    _ipController.dispose();
    _portController.dispose();
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
    HapticFeedback.mediumImpact();

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

    final result = await testConnection(host: testHost, credential: cred);

    if (!mounted) return;
    setState(() => _isTesting = false);

    if (result == 'ok') {
      _showResult(t('conn_success_detail'), isError: false);
      HapticFeedback.heavyImpact();
    } else {
      _showResult('❌ $result', isError: true);
      HapticFeedback.heavyImpact();
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

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCredentialId == null) {
      _showResult(t('must_select_credential'), isError: true);
      return;
    }

    final creds = ref.read(credentialListProvider).value ?? [];
    final matched = creds
        .where((c) => c.id == _selectedCredentialId)
        .firstOrNull;

    final host = Host(
      id: _isEditing ? widget.existingHost!.id : const Uuid().v4(),
      alias: _aliasController.text.trim(),
      ipAddress: _ipController.text.trim(),
      port: int.parse(_portController.text.trim()),
      credentialId: _selectedCredentialId!,
      credentialName: matched?.name,
      credentialUsername: matched?.username,
      osType: _osType,
      isOnline: widget.existingHost?.isOnline ?? false,
    );

    HapticFeedback.lightImpact();

    if (_isEditing) {
      ref.read(hostListProvider.notifier).updateItem(host);
      _showResult(t('host_updated'), isError: false);
    } else {
      ref.read(hostListProvider.notifier).addItem(host);
      _showResult(t('host_added'), isError: false);
    }

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
