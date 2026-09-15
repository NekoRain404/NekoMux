import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/haptics.dart';
import '../core/i18n/strings.dart';
import '../models/credential.dart';
import '../providers/providers.dart';
import '../providers/settings_provider.dart';
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

  /// Whether the user has typed secret material of their own.
  /// 用户是否已自行输入密钥内容（密码或私钥）。
  bool _hasUserSecret = false;

  /// Whether the auth method was switched on this page. A secret stored for
  /// the previous method must never be reused afterwards.
  /// 本页是否切换过认证方式；切换后不得复用此前存储的密钥。
  bool _authTypeSwitched = false;

  bool get _isEditing => widget.existingCredential != null;

  /// Whether saving may reuse the secret already in secure storage: only while
  /// editing, only when the user typed nothing, and only when the auth method
  /// still matches the one the stored secret belongs to.
  /// 保存时是否可以沿用安全存储中已有的密钥：
  /// 仅在编辑模式、用户未输入内容、且认证方式未切换时为 true。
  bool get _keepStoredSecret =>
      _isEditing &&
      !_hasUserSecret &&
      !_authTypeSwitched &&
      widget.existingCredential!.secretData.isNotEmpty;

  bool get _hasChanges {
    final c = widget.existingCredential;
    if (c == null) {
      return _nameController.text.trim().isNotEmpty ||
          _usernameController.text.trim().isNotEmpty ||
          _secretController.text.trim().isNotEmpty ||
          _authType != 0;
    }
    final secretChanged =
        !_keepStoredSecret &&
        _secretController.text.isNotEmpty &&
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
    // The field always starts empty: the stored secret is never written into
    // it, so typed input can never be appended to a placeholder value.
    // 输入框始终以空内容开始：已存储的密钥绝不写入输入框，
    // 因此用户输入永远不会拼接在占位内容之后。
    _secretController = TextEditingController();
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
    // Keeping the stored key unchanged is a state decision, never a text match.
    // 沿用已存储的私钥是状态判断，绝不依赖文本比对。
    if (_keepStoredSecret) return null;
    if (value == null || value.trim().isEmpty) {
      return t('must_enter_key_content');
    }
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

  /// Switches the auth method and invalidates whatever the secret field holds.
  /// Material of one kind must never be carried over to the other kind.
  /// 切换认证方式，并作废输入框中的内容：
  /// 一种认证方式的密钥材料绝不能顺延到另一种认证方式。
  void _selectAuthType(int type) {
    if (_authType == type) return;
    setState(() {
      _authType = type;
      _keyValidationError = null;
      _authTypeSwitched = true;
      _hasUserSecret = false;
      _secretController.clear();
    });
  }

  void _save() {
    hapticIf(ref.read(settingsProvider).value?.hapticEnabled, HapticKind.light);
    if (!_formKey.currentState!.validate()) return;
    final cs = Theme.of(context).colorScheme;

    // Reuse the stored secret only when no new material was typed and the auth
    // method still matches what the stored secret was created for.
    // 仅在用户未输入新内容、且认证方式与已存储密钥相符时才沿用旧密钥。
    final secretData = _keepStoredSecret
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
                      hapticsEnabled: ref
                          .read(settingsProvider)
                          .value
                          ?.hapticEnabled,
                      onTap: () => _selectAuthType(0),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _AuthTypeCard(
                      icon: Icons.key_outlined,
                      label: t('key_auth'),
                      selected: _authType == 1,
                      color: cs.primary,
                      hapticsEnabled: ref
                          .read(settingsProvider)
                          .value
                          ?.hapticEnabled,
                      onTap: () => _selectAuthType(1),
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
                  // Distinct keys rebuild the field when the auth method is
                  // switched, so no stale validation state survives the swap.
                  // 使用不同的 Key，切换认证方式时重建输入框，不残留旧的校验状态。
                  key: const ValueKey('credential_password_field'),
                  controller: _secretController,
                  style: TextStyle(color: cs.onSurface),
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  decoration: _inputDecoration(
                    t('password'),
                    hint: _keepStoredSecret
                        ? t('secret_kept_hint')
                        : t('password_hint'),
                  ),
                  onChanged: (v) =>
                      setState(() => _hasUserSecret = v.isNotEmpty),
                  onFieldSubmitted: (_) => _save(),
                  validator: (v) {
                    if (_authType != 0) return null;
                    if (_keepStoredSecret) return null;
                    return (v == null || v.isEmpty)
                        ? t('must_enter_password')
                        : null;
                  },
                )
              else ...[
                TextFormField(
                  key: const ValueKey('credential_private_key_field'),
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
                    hint: _keepStoredSecret
                        ? t('secret_kept_hint')
                        : t('private_key_hint'),
                    error: _keyValidationError,
                  ),
                  onChanged: (v) {
                    setState(() {
                      _hasUserSecret = v.isNotEmpty;
                      _keyValidationError = _validateKey(v);
                    });
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
                    _hasUserSecret &&
                    _secretController.text.length > 5)
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

  /// Settings → haptic feedback, forwarded by the page: this card is a leaf
  /// widget with no `Ref`, and the flag has to travel with the tap it belongs
  /// to rather than being read from a global.
  /// 「设置 → 触觉反馈」，由页面转发：本卡片是不持有 `Ref` 的叶子组件，标志必须随
  /// 它所修饰的那次点击一同传入，而不是从全局读取。
  final bool? hapticsEnabled;

  const _AuthTypeCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.color,
    required this.hapticsEnabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    return GestureDetector(
      onTap: () {
        // Kept ahead of the (possibly early-returning) `onTap`: selecting the
        // already-selected card used to click, and still does.
        // 仍然先于（可能提前返回的）`onTap` 执行：点击已选中的卡片过去会发出反馈，
        // 现在依然会。
        hapticIf(hapticsEnabled, HapticKind.selection);
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
