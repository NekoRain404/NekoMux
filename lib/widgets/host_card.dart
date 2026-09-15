import 'package:flutter/material.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import 'app_ui.dart';

/// A card widget displaying a server host's online status, alias, address, OS logo, and a chevron.
/// 服务器主机卡片组件，显示在线状态、别名、地址、操作系统标志和右箭头。
class HostCard extends StatelessWidget {
  final Host host;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onMore;

  const HostCard({
    super.key,
    required this.host,
    this.onTap,
    this.onLongPress,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = host.isOnline ? colorScheme.primary : colorScheme.error;

    return AppCard(
      onTap: onTap,
      onLongPress: onLongPress,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 38,
            decoration: BoxDecoration(
              color: statusColor,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        host.alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      Host.getOsLogoChar(host.osType),
                      style: const TextStyle(fontSize: 17),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  host.displayAddress,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurface.withValues(alpha: 0.58),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    AppBadge(
                      label: host.isOnline ? t('running') : t('offline_status'),
                      color: statusColor,
                    ),
                    AppBadge(
                      label: 'SSH ${host.port}',
                      color: colorScheme.secondary,
                    ),
                    if (host.credentialUsername != null)
                      AppBadge(
                        label: host.credentialUsername!,
                        color: colorScheme.onSurface.withValues(alpha: 0.54),
                      ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: t('host_detail'),
            onPressed: onTap,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            icon: Icon(
              Icons.chevron_right,
              color: colorScheme.onSurface.withValues(alpha: 0.34),
              size: 20,
            ),
          ),
          IconButton(
            tooltip: t('more_actions'),
            onPressed: onMore ?? onLongPress,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            icon: Icon(
              Icons.more_vert,
              color: colorScheme.onSurface.withValues(alpha: 0.46),
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}
