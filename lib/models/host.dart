/// Data model representing a remote server host configuration.
/// 表示远程服务器主机配置的数据模型。
class Host {
  /// Unique identifier for this host.
  /// 此主机的唯一标识符。
  final String id;

  /// Human-readable alias for the server.
  /// 服务器的可读别名。
  final String alias;

  /// IP address or hostname of the server.
  /// 服务器的 IP 地址或主机名。
  final String ipAddress;

  /// SSH port number (default 22).
  /// SSH 端口号（默认 22）。
  final int port;

  /// Foreign key referencing the associated credential record.
  /// 外键，引用关联的凭证记录。
  final String credentialId;

  /// Denormalized credential display name (for UI convenience).
  /// 反规范化的凭证显示名称（便于 UI 使用）。
  String? credentialName;

  /// Denormalized credential username (for UI convenience).
  /// 反规范化的凭证用户名（便于 UI 使用）。
  String? credentialUsername;

  /// Operating system type: 0 = Linux, 1 = Windows.
  /// 操作系统类型：0 = Linux，1 = Windows。
  final int osType;

  /// Whether the host is currently reachable.
  /// 主机当前是否可达。
  bool isOnline;

  Host({
    required this.id,
    required this.alias,
    required this.ipAddress,
    this.port = 22,
    required this.credentialId,
    this.credentialName,
    this.credentialUsername,
    this.osType = 0,
    this.isOnline = false,
  });

  /// Returns a concise display string for the address, omitting the default SSH port.
  /// 返回地址的简洁显示字符串，省略默认 SSH 端口。
  String get displayAddress => '$ipAddress${port != 22 ? ':$port' : ''}';

  /// Returns an emoji character representing the operating system logo.
  /// 返回表示操作系统标志的表情符号字符。
  static String getOsLogoChar(int osType) {
    switch (osType) {
      case 0:
        return '🐧';
      case 1:
        return '🪟';
      default:
        return '🖥';
    }
  }

  /// Creates a copy of this instance with optionally overridden fields.
  /// 创建此实例的副本，可选择性覆盖字段值。
  Host copyWith({
    String? id,
    String? alias,
    String? ipAddress,
    int? port,
    String? credentialId,
    String? credentialName,
    String? credentialUsername,
    int? osType,
    bool? isOnline,
  }) {
    return Host(
      id: id ?? this.id,
      alias: alias ?? this.alias,
      ipAddress: ipAddress ?? this.ipAddress,
      port: port ?? this.port,
      credentialId: credentialId ?? this.credentialId,
      credentialName: credentialName ?? this.credentialName,
      credentialUsername: credentialUsername ?? this.credentialUsername,
      osType: osType ?? this.osType,
      isOnline: isOnline ?? this.isOnline,
    );
  }

  /// Serializes the host to a database-compatible map.
  /// 将主机序列化为数据库兼容的映射。
  Map<String, dynamic> toMap() => {
    'id': id,
    'alias': alias,
    'ip_address': ipAddress,
    'port': port,
    'credential_id': credentialId,
    'os_type': osType,
  };

  /// Deserializes a host from a database row map.
  /// 从数据库行映射反序列化主机对象。
  factory Host.fromMap(Map<String, dynamic> map) => Host(
    id: map['id'] as String,
    alias: map['alias'] as String,
    ipAddress: map['ip_address'] as String,
    port: map['port'] as int,
    credentialId: map['credential_id'] as String,
    osType: map['os_type'] as int,
  );
}
