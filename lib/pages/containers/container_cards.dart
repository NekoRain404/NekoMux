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

/// One container's status card: name, state dot, image, uptime and ports.
/// 单个容器的状态卡片：名称、状态圆点、镜像、运行时间与端口映射。
class ContainerCard extends StatelessWidget {
  /// The container to render.
  /// 要渲染的容器。
  final DockerContainer container;

  /// Called when the card is tapped (opens the action sheet).
  /// 卡片被点击时调用（打开操作面板）。
  final VoidCallback onTap;

  const ContainerCard({
    super.key,
    required this.container,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRunning = container.isRunning;
    final statusColor = isRunning ? cs.primary : cs.error;

    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      padding: const EdgeInsets.all(14),
      onTap: onTap,
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
                      fontFamily: 'monospace',
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

/// The "add container" placeholder shown at the end of the list (and alone when
/// the list is empty).
/// 列表末尾（以及列表为空时单独）展示的「新增容器」占位项。
class AddContainerNotice extends StatelessWidget {
  const AddContainerNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 20),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: cs.onSurface.withValues(alpha: 0.035),
      borderColor: Theme.of(context).dividerColor.withValues(alpha: 0.5),
      child: Row(
        children: [
          AppIconBox(
            icon: Icons.add_box_outlined,
            color: cs.onSurface.withValues(alpha: 0.34),
            size: 36,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              t('container_add_coming_soon'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.52),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          AppBadge(
            label: t('soon_badge'),
            color: cs.onSurface.withValues(alpha: 0.42),
          ),
        ],
      ),
    );
  }
}
