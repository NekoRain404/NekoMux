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

/// The data sections a backup payload carries.
/// 备份载荷携带的各个数据分节。
///
/// [key] is the JSON key used in the payload, [table] is the database table the
/// rows belong to. Keeping both here means export and restore cannot drift.
/// [key] 是载荷中的 JSON 键，[table] 是对应的数据库表；二者集中于此，
/// 导出与恢复不会再发生错位。
enum BackupSection {
  hosts(key: 'hosts', table: 'tb_hosts'),
  credentials(key: 'credentials', table: 'tb_credentials'),
  snippets(key: 'snippets', table: 'tb_snippets'),

  /// The `tb_settings` key/value rows — theme, language, font size, connect
  /// timeout and whatever else the settings table holds.
  /// `tb_settings` 的键值对行——主题、语言、字号、连接超时，以及设置表中其它内容。
  ///
  /// Optional on *read* only, and only because of age: payloads written before
  /// settings were backed up have no settings section at all, so [readBackupRows]
  /// returns an empty list for a missing one instead of throwing the way it does
  /// for the three above. The exporter always writes the section; a device whose
  /// settings table is empty simply writes `[]`.
  /// 仅在**读取**时可缺席，且原因只是新旧之别：在设置被纳入备份之前写出的载荷完全没有
  /// 设置分节，因此 [readBackupRows] 在缺失时返回空列表，而不像上面三节那样抛异常。
  /// 导出端总会写入该分节；设置表为空的设备写出的就是 `[]`。
  settings(key: 'settings', table: 'tb_settings', optional: true);

  const BackupSection({
    required this.key,
    required this.table,
    this.optional = false,
  });

  /// Canonical JSON key of this section in a backup payload.
  /// 本节在备份载荷中的规范 JSON 键。
  final String key;

  /// Database table holding this section's rows.
  /// 存放本节数据行的数据库表。
  final String table;

  /// Whether a payload may legitimately carry no such section.
  /// 载荷是否可以合法地不携带该分节。
  ///
  /// True for [settings] alone. A missing *mandatory* section is never "nothing
  /// to restore" — that is the mismatch [readBackupRows] was made to throw on,
  /// after a silently wrong key name restored an empty backup over the user's
  /// data. A missing settings section, by contrast, is exactly what every
  /// payload written before settings were exported looks like, and it has to
  /// keep restoring.
  /// 只有 [settings] 为真。**必需**分节缺失绝不等于「没有数据可恢复」——那正是
  /// [readBackupRows] 改为止损抛出异常的键名错位：一次静默的键名错误曾把一份空备份
  /// 覆盖到用户数据上。而设置分节缺失恰恰是「设置被导出之前写出的每一份载荷」的样子，
  /// 它必须继续能恢复。
  final bool optional;
}

/// Builds the payload written by Settings → Export Backup.
/// 构建「设置 → 导出备份」写入的载荷。
///
/// [credentials] must already be mapped (e.g. `Credential.toBackupMap()`) so
/// this module stays free of model imports.
/// [credentials] 需为已映射好的行（如 `Credential.toBackupMap()`），
/// 以使本模块不依赖任何模型。
///
/// [settings] carries the `tb_settings` rows — the theme, the language, the font
/// size, the connect timeout. It is the caller's to gather, because this module
/// has no database, and it defaults to empty so that a caller which does not
/// gather them still compiles and still produces a payload the reader accepts.
/// That default is a compatibility floor, not an endorsement: the tile that
/// opens this export says "export all data as JSON", and a backup that silently
/// carries no settings is what people discover only after wiping the old phone.
/// A caller that can read the table passes every row of it.
/// [settings] 携带 `tb_settings` 的数据行——主题、语言、字号、连接超时。收集这些行是
/// 调用方的事，因为本模块没有数据库；它的默认值是空，好让不收集它们的调用方仍然可以
/// 编译，并且仍然产出读取端接受的载荷。那个默认值是兼容底线，不是认可：打开这个导出的
/// 磁贴写的是「导出所有数据为 JSON」，而一份悄悄不含设置的备份，人们往往在抹掉旧手机
/// 之后才发现。能读表的调用方会把它整表传进来。
///
/// The section is additive, so the payload version stays [backupPayloadVersion]:
/// a payload carrying it still restores on a build that predates it (the section
/// is simply ignored there), and a payload that lacks it — every payload written
/// by such a build — still restores here, because the section is
/// [BackupSection.optional].
/// 该分节是纯增量的，因此载荷版本保持 [backupPayloadVersion]：携带它的载荷在更早的构建
/// 上仍能恢复（那里只是忽略该分节），而缺少它的载荷——更早构建写出的每一份都是——在这里
/// 也仍能恢复，因为该分节是 [BackupSection.optional]。
Map<String, dynamic> buildExportPayload({
  required List<Map<String, dynamic>> hosts,
  required List<Map<String, dynamic>> credentials,
  required List<Map<String, dynamic>> snippets,
  List<Map<String, dynamic>> settings = const [],
  DateTime? exportedAt,
  int version = backupPayloadVersion,
}) => {
  'version': version,
  'exported_at': (exportedAt ?? DateTime.now()).toIso8601String(),
  BackupSection.hosts.key: hosts,
  BackupSection.credentials.key: credentials,
  BackupSection.snippets.key: snippets,
  BackupSection.settings.key: settings,
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
///
/// The absence rule has exactly one exception, and it is a property of the
/// section rather than of this function: an [BackupSection.optional] section
/// ([BackupSection.settings]) returns an empty list when it is missing, because
/// every payload written before it existed is missing it and still has to
/// restore. Nothing about that weakens the rule for the other three — they are
/// not optional, and a missing one still throws, which is what keeps a wrong key
/// name from silently restoring an empty backup. Keeping the flag on the enum
/// instead of adding a second, laxer reader means a caller cannot accidentally
/// ask for "hosts, but optional", or reach for the loose reader out of habit.
/// 缺失规则只有一个例外，而且它是分节自身的属性，不是本函数的属性：
/// [BackupSection.optional] 的分节（[BackupSection.settings]）缺失时返回空列表，
/// 因为凡是它出现之前写出的载荷都缺它，且仍必须能恢复。这丝毫没有削弱另外三节的规则
/// ——它们不可选，缺失时照样抛异常，而正是这一点让错误的键名无法静默恢复出一份空备份。
/// 把标志放在枚举上、而不是再加一个更宽松的读取函数，是为了让调用方不可能误问「主机，
/// 但可选」，也不可能出于习惯去够那个宽松的读取函数。
List<Map<String, dynamic>> readBackupRows(
  Map<String, dynamic> payload,
  BackupSection section,
) {
  final value = payload[section.key] ?? payload[section.table];
  if (value == null) {
    if (section.optional) return const [];
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
