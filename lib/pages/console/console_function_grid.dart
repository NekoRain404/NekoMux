import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../models/host.dart';
import '../../widgets/function_grid_tile.dart';
import '../container_shell_page.dart';
import '../sftp_page.dart';
import '../ssh_terminal_page.dart';
import '../systemd_page.dart';
import '../tunnels_page.dart';
import '../task_manager_page.dart';

/// The feature launcher under the resource panel.
/// 资源面板下方的功能入口。
///
/// Every tile opens a page that really does the thing it names; the one that
/// does not exist yet (remote desktop) is disabled and badged as upcoming
/// rather than opening a plausible-looking fake.
/// 每个瓷片都打开一个真正能做该事的页面；唯一尚不存在的能力（远程桌面）被禁用并
/// 标注「即将支持」，而不是打开一个看起来像样的假页面。
class ConsoleFunctionGrid extends StatelessWidget {
  /// Host whose modules are launched.
  /// 要启动模块的主机。
  final Host host;

  const ConsoleFunctionGrid({super.key, required this.host});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mutedPurple = Color.lerp(cs.primary, cs.secondary, 0.55)!;
    final warmAccent = Color.lerp(cs.error, cs.secondary, 0.35)!;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              t('function_modules'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.35,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              FunctionGridTile(
                icon: Icons.terminal,
                iconColor: cs.primary,
                title: t('terminal'),
                subtitle: 'SSH ${host.port}',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SshTerminalPage(host: host),
                  ),
                ),
              ),
              FunctionGridTile(
                icon: Icons.folder_outlined,
                iconColor: cs.secondary,
                title: t('file_manager'),
                subtitle: t('sftp_protocol'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SftpPage(host: host)),
                ),
              ),
              FunctionGridTile(
                icon: Icons.memory,
                iconColor: mutedPurple,
                title: t('process_manager'),
                subtitle: t('task_manager'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TaskManagerPage(host: host),
                  ),
                ),
              ),
              FunctionGridTile(
                icon: Icons.miscellaneous_services,
                iconColor: warmAccent,
                title: t('service_manager'),
                subtitle: 'systemd',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SystemdPage(host: host)),
                ),
              ),
              FunctionGridTile(
                icon: Icons.dashboard_outlined,
                iconColor: cs.secondary,
                title: t('containers'),
                subtitle: t('docker'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ContainerShellPage(host: host),
                  ),
                ),
              ),
              // Real, and verified end to end on a device: the tunnel carries
              // bytes from a local socket through the SSH session to a port only
              // the server can reach. It says how long it lasts on its own page.
              FunctionGridTile(
                icon: Icons.swap_horiz,
                iconColor: mutedPurple,
                title: t('port_forwarding'),
                subtitle: t('new_tunnel'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => TunnelsPage(host: host)),
                ),
              ),
              FunctionGridTile(
                icon: Icons.desktop_windows_outlined,
                iconColor: cs.onSurface.withValues(alpha: 0.42),
                title: t('remote_desktop'),
                subtitle: t('vnc'),
                enabled: false,
                badge: t('soon_badge'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
