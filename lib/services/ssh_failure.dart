/// What went wrong with an [SshConnection].
/// [SshConnection] 出了什么问题。
///
/// A machine-readable code, not a sentence. The words a user reads come from the
/// i18n table via `pages/console/ssh_error_text.dart`; this service used to
/// write those words itself, in Chinese, on every failed connect — which is why
/// an English user got a Chinese diagnosis for a failed connection.
/// 机器可读的编码，而非句子。用户读到的文字来自 i18n 表，经由
/// `pages/console/ssh_error_text.dart`；本服务此前自己书写这些文字，且写的是中文，
/// 因此英文用户在连接失败时得到的是中文诊断。
///
/// The codes line up with the SFTP service's `SftpFailure` where the two
/// describe the same transport failure; each service keeps its own enum because
/// each has codes of its own (`hostKeyVerify` here, the file operations there).
/// 在两个服务描述同一种传输层失败之处，这些编码与 SFTP 服务的 `SftpFailure` 对应；
/// 各服务保留自己的枚举，因为各自都有对方没有的编码（此处的 `hostKeyVerify`、
/// 那边的文件操作）。
enum SshFailure {
  /// There is no live session to run a command on. Comparable to
  /// `SftpFailure.notConnected`; thrown as an [SshException], never stored on
  /// the connection.
  /// 没有可执行命令的活动会话。与 `SftpFailure.notConnected` 对应；以
  /// [SshException] 抛出，不会存到连接上。
  notConnected,

  /// The connect attempt timed out.
  /// 连接尝试超时。
  connTimeout,

  /// Authentication was rejected.
  /// 认证被拒绝。
  authFailed,

  /// The server refused the connection.
  /// 服务器拒绝连接。
  connRefused,

  /// The host address could not be resolved.
  /// 主机地址无法解析。
  hostUnreachable,

  /// The server's host key was not accepted, so the connection was refused.
  /// 服务器的主机密钥未被接受，连接因此被拒绝。
  ///
  /// `dartssh2` reports this as `SSHHostkeyError(Hostkey verification failed)`
  /// when the verifier declines — including when the prompt could not be shown
  /// because the page was already gone.
  /// 当验证回调拒绝时，`dartssh2` 上报为
  /// `SSHHostkeyError(Hostkey verification failed)`——包括页面已销毁、无法弹窗询问
  /// 的情形。
  hostKeyVerify,

  /// The connection failed for a reason none of the above covers.
  /// 连接失败，原因不属于以上任何一类。
  connect,
}

/// Classify a raw connection failure into a code the presentation layer can turn
/// into a sentence in the user's own language.
/// 将原始连接失败归类为展示层可据此生成用户语言句子的编码。
///
/// Reading a transport error is protocol knowledge and stays here; wording it is
/// not, and left for the i18n table.
/// 解读传输层错误属于协议知识，留在这里；措辞不属于，交给 i18n 表。
///
/// The predicates and their order are the ones the message-based translation
/// used, so a given failure keeps yielding the same code. Two of them are
/// load-bearing: `'host key'` is tested before the broader `'key'` of the
/// authentication branch (otherwise a rejected host key would be reported as a
/// credential problem), and `'timed out'` is a separate spelling from
/// `'timeout'` because that is what `Socket.connect` actually produces
/// (`SocketException: Connection timed out, host: …, port: …`).
/// 判断条件及其顺序与基于消息的翻译一致，因此某种失败得到的编码不变。其中两条不可
/// 省略：`'host key'` 必须先于认证分支中更宽泛的 `'key'` 判断（否则被拒绝的主机密钥
/// 会被报成凭据问题）；`'timed out'` 与 `'timeout'` 是两种写法，因为
/// `Socket.connect` 实际给出的正是前者
/// （`SocketException: Connection timed out, host: …, port: …`）。
///
/// One predicate is new: `'failed host lookup'` is how a mistyped address
/// actually fails on Android and Linux, and it matches none of the older
/// substrings — the address the user just typed is exactly the one worth naming
/// as the suspect. Everything else, including a message this app has never
/// seen, still comes back as a code ([SshFailure.connect]) rather than throwing
/// or passing a raw error through.
/// 另有一条是新增的：地址写错时在 Android 与 Linux 上实际出现的是
/// `'failed host lookup'`，它不匹配任何一个旧子串——而用户刚输入的地址正是最值得
/// 指出来的嫌疑对象。除此之外的一切，包括本应用从未见过的消息，也都会返回编码
/// （[SshFailure.connect]），既不抛出，也不把原始错误原样放行。
SshFailure classifySshFailure(String error) {
  final lower = error.toLowerCase();
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return SshFailure.connTimeout;
  }
  if (lower.contains('host key') || lower.contains('hostkey')) {
    return SshFailure.hostKeyVerify;
  }
  if (lower.contains('auth') ||
      lower.contains('password') ||
      lower.contains('key')) {
    return SshFailure.authFailed;
  }
  if (lower.contains('refused') || lower.contains('connection refused')) {
    return SshFailure.connRefused;
  }
  if (lower.contains('resolve') ||
      lower.contains('unknown host') ||
      lower.contains('no address') ||
      lower.contains('failed host lookup')) {
    return SshFailure.hostUnreachable;
  }
  return SshFailure.connect;
}

/// Exception thrown by [SshConnection] operations.
/// [SshConnection] 操作抛出的异常。
///
/// Carries a code and the raw detail instead of a message: prose belongs to the
/// i18n table, and a service that composes it can only compose it in one
/// language. Pair it with `sshErrorText` to get something a user can read.
/// 携带编码与原始细节，而不是消息：文案属于 i18n 表，而自行组装文案的服务只能组装
/// 出一种语言。需要给用户读的文字时，请配合 `sshErrorText` 使用。
class SshException implements Exception {
  /// What went wrong.
  /// 出了什么问题。
  final SshFailure kind;

  /// The underlying error's own rendering — a socket error, a protocol status —
  /// never a sentence this app wrote. Null when there is nothing to add, as with
  /// [SshFailure.notConnected].
  /// 底层错误自身的呈现——套接字错误、协议状态——绝不是本应用写下的句子。
  /// 无可补充时为 null，例如 [SshFailure.notConnected]。
  final String? detail;

  const SshException(this.kind, [this.detail]);

  /// Technical rendering of the failure: printable, never displayable.
  /// 失败的技术呈现：可以打印，不能直接展示。
  ///
  /// The counterpart of [SshConnection.lastError] for a failure that is thrown
  /// rather than stored. Deliberately not translated — anything a user reads
  /// must go through `sshErrorText`, which is what actually respects the
  /// language setting.
  /// 它是「抛出而非存储」的失败对应的 [SshConnection.lastError]。有意不做翻译——
  /// 任何给用户读的文字都必须经由 `sshErrorText`，那才是真正遵循语言设置的路径。
  String get message => detail ?? kind.name;

  @override
  String toString() => detail == null ? kind.name : '${kind.name}: $detail';
}

/// [ForwardChannel] over dartssh2's own forwarding channel.
///
/// An adapter rather than a use of the library type directly: `SSHForwardChannel`
/// is a concrete class over an SSH channel, which a test cannot stand in for —
/// and the tunnel's plumbing (sockets, pipes, teardown) is exactly what deserves
/// testing.
