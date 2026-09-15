// The service page's fixed bars: the counts row, the search box, and the filter
// chips.
// 服务页面的固定栏：统计行、搜索框与筛选标签。
//
// All of them are presentation only: they render the numbers and the selection
// they are handed and report taps back, so the page stays the only place
// holding the service list and the filter state.
// 三者都只负责展示：渲染传入的计数与选中项并回传点击，因此页面仍是唯一持有服务列表
// 与筛选状态的地方。

import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';

/// Running / failed / inactive / total counts across the top of the page.
/// 页面顶部的运行 / 失败 / 未激活 / 总数统计。
class SystemdStatsBar extends StatelessWidget {
  /// How many services are `active`.
  /// `active` 状态的服务数量。
  final int running;

  /// How many services are `failed`.
  /// `failed` 状态的服务数量。
  final int failed;

  /// How many services are neither (the page's own definition of inactive).
  /// 两者皆非的服务数量（即页面自身对「未激活」的定义）。
  final int inactive;

  /// How many services were listed in total.
  /// 列出的服务总数。
  final int total;

  const SystemdStatsBar({
    super.key,
    required this.running,
    required this.failed,
    required this.inactive,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      color: cs.surface,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Expanded(child: _Stat(t('filter_running'), running, cs.primary)),
          Expanded(child: _Stat(t('filter_failed'), failed, cs.error)),
          Expanded(
            child: _Stat(
              t('filter_inactive'),
              inactive,
              cs.onSurface.withValues(alpha: 0.56),
            ),
          ),
          Expanded(child: _Stat(t('total'), total, cs.primary)),
        ],
      ),
    );
  }
}

/// One count and its label: a column of [SystemdStatsBar].
/// 单个计数及其标签：[SystemdStatsBar] 的一列。
class _Stat extends StatelessWidget {
  final String label;
  final int count;
  final Color c;

  const _Stat(this.label, this.count, this.c);

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        '$count',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: c, fontSize: 18, fontWeight: FontWeight.w700),
      ),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.56),
          fontSize: 10,
        ),
      ),
    ],
  );
}

/// The service search box: narrows the list as the user types.
/// 服务搜索框：随输入收窄列表。
class SystemdSearchField extends StatelessWidget {
  /// The page's controller, so the field's text survives a rebuild.
  /// 页面的控制器，输入内容因此能在重建后保留。
  final TextEditingController controller;

  /// The current query; a non-empty one shows the clear button.
  /// 当前查询串；非空时显示清除按钮。
  final String query;

  /// Every keystroke, verbatim.
  /// 每次输入，原样上报。
  final ValueChanged<String> onChanged;

  /// The clear button: the page empties the controller and re-filters.
  /// 清除按钮：由页面清空控制器并重新筛选。
  final VoidCallback onClear;

  const SystemdSearchField({
    super.key,
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: TextField(
        controller: controller,
        style: TextStyle(color: cs.onSurface, fontSize: 13),
        decoration: InputDecoration(
          hintText: t('search_services'),
          hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.48)),
          prefixIcon: Icon(
            Icons.search,
            color: cs.onSurface.withValues(alpha: 0.54),
            size: 18,
          ),
          suffixIcon: query.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Icons.clear,
                    size: 16,
                    color: cs.onSurface.withValues(alpha: 0.54),
                  ),
                  onPressed: onClear,
                )
              : null,
          filled: true,
          fillColor: cs.surface,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Theme.of(context).dividerColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Theme.of(context).dividerColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: cs.primary),
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

/// The All / Running / Failed / Inactive row, each chip carrying its count.
/// All / Running / Failed / Inactive 一行，每个胶囊带上各自的计数。
class SystemdFilterChips extends StatelessWidget {
  /// Counts shown on the chips, in the order they are laid out.
  /// 各胶囊上显示的计数，顺序与排布一致。
  final int total;
  final int running;
  final int failed;
  final int inactive;

  /// The filter value currently selected; exactly one chip matches it.
  /// 当前选中的筛选值；只有一个胶囊与之相符。
  final String selected;

  /// Tapping a chip: the page stores the value and re-filters.
  /// 点击胶囊：由页面保存该值并重新筛选。
  final ValueChanged<String> onSelected;

  const SystemdFilterChips({
    super.key,
    required this.total,
    required this.running,
    required this.failed,
    required this.inactive,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _FilterChip(
            'All',
            t('filter_all'),
            total,
            selected == 'All',
            onSelected,
          ),
          const SizedBox(width: 6),
          _FilterChip(
            'Running',
            t('filter_running'),
            running,
            selected == 'Running',
            onSelected,
          ),
          const SizedBox(width: 6),
          _FilterChip(
            'Failed',
            t('filter_failed'),
            failed,
            selected == 'Failed',
            onSelected,
          ),
          const SizedBox(width: 6),
          _FilterChip(
            'Inactive',
            t('filter_inactive'),
            inactive,
            selected == 'Inactive',
            onSelected,
          ),
        ],
      ),
    );
  }
}

/// One pill of [SystemdFilterChips]; tapping it reports its filter value.
/// [SystemdFilterChips] 中的单个胶囊；点击时上报其筛选值。
class _FilterChip extends StatelessWidget {
  final String value;
  final String label;
  final int count;
  final bool active;
  final ValueChanged<String> onSelected;

  const _FilterChip(
    this.value,
    this.label,
    this.count,
    this.active,
    this.onSelected,
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => onSelected(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? cs.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? cs.primary : Theme.of(context).dividerColor,
            width: 0.5,
          ),
        ),
        child: Text(
          '$label $count',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.56),
            fontSize: 11,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
