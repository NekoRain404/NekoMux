import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/app_info.dart';
import 'core/theme/app_theme.dart';
import 'providers/theme_provider.dart';
import 'pages/add_host_page.dart';
import 'pages/credential_list_page.dart';
import 'pages/home_page.dart';
import 'pages/settings_page.dart';
import 'pages/snippet_list_page.dart';

class NekoMuxApp extends ConsumerWidget {
  const NekoMuxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeId = ref.watch(themeIdProvider);
    final isDark = ref.watch(isDarkProvider);

    // Watching the language here is what makes a saved language survive a cold
    // start. `LanguageNotifier.build()` is the only thing that writes
    // `AppStrings.currentLang`, and nothing on the startup path used to read
    // this provider — only the Settings page did. So a language chosen in
    // Settings was applied while the app ran and then silently lost on the next
    // launch, until the user happened to open Settings again.
    // 在这里订阅语言，是「保存的语言能跨冷启动生效」的关键。只有
    // `LanguageNotifier.build()` 会写入 `AppStrings.currentLang`，而启动路径上
    // 原本没有任何地方读这个 provider——只有设置页会读。于是在设置里选好的语言
    // 只在本次运行内生效，下次启动就静默丢失，直到用户碰巧再打开一次设置页。
    final language = ref.watch(languageProvider);

    final theme = AppThemeDef.presets.firstWhere(
      (t) => t.id == themeId,
      orElse: () => AppThemeDef.presets.first,
    );
    return MaterialApp(
      // `t()` reads a global, not an InheritedWidget, so descendants do not
      // depend on anything that would rebuild them when the language changes —
      // and `home`/the route widgets are `const`, so an identical widget
      // instance is reused and Flutter skips the whole subtree. Keying on the
      // language forces a fresh element tree, which is the only thing that
      // makes an already-built screen re-read the new translations.
      // Trade-off: changing the language returns to the first route, since the
      // Navigator is recreated with everything else. That is a deliberate
      // choice over the alternatives (screens keeping the old language until
      // they happen to rebuild) — switching the language is rare and the result
      // is immediately visible.
      // `t()` 读的是全局变量而不是 InheritedWidget，因此后代并不依赖任何会在语言
      // 变化时重建它们的东西；而 `home` 与各路由 widget 都是 `const`，同一个实例
      // 会被复用，Flutter 会整棵子树跳过。以语言为 key 才能强制重建元素树——这是
      // 让已经构建好的界面重新读取新译文的唯一办法。
      // 代价：切换语言会回到首个路由，因为 Navigator 随之重建。这是有意选择的
      // 取舍（另一种是界面继续显示旧语言直到因其它原因重建）——切换语言很少发生，
      // 且结果立即可见。
      key: ValueKey<String>('locale-$language'),
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: theme.buildTheme(isDark: isDark),
      home: const HomePage(),
      routes: {
        '/add-host': (_) => const AddHostPage(),
        '/credentials': (_) => const CredentialListPage(),
        '/settings': (_) => const SettingsPage(),
        '/snippets': (_) => const SnippetListPage(),
      },
    );
  }
}
