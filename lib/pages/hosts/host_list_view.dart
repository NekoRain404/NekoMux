import 'package:flutter/material.dart';
import '../../core/i18n/strings.dart';
import '../../models/host.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/host_card.dart';
import 'host_list_model.dart';
import 'host_list_widgets.dart';

/// The home screen's scrollable host list: the overview card, then one section
/// per reachability state, each split into its groups.
/// 主页可滚动的主机列表：先是摘要卡，然后每个可达性状态一个分组，各分组内再按组切分。
///
/// Presentational only — it is handed the display model that
/// [buildHostSections] produced and calls back for anything that needs a route,
/// a provider or a dialog. That is what lets it be rendered in a test without
/// the page's background reachability probe running underneath it.
/// 纯展示：它接收 [buildHostSections] 产出的展示模型，凡涉及路由、provider 或对话框的
/// 操作一律回调出去。正因如此，它可以在测试中单独渲染，而不必让其下跑起页面的后台
/// 可达性探测。
class HostListView extends StatelessWidget {
  /// Sections in display order, including empty ones.
  /// 按显示顺序排列的分组，含空分组。
  final List<HostSection> sections;

  /// Whether a search query is currently narrowing the list.
  /// 当前是否有搜索词在收窄列表。
  final bool hasQuery;

  /// Opens the add-host form, from the empty state.
  /// 从空状态打开新增主机表单。
  final VoidCallback onAddHost;

  final void Function(Host host) onOpenHost;

  /// Opens the action sheet; used by both the long press and the "more" button.
  /// 打开操作面板；长按与「更多」按钮共用。
  final void Function(Host host) onHostOptions;

  const HostListView({
    super.key,
    required this.sections,
    required this.hasQuery,
    required this.onAddHost,
    required this.onOpenHost,
    required this.onHostOptions,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final visible = [for (final s in sections) if (s.count > 0) s];
    final showGroupHeaders = shouldShowGroupHeaders(sections);

    if (visible.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        children: [hasQuery ? _buildNoResults(cs) : _buildEmptyState(context, cs)],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 12, bottom: 32),
      children: [
        // The counts describe what is on screen, not the whole inventory, so
        // that in every state — plain list or filtered — the overview, the
        // section headers and the cards agree with each other. A total that
        // stayed at "12" above two visible rows would read as a broken screen,
        // and the numbers adding up is exactly the property that was worth
        // fixing here. With no query the two are the same list, so the common
        // case is unchanged.
        // 计数描述的是屏幕上的内容，而非全部清单，这样无论在哪种状态下——平铺列表还是
        // 过滤后的列表——摘要、分组标题与卡片三者都彼此一致。在只显示两行时总数仍写着
        // 「12」，读起来就是一个坏掉的界面，而「数字能对上」正是这里当初值得修的性质。
        // 没有搜索词时二者本就是一回事，因此常见路径毫无变化。
        HostOverviewCard(
          total: sections.fold(0, (sum, s) => sum + s.count),
          onlineCount: _countOf(HostStatus.online),
          unverifiedCount: _countOf(HostStatus.unverified),
          offlineCount: _countOf(HostStatus.offline),
        ),
        for (var i = 0; i < visible.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          AppSectionHeader(
            title: _sectionTitle(visible[i].status),
            trailing: '${visible[i].count}',
            color: hostStatusColor(cs, visible[i].status),
          ),
          // Unverified hosts get their own section between the two, and this
          // line of explanation. They are neither usable-as-confirmed nor known
          // to be down: filing them under "Offline" would state an outage
          // nobody measured, which is how a user learns that a red section
          // means nothing — and then misses the one that does.
          // 待验证的主机在两个分组之间单列，并带上这句说明。它们既不是「可用且已确认」，
          // 也不是「确知宕机」：归入「离线」等于宣称一次无人测量过的故障，那正是用户
          // 学会「红色分组不代表什么」的途径，之后连有意义的那次也会被忽略。
          if (visible[i].status == HostStatus.unverified)
            UnverifiedNote(color: hostStatusColor(cs, HostStatus.unverified)),
          for (final group in visible[i].groups) ...[
            if (showGroupHeaders)
              HostGroupHeader(name: group.name, count: group.hosts.length),
            ...group.hosts.map(_buildHostCard),
          ],
        ],
      ],
    );
  }

  int _countOf(HostStatus status) => sections
      .where((s) => s.status == status)
      .fold(0, (sum, s) => sum + s.count);

  /// Section header text. The status names are the ones this page has always
  /// used; the badge labels on the cards are shorter and stay on the cards.
  /// 分组标题文案，沿用本页一直使用的状态名；卡片上的徽标文案更短，留在卡片上。
  String _sectionTitle(HostStatus status) => switch (status) {
    HostStatus.online => t('online_hosts'),
    HostStatus.unverified => t('host_status_unverified'),
    HostStatus.offline => t('offline_hosts'),
  };

  Widget _buildHostCard(Host host) => HostCard(
    host: host,
    onTap: () => onOpenHost(host),
    onLongPress: () => onHostOptions(host),
    onMore: () => onHostOptions(host),
  );

  /// Shown when a query matched nothing.
  /// 搜索无匹配时显示。
  ///
  /// A dedicated message, not the "no hosts yet" state: those are opposite
  /// facts, and telling a user with twelve hosts that they have none is the
  /// kind of thing they remember about the app.
  /// 使用专门的文案，而非「还没有添加主机」的状态：这是两个相反的事实，而告诉一位
  /// 存有十二台主机的用户「一台都没有」是会被记住的那种事。
  ///
  /// The subtitle is the search field's own hint, reused rather than rewritten.
  /// Nothing matched, and the likeliest reason is that the term is not something
  /// this field covers — the group name is the one people reach for first, and
  /// it is deliberately not searched.
  /// 副标题复用搜索框自身的提示词，而非另写一句。没有匹配，而最可能的原因是那个词不在
  /// 本输入框覆盖的范围内——人们最先想到的正是分组名，而它被刻意排除在搜索之外。
  Widget _buildNoResults(ColorScheme cs) {
    return SizedBox(
      height: 300,
      child: AppEmptyState(
        icon: Icons.search_off,
        title: t('no_search_results'),
        message: t('search_hosts'),
        color: cs.onSurface.withValues(alpha: 0.6),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, ColorScheme cs) {
    return SizedBox(
      height: 360,
      child: AppEmptyState(
        icon: Icons.dns_outlined,
        title: t('empty_hosts'),
        message: t('empty_hosts_hint'),
        actionLabel: t('add_host'),
        color: cs.primary,
        onAction: onAddHost,
      ),
    );
  }
}
