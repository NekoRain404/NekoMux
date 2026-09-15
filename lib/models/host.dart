/// Reachability state of a host, in the three states this app can actually
/// distinguish.
/// 主机的可达性状态，即本应用真正能够区分的三种状态。
///
/// [unverified] is not a soft form of [offline]. It means the host's identity
/// has not been confirmed — its key is not in the known-hosts table — so the
/// connection was refused before the handshake finished, and nothing at all was
/// learned about whether the machine is up. The background reachability probe
/// never raises a trust decision, so a host sits here until the user connects
/// to it deliberately and answers the prompt; that is the moment the state
/// collapses into online or offline.
/// [unverified] 不是 [offline] 的柔和说法。它表示尚未确认主机身份——其密钥不在
/// known_hosts 表中——连接因此在握手完成前被拒绝，机器是否在运行一无所知。
/// 后台可达性探测绝不提出信任决策，因此主机在用户主动连接并回答提示之前一直停留在
/// 此状态；那一刻状态才收敛为在线或离线。
enum HostStatus {
  /// Identity unconfirmed, so reachability is unknown. Covers both "never
  /// probed" and "probed, but we refused the handshake".
  /// 身份未确认，因此可达性未知。涵盖「从未探测」与「已探测但拒绝握手」两者。
  unverified,

  /// Reachable: a connection was completed over a host key we were allowed to
  /// accept.
  /// 可达：使用我们获准接受的主机密钥完成了连接。
  online,

