// The bottom sheet that offers one container's actions.
// 提供单个容器操作入口的底部面板。
//
// Like the SFTP page's dialogs, this is a free function that only asks the
// question: every callback is answered by the page, which is the only thing
// holding an SSH connection.
// 与 SFTP 页面的对话框一样，这是一个只负责提问的自由函数：每个回调都由页面应答，
// 而页面是唯一持有 SSH 连接的地方。

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/haptics.dart';
import '../../core/i18n/strings.dart';
import '../../widgets/app_ui.dart';
import 'docker_commands.dart';
import 'docker_container.dart';

/// Shows the container action sheet: start/stop/restart, logs, shell, remove.
/// 显示容器操作面板：启动/停止/重启、日志、Shell、删除。
///
/// [onAction] runs a lifecycle action, [onRemove] asks for confirmation and then
/// removes, and [onShowLogs] opens the log viewer. All three are invoked after
/// the sheet has closed itself, so a dialog opened from one of them cannot end
/// up underneath it.
/// [onAction] 执行生命周期操作，[onRemove] 先确认再删除，[onShowLogs] 打开日志
/// 查看器。三者都在面板自行关闭之后才被调用，因此由它们打开的对话框不会压在面板
/// 下面。
///
/// [hapticsEnabled] is the Settings → haptic feedback flag, passed in rather
/// than read here because this is a free function with no `Ref` — the page is
/// the only thing holding one, exactly as it is for the callbacks above. It is
/// `bool?` so the caller forwards the setting unmodified: `null` means "not
/// loaded yet" and is treated as enabled by [hapticIf], so the default stays
/// defined in one place instead of being re-invented here.
/// [hapticsEnabled] 即「设置 → 触觉反馈」开关，之所以传入而不在此读取，是因为本函数
/// 是不持有 `Ref` 的自由函数——只有页面持有它，与上面那些回调的情形完全相同。它声明
/// 为 `bool?` 以便调用方原样转发设置：`null` 表示「尚未加载」，[hapticIf] 会将其视为
/// 开启，默认值因此只有一处定义，而不必在此另造一个。
void showContainerActionSheet(
  BuildContext context, {
  required DockerContainer container,
  required bool? hapticsEnabled,
  required void Function(DockerAction action) onAction,
  required VoidCallback onRemove,
  required VoidCallback onShowLogs,
}) {
  final cs = Theme.of(context).colorScheme;
  hapticIf(hapticsEnabled, HapticKind.light);
  final isRunning = container.isRunning;

  showModalBottomSheet(
    context: context,
    backgroundColor: cs.surface,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              container.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.jetBrainsMono(
                color: cs.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              container.image,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.6),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),

            /// Action buttons row. /// 操作按钮行。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (!isRunning)
                    _ActionButton(
                      icon: Icons.play_arrow,
                      label: t('start'),
                      color: cs.primary,
                      hapticsEnabled: hapticsEnabled,
                      onTap: () {
                        Navigator.pop(ctx);
                        onAction(DockerAction.start);
                      },
                    ),
                  if (isRunning)
                    _ActionButton(
                      icon: Icons.stop,
                      label: t('stop'),
                      color: cs.error,
                      hapticsEnabled: hapticsEnabled,
                      onTap: () {
                        Navigator.pop(ctx);
                        onAction(DockerAction.stop);
                      },
                    ),
                  _ActionButton(
                    icon: Icons.restart_alt,
                    label: t('restart'),
                    color: cs.secondary,
                    hapticsEnabled: hapticsEnabled,
                    onTap: () {
                      Navigator.pop(ctx);
                      onAction(DockerAction.restart);
                    },
                  ),
                  _ActionButton(
                    icon: Icons.delete_outline,
                    label: t('remove_container'),
                    color: cs.error,
                    hapticsEnabled: hapticsEnabled,
                    onTap: () {
                      Navigator.pop(ctx);
                      onRemove();
                    },
                  ),
                ],
              ),
            ),

            Divider(height: 32, color: Theme.of(context).dividerColor),

            AppCard(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              onTap: () {
                Navigator.pop(ctx);
                onShowLogs();
              },
              child: Row(
                children: [
                  Icon(
                    Icons.article_outlined,
                    color: cs.onSurface.withValues(alpha: 0.6),
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t('logs'),
                      style: TextStyle(color: cs.onSurface, fontSize: 14),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: cs.onSurface.withValues(alpha: 0.6),
                    size: 20,
                  ),
                ],
              ),
            ),

            AppCard(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: cs.onSurface.withValues(alpha: 0.04),
              borderColor: Theme.of(
                context,
              ).dividerColor.withValues(alpha: 0.5),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal,
                    color: cs.onSurface.withValues(alpha: 0.34),
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t('container_shell'),
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.46),
                        fontSize: 14,
                      ),
                    ),
                  ),
                  AppBadge(
                    label: t('soon_badge'),
                    color: cs.onSurface.withValues(alpha: 0.42),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// A compact action button used in the bottom sheet.
/// 底部弹窗中使用的紧凑操作按钮。
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  /// Settings → haptic feedback, forwarded from [showContainerActionSheet]:
  /// this widget is built inside the sheet's builder, which is the only place
  /// that knows the flag.
  /// 「设置 → 触觉反馈」，由 [showContainerActionSheet] 转发而来：本组件在面板的
  /// builder 内构建，而那里是唯一知道该标志的地方。
  final bool? hapticsEnabled;

  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.hapticsEnabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        hapticIf(hapticsEnabled, HapticKind.light);
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 72,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
