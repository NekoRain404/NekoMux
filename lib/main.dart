import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';

/// App entry point. Initializes Flutter bindings, sets a transparent status bar
/// with light icons, then runs the app wrapped in a Riverpod ProviderScope.
/// 应用入口。初始化 Flutter 绑定，设置透明状态栏和浅色图标，然后用 Riverpod
/// ProviderScope 包裹运行应用。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const ProviderScope(child: NekoMuxApp()));
}
