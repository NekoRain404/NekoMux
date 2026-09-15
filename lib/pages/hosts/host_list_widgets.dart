// Pieces the home screen's host list is built from: the overview card, the
// status section note, the group sub-header, and the rows of the host action
// sheet.
// 主页主机列表的构成部件：摘要卡、状态分组说明、分组子标题，以及主机操作面板的各行。
//
// Split out of `home_page.dart` so that file keeps fitting under the project's
// 800-line ceiling once search and grouping are added to it — and so the pieces
// can be rendered in a test without standing up the page, its providers, and
// its background reachability probe.
// 从 `home_page.dart` 中拆出，使该文件在加入搜索与分组后仍不超过项目 800 行的上限；
// 同时让这些部件可以在测试中单独渲染，无需搭起整个页面、它的 provider 以及后台
// 可达性探测。
import 'package:flutter/material.dart';
import '../../core/i18n/strings.dart';
import '../../models/host.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/host_card.dart';

/// The totals card at the top of the host list: total, online, unverified,
/// offline.
/// 主机列表顶部的汇总卡：总数、在线、待验证、离线。
class HostOverviewCard extends StatelessWidget {
  final int total;
  final int onlineCount;
  final int unverifiedCount;
  final int offlineCount;

  const HostOverviewCard({
    super.key,
    required this.total,
    required this.onlineCount,
    required this.unverifiedCount,
    required this.offlineCount,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Two rows of two, not one row of four. All three states plus the total have
    // to be readable at once, and at 360dp a four-across row squeezes each
    // label to roughly two thirds of what "Unverified" or "Не подтверждён"
    // needs — they would ellipsise, and a summary that hides its labels is not
    // a summary. The counts must also visibly add up: a total that does not
    // equal its parts reads as a broken screen, which is exactly what the
    // three-item version did whenever a host was unverified, i.e. on every
    // first launch.
    // 两行两列而不是一行四个。三种状态加总数必须同时可读：在 360dp 上排成一行会把每个
    // 标签压到 "Unverified" 或 "Не подтверждён" 所需宽度的约三分之二，它们会被省略号
    // 截断，而藏起标签的摘要就不成其为摘要。数字还必须一眼看得出能对上：总数与各部分不等
    // 的摘要卡看起来就是坏掉的，而这正是三格版本在有主机未验证时的表现——也就是每次首次
    // 启动都会如此。
    //
    // Labels and colours come from the same helpers the host cards use, so the
    // header and the rows below it cannot drift apart.
    // 文案与配色取自主机卡片所用的同一组 helper，因此顶部摘要与下方列表不会各说各话。
    return AppCard(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Column(
        children: [
          Row(
            children: [
              _OverviewItem(
                label: t('total'),
                value: '$total',
                color: cs.secondary,
                icon: Icons.dns_outlined,
              ),
              _OverviewDivider(),
              _OverviewItem(
                label: hostStatusLabel(HostStatus.online),
                value: '$onlineCount',
                color: hostStatusColor(cs, HostStatus.online),
                icon: Icons.check_circle_outline,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _OverviewItem(
                label: hostStatusLabel(HostStatus.unverified),
                value: '$unverifiedCount',
                color: hostStatusColor(cs, HostStatus.unverified),
                icon: Icons.help_outline,
              ),
              _OverviewDivider(),
              _OverviewItem(
                label: hostStatusLabel(HostStatus.offline),
                value: '$offlineCount',
                color: hostStatusColor(cs, HostStatus.offline),
                icon: Icons.link_off,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The sub-header that names one group inside a status section, e.g.
/// "生产 · 4".
/// 某个状态分组内为一组命名的子标题，例如「生产 · 4」。
///
/// Deliberately smaller, indented and quieter than [AppSectionHeader]: it is
/// the finer of the two facts, and a header that competed with the status
/// header above it would undo the reason for making the status the outer level.
/// 刻意比 [AppSectionHeader] 更小、更缩进、更安静：它是两个事实中更细的那个，一个与
/// 上方状态标题争抢注意力的标题会抵消掉「状态作为外层」的全部理由。
class HostGroupHeader extends StatelessWidget {
  /// Group name, or `null` for the ungrouped bucket.
  /// 分组名；未分组的分桶为 `null`。
  final String? name;

  /// Number of hosts in this group.
  /// 本组的主机数。
  final int count;

  const HostGroupHeader({super.key, required this.name, required this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = cs.onSurface.withValues(alpha: 0.52);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 10, 20, 2),
      child: Row(
        children: [
          Icon(
            name == null ? Icons.folder_off_outlined : Icons.folder_outlined,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              // `host_group_none` rather than an empty label: a bucket with no
              // heading is indistinguishable from a rendering bug.
              // 用 `host_group_none` 而不是留空：没有标题的分桶与渲染错误无从区分。
              name ?? t('host_group_none'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color.withValues(alpha: 0.8),
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// One-line explanation shown under the "unverified" section header, so the
/// state reads as "we have not checked this host yet" rather than as a failure.
/// 「待验证」分组标题下的一行说明，让该状态读起来是「我们还没核对过这台主机」
/// 而不是一次故障。
class UnverifiedNote extends StatelessWidget {
  /// Colour matching the section header and the cards below it.
  /// 与该分组标题及其下卡片一致的颜色。
  final Color color;

  const UnverifiedNote({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Text(
        t('host_status_unverified_hint'),
        style: TextStyle(color: color, fontSize: 11.5, height: 1.35),
      ),
    );
  }
}

/// One tappable row of the host action sheet.
/// 主机操作面板中的一行可点按条目。
class HostActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const HostActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: color, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _OverviewItem({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.46),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OverviewDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 32,
      color: Theme.of(context).dividerColor,
    );
  }
}
