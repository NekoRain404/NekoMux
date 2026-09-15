// The vocabulary a failed SFTP operation reports.
// SFTP 操作失败所上报的词汇。
//
// Split out of `services/sftp_service.dart` when that file outgrew the 800-line
// limit (`CLAUDE.md`), which is also why it is re-exported from there: every
// existing `import 'services/sftp_service.dart'` keeps resolving
// [SftpException] and [SftpFailure] without a single call site changing.
// 它是在 `services/sftp_service.dart` 超出 800 行上限（`CLAUDE.md`）时拆分出来的，
// 这也正是它在那边被重新导出的原因：现有每一处
// `import 'services/sftp_service.dart'` 都无需任何改动即可继续解析出
// [SftpException] 与 [SftpFailure]。

/// What went wrong in an [SftpService] operation.
/// [SftpService] 的某次操作出了什么问题。
///
/// A machine-readable code, not a sentence. The words a user reads come from the
/// i18n table, via `pages/sftp/sftp_error_text.dart`; this service used to write
/// those words itself, in Chinese, on every failed operation — which is why an
/// English user got a Chinese diagnosis for a failed listing, read or delete.
/// 机器可读的编码，而非句子。用户读到的文字来自 i18n 表，经由
/// `pages/sftp/sftp_error_text.dart`；本服务此前自己书写这些文字，且写的是中文，
/// 因此英文用户在列举、读取或删除失败时得到的都是中文诊断。
enum SftpFailure {
  /// No live SFTP session to run the operation on.
  /// 没有可执行操作的 SFTP 会话。
  notConnected,

  /// The connection attempt timed out.
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

  /// The connection failed for a reason none of the above covers.
  /// 连接失败，原因不属于以上任何一类。
  connect,

  /// Listing a directory failed.
  /// 列举目录失败。
  list,

  /// Reading a file failed.
  /// 读取文件失败。
  read,

  /// Writing a file failed.
  /// 写入文件失败。
  write,

  /// Deleting an entry failed.
  /// 删除条目失败。
  delete,

  /// Renaming an entry failed.
  /// 重命名条目失败。
  rename,

  /// Creating a directory failed.
  /// 创建目录失败。
  mkdir,
}

/// Exception thrown by [SftpService] operations.
/// [SftpService] 操作抛出的异常。
///
/// Carries a code and the raw detail instead of a message: prose belongs to the
/// i18n table, and a service that composes it can only compose it in one
/// language. Pair it with `sftpErrorText` to get something a user can read.
/// 携带编码与原始细节，而不是消息：文案属于 i18n 表，而自行组装文案的服务只能组装
/// 出一种语言。需要给用户读的文字时，请配合 `sftpErrorText` 使用。
class SftpException implements Exception {
  /// What went wrong.
  /// 出了什么问题。
  final SftpFailure kind;

  /// The underlying error's own rendering — a socket error, a protocol status —
  /// never a sentence this app wrote. Null when there is nothing to add, as with
  /// [SftpFailure.notConnected].
  /// 底层错误自身的呈现——套接字错误、协议状态——绝不是本应用写下的句子。
  /// 无可补充时为 null，例如 [SftpFailure.notConnected]。
  final String? detail;

  const SftpException(this.kind, [this.detail]);

  /// Technical rendering of the failure: printable, never displayable.
  /// 失败的技术呈现：可以打印，不能直接展示。
  ///
  /// Kept so callers that read `.message` still compile and still have something
  /// to print. It is deliberately not translated — anything a user reads must go
  /// through `sftpErrorText`, which is what actually respects the language
  /// setting.
  /// 保留它，是为了让读取 `.message` 的调用方仍能编译、仍能拿到可打印的内容。它有
  /// 意不做翻译——任何给用户读的文字都必须经由 `sftpErrorText`，那才是真正遵循语言
  /// 设置的路径。
  String get message => detail ?? kind.name;

  @override
  String toString() => detail == null ? kind.name : '${kind.name}: $detail';
}