import 'package:flutter/material.dart';
import '../../core/i18n/strings.dart';

/// The home screen's host search box.
/// 主页的主机搜索框。
///
/// Stateless on purpose: the controller belongs to the page, which already
/// listens to it to rebuild the list. A widget that owned its own state would
/// need a second channel to tell the page what was typed, and the two could
/// disagree.
/// 刻意做成无状态：控制器属于页面，页面本就监听它来重建列表。自己持有状态的组件需要
/// 第二条通道把输入内容告诉页面，而两者可能不一致。
///
/// It clears through the same controller, so the "clear" button cannot leave the
/// list filtered by text the field no longer shows.
/// 清除按钮同样通过该控制器生效，因此「清除」不可能让列表继续按输入框已不再显示的
/// 文字过滤。
class HostSearchField extends StatelessWidget {
  final TextEditingController controller;

  const HostSearchField({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dividerColor = Theme.of(context).dividerColor;
    final outline = OutlineInputBorder(
      borderSide: BorderSide(color: dividerColor),
      borderRadius: const BorderRadius.all(Radius.circular(8)),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: TextField(
        controller: controller,
        style: TextStyle(color: cs.onSurface, fontSize: 14),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: cs.surface,
          hintText: t('search_hosts'),
          hintStyle: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.36),
            fontSize: 13.5,
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 19,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 40,
          ),
          // Only while there is something to clear, so the field does not carry
          // a dead control in its resting state.
          // 仅在确实有内容可清除时出现，输入框在常态下不会挂着一个无效控件。
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: t('cancel'),
                  visualDensity: VisualDensity.compact,
                  onPressed: controller.clear,
                  icon: Icon(
                    Icons.close,
                    size: 17,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
          enabledBorder: outline,
          focusedBorder: outline.copyWith(
            borderSide: BorderSide(color: cs.secondary, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
      ),
    );
  }
}
