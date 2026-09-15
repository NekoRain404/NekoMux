// Shared haptic feedback, honouring the "haptic feedback" app setting.
// 共享的触觉反馈，遵循「触觉反馈」应用设置。
//
// Eleven call sites used to invoke `HapticFeedback.*` unconditionally while
// Settings → haptic feedback persisted a switch that nothing outside the
// settings page ever read, so turning it off changed nothing (audit: settings
// that lie). [hapticIf] is now the only place that decides whether a feedback
// call is made at all, and the site-level rule is "call this, never
// `HapticFeedback` directly" — which is what keeps a new call site from
// silently re-introducing the bug.
// 过去有十一处无条件调用 `HapticFeedback.*`，而「设置 → 触觉反馈」持久化的开关
// 除设置页外没有任何地方读取，关掉它什么也不会改变（审计：会撒谎的设置）。
// 如今只有 [hapticIf] 决定是否发出反馈，调用点的规则是「调用它，绝不直接调用
// `HapticFeedback`」——这正是新增调用点不会悄悄让该缺陷复活的原因。
//
// This file imports nothing but `flutter/services.dart` on purpose.
// `docs/ARCHITECTURE.md` places `core/` below `providers/`
// (`UI pages -> providers -> services/database`), so reading the setting here
// would invert the layering; the caller holds the `Ref` and passes the flag in.
// 本文件刻意只引入 `flutter/services.dart`。`docs/ARCHITECTURE.md` 把 `core/`
// 放在 `providers/` 之下（`UI pages -> providers -> services/database`），在这里
// 读取设置会颠倒分层；由持有 `Ref` 的调用方把标志位传进来。

import 'package:flutter/services.dart';

/// The [HapticFeedback] variants this app uses.
/// 本应用用到的 [HapticFeedback] 变体。
enum HapticKind { light, medium, heavy, selection }

/// Fires [kind] unless the user has switched haptics off.
/// 除非用户关闭了触觉反馈，否则发出 [kind]。
///
/// [enabled] is the `hapticEnabled` setting, and it is nullable deliberately:
/// `null` means the settings have not finished loading, which must behave as
/// the **default** — enabled. That way the one place that knows what the
/// default is, is this function, instead of a `?? true` repeated at every call
/// site, where a single `?? false` would silently swallow every vibration on a
/// cold start.
/// [enabled] 即 `hapticEnabled` 设置，它可为空是有意为之：`null` 表示设置尚未
/// 加载完成，此时必须按**默认值**处理，即开启。这样「默认是什么」只有本函数知道，
/// 而不是在每个调用点重复 `?? true`——那里只要有一处写成 `?? false`，冷启动时的
/// 所有振动都会被悄悄吞掉。
void hapticIf(bool? enabled, HapticKind kind) {
  // Only `false` suppresses: an unloaded setting is not a "no".
  // 只有 `false` 才抑制：设置未加载并不等于「否」。
  if (enabled == false) return;
  switch (kind) {
    case HapticKind.light:
      HapticFeedback.lightImpact();
    case HapticKind.medium:
      HapticFeedback.mediumImpact();
    case HapticKind.heavy:
      HapticFeedback.heavyImpact();
    case HapticKind.selection:
      HapticFeedback.selectionClick();
  }
}
