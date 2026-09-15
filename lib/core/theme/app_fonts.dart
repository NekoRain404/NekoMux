import 'package:flutter/material.dart';

/// The typefaces this app ships with, and the single place their names live.
/// 本应用随包分发的字体，以及它们名字的唯一出处。
///
/// Both faces are **bundled**, declared in `pubspec.yaml` and stored under
/// `assets/fonts/`. They used to be fetched at runtime by `google_fonts`, which
/// meant the app's typography depended on reaching `fonts.gstatic.com` on a cold
/// start: where that host is unreachable — a guarded network, a device behind a
/// proxy, a first launch with no connectivity — the fonts silently never
/// arrived and the whole app fell back to the system face. Nothing failed, so
/// nothing said so; the app simply looked like a different app to exactly the
/// users least able to diagnose it. Bundling removes the network from the
/// startup path entirely.
/// 两款字体都是**随包分发**的：在 `pubspec.yaml` 中声明，文件放在 `assets/fonts/`
/// 下。它们此前由 `google_fonts` 在运行时获取，这意味着应用的排版在冷启动时依赖能否
/// 连上 `fonts.gstatic.com`：在该主机不可达的环境里（受限网络、走代理的设备、首次启动
/// 时没有连接），字体会静默地永远不到达，整个应用回退到系统字体。没有任何东西失败，
/// 因此也没有任何东西说出来；应用只是对最没有能力诊断它的那批用户，长成了另一个样子。
/// 随包分发把网络从启动路径上整个移除了。
class AppFonts {
  AppFonts._();

  /// The UI face. Weights 400/500/600/700 are bundled; these are the weights the
  /// theme and the widgets actually ask for, so adding another means adding a
  /// file rather than getting a synthesised approximation.
  /// 界面字体。随包提供 400/500/600/700 四个字重；它们正是主题与各控件实际用到的
  /// 字重，因此再需要别的字重意味着要补一个文件，而不是让系统去合成一个近似字形。
  static const String sans = 'Inter';

  /// The monospaced face, used where characters must align: terminal output,
  /// fingerprints, logs, container ids.
  /// 等宽字体，用于字符必须对齐之处：终端输出、指纹、日志、容器 ID。
  static const String mono = 'JetBrainsMono';

  /// A monospaced style in the bundled mono face.
  /// 使用随包等宽字体的等宽样式。
  ///
  /// Exists so no call site has to remember the family name — the ten former
  /// `GoogleFonts.jetBrainsMono(...)` sites each repeated it, and one of them
  /// spelling it differently would have quietly rendered in the fallback face.
  /// 它的存在使任何调用点都不必记住字体族名——此前十处
  /// `GoogleFonts.jetBrainsMono(...)` 各自重复该名字，其中任何一处拼写不同都会静默
  /// 地渲染成回退字体。
  static TextStyle monoText({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: mono,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
      letterSpacing: letterSpacing,
    );
  }
}
