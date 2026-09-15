import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/host.dart';
import '../models/credential.dart';
import '../services/ssh_service.dart';

/// Provider that resolves to an [SshConnection] keyed by [hostId].
/// 根据 [hostId] 解析为 [SshConnection] 的提供者。
///
/// Currently returns a placeholder; the real session is managed externally
/// by the terminal view.
/// 当前返回占位值；实际会话由终端视图在外部管理。
final sshConnectionProvider =
    Provider.family<AsyncValue<SshConnection?>, String>((ref, hostId) {
      return AsyncData(null); // managed externally, placeholder / 外部管理，占位值
    });

/// Performs a one-shot SSH connection test for the given [host] and [credential].
/// 对给定的 [host] 和 [credential] 执行一次性 SSH 连接测试。
///
/// Returns 'ok' on success, or a user-facing error message on failure.
/// 成功时返回 'ok'，失败时返回面向用户的错误信息。
Future<String> testConnection({
  required Host host,
  required Credential credential,
}) async {
  final service = SshConnection(host: host, credential: credential);
  try {
    await service.connect();
    if (service.state == SshConnectionState.connected) {
      await service.disconnect();
      return 'ok';
    }
    return service.lastError ?? '连接失败';
  } catch (e) {
    return e.toString();
  }
}
