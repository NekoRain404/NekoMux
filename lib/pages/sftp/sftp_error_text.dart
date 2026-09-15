// Localised text for a failed SFTP operation.
// SFTP 操作失败时的本地化文案。
//
// The service reports a code and a raw detail; the words a user reads are chosen
// here, from the i18n table, so switching the app to English switches the
// diagnosis with it. This is the other half of the split that keeps
// `services/sftp_service.dart` free of prose.
// 服务上报编码与原始细节；用户读到的文字在这里从 i18n 表中选择，因此把应用切到英文
// 时诊断文字随之切换。这正是让 `services/sftp_service.dart` 不含文案的另一半。

import '../../core/i18n/strings.dart';
import '../../services/sftp_service.dart';

/// The message to show the user for [error].
/// 向用户展示的 [error] 文案。
String sftpErrorText(SftpException error) =>
    sftpFailureText(error.kind, error.detail);

/// The localised message for a failure [kind], with an optional raw [detail].
/// 失败 [kind] 的本地化文案，可附带原始细节 [detail]。
///
/// The detail is appended after a plain ': ' — punctuation no language owns —
/// and only where it adds something. The connection family already names both
/// the cause and what to check, so repeating the socket error after it would
/// bury the advice; the operation failures name only what was attempted, so the
/// server's own complaint is the useful half.
/// 细节以普适的 ': ' 追加，且只在能补充信息时追加。连接类失败已同时说明原因与需要
/// 检查的内容，再附上套接字错误只会淹没建议；操作类失败只说明了尝试做什么，服务器
/// 自己的抱怨才是有用的那一半。
///
/// Takes the code rather than an [SftpException] so the page can report an
/// unexpected failure it caught itself through the very same mapping, instead of
/// printing the raw error at the user.
/// 接收编码而非 [SftpException]，是为了让页面把它自己捕获的意外失败也走同一条映射，
/// 而不是把原始错误直接抛给用户看。
String sftpFailureText(SftpFailure kind, [String? detail]) {
  switch (kind) {
    case SftpFailure.notConnected:
      return t('ssh_not_connected');
    case SftpFailure.connTimeout:
      return t('conn_timeout');
    case SftpFailure.authFailed:
      return t('auth_failed');
    case SftpFailure.connRefused:
      return t('conn_refused');
    case SftpFailure.hostUnreachable:
      return t('host_unreachable');
    case SftpFailure.connect:
      return _withDetail(t('connection_failed'), detail);
    case SftpFailure.list:
      return _withDetail(t('list_failed'), detail);
    case SftpFailure.read:
      return _withDetail(t('read_failed'), detail);
    case SftpFailure.write:
      return _withDetail(t('write_failed'), detail);
    case SftpFailure.delete:
      return _withDetail(t('delete_failed'), detail);
    case SftpFailure.rename:
      return _withDetail(t('rename_failed'), detail);
    case SftpFailure.mkdir:
      return _withDetail(t('mkdir_failed'), detail);
  }
}

/// [label] with [detail] appended, or [label] alone when there is nothing to add.
/// 在 [label] 后追加 [detail]；无内容可追加时只返回 [label]。
String _withDetail(String label, String? detail) =>
    (detail == null || detail.isEmpty) ? label : '$label: $detail';