  /// Asked, over a handshake we were allowed to complete, and did not answer.
  /// 在我们获准完成的握手上被请求，但没有应答。
  offline,
}

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

  /// Group this host belongs to — "production", "staging", a customer name —
  /// or `null` for a host the user has not grouped.
  /// 此主机所属的分组——「生产」「预发布」或某个客户名——未分组的主机为 `null`。
  ///
  /// `null` and the empty string are *not* two different states to the user: a
  /// blank group field means "no group", so [fromMap] folds an empty or
  /// whitespace-only value down to `null` rather than letting a stray space
  /// create a group that looks unnamed and sorts before every real one.
  /// 对用户而言 `null` 与空字符串**不是**两种状态：分组输入框留空就是「不分组」，因此
  /// [fromMap] 会把空值或纯空白折叠为 `null`，而不是让一个多余的空格造出一个看起来
  /// 无名、却排在所有真实分组之前的分组。
  ///
  /// Stored as free text rather than a foreign key: a group is a label the user
  /// types, not an entity with a lifetime of its own. Deleting the last host of
  /// a group must not leave a group row behind to clean up, and renaming one is
  /// not a feature anybody asked for.
  /// 以自由文本而非外键存储：分组是用户随手输入的标签，不是有独立生命周期的实体。
  /// 删掉某分组的最后一台主机不应留下需要清理的分组记录，而重命名分组也不是任何人
  /// 要求过的功能。
  final String? groupName;

  /// Reachability state of the host, as far as we can honestly establish it.
  /// 主机的可达性状态，限我们能够诚实确定的范围。
  ///
  /// Deliberately *not* persisted: it is an observation of the current run, not
  /// part of the stored configuration, so [toMap] leaves it out and every host
  /// loaded from the database starts [HostStatus.unverified].
  /// 有意不持久化：它是本次运行期的观测结果，而非存储配置的一部分，因此 [toMap]
  /// 不包含它，从数据库读出的主机一律以 [HostStatus.unverified] 起步。
  HostStatus status;

  /// Whether the host is currently reachable.
  /// 主机当前是否可达。
  ///
  /// Read-only view of [status] for callers that only need a yes/no answer.
  /// `unverified` answers `false` without asserting that the host is down —
  /// that distinction is the point of the three-state field, so anything that
  /// shows the difference to the user should read [status] instead.
  /// [status] 的只读视图，供只需要「是/否」的调用方使用。`unverified` 返回
  /// `false`，但并不断言主机已宕机——这一区分正是三态字段存在的意义，凡是需要向
  /// 用户呈现差异的地方都应改读 [status]。
  bool get isOnline => status == HostStatus.online;

  /// Creates a host configuration.
  /// 创建主机配置。
  ///
  /// [isOnline] is the two-state form of [status], kept so callers written
  /// against the old boolean field keep compiling. `true` asserts
  /// [HostStatus.online]. `false` — and omitting it — yields
  /// [HostStatus.unverified], never [HostStatus.offline]: the old boolean could
  /// not tell "known to be down" from "never checked", and a caller that only
  /// knows it is *not* online has not established an outage. Callers that know
  /// the host was asked and did not answer should pass
  /// `status: HostStatus.offline`.
  /// [isOnline] 是 [status] 的两态写法，保留它是为了让按旧布尔字段编写的调用方
  /// 继续编译。`true` 断言 [HostStatus.online]。`false`（以及不传）得到
  /// [HostStatus.unverified]，绝不是 [HostStatus.offline]：旧的布尔值无法区分
  /// 「确知宕机」与「从未检查」，而只知道「并非在线」的调用方并未确认一次故障。
  /// 确知主机被请求过且没有应答的调用方，应传 `status: HostStatus.offline`。
  Host({
    required this.id,
    required this.alias,
    required this.ipAddress,
    this.port = 22,
    required this.credentialId,
    this.credentialName,
    this.credentialUsername,
    this.osType = 0,
    this.groupName,
    HostStatus status = HostStatus.unverified,
    bool? isOnline,
  }) : status = isOnline == null
           ? status
           : (isOnline ? HostStatus.online : HostStatus.unverified);

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

  /// Maps the outcome of one reachability probe to a [HostStatus].
  /// 将一次可达性探测的结果映射为 [HostStatus]。
  ///
  /// Kept as a pure function so the decision — the part that decides whether a
  /// silent background probe is allowed to claim a host is down — is pinned by
  /// a unit test instead of only being reachable through a live socket.
  /// 特意写成纯函数：这一决策决定了静默的后台探测是否可以断言主机已宕机，因此需要
  /// 由单元测试固定，而不是只能通过真实套接字触达。
  ///
  /// * [trustRefused]: the probe presented a key that is not trusted and
  ///   refused the handshake (it never asks the user). We learned nothing about
  ///   the machine, so the answer is [HostStatus.unverified] — not
  ///   [HostStatus.offline], which would invent an outage.
  /// * [attempted] false: the probe never ran — a host with no usable
  ///   credential is equally unmeasured.
  /// * otherwise the handshake was allowed to complete, so the host's answer is
  ///   real evidence: [HostStatus.online] if connected, [HostStatus.offline] if
  ///   it did not answer.
  /// * [trustRefused]：探测拿到的密钥未受信，因而拒绝握手（它绝不询问用户）。
  ///   我们对那台机器一无所知，所以答案是 [HostStatus.unverified]，而不是会凭空
  ///   断言一次故障的 [HostStatus.offline]。
  /// * [attempted] 为 false：探测根本没有发起——没有可用凭据的主机同样未被测量。
  /// * 其余情况握手获准完成，主机的应答是真实证据：连上即 [HostStatus.online]，
  ///   没有应答即 [HostStatus.offline]。
  static HostStatus statusForProbe({
    required bool attempted,
    required bool connected,
    required bool trustRefused,
  }) {
    if (!attempted || trustRefused) return HostStatus.unverified;
    return connected ? HostStatus.online : HostStatus.offline;
  }

  /// Creates a copy of this instance with optionally overridden fields.
  /// 创建此实例的副本，可选择性覆盖字段值。
  ///
  /// Like the credential fields, an omitted [groupName] keeps the current one
  /// and there is no way to clear it here — `null` already means "leave it".
  /// Clearing is not needed by any caller: the edit form builds a whole new
  /// [Host] on save, turning a blank group field into `null` there.
  /// 与凭据字段一样，省略 [groupName] 表示保留原值，此处无法将其清除——`null` 已经
  /// 表示「保持不变」。没有任何调用方需要清除：编辑表单在保存时构造全新的 [Host]，
  /// 在那一步把空的分组输入变成 `null`。
  Host copyWith({
    String? id,
    String? alias,
    String? ipAddress,
    int? port,
    String? credentialId,
    String? credentialName,
    String? credentialUsername,
    int? osType,
    String? groupName,
    HostStatus? status,
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
      groupName: groupName ?? this.groupName,
      status: status ?? this.status,
    );
  }

  /// Serializes the host to a database-compatible map.
  /// 将主机序列化为数据库兼容的映射。
  ///
  /// [status] is a runtime observation and is deliberately left out.
  /// [status] 是运行期观测结果，有意不写入。
  Map<String, dynamic> toMap() => {
    'id': id,
    'alias': alias,
    'ip_address': ipAddress,
    'port': port,
    'credential_id': credentialId,
    'os_type': osType,
    'group_name': groupName,
  };

  /// Deserializes a host from a database row map.
  /// 从数据库行映射反序列化主机对象。
  ///
  /// `group_name` is read defensively. A row that predates the v4 migration, a
  /// row from a hand-edited database, or a row from an older backup all arrive
  /// without a usable value for it, and none of those may turn into a throw
  /// that takes the whole host list down — the user would lose sight of hosts
  /// they still have. Anything that is not a non-blank string reads as
  /// "ungrouped".
  /// `group_name` 以防御性方式读取。早于 v4 迁移的行、来自手工编辑过的数据库的行、
  /// 或来自旧备份的行，都不带可用的该字段值，而这些情况中的任何一种都不能变成抛异常
  /// 并连带整个主机列表一起失败——那会让用户看不见他们仍然拥有的主机。凡不是「非空白
  /// 字符串」的值，一律读作「未分组」。
  factory Host.fromMap(Map<String, dynamic> map) => Host(
    id: map['id'] as String,
    alias: map['alias'] as String,
    ipAddress: map['ip_address'] as String,
    port: map['port'] as int,
    credentialId: map['credential_id'] as String,
    osType: map['os_type'] as int,
    groupName: normalizeGroupName(map['group_name']),
  );

  /// Normalizes a stored or typed group name to the one shape the rest of the
  /// app compares against: a non-blank string, or `null` for "no group".
  /// 把存储的或用户输入的分组名归一化为应用其余部分统一比较的形态：非空白字符串，
  /// 或表示「未分组」的 `null`。
  ///
  /// Kept here, next to the field, so the database read, the form's save and the
  /// dirty check cannot each invent their own idea of what "blank" means.
  /// 放在字段旁边，使数据库读取、表单保存与脏检查不会各自发明一套「留空」的定义。
  static String? normalizeGroupName(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
