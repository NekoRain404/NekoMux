import 'package:sqflite/sqflite.dart';

import 'known_hosts_store.dart';

/// Builds the `onHostKeyVerify` callback for a single host endpoint.
/// 为单个主机端点构造 `onHostKeyVerify` 回调。
///
/// This is the one place that decides whether a presented host key is accepted,
/// so every connection path in the app has to go through it. Before this
/// existed, six of the eight places that open an SSH connection passed no
/// verification callback at all — and `dartssh2` treats a null callback as
/// "trust anything" (`ssh_transport.dart`:
/// `onVerifyHostKey != null ? onVerifyHostKey!(...) : true`), so those paths
/// silently accepted any host key a machine-in-the-middle offered.
/// 这是决定是否接受主机密钥的唯一入口，应用内每条连接路径都必须经过它。
/// 在本模块出现之前，八处 SSH 连接点里有六处根本没有传验证回调，
/// 而 `dartssh2` 把 null 回调当作「无条件信任」，于是那些路径会静默接受
/// 中间人提供的任意主机密钥。
///
/// [onPrompt] is invoked only when the key is not already trusted — that is,
/// for [HostKeyVerdict.unknown] (first contact with this host) or
/// [HostKeyVerdict.changed] (this host used to present a different key). The
/// two cases must not be presented identically to the user: a changed key is
/// the only available signal of an interception attempt, while an unknown key
/// is the ordinary first-connection case.
/// 仅在密钥尚未受信时才调用 [onPrompt]，即 [HostKeyVerdict.unknown]
/// （首次连接该主机）或 [HostKeyVerdict.changed]（该主机此前用的是另一个密钥）。
/// 这两种情况绝不能对用户呈现为同一件事：密钥变化是唯一可用的被劫持信号，
/// 而未知密钥只是普通的首次连接。
///
/// Accepting a [HostKeyVerdict.changed] key overwrites the stored record. That
/// is deliberate — the user may have legitimately reinstalled the server — but
/// it is also why the prompt has to be an explicit, worded warning.
/// 接受 [HostKeyVerdict.changed] 的密钥会覆盖既有记录。这是有意为之——
/// 用户可能确实重装了服务器——但也正因如此，该提示必须是一句明确的警告。
Future<bool> Function(String fingerprint) buildHostKeyVerifier({
  required Database db,
  required String address,
  required int port,
  required Future<bool> Function(String fingerprint, HostKeyVerdict verdict)
  onPrompt,
}) {
  final store = KnownHostsStore(db);
  final host = hostKeyFor(address, port);

  return (String fingerprint) async {
    final verdict = await store.check(host: host, fingerprint: fingerprint);

    if (verdict == HostKeyVerdict.trusted) return true;

    final accepted = await onPrompt(fingerprint, verdict);
    if (accepted) {
      await store.trust(
        host: host,
        // The key type ("ssh-ed25519", "ssh-rsa", ...) is recorded for display.
        // SshConnection's wrapper drops it, so it is left blank here rather than
        // guessed; the fingerprint is what the decision is based on.
        // 记录密钥类型（"ssh-ed25519"、"ssh-rsa" 等）是为了展示。SshConnection 的
        // 包装层没有透传该值，所以这里留空而不臆测；真正参与判定的是指纹。
        keyType: '',
        fingerprint: fingerprint,
      );
    }
    return accepted;
  };
}

/// Accepts every key without asking. **Test and mock paths only.**
/// 不询问即接受一切密钥。**仅用于测试与 mock 路径。**
///
/// Named so that a reviewer can grep for it: any production call site is a bug.
/// 特意取了这个名字，方便审查时直接搜索：任何生产代码里出现它都是缺陷。
Future<bool> Function(String fingerprint) acceptAnyHostKeyForTesting() {
  return (String fingerprint) async => true;
}
