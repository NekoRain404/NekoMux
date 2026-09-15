// Localised text for a failed SSH connection or command.
// SSH 连接或命令失败时的本地化文案。
//
// `services/ssh_service.dart` reports a code (`SshFailure`) plus the raw
// technical detail; the words a user reads are chosen here, from the i18n
// table, so switching the app to English switches the diagnosis with it. This
// is the other half of the split that keeps the SSH service free of prose — the
// same split `pages/sftp/sftp_error_text.dart` provides for the SFTP service.
// `services/ssh_service.dart` 上报编码（`SshFailure`）与原始技术细节；用户读到的
// 文字在这里从 i18n 表中选择，因此把应用切到英文时诊断文字随之切换。这正是让 SSH
// 服务不含文案的另一半——与 `pages/sftp/sftp_error_text.dart` 为 SFTP 服务提供的
// 分工完全相同。
//
// It lives under `pages/console/` because the host console owns the one session
// that all of these failures arrive on, and because every page that reports a
// connection failure already reaches the connection through
// `providers/ssh_provider.dart`; nothing here is console-specific.
// 它放在 `pages/console/` 下，是因为主机控制台持有这些失败所来自的那条会话，也因为
// 每个上报连接失败的页面本来就经由 `providers/ssh_provider.dart` 拿到连接；这里没有
// 任何内容是控制台专有的。

import '../../core/i18n/strings.dart';
import '../../services/ssh_service.dart';

/// The message to show the user for [error].
/// 向用户展示的 [error] 文案。
String sshErrorText(SshException error) =>
    sshFailureText(error.kind, error.detail);

/// The localised message for a failure [kind], with an optional raw [detail].
/// 失败 [kind] 的本地化文案，可附带原始细节 [detail]。
///
/// The detail is appended after a plain ': ' — punctuation no language owns —
/// and only where it adds something. The connection family already names both
/// the cause and what to check, so repeating the socket error after it would
/// bury the advice; the catch-all [SshFailure.connect] names nothing, so there
/// the raw error is the useful half.
/// 细节以普适的 ': ' 追加，且只在能补充信息时追加。连接类失败已同时说明原因与需要
/// 检查的内容，再附上套接字错误只会淹没建议；兜底的 [SshFailure.connect] 什么都没
/// 说明，此时原始错误才是有用的那一半。
///
/// Takes the code rather than an [SshException] so a page can report a failure it
/// classified itself through the very same mapping, instead of printing the raw
/// error at the user.
/// 接收编码而非 [SshException]，是为了让页面把它自己归类的失败也走同一条映射，
/// 而不是把原始错误直接抛给用户看。
String sshFailureText(SshFailure kind, [String? detail]) {
  switch (kind) {
    case SshFailure.notConnected:
      return t('ssh_not_connected');
    case SshFailure.connTimeout:
      return t('conn_timeout');
    case SshFailure.authFailed:
      return t('auth_failed');
    case SshFailure.connRefused:
      return t('conn_refused');
    case SshFailure.hostUnreachable:
      return t('host_unreachable');
    case SshFailure.hostKeyVerify:
      // The table has no sentence that literally says "the host key was
      // rejected". Of the two host-key keys, this one names the cause (the
      // server's identity could not be verified) while `host_key_verify` is the
      // title of the trust prompt, which would read as a heading rather than as
      // the reason the connection stopped.
      // 表里没有一句直说「主机密钥被拒绝」的文案。两个主机密钥相关的键中，这一个说明
      // 了原因（无法验证服务器身份），而 `host_key_verify` 是信任询问的标题，用作失败
      // 原因会读成一个标题而不是连接中止的理由。
      return t('cannot_verify_host_key');
    case SshFailure.connect:
      return _withDetail(t('connection_failed'), detail);
  }
}

/// The message for a connection whose state is [SshConnectionState.error].
/// 状态为 [SshConnectionState.error] 的连接所对应的文案。
///
/// The one call shape the pages need: [SshConnection.lastError] is technical and
/// [SshConnection.failure] is the code, and both are written together on every
/// failure path. The fallback covers the impossible combination rather than
/// showing the user a null or an identifier.
/// 页面唯一需要的调用形态：[SshConnection.lastError] 是技术细节，
/// [SshConnection.failure] 是编码，两者在每条失败路径上都一同写入。兜底值是为了
/// 应对那种不可能的组合，而不是把 null 或标识符展示给用户。
String sshConnectErrorText(SshConnection connection) => sshFailureText(
  connection.failure ?? SshFailure.connect,
  connection.lastError,
);

/// The message for an [error] caught around an SSH command.
/// SSH 命令周围捕获到的 [error] 所对应的文案。
///
/// A command can fail as an [SshException] — most often [SshFailure.notConnected],
/// when the session went away while the page was open — and that case deserves
/// the same translated sentence as a failed connect. Anything else is not ours
/// to word, so it is passed through as the technical text it already is.
/// 命令可能以 [SshException] 失败——最常见的是 [SshFailure.notConnected]，即页面
/// 打开期间会话消失——这种情况理应与连接失败得到同一句译文。其它错误不属于我们措辞
/// 的范围，因此按原样作为技术文本透传。
String sshCaughtErrorText(Object error) =>
    error is SshException ? sshErrorText(error) : error.toString();

/// [label] with [detail] appended, or [label] alone when there is nothing to add.
/// 在 [label] 后追加 [detail]；无内容可追加时只返回 [label]。
String _withDetail(String label, String? detail) =>
    (detail == null || detail.isEmpty) ? label : '$label: $detail';
