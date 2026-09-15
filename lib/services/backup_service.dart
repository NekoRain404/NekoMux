// Pure Dart helpers for the Settings → Export / Restore backup payload.
// 设置 → 导出 / 恢复备份载荷的纯 Dart 辅助模块。
//
// No Flutter, no sqflite: this file only knows about JSON shapes so that the
// export side and the restore side share one definition of the payload and can
// never disagree about key names again.
// 不依赖 Flutter 与 sqflite：本文件只处理 JSON 结构，使导出与恢复共用同一份
// 载荷定义，不会再出现键名错位。
import 'dart:convert';

/// Version stamped into every exported backup payload.
/// 写入每份导出备份载荷的版本号。
const int backupPayloadVersion = 1;

/// The three data sections carried by a backup payload.
/// 备份载荷携带的三个数据分节。
///
/// [key] is the JSON key used in the payload, [table] is the database table the
/// rows belong to. Keeping both here means export and restore cannot drift.
/// [key] 是载荷中的 JSON 键，[table] 是对应的数据库表；二者集中于此，
/// 导出与恢复不会再发生错位。
enum BackupSection {
  hosts(key: 'hosts', table: 'tb_hosts'),
  credentials(key: 'credentials', table: 'tb_credentials'),
  snippets(key: 'snippets', table: 'tb_snippets');

  const BackupSection({required this.key, required this.table});

  /// Canonical JSON key of this section in a backup payload.
  /// 本节在备份载荷中的规范 JSON 键。
  final String key;

  /// Database table holding this section's rows.
  /// 存放本节数据行的数据库表。
  final String table;
}

/// Builds the payload written by Settings → Export Backup.
/// 构建「设置 → 导出备份」写入的载荷。
///
/// [credentials] must already be mapped (e.g. `Credential.toBackupMap()`) so
/// this module stays free of model imports.
/// [credentials] 需为已映射好的行（如 `Credential.toBackupMap()`），
/// 以使本模块不依赖任何模型。
Map<String, dynamic> buildExportPayload({
  required List<Map<String, dynamic>> hosts,
  required List<Map<String, dynamic>> credentials,
  required List<Map<String, dynamic>> snippets,
  DateTime? exportedAt,
  int version = backupPayloadVersion,
}) => {
  'version': version,
  'exported_at': (exportedAt ?? DateTime.now()).toIso8601String(),
  BackupSection.hosts.key: hosts,
  BackupSection.credentials.key: credentials,
  BackupSection.snippets.key: snippets,
};

/// Decodes the JSON text pasted into Settings → Restore Backup.
/// 解析「设置 → 恢复备份」中粘贴的 JSON 文本。
///
/// Throws a [FormatException] with a human-readable message when the text is
/// not valid JSON or is not a JSON object.
/// 当文本不是合法 JSON 或不是 JSON 对象时，抛出带可读信息的 [FormatException]。
Map<String, dynamic> parseBackupPayload(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw FormatException('Backup is not valid JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw const FormatException('Backup must be a JSON object');
  }
  return Map<String, dynamic>.from(decoded);
}

/// Reads one section of a parsed backup payload as database-ready rows.
/// 从已解析的备份载荷中读取某一分节，返回可直接写入数据库的行。
///
/// Accepts the canonical [BackupSection.key] and, for payloads written by older
/// builds, the legacy table-name key. Throws a [FormatException] — never
/// returns an empty list — when the section is absent or malformed, so a
/// mismatch can no longer be mistaken for "nothing to restore".
/// 接受规范的 [BackupSection.key]，并兼容旧版本按表名写入的键。当分节缺失或
/// 结构错误时抛出 [FormatException] 而绝不返回空列表，避免键名错位被误当作
/// 「没有数据可恢复」。
List<Map<String, dynamic>> readBackupRows(
  Map<String, dynamic> payload,
  BackupSection section,
) {
  final value = payload[section.key] ?? payload[section.table];
  if (value == null) {
    throw FormatException('Backup is missing the "${section.key}" section');
  }
  if (value is! List) {
    throw FormatException('Invalid backup field: ${section.key}');
  }
  return value.map((row) {
    if (row is! Map) {
      throw FormatException('Invalid row in backup field: ${section.key}');
    }
    return Map<String, dynamic>.from(row);
  }).toList();
}
