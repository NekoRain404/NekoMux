// The horizontal theme chooser shown under Settings → Appearance.
// 设置 → 外观下的横向主题选择器。
//
// It reads the selected theme from `themeIdProvider` and writes it back there;
// the previews themselves come from `AppThemeDef.presets`, so adding a preset
// makes a card appear without touching this file.
// 它从 `themeIdProvider` 读取当前主题并写回；预览配色来自 `AppThemeDef.presets`，
// 因此新增一个预设就会多出一张卡片，无需改动本文件。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/theme_provider.dart';

/// Theme picker widget — shows all themes as tappable color preview cards.
/// 主题选择控件——把所有主题显示为可点击的配色预览卡片。
class SettingsThemePicker extends ConsumerWidget {
  const SettingsThemePicker({super.key});

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
                // InkWell inside a Material rather than a bare GestureDetector:
                // a theme card is a button, and a button that gives nothing back
                // under a finger — no ripple, no highlight — reads as inert even
                // when the theme behind it has just changed.
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () =>
                        ref.read(themeIdProvider.notifier).set(preset.id),
                    borderRadius: BorderRadius.circular(8),
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
                            // The preset's id doubles as the translation key
                            // suffix, so the name is shown in the user's language.
                            // `AppThemeDef` also carries `nameZh`/`nameEn`, but
                            // only the Chinese one was ever rendered — the other
                            // six of the eight shipped languages had no way to be
                            // named, and `nameEn` was dead code.
                            // 预设的 id 同时用作翻译键的后缀，因此主题名会按用户语言显示。
                            // `AppThemeDef` 还带着 `nameZh`/`nameEn`，但此前只渲染过中文那
                            // 一个——已支持的八种语言里有六种无从命名，而 `nameEn` 是死代码。
                            t('theme_${preset.id}'),
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

/// One accent dot inside a theme preview card.
/// 主题预览卡片中的一个小色点。
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
