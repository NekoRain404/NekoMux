import 'package:flutter/material.dart';

import '../core/i18n/strings.dart';
import '../services/known_hosts_store.dart';

/// Asks the user to decide about a host key that is not already trusted.
/// 当主机密钥尚未受信时，询问用户如何处置。
///
/// The two verdicts are deliberately rendered as different dialogs. A
/// [HostKeyVerdict.unknown] key is the ordinary first-connection case: the user
/// has never seen this server before and is confirming its identity. A
/// [HostKeyVerdict.changed] key means this server used to present a *different*
/// key, which is the only signal the app can give that the connection may be
/// intercepted — so it gets a warning title, an explanatory body, and a
/// confirmation label that requires the user to have checked the fingerprint
/// elsewhere. Showing both as the same dialog would train users to tap through
/// the one prompt that matters.
/// 两种判定刻意渲染成不同的对话框。[HostKeyVerdict.unknown] 是普通的首次连接：
/// 用户此前没见过这台服务器，正在确认其身份。[HostKeyVerdict.changed] 意味着这台
/// 服务器以前用的是**另一个**密钥——这是应用能给出的、连接可能被劫持的唯一信号，
/// 因此它使用警告标题、需要解释的正文，以及一个要求用户已通过其它渠道核对过指纹的
/// 确认按钮。把两者做成同一个对话框，会让用户习惯性略过真正重要的那一次询问。
///
/// Returns true when the user accepted the key.
/// 用户接受该密钥时返回 true。
Future<bool> showHostKeyPrompt(
  BuildContext context, {
  required String fingerprint,
  required HostKeyVerdict verdict,
}) async {
  final cs = Theme.of(context).colorScheme;
  final dividerColor = Theme.of(context).dividerColor;
  final isChanged = verdict == HostKeyVerdict.changed;

  // A changed key is a warning, so it takes the theme's error colour; a first
  // contact is informational.
  // 密钥变化属于警告，使用主题的错误色；首次连接只是信息提示。
  final accent = isChanged ? cs.error : cs.secondary;

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: Row(
        children: [
          Icon(
            isChanged
                ? Icons.gpp_maybe_outlined
                : Icons.warning_amber_rounded,
            color: accent,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isChanged ? t('host_key_changed_title') : t('host_key_verify'),
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isChanged
                ? t('host_key_changed_body')
                : t('cannot_verify_host_key'),
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.6),
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isChanged
                    ? cs.error.withValues(alpha: 0.45)
                    : dividerColor,
                width: isChanged ? 1 : 0.5,
              ),
            ),
            child: SelectableText(
              fingerprint,
              style: TextStyle(
                color: isChanged ? cs.error : cs.primary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(t('reject'), style: TextStyle(color: cs.error)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            isChanged ? t('host_key_trust_anyway') : t('accept'),
            style: TextStyle(color: isChanged ? cs.error : cs.primary),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}
