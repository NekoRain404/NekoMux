import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../core/i18n/strings.dart';
import 'providers.dart';
import 'settings_provider.dart';

final themeIdProvider = NotifierProvider<ThemeIdNotifier, String>(
  ThemeIdNotifier.new,
);
final isDarkProvider = NotifierProvider<IsDarkNotifier, bool>(
  IsDarkNotifier.new,
);
final languageProvider = NotifierProvider<LanguageNotifier, String>(
  LanguageNotifier.new,
);

/// Helper: read current settings, apply a copyWith, and save only changed keys.
Future<void> _saveSetting(
  Ref ref,
  AppSettings Function(AppSettings) update,
) async {
  final current = await ref.read(settingsProvider.future);
  final changed = update(current);
  for (final e in current.toMap().entries) {
    final newVal = changed.toMap()[e.key];
    if (newVal != null && newVal != e.value) {
      final db = await ref.read(databaseProvider.future);
      await db.insert('tb_settings', {
        'key': e.key,
        'value': newVal,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
  ref.invalidate(settingsProvider);
}

class ThemeIdNotifier extends Notifier<String> {
  @override
  String build() {
    final s = ref.watch(settingsProvider);
    return s.value?.themeId ?? 'neko_dark';
  }

  void set(String id) {
    state = id;
    _saveSetting(ref, (s) => s.copyWith(themeId: id));
  }
}

class IsDarkNotifier extends Notifier<bool> {
  @override
  bool build() {
    final s = ref.watch(settingsProvider);
    return s.value?.isDarkMode ?? true;
  }

  void toggle() => set(!state);
  void set(bool v) {
    state = v;
    _saveSetting(ref, (s) => s.copyWith(isDarkMode: v));
  }
}

class LanguageNotifier extends Notifier<String> {
  @override
  String build() {
    final s = ref.watch(settingsProvider);
    final lang = s.value?.language ?? 'zh';
    AppStrings.currentLang = lang;
    return lang;
  }

  void set(String lang) {
    AppStrings.currentLang = lang;
    state = lang;
    _saveSetting(ref, (s) => s.copyWith(language: lang));
  }
}
