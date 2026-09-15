import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/i18n/strings.dart';
import '../models/credential.dart';
import '../providers/providers.dart';
import '../widgets/app_ui.dart';

/// Page for adding a new credential or editing an existing one.
class AddCredentialPage extends ConsumerStatefulWidget {
  final Credential? existingCredential;
  const AddCredentialPage({super.key, this.existingCredential});

  @override
  ConsumerState<AddCredentialPage> createState() => _AddCredentialPageState();
}

class _AddCredentialPageState extends ConsumerState<AddCredentialPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _usernameController;
  late final TextEditingController _secretController;
  late int _authType;
  String? _keyValidationError;
  bool _isHandlingBack = false;

  bool get _isEditing => widget.existingCredential != null;
  bool get _hasChanges {
    final c = widget.existingCredential;
    if (c == null) {
      return _nameController.text.trim().isNotEmpty ||
          _usernameController.text.trim().isNotEmpty ||
          _secretController.text.trim().isNotEmpty ||
          _authType != 0;
    }
    final secretChanged =
        _secretController.text != '••••••••' &&
        _secretController.text != c.secretData;
    return _nameController.text.trim() != c.name ||
        _usernameController.text.trim() != c.username ||
        _authType != c.authType ||
        secretChanged;
  }

  @override
  void initState() {
    super.initState();
    final c = widget.existingCredential;
    _nameController = TextEditingController(text: c?.name ?? '');
    _usernameController = TextEditingController(text: c?.username ?? '');
    _secretController = TextEditingController(
      text: _isEditing ? '••••••••' : '',
    );
    _authType = c?.authType ?? 0;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _secretController.dispose();
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

  String? _validateKey(String? value) {
    if (_authType != 1) return null;
    if (value == null || value.trim().isEmpty) {
      return t('must_enter_key_content');
    }
    if (value == '••••••••') return null;
    final trimmed = value.trim();
    final validStart = [
      '-----BEGIN RSA PRIVATE KEY-----',
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      '-----BEGIN EC PRIVATE KEY-----',
      '-----BEGIN PRIVATE KEY-----',
      '-----BEGIN ED25519 PRIVATE KEY-----',
    ];
    final hasValidStart = validStart.any((start) => trimmed.startsWith(start));
    if (!hasValidStart) return t('key_invalid_format');
    if (!trimmed.contains('-----END') ||
        !trimmed.contains('PRIVATE KEY-----')) {
      return t('key_incomplete');
    }
    return null;
  }

  void _save() {
    HapticFeedback.lightImpact();
    if (!_formKey.currentState!.validate()) return;
    final cs = Theme.of(context).colorScheme;

    final secretData = _secretController.text == '••••••••' && _isEditing
        ? widget.existingCredential!.secretData
        : _secretController.text;

    final cred = Credential(
      id: _isEditing ? widget.existingCredential!.id : const Uuid().v4(),
      name: _nameController.text.trim(),
      authType: _authType,
      username: _usernameController.text.trim(),
      secretData: secretData,
    );

    if (_isEditing) {
      ref.read(credentialListProvider.notifier).updateItem(cred);
    } else {
      ref.read(credentialListProvider.notifier).addItem(cred);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _isEditing ? t('credential_updated') : t('credential_added'),
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: cs.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: cs.onSurface),
            onPressed: _handleBack,
          ),
          title: Text(
            _isEditing ? t('edit_credential') : t('add_credential'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
                color: cs.primary.withValues(alpha: 0.06),
                borderColor: cs.primary.withValues(alpha: 0.18),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, color: cs.primary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        t('credential_encrypted_notice'),
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
                controller: _nameController,
                style: TextStyle(color: cs.onSurface),
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  t('credential_name'),
                  hint: t('credential_name_hint'),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? t('must_enter_name')
                    : null,
              ),
              const SizedBox(height: 16),
              Text(
                t('auth_method'),
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.48),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _AuthTypeCard(
                      icon: Icons.password_outlined,
                      label: t('password_auth'),
                      selected: _authType == 0,
                      color: cs.secondary,
                      onTap: () => setState(() {
                        _authType = 0;
                        _keyValidationError = null;
                      }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _AuthTypeCard(
                      icon: Icons.key_outlined,
                      label: t('key_auth'),
                      selected: _authType == 1,
                      color: cs.primary,
                      onTap: () => setState(() {
                        _authType = 1;
                        _keyValidationError = null;
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _usernameController,
                style: TextStyle(color: cs.onSurface),
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  t('username'),
                  hint: t('username_hint'),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? t('must_enter_username')
                    : null,
              ),
              const SizedBox(height: 16),
              if (_authType == 0)
                TextFormField(
                  controller: _secretController,
                  style: TextStyle(color: cs.onSurface),
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  decoration: _inputDecoration(
                    t('password'),
                    hint: t('password_hint'),
                  ),
                  onFieldSubmitted: (_) => _save(),
                  validator: (v) {
                    if (_isEditing && v == '••••••••') return null;
                    return (v == null || v.isEmpty)
                        ? t('must_enter_password')
                        : null;
                  },
                )
              else ...[
                TextFormField(
                  controller: _secretController,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                  maxLines: 10,
                  minLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: _inputDecoration(
                    t('private_key'),
                    hint: t('private_key_hint'),
                    error: _keyValidationError,
                  ),
                  onChanged: (v) {
                    setState(() => _keyValidationError = _validateKey(v));
                  },
                  validator: _validateKey,
                ),
                if (_keyValidationError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: cs.error,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _keyValidationError!,
                            style: TextStyle(color: cs.error, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_keyValidationError == null &&
                    _secretController.text.length > 5 &&
                    _secretController.text != '••••••••')
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: cs.primary, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            t('key_format_valid'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: cs.primary, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(
                    _isEditing ? t('update_credential') : t('save_credential'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

/// Animated selectable card for authentication type selection.
class _AuthTypeCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _AuthTypeCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : cs.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : dividerColor,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            AnimatedScale(
              scale: selected ? 1.2 : 1.0,
              duration: const Duration(milliseconds: 250),
              child: Icon(
                icon,
                color: selected ? color : cs.onSurface.withValues(alpha: 0.52),
                size: 24,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? color : cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
