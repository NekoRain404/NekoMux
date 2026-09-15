import 'package:sqflite/sqflite.dart';

/// Outcome of comparing a presented host key against what we recorded before.
/// 将本次收到的主机密钥与既有记录比对的结果。
enum HostKeyVerdict {
  /// We have a record for this host and the key matches. Connect silently.
  /// 该主机已有记录且密钥一致，可直接连接。
  trusted,

  /// We have never recorded a key for this host. Ask the user (trust on first use).
  /// 从未记录过该主机的密钥，需要询问用户（首次使用即信任）。
  unknown,

  /// We recorded a *different* key for this host. This is the only signal that
  /// a machine-in-the-middle may be intercepting the connection, so it must
  /// never be treated as a routine prompt.
  /// 该主机记录的是**另一个**密钥——这是可能存在中间人的唯一信号，绝不能当作普通提示处理。
  changed,
}

/// Decides how a presented fingerprint relates to the stored one.
/// 判断本次收到的指纹与已存储指纹的关系。
///
/// Kept free of storage so the rule can be tested directly. An absent *or blank*
/// stored value counts as [HostKeyVerdict.unknown]: a blank row is a storage
/// artefact, and reporting it as [HostKeyVerdict.changed] would train users to
/// click through the one warning that actually matters.
/// 本函数不涉及存储层，便于直接测试。存储值缺失**或为空**都算
/// [HostKeyVerdict.unknown]：空行只是存储残留，若报成 [HostKeyVerdict.changed]
/// 会让用户习惯性略过真正重要的那条警告。
HostKeyVerdict evaluateHostKey({
  required String? storedFingerprint,
  required String presentedFingerprint,
}) {
  final stored = storedFingerprint;
  if (stored == null || stored.isEmpty) return HostKeyVerdict.unknown;
  return stored == presentedFingerprint
      ? HostKeyVerdict.trusted
      : HostKeyVerdict.changed;
}

/// Builds the stable identity of a host endpoint for known-hosts lookups.
/// 构造用于 known_hosts 查询的主机端点标识。
///
/// The port is part of the identity because the same address on two ports is
/// two different servers. IPv6 literals are bracketed so the port cannot be
/// confused with the address's own colons.
/// 端口属于标识的一部分：同一地址的不同端口是两台不同的服务器。
/// IPv6 字面量加方括号，避免端口与其自身冒号混淆。
String hostKeyFor(String address, int port) {
  return address.contains(':') ? '[$address]:$port' : '$address:$port';
}

/// Persistent record of host keys the user has accepted.
/// 用户已接受的主机密钥的持久化记录。
///
/// Replaces the previous in-memory-only fingerprint cache, which was keyed by
/// fingerprint alone and lost its contents on every restart. Two consequences
/// of that design are fixed here: a saved key now survives a restart, and
/// because records are keyed by host, a key that *changes* for a host we already
/// know can finally be distinguished from a host we are meeting for the first
/// time.
/// 取代此前仅存在于内存的指纹缓存——那个实现只以指纹为键，且每次重启即清空。
/// 这里修掉它的两个后果：已保存的密钥能跨重启留存；因为记录以主机为键，
/// 「已知主机的密钥发生了变化」终于能与「第一次见到这台主机」区分开。
class KnownHostsStore {
  static const String table = 'tb_known_hosts';

  final Database _db;

  const KnownHostsStore(this._db);

  /// Compares the presented [fingerprint] against the record for [host].
  /// 将本次收到的 [fingerprint] 与该 [host] 的记录比对。
  Future<HostKeyVerdict> check({
    required String host,
    required String fingerprint,
  }) async {
    final rows = await _db.query(
      table,
      columns: const ['fingerprint'],
      where: 'host = ?',
      whereArgs: [host],
      limit: 1,
    );
    final stored = rows.isEmpty ? null : rows.first['fingerprint'] as String?;
    return evaluateHostKey(
      storedFingerprint: stored,
      presentedFingerprint: fingerprint,
    );
  }

  /// Records [fingerprint] as trusted for [host], replacing any previous value.
  /// 将 [fingerprint] 记为 [host] 的可信密钥，覆盖此前的值。
  ///
  /// Used both for first-use acceptance and for a deliberate override after a
  /// [HostKeyVerdict.changed] warning.
  /// 既用于首次接受的场景，也用于用户在 [HostKeyVerdict.changed] 警告后主动覆盖的场景。
  Future<void> trust({
    required String host,
    required String keyType,
    required String fingerprint,
  }) async {
    await _db.insert(table, {
      'host': host,
      'key_type': keyType,
      'fingerprint': fingerprint,
      'trusted_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Drops the record for [host], so the next connection prompts again.
  /// 删除 [host] 的记录，下次连接将重新询问。
  Future<void> forget(String host) async {
    await _db.delete(table, where: 'host = ?', whereArgs: [host]);
  }

  /// Every recorded host key, ordered by host for stable display.
  /// 全部已记录的主机密钥，按主机排序以便稳定展示。
  Future<List<Map<String, Object?>>> all() {
    return _db.query(table, orderBy: 'host');
  }
}
