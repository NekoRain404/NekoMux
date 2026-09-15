import 'dart:typed_data';

/// Formats host key fingerprints, and holds the superseded in-memory trust
/// cache.
/// 负责格式化主机密钥指纹，并保留已被取代的内存信任缓存。
///
/// Only [formatMd5] is still part of the design. The [isAccepted] / [accept]
/// pair below is a trust store kept in a `Set<String>`, which cannot represent
/// the one thing host key verification exists to catch: a host whose key
/// *changed*. It also forgets every accepted key when the process restarts, so
/// it re-trusts silently on the next launch. [KnownHostsStore] persists the
/// fingerprint per endpoint and [HostKeyVerdict] distinguishes "never seen"
/// from "changed", which is how `buildHostKeyVerifier` in `host_key_trust.dart`
/// makes that decision.
/// 只有 [formatMd5] 仍属于现行设计。下面的 [isAccepted] / [accept] 用
/// `Set<String>` 保存信任状态，无法表达主机密钥验证真正要防的那件事——某个主机的
/// 密钥*变了*；它还会在进程重启后忘掉所有已接受的密钥，于是下次启动又静默信任。
/// `known_hosts_store.dart` 按端点持久化指纹，`host_key_trust.dart` 中的
/// `buildHostKeyVerifier` 则通过 `HostKeyVerdict` 区分「从未见过」与「已变化」。
class HostKeyVerifier {
  static final Set<String> _acceptedFingerprints = {};

  HostKeyVerifier._();

  /// Renders raw fingerprint bytes as `MD5:ab:cd:...`.
  /// 将原始指纹字节渲染为 `MD5:ab:cd:...`。
  static String formatMd5(Uint8List bytes) {
    return 'MD5:${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}';
  }

  /// Whether [fingerprint] was accepted during this process's lifetime.
  /// [fingerprint] 是否在本进程生命周期内被接受过。
  ///
  /// Deprecated: it knows nothing about a key that changed, and it forgets
  /// everything on restart. Use [KnownHostsStore] + [evaluateHostKey] through
  /// `buildHostKeyVerifier` (`lib/services/host_key_trust.dart`) instead, which
  /// persists decisions and reports `HostKeyVerdict.changed`.
  /// 已弃用：它对密钥变化一无所知，且重启后忘光一切。请改用
  /// [KnownHostsStore] + [evaluateHostKey]（经由 `buildHostKeyVerifier`），
  /// 它会持久化判定结果并上报 `HostKeyVerdict.changed`。
  @Deprecated(
    'In-memory only: cannot detect a changed host key and forgets every '
    'accepted key on restart. Use KnownHostsStore / buildHostKeyVerifier '
    '(lib/services/host_key_trust.dart) instead.',
  )
  static bool isAccepted(String fingerprint) {
    return _acceptedFingerprints.contains(fingerprint);
  }

  /// Records [fingerprint] as accepted for the rest of this process.
  /// 在本进程剩余时间内把 [fingerprint] 记为已接受。
  ///
  /// Deprecated: the acceptance is lost on restart, so the next connection
  /// re-prompts (or, in a path that has no callback at all, is trusted
  /// outright). Persist it with [KnownHostsStore] instead — see
  /// `lib/services/host_key_trust.dart`.
  /// 已弃用：接受结果在重启后丢失，下次连接会再次弹窗（而在完全没有回调的路径上
  /// 则会被无条件信任）。请改用 [KnownHostsStore] 持久化——见
  /// `lib/services/host_key_trust.dart`。
  @Deprecated(
    'In-memory only: the acceptance is lost on restart. Persist it with '
    'KnownHostsStore (lib/services/host_key_trust.dart) instead.',
  )
  static void accept(String fingerprint) {
    _acceptedFingerprints.add(fingerprint);
  }
}
