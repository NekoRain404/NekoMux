// The service-state colour table of the service manager.
// 服务管理的服务状态颜色表。
//
// Kept apart from the widgets that draw it because two surfaces need the very
// same mapping: the list card's border and tags, and the action sheet's chips.
// Two copies of this table would drift the moment either one is touched.
// 单独成文件，是因为有两处界面需要完全相同的映射：列表卡片的边框与标签，以及操作面板
// 的胶囊。两份副本只要动了一处就会开始不一致。

import 'package:flutter/material.dart';

/// Colour for service state [s] under [context]'s colour scheme.
/// 服务状态 [s] 在 [context] 配色方案下的颜色。
Color systemdStateColor(BuildContext context, String s) {
  final cs = Theme.of(context).colorScheme;
  switch (s.toLowerCase()) {
    case 'active':
    case 'running':
      return cs.primary;
    case 'failed':
      return cs.error;
    case 'activating':
    case 'reloading':
    case 'deactivating':
      return const Color(0xFFD29922);
    default:
      return cs.onSurface.withValues(alpha: 0.56);
  }
}
