// The app's identity, in one place.
// 应用标识信息的唯一来源。
//
// Both constants must be kept in step with `pubspec.yaml` BY HAND. The name
// mirrors the package/description there; the version mirrors its `version:`
// field, which is currently `1.0.0+1` — the `+1` is the build number Flutter
// stamps onto every APK, not part of the version a user is shown, so it stays
// out of [appVersion].
// 两个常量都必须与 `pubspec.yaml` 手工保持同步：名称对应其中的包名/描述，版本对应
// `version:` 字段（当前为 `1.0.0+1`——`+1` 是 Flutter 打进每个 APK 的构建号，
// 不属于展示给用户的版本号，因此不写进 [appVersion]）。
//
// This file exists because the version used to be three unrelated literals — the
// drawer footer, the About dialog and the Settings "About" row — and one of them
// had already drifted (`v1.0.0-beta`, against a `1.0.0+1` pubspec). Reading the
// real values at runtime (a `package_info_plus`-style plugin) would remove the
// manual step entirely, but it needs a new dependency and a rebuild; until then
// this constant is the one place to edit when the version changes.
// 之所以有本文件：版本号此前是三处互不相干的字面量——抽屉页脚、关于对话框、设置页
// 「关于」行——其中一处已经与 `1.0.0+1` 的 pubspec 脱节（`v1.0.0-beta`）。在运行时
// 读取真实值（`package_info_plus` 之类的插件）可以彻底免去手工同步，但需要新增依赖
// 并重新构建；在那之前，改版本号只需要改这里的常量。

/// Application name, as shown in the drawer header, the task-switcher title and
/// the About dialog.
/// 应用名称，用于抽屉页眉、任务切换器标题与关于对话框。
const String appName = 'NekoMux';

/// User-visible version, without the `+build` suffix — `1.0.0` for a pubspec of
/// `version: 1.0.0+1`.
/// 用户可见的版本号，不含 `+构建号` 后缀——pubspec 中的 `version: 1.0.0+1` 对应
/// `1.0.0`。
const String appVersion = '1.0.0';
