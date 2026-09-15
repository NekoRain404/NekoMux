import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../providers/providers.dart';

/// App-wide settings stored as key-value pairs in tb_settings.
/// 全局应用设置，以键值对形式存储在 tb_settings 表中。
class AppSettings {
  int terminalFontSize;
  int defaultPort;
  int connectTimeout;
  bool isDarkMode;
  bool hapticEnabled;
  String language;
  String themeId;

  AppSettings({
    this.terminalFontSize = 13,
    this.defaultPort = 22,
    this.connectTimeout = 10,
    this.isDarkMode = true,
    this.hapticEnabled = true,
    this.language = 'zh',
    this.themeId = 'neko_dark',
  });

  AppSettings copyWith({
    int? terminalFontSize,
    int? defaultPort,
    int? connectTimeout,
    bool? isDarkMode,
    bool? hapticEnabled,
    String? language,
    String? themeId,
  }) {
    return AppSettings(
      terminalFontSize: terminalFontSize ?? this.terminalFontSize,
      defaultPort: defaultPort ?? this.defaultPort,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      isDarkMode: isDarkMode ?? this.isDarkMode,
      hapticEnabled: hapticEnabled ?? this.hapticEnabled,
      language: language ?? this.language,
      themeId: themeId ?? this.themeId,
    );
  }

  /// Parse from raw key-value map.
  /// 从原始键值对 Map 解析。
  factory AppSettings.fromMap(Map<String, String> map) {
    return AppSettings(
      terminalFontSize: int.tryParse(map['terminal_font_size'] ?? '') ?? 13,
      defaultPort: int.tryParse(map['default_port'] ?? '') ?? 22,
      connectTimeout: int.tryParse(map['connect_timeout'] ?? '') ?? 10,
      isDarkMode: map['is_dark_mode'] != 'false',
      hapticEnabled: map['haptic_enabled'] != 'false',
      language: map['language'] ?? 'zh',
      themeId: map['theme_id'] ?? 'neko_dark',
    );
  }

  /// Convert to key-value pairs for storage.
  /// 转换为键值对以便存储。
  Map<String, String> toMap() => {
    'terminal_font_size': terminalFontSize.toString(),
    'default_port': defaultPort.toString(),
    'connect_timeout': connectTimeout.toString(),
    'is_dark_mode': isDarkMode.toString(),
    'haptic_enabled': hapticEnabled.toString(),
    'language': language,
    'theme_id': themeId,
  };
}

/// Settings notifier — loads from db on build, persists on change.
/// 设置状态通知器——构建时从数据库加载，更改时持久化。
class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final db = await ref.watch(databaseProvider.future);
    final rows = await db.query('tb_settings');
    final map = {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
    return AppSettings.fromMap(map);
  }

  Future<void> updateSettings(AppSettings settings) async {
    final db = await ref.read(databaseProvider.future);
    for (final entry in settings.toMap().entries) {
      await db.insert('tb_settings', {
        'key': entry.key,
        'value': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    ref.invalidateSelf();
  }
}

/// Global settings provider.
/// 全局设置提供者。
final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
