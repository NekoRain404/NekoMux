/// Data model representing a saved terminal command snippet.
/// 表示已保存的终端命令片段的数据模型。
class Snippet {
  /// Unique identifier for this snippet.
  /// 此片段的唯一标识符。
  final String id;

  /// Human-readable title describing the command.
  /// 描述该命令的可读标题。
  final String title;

  /// The actual shell command text.
  /// 实际的 shell 命令文本。
  final String command;

  const Snippet({required this.id, required this.title, required this.command});

  /// Creates a copy of this instance with optionally overridden fields.
  /// 创建此实例的副本，可选择性覆盖字段值。
  Snippet copyWith({String? id, String? title, String? command}) {
    return Snippet(
      id: id ?? this.id,
      title: title ?? this.title,
      command: command ?? this.command,
    );
  }

  /// Serializes the snippet to a database-compatible map.
  /// 将片段序列化为数据库兼容的映射。
  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'command': command,
  };

  /// Deserializes a snippet from a database row map.
  /// 从数据库行映射反序列化片段对象。
  factory Snippet.fromMap(Map<String, dynamic> map) => Snippet(
    id: map['id'] as String,
    title: map['title'] as String,
    command: map['command'] as String,
  );
}
