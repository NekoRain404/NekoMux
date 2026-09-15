import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/database/app_database.dart';
import '../core/i18n/strings.dart';
import '../models/host.dart';
import '../models/credential.dart';
import '../services/host_key_trust.dart';
import '../services/known_hosts_store.dart';
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
///
/// The host key is verified like on every other connection path: this function
/// used to build `SshConnection` without a verification callback, and
/// `dartssh2` treats a missing callback as "accept any key", so the test itself
/// could be answered by a machine-in-the-middle.
/// 主机密钥与其它连接路径一样要经过校验：本函数此前构造 `SshConnection` 时不传
/// 验证回调，而 `dartssh2` 把缺失回调当作「接受任意密钥」，因此这个测试本身就可能
/// 被中间人应答。
///
/// An *untrusted* key (first contact, or a key that changed for this host) is
/// refused rather than prompted for. There is no UI here to show a fingerprint
/// in, and the button exists to test the *credential*, not to establish trust;
/// silently accepting would be the very hole this verification closes. The
/// message returned in that case carries the verdict and the fingerprint so the
/// user knows why the test stopped and where the key can be reviewed and
/// accepted — the terminal page prompts for it.
/// 对**未受信**的密钥（首次连接，或该主机的密钥发生变化）一律拒绝，而不是弹窗询问。
/// 这里没有可以展示指纹的界面，而且该按钮的用途是测试**凭据**、不是建立信任；
/// 静默接受正是这次校验要堵的洞。这种情形返回的信息会带上判定结果和指纹，让用户知道
/// 测试为何中止、以及可以在哪里核对并接受该密钥——终端页面会给出该询问。
Future<String> testConnection({
  required Host host,
  required Credential credential,
}) async {
  SshConnection? service;
  try {
    // The known-hosts table is needed before the connection can be built. This
    // function has no `Ref` — its only caller passes host and credential — so
    // it reads the same singleton database that `databaseProvider` resolves to.
    // 构造连接之前就需要 known_hosts 表。本函数没有 `Ref`（唯一的调用方只传 host
    // 和 credential），因此直接读取 `databaseProvider` 所解析的那个单例数据库。
    final db = await AppDatabase().database;

    // Verdict of a host key this path refused, and the fingerprint it presented.
    // `null` means the key was already trusted, or no key was ever presented.
    // 本路径拒绝的主机密钥的判定结果，以及它出示的指纹。为 `null` 表示密钥已受信，
    // 或压根没有收到过密钥。
    HostKeyVerdict? refusedVerdict;
    String? refusedFingerprint;

    service = SshConnection(
      host: host,
      credential: credential,
      onHostKeyVerify: buildHostKeyVerifier(
        db: db,
        address: host.ipAddress,
        port: host.port,
        onPrompt: (fingerprint, verdict) async {
          refusedVerdict = verdict;
          refusedFingerprint = fingerprint;
          return false;
        },
      ),
    );

    await service.connect();

    final refused = refusedVerdict;
    if (refused != null) {
      final isChanged = refused == HostKeyVerdict.changed;
      final title = isChanged
          ? t('host_key_changed_title')
          : t('host_key_verify');
      final body = isChanged
          ? t('host_key_changed_body')
          : t('cannot_verify_host_key');
      return '$title\n$body\n${refusedFingerprint ?? ''}';
    }

    if (service.state == SshConnectionState.connected) {
      return 'ok';
    }
    return service.lastError ?? '连接失败';
  } catch (e) {
    return e.toString();
  } finally {
    // Unconditional teardown. Previously only the success path disconnected, so
    // a failed test left the SSH client and both broadcast controllers alive
    // (audit leak-6); `disconnect()` closes the client, `dispose()` the
    // controllers, so both are needed on every path.
    // 无条件清理。原先只有成功路径会断开连接，测试失败时 SSH 客户端和两个广播控制器
    // 都会继续存活（审计 leak-6）；关闭客户端靠 `disconnect()`，关闭控制器靠
    // `dispose()`，因此每条路径都需要两者。
    final conn = service;
    if (conn != null) {
      try {
        await conn.disconnect();
      } catch (_) {
        // A teardown failure must not turn a user-facing message into a throw:
        // the caller shows whatever this function returns.
        // 清理失败不能把本该返回的提示信息变成抛出异常：调用方展示的是本函数的返回值。
      }
      conn.dispose();
    }
  }
}
