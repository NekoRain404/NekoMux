import 'dart:typed_data';

/// Renders raw host key fingerprint bytes as `MD5:ab:cd:...`.
/// 将主机密钥指纹的原始字节渲染为 `MD5:ab:cd:...`。
///
/// This file is the last remnant of an in-memory trust cache that kept a
/// `Set<String>` of accepted fingerprints. That cache could not express the one
/// thing host key verification exists to catch — a host whose key *changed* —
/// and it forgot every accepted key when the process restarted, so it
/// re-trusted silently on the next launch. It has been replaced by
/// `KnownHostsStore` (which persists per `host:port`) plus
/// `buildHostKeyVerifier` in `host_key_trust.dart` (which distinguishes
/// "never seen" from "changed").
/// 本文件是一套内存信任缓存的最后残留——那套缓存用一个 `Set<String>` 保存已接受的
/// 指纹。它无法表达主机密钥验证真正要防的那件事——某个主机的密钥*变了*；并且会在
/// 进程重启后忘掉所有已接受的密钥，于是下次启动又静默信任。它已被
/// `KnownHostsStore`（按 `host:port` 持久化）与 `host_key_trust.dart` 中的
/// `buildHostKeyVerifier`（区分「从未见过」与「已变化」）取代。
///
/// All that survives is the formatting, because both `ssh_service.dart` and
/// `sftp_service.dart` need to turn the bytes `dartssh2` hands them into the
/// string that gets stored and compared. Keeping one implementation is what
/// makes the two connection paths agree about what a fingerprint *is*.
/// 只保留了格式化函数，因为 `ssh_service.dart` 与 `sftp_service.dart` 都需要把
/// `dartssh2` 交来的字节转成用于存储与比较的字符串。只有一份实现，两条连接路径对
/// 「指纹是什么」的看法才可能一致。
class HostKeyVerifier {
  HostKeyVerifier._();

  /// Formats [bytes] as `MD5:ab:cd:...`.
  /// 将 [bytes] 格式化为 `MD5:ab:cd:...`。
  ///
  /// `dartssh2` passes the digest of the host key to `onVerifyHostKey`
  /// (`ssh_transport.dart`: `MD5Digest().process(hostkey)`), so the `MD5:` label
  /// is accurate rather than a guess. The fingerprint is also what the user
  /// compares against `ssh-keyscan` output, so the formatting has to stay
  /// byte-stable: changing it would silently invalidate every record in
  /// `tb_known_hosts` and make the app report a changed key for every host at
  /// once — the loudest possible false alarm from the one warning that must
  /// never cry wolf.
  /// `dartssh2` 交给 `onVerifyHostKey` 的是主机密钥的摘要
  /// （`ssh_transport.dart`：`MD5Digest().process(hostkey)`），因此 `MD5:` 这个
  /// 标注是准确的，不是猜测。指纹也是用户拿来与 `ssh-keyscan` 输出比对的东西，所以
  /// 格式必须保持逐字节稳定：一旦改动，`tb_known_hosts` 里的每条记录都会静默失效，
  /// 应用会一次性对所有主机报告「密钥已变化」——而那是一条绝不能虚报的警告。
  static String formatMd5(Uint8List bytes) {
    return 'MD5:${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}';
  }
}
