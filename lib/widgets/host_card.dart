import 'package:flutter/material.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import 'app_ui.dart';

/// Colour for a reachability state, for the theme in [cs].
/// 在 [cs] 主题下，某个可达性状态对应的颜色。
///
/// [HostStatus.unverified] deliberately gets a muted, neutral tone instead of
/// the theme's error colour: such a host is one whose state we could not
/// determine — its key is untrusted, so we refused the handshake — not one
/// known to be down. Red has to keep meaning "down" if it is to mean anything.
/// [HostStatus.unverified] 刻意使用柔和中性的色调，而非主题的错误色：这类主机是
/// 我们无法判定状态的主机——其密钥未受信，因此我们拒绝握手——而不是确知宕机的主机。
/// 红色必须继续表示「宕机」，否则它就不再表示任何东西。
Color hostStatusColor(ColorScheme cs, HostStatus status) => switch (status) {
  HostStatus.online => cs.primary,
  HostStatus.unverified => cs.onSurface.withValues(alpha: 0.5),
  HostStatus.offline => cs.error,
};

/// Badge label for a reachability state, from the existing translation keys.
/// 某可达性状态对应的徽标文案，取自现有翻译键。
String hostStatusLabel(HostStatus status) => switch (status) {
  HostStatus.online => t('running'),
  HostStatus.unverified => t('host_status_unverified'),
  HostStatus.offline => t('offline_status'),
};

/// A card widget displaying a server host's reachability status, alias, address, OS logo, and a chevron.
/// 服务器主机卡片组件，显示可达性状态、别名、地址、操作系统标志和右箭头。
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
    final statusColor = hostStatusColor(colorScheme, host.status);

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
                      label: hostStatusLabel(host.status),
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
