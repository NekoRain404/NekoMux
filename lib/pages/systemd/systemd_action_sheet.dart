// The bottom sheet that offers one service's actions, and the two small pieces
// it is built from.
// 提供单个服务操作入口的底部面板，以及构成它的两个小部件。
//
// Like the container page's sheet, this is a free function that only asks the
// question: every action is reported to the page, which is the only thing
// holding an SSH connection.
// 与容器页面的面板一样，这是一个只负责提问的自由函数：每个操作都上报给页面，而页面
// 是唯一持有 SSH 连接的地方。

import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import 'systemd_visuals.dart';

/// Shows the service action sheet: start/stop/restart, reload, enable/disable.
/// 显示服务操作面板：启动/停止/重启、重载、启用/禁用。
///
/// [onAction] receives the bare action name (`start`, `stop`, …) of the entry
/// that was tapped, and is invoked after the sheet has closed itself, so the
/// confirmation dialog opened from it cannot end up underneath the sheet.
/// [onAction] 收到被点击条目的裸操作名（`start`、`stop` 等）；它在面板自行关闭之后才
/// 被调用，因此由它打开的确认对话框不会压在面板下面。
void showSystemdActionSheet(
  BuildContext context, {
  required Map<String, dynamic> svc,
  required ValueChanged<String> onAction,
}) {
  final cs = Theme.of(context).colorScheme;
  final unit = svc['unit'] as String;
  final active = svc['active'] as String;
  showModalBottomSheet(
    context: context,
    backgroundColor: cs.surface,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              unit,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
            ),
            if ((svc['description'] as String).isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                svc['description'] as String,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.56),
                  fontSize: 12,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StateChip(active, systemdStateColor(context, active)),
                _StateChip(
                  svc['sub'] as String,
                  systemdStateColor(context, svc['sub'] as String),
                ),
                _StateChip(
                  svc['load'] as String,
                  cs.onSurface.withValues(alpha: 0.56),
                ),
              ],
            ),
            const SizedBox(height: 20),
            GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.5,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _ServiceActionButton(
                  Icons.play_arrow,
                  t('systemd_start'),
                  cs.primary,
                  () {
                    Navigator.pop(ctx);
                    onAction('start');
                  },
                ),
                _ServiceActionButton(
                  Icons.stop,
                  t('systemd_stop'),
                  cs.error,
                  () {
                    Navigator.pop(ctx);
                    onAction('stop');
                  },
                ),
                _ServiceActionButton(
                  Icons.restart_alt,
                  t('systemd_restart'),
                  const Color(0xFFD29922),
                  () {
                    Navigator.pop(ctx);
                    onAction('restart');
                  },
                ),
                _ServiceActionButton(
                  Icons.refresh,
                  t('systemd_reload'),
                  cs.primary,
                  () {
                    Navigator.pop(ctx);
                    onAction('reload');
                  },
                ),
                _ServiceActionButton(
                  Icons.check_circle_outline,
                  t('systemd_enable'),
                  cs.primary,
                  () {
                    Navigator.pop(ctx);
                    onAction('enable');
                  },
                ),
                _ServiceActionButton(
                  Icons.block,
                  t('systemd_disable'),
                  cs.onSurface.withValues(alpha: 0.56),
                  () {
                    Navigator.pop(ctx);
                    onAction('disable');
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// One state chip in the sheet's header row.
/// 面板标题行中的单个状态胶囊。
class _StateChip extends StatelessWidget {
  final String label;
  final Color c;

  const _StateChip(this.label, this.c);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: c.withValues(alpha: 0.3)),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );
}

/// One tile of the sheet's action grid.
/// 面板操作网格中的单个瓷片。
class _ServiceActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color c;
  final VoidCallback fn;

  const _ServiceActionButton(this.icon, this.label, this.c, this.fn);

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: fn,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: c, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
