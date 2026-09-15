import 'package:flutter/material.dart';
import '../core/i18n/strings.dart';

/// Horizontal scrollable quick-access key bar for terminal. Each key triggers a callback when tapped.
/// 横向可滚动的终端快捷按键栏，每个按键可触发回调。
class QuickKeyBar extends StatelessWidget {
  final void Function(String label, String sequence)? onKeyTap;
  final VoidCallback? onSnippetsTap;

  const QuickKeyBar({super.key, this.onKeyTap, this.onSnippetsTap});

  static const _keys = <_KeyDef>[
    _KeyDef('Tab', '\t', null),
    _KeyDef('↑', '\x1B[A', null),
    _KeyDef('↓', '\x1B[B', null),
    _KeyDef('←', '\x1B[D', null),
    _KeyDef('→', '\x1B[C', null),
    _KeyDef('Home', '\x1B[H', null),
    _KeyDef('End', '\x1B[F', null),
    _KeyDef('PgUp', '\x1B[5~', null),
    _KeyDef('PgDn', '\x1B[6~', null),
    _KeyDef('Esc', '\x1B', null),
    _KeyDef('C-c', '\x03', null),
    _KeyDef('C-d', '\x04', null),
    _KeyDef('C-z', '\x1A', null),
    _KeyDef('/', '/', null),
    _KeyDef('|', '|', null),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final primaryColor = colorScheme.primary;
    final errorColor = colorScheme.error;
    final secondaryColor = colorScheme.secondary;

    return Container(
      color: colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (onSnippetsTap != null)
              _KeyPill(
                label: '{}',
                tooltip: t('snippets'),
                color: primaryColor,
                onTap: onSnippetsTap,
              ),
            ..._keys.map((k) {
              Color? keyColor;
              if (k.label == 'C-c' || k.label == 'C-d') {
                keyColor = errorColor;
              } else if (k.label == 'C-z') {
                keyColor = secondaryColor;
              } else {
                keyColor = k.color;
              }
              return _KeyPill(
                label: k.label,
                tooltip: k.label,
                color: keyColor,
                onTap: onKeyTap != null
                    ? () => onKeyTap!(k.label, k.sequence)
                    : null,
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _KeyPill extends StatelessWidget {
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;
  final Color? color;

  const _KeyPill({required this.label, this.tooltip, this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      child: Material(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            constraints: const BoxConstraints(minWidth: 42, minHeight: 34),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.withValues(alpha: 0.4), width: 0.5),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyDef {
  final String label;
  final String sequence;
  final Color? color;
  const _KeyDef(this.label, this.sequence, this.color);
}
