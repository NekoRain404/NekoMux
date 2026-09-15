// The language chooser shown under Settings → Interaction.
// 设置 → 交互下的语言选择对话框。
//
// Like the other Settings dialogs it only asks: it is handed the current
// language, lists what `AppStrings.supportedLanguages` offers, and returns the
// code the user picked — or null when the dialog was dismissed. Applying it is
// the page's job, so this file never writes a provider.
// 与其它设置对话框一样，它只负责询问：接收当前语言，列出
// `AppStrings.supportedLanguages` 提供的选项，并返回用户选择的语言代码，被关闭时
// 返回 null。是否应用由页面决定，因此本文件从不写 provider。
import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../widgets/app_ui.dart';

/// Offers every supported language; returns the chosen code, or null.
/// 列出所有支持的语言；返回所选语言代码，或 null。
Future<String?> showLanguagePickerDialog(
  BuildContext context, {
  required String current,
}) {
  final languages = AppStrings.supportedLanguages;
  final maxHeight = MediaQuery.sizeOf(context).height * 0.62;
  return showDialog<String>(
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
                onTap: () => Navigator.pop(ctx, e.key),
              );
            }).toList(),
          ),
        ),
      ),
    ),
  );
}

/// One language row, ticked when it is the one in use.
/// 单个语言行，当前使用的语言带勾选标记。
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
