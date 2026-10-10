// The container list's presentation: the status card for one container and the
// notice at the end of the list.
// 容器列表的展示层：单个容器的状态卡片，以及列表末尾的提示。
//
// Both are stateless and take everything they render as arguments, so the page
// stays the only place that knows about the SSH connection.
// 两者都是无状态组件，渲染所需的一切都来自参数，页面因此仍是唯一了解 SSH 连接的
// 地方。

import 'package:flutter/material.dart';

import '../../core/theme/app_fonts.dart';
import '../../core/i18n/strings.dart';
import '../../widgets/app_ui.dart';
import 'docker_container.dart';
import 'docker_stats.dart';

/// One container's status card: name, state dot, image, uptime and ports.
/// 单个容器的状态卡片：名称、状态圆点、镜像、运行时间与端口映射。
class ContainerCard extends StatelessWidget {
  /// The container to render.
  /// 要渲染的容器。
  final DockerContainer container;

  /// Called when the card is tapped (opens the action sheet). Ignored while
  /// [busy], since the sheet's actions are the ones already running.
  final VoidCallback onTap;

  /// True while a `docker` command for THIS container is in flight.
  ///
  /// The status dot keeps showing the daemon's last known answer, which for a
  /// stop/restart is the state before the command — so without this the card
  /// looks untouched for the seconds `docker stop` takes, and tapping again
  /// issues a second one. The spinner says "in progress" without claiming a
  /// state the daemon has not reported yet.
  final bool busy;

  /// Live resource use, or null when there is none to show.
  ///
  /// Optional because it comes from a second command that runs after the list
  /// is already on screen: the listing is what the page is for, and these
  /// numbers fill in when they arrive rather than holding the list back. A
  /// stopped container has none, and a host that refused the snapshot leaves
  /// every card without one — the row is absent rather than showing a zero,
  /// which would be a measurement nobody took.
  final ContainerStats? stats;

  const ContainerCard({
    super.key,
    required this.container,
    required this.onTap,
    this.busy = false,
    this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRunning = container.isRunning;
    final statusColor = isRunning ? cs.primary : cs.error;

    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      padding: const EdgeInsets.all(14),
      onTap: busy ? null : onTap,
      borderColor: Theme.of(context).dividerColor.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /// Row 1: container name + status dot. /// 第一行：容器名称 + 状态圆点。
          Row(
            children: [
              Expanded(
                child: Text(
                  container.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.monoText(
                    color: cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (busy)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: cs.secondary,
                  ),
                )
              else
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: statusColor.withValues(alpha: 0.5),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  container.statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),

          // Resource use sits directly under the name, ahead of the image and
          // the uptime. It is the one line here that changes between two looks
          // at this list, and finding the container that is eating the machine
          // is the reason the list gets opened on a phone at all.
          //
          // Only the amount in use is shown, never `14.72MiB / 2GiB`: the
          // daemon puts the host's total RAM after that slash for a container
          // with no memory limit, and nothing in the snapshot says which case a
          // row is. See `ContainerStats.memoryUsed`.
          if (stats != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.speed,
                  color: stats!.isBusy
                      ? cs.error
                      : cs.onSurface.withValues(alpha: 0.6),
                  size: 14,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'CPU ${stats!.cpuPercent.toStringAsFixed(2)}% · '
                    '${stats!.memoryUsed}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: stats!.isBusy
                          ? cs.error
                          : cs.onSurface.withValues(alpha: 0.75),
                      fontSize: 12,
                      fontFamily: AppFonts.mono,
                      fontWeight: stats!.isBusy
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 8),

          /// Row 2: image name. /// 第二行：镜像名称。
          Row(
            children: [
              Icon(
                Icons.layers_outlined,
                color: cs.onSurface.withValues(alpha: 0.6),
                size: 14,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  container.image,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          /// Row 3: uptime. /// 第三行：运行时间。
          Row(
            children: [
              Icon(
                Icons.timer_outlined,
                color: cs.onSurface.withValues(alpha: 0.6),
                size: 14,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${t('container_uptime')}: ${container.uptime}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          /// Row 4: port mapping (if any). /// 第四行：端口映射（如有）。
          if (container.ports.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.settings_ethernet,
                  color: cs.onSurface.withValues(alpha: 0.6),
                  size: 14,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    container.ports,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.secondary.withValues(alpha: 0.8),
                      fontSize: 11,
                      fontFamily: AppFonts.mono,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
