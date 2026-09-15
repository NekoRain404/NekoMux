/// Data model representing an SSH authentication credential.
/// 表示 SSH 认证凭证的数据模型。
class Credential {
  /// Unique identifier for this credential.
  /// 此凭证的唯一标识符。
  final String id;

  /// Human-readable label for this credential entry.
  /// 此凭证条目的可读标签。
  final String name;

  /// Authentication type: 0 = password, 1 = private key.
  /// 认证类型：0 = 密码，1 = 私钥。
  final int authType;

  /// SSH username used for authentication.
  /// 用于认证的 SSH 用户名。
  final String username;

  /// Password or private key content loaded from secure storage.
  /// 从安全存储加载出的密码或私钥内容。
  final String secretData;

  const Credential({
    required this.id,
    required this.name,
    required this.authType,
    required this.username,
    required this.secretData,
  });

  /// Creates a copy of this instance with optionally overridden fields.
  /// 创建此实例的副本，可选择性覆盖字段值。
  Credential copyWith({
    String? id,
    String? name,
    int? authType,
    String? username,
    String? secretData,
  }) {
    return Credential(
      id: id ?? this.id,
      name: name ?? this.name,
      authType: authType ?? this.authType,
      username: username ?? this.username,
      secretData: secretData ?? this.secretData,
    );
  }

  /// Serializes the credential to a database-compatible map.
  /// 将凭证序列化为数据库兼容的映射。
  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'auth_type': authType,
    'username': username,
    'secret_data': 'secure_storage',
  };

  /// Serializes the credential for user-controlled backup export.
  Map<String, dynamic> toBackupMap() => {
    'id': id,
    'name': name,
    'auth_type': authType,
    'username': username,
    'secret_data': secretData,
  };

  /// Deserializes a credential from a database row map.
  /// 从数据库行映射反序列化凭证对象。
  factory Credential.fromMap(Map<String, dynamic> map) => Credential(
    id: map['id'] as String,
    name: map['name'] as String,
    authType: map['auth_type'] as int,
    username: map['username'] as String,
    secretData: map['secret_data'] as String,
  );
}
