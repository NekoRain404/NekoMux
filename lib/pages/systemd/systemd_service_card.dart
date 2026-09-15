// The service list's row: one unit's name, description and state tags.
// 服务列表的一行：单个单元的名称、描述与状态标签。
//
// Stateless and takes everything it renders as arguments, so the page stays the
// only place that knows about the SSH connection.
// 无状态组件，渲染所需的一切都来自参数，页面因此仍是唯一了解 SSH 连接的地方。

import 'package:flutter/material.dart';

import '../../core/theme/app_fonts.dart';

import '../../widgets/app_ui.dart';
import 'systemd_visuals.dart';

/// One service's row: unit name, description, and the three state tags.
/// 单个服务的行：单元名称、描述，以及三个状态标签。
class SystemdServiceCard extends StatelessWidget {
  /// The parsed `systemctl` row to render.
  /// 要渲染的 `systemctl` 解析行。
  final Map<String, dynamic> svc;

  /// Called when the card is tapped (opens the action sheet).
  /// 卡片被点击时调用（打开操作面板）。
  final VoidCallback onTap;

  const SystemdServiceCard({super.key, required this.svc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = svc['active'] as String;
    final ac = systemdStateColor(context, active);
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      padding: const EdgeInsets.all(12),
      borderColor: ac.withValues(alpha: 0.7),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  svc['unit'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFamily: AppFonts.mono,
                  ),
                ),
                if ((svc['description'] as String).isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    svc['description'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.56),
                      fontSize: 11,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 5,
                  runSpacing: 3,
                  children: [
                    _tag(active, ac),
                    _tag(
                      svc['sub'] as String,
                      systemdStateColor(context, svc['sub'] as String),
                    ),
                    _tag(
                      svc['load'] as String,
                      cs.onSurface.withValues(alpha: 0.56),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            color: cs.onSurface.withValues(alpha: 0.3),
            size: 18,
          ),
        ],
      ),
    );
  }
}

/// One state tag inside the card: the badge the whole app uses for one.
/// 卡片内的单个状态标签：全应用统一使用的徽标。
Widget _tag(String label, Color c) => AppBadge(label: label, color: c);
