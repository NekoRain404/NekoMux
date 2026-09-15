import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    final theme = AppThemeDef.presets.firstWhere(
      (t) => t.id == themeId,
      orElse: () => AppThemeDef.presets.first,
    );
    return MaterialApp(
      title: 'NekoMux',
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
