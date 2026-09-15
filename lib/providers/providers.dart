import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../core/database/app_database.dart';
import '../models/credential.dart';
import '../models/host.dart';
import '../models/snippet.dart';
import '../services/secure_storage.dart';

// ---- Database / 数据库 ----

/// Global database provider. Resolves to the app's SQLite [Database] instance.
/// 全局数据库提供者，解析为应用的 SQLite [Database] 实例。
final databaseProvider = FutureProvider<Database>((ref) async {
  return AppDatabase().database;
});

// ---- Credentials / 凭据 ----

/// Provider for the list of stored [Credential] objects.
/// 已存储 [Credential] 对象列表的提供者。
final credentialListProvider =
    AsyncNotifierProvider<CredentialListNotifier, List<Credential>>(
      CredentialListNotifier.new,
    );

/// Async notifier managing the credentials list state.
/// 管理凭据列表状态的异步通知器。
class CredentialListNotifier extends AsyncNotifier<List<Credential>> {
  /// Build the initial list by querying the database.
  /// 通过查询数据库构建初始列表。
  @override
  Future<List<Credential>> build() async {
    final db = await ref.watch(databaseProvider.future);
    final maps = await db.query('tb_credentials', orderBy: 'name');
    final credentials = <Credential>[];
    for (final map in maps) {
      credentials.add(await _credentialFromRow(db, map));
    }
    return credentials;
  }

  /// Insert a new [cred] and refresh the list.
  /// 插入新的 [cred] 并刷新列表。
  Future<void> addItem(Credential cred) async {
    final db = await ref.read(databaseProvider.future);
    await SecureStorage.saveCredential(cred.id, cred.secretData);
    await db.insert(
      'tb_credentials',
      cred.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    ref.invalidateSelf();
  }

  /// Update an existing [cred] and refresh the list.
  /// 更新已有的 [cred] 并刷新列表。
  Future<void> updateItem(Credential cred) async {
    final db = await ref.read(databaseProvider.future);
    await SecureStorage.saveCredential(cred.id, cred.secretData);
    await db.update(
      'tb_credentials',
      cred.toMap(),
      where: 'id = ?',
      whereArgs: [cred.id],
    );
    ref.invalidateSelf();
  }

  /// Delete the credential with the given [id] and refresh the list.
  /// 删除指定 [id] 的凭据并刷新列表。
  ///
  /// Same order, and the same reason, as [clearAll]: the secret goes first. A
  /// row deleted before its secret leaves a secret no row points at, which
  /// nothing would ever clean up — and when removing the secret itself fails,
  /// the row is deliberately kept, so the credential still works and is still
  /// listed instead of leaving that orphan behind. The deletion is retryable
  /// exactly because nothing was half-done.
  /// 与 [clearAll] 相同的顺序、相同的理由：先删密钥。若先删行，留下的密钥将不再被任何
  /// 行指向，永远无人清理；而删除密钥本身失败时，这里刻意保留该行，让凭据继续可用、
  /// 继续出现在列表里，而不是留下那样一个孤儿。删除之所以可以重试，正是因为没有被
  /// 做一半的操作。
  ///
  /// The refresh sits in a `finally` because `SecureStorage` throws on failure
  /// and nothing above catches it (see `secure_storage.dart`). With the refresh
  /// only on the success path, that throw left the row gone from the database
  /// while the list and every host card still rendered it — a ghost that only an
  /// app restart cleared, and whose every retry failed in exactly the same way,
  /// so the retry could never fix what it was retrying.
  /// 刷新放在 `finally` 中，因为 `SecureStorage` 失败时会抛异常，且上层无人捕获
  /// （见 `secure_storage.dart`）。若只在成功路径刷新，这个异常会让数据库中的行已经
  /// 删除、而列表与所有主机卡片仍在显示它——一个只有重启应用才能消除的幽灵条目，且每次
  /// 重试都以完全相同的方式失败，重试永远修不好它要修的东西。
  Future<void> deleteItem(String id) async {
    final db = await ref.read(databaseProvider.future);
    try {
      await SecureStorage.deleteCredential(id);
      await db.delete('tb_credentials', where: 'id = ?', whereArgs: [id]);
    } finally {
      ref.invalidateSelf();
    }
  }

  /// Removes every credential and its stored secret, refreshing once.
  /// 删除全部凭据及其已存储的密钥，且只刷新一次。
  ///
  /// Looping over [deleteItem] would work, but each call refreshes on its own
  /// and this notifier is watched by the host notifier — so clearing N
  /// credentials rebuilt the host list N times and re-queried both tables each
  /// time. On a device with a few dozen saved hosts that is visible as a stall
  /// on a button that should feel instant.
  /// 循环调用 [deleteItem] 也能用，但它每删一条就自行刷新一次，而本通知器又被主机
  /// 通知器 watch——于是清空 N 条凭据会让主机列表重建 N 次，每次都重查两张表。
  /// 在存了几十台主机的设备上，这会让一个本应瞬间完成的按钮出现可见卡顿。
  ///
  /// Secrets are removed before the rows, so an interruption can only leave a
  /// credential whose secret is gone (visible, and already handled elsewhere as
  /// an empty secret) rather than a secret with no row pointing at it, which
  /// nothing would ever clean up.
  /// 先把密钥删掉再删行：中途中断只会留下一条密钥已丢失的凭据（可见，且其它地方
  /// 已按空密钥处理），而不是一个没有任何行指向的密钥——那将永远无人清理。
  Future<void> clearAll() async {
    final db = await ref.read(databaseProvider.future);
    final rows = await db.query('tb_credentials', columns: const ['id']);
    for (final row in rows) {
      await SecureStorage.deleteCredential(row['id']! as String);
    }
    await db.delete('tb_credentials');
    ref.invalidateSelf();
  }

  Future<Credential> _credentialFromRow(
    Database db,
    Map<String, Object?> map,
  ) async {
    final id = map['id'] as String;
    final storedSecret = map['secret_data'] as String? ?? '';
    final secureSecret = await SecureStorage.getCredential(id);
    if (secureSecret != null) {
      return Credential.fromMap({...map, 'secret_data': secureSecret});
    }

    if (storedSecret.isNotEmpty && storedSecret != 'secure_storage') {
      await SecureStorage.saveCredential(id, storedSecret);
      await db.update(
        'tb_credentials',
        {'secret_data': 'secure_storage'},
        where: 'id = ?',
        whereArgs: [id],
      );
      return Credential.fromMap({...map, 'secret_data': storedSecret});
    }

    return Credential.fromMap({...map, 'secret_data': ''});
  }
}

// ---- Hosts / 主机 ----

/// Provider for the list of stored [Host] objects.
/// 已存储 [Host] 对象列表的提供者。
final hostListProvider = AsyncNotifierProvider<HostListNotifier, List<Host>>(
  HostListNotifier.new,
);

/// Async notifier managing the hosts list state.
/// 管理主机列表状态的异步通知器。
///
/// Enriches each host with the associated credential's name and username
/// for display purposes.
/// 为每个主机附加关联凭据的名称和用户名，供显示使用。
class HostListNotifier extends AsyncNotifier<List<Host>> {
  /// Build the initial list from the database, enriched with credential info.
  /// 从数据库构建初始列表，并附加凭据信息。
  @override
  Future<List<Host>> build() async {
    final db = await ref.watch(databaseProvider.future);
    final creds = await ref.watch(credentialListProvider.future);
    final credMap = {for (final c in creds) c.id: c};

    final maps = await db.query('tb_hosts', orderBy: 'alias');
    return maps.map((m) {
      final host = Host.fromMap(m);
      final cred = credMap[host.credentialId];
      if (cred != null) {
        host.credentialName = cred.name;
        host.credentialUsername = cred.username;
      }
      return host;
    }).toList();
  }

  /// Insert a new [host] and refresh the list.
  /// 插入新的 [host] 并刷新列表。
  Future<void> addItem(Host host) async {
    final db = await ref.read(databaseProvider.future);
    await db.insert(
      'tb_hosts',
      host.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    ref.invalidateSelf();
  }

  /// Update an existing [host] and refresh the list.
  /// 更新已有的 [host] 并刷新列表。
  Future<void> updateItem(Host host) async {
    final db = await ref.read(databaseProvider.future);
    await db.update(
      'tb_hosts',
      host.toMap(),
      where: 'id = ?',
      whereArgs: [host.id],
    );
    ref.invalidateSelf();
  }

  /// Delete the host with the given [id] and refresh the list.
  /// 删除指定 [id] 的主机并刷新列表。
  ///
  /// Deliberately the same shape as `CredentialListNotifier.deleteItem`: the
  /// refresh is in a `finally`, so a throw from the delete can never leave the
  /// list describing a database it no longer agrees with. There is no secret to
  /// order against here — a host row owns nothing outside this table.
  /// 刻意与 `CredentialListNotifier.deleteItem` 保持同一形态：刷新放在 `finally` 中，
  /// 因此删除抛出的异常绝不可能让列表继续描述一个已经对不上的数据库。这里没有需要
  /// 排序的密钥——主机行不拥有本表之外的任何东西。
  Future<void> deleteItem(String id) async {
    final db = await ref.read(databaseProvider.future);
    try {
      await db.delete('tb_hosts', where: 'id = ?', whereArgs: [id]);
    } finally {
      ref.invalidateSelf();
    }
  }

  /// Removes every host, refreshing once. See `CredentialListNotifier.clearAll`
  /// for why the per-item loop is not good enough for a bulk wipe.
  /// 删除全部主机，且只刷新一次。为何逐条循环不足以应付整批清空，见
  /// `CredentialListNotifier.clearAll`。
  Future<void> clearAll() async {
    final db = await ref.read(databaseProvider.future);
    await db.delete('tb_hosts');
    ref.invalidateSelf();
  }

  /// Set a host's reachability [status], updating state without a DB round-trip.
  /// 设置主机的可达性 [status]，直接更新状态而不访问数据库。
  ///
  /// The write is a no-op — no new list, no listener notification — when the
  /// value already matches or the id is unknown. `AsyncValue` compares its
  /// payload with `==`, and `List` compares by identity, so publishing a fresh
  /// list for an unchanged status makes every listener rebuild; callers such as
  /// the reachability probe call this repeatedly with the same result, which
  /// used to keep the UI rebuilding forever. That matters for the probe's
  /// silent re-refusal too: an untrusted host is written [HostStatus.unverified]
  /// on every round, and each of those rounds has to stay invisible.
  /// 当取值已一致或 id 不存在时，本次写入为空操作：不新建列表，也不通知监听者。
  /// `AsyncValue` 以 `==` 比较其内容，而 `List` 按同一性比较，因此为未变化的
  /// 状态发布新列表会让所有监听者重建；可达性探测等调用方会反复写入相同结果，
  /// 这曾导致界面无休止地重建。探测的静默重拒绝同样依赖这一点：未受信的主机每轮
  /// 都会被写入 [HostStatus.unverified]，而这些轮次必须全都不可见。
  Future<void> setStatus(String id, HostStatus status) async {
    final current = state.value;
    if (current == null) return;

    // `Host.status` is a mutable field, so read it before writing: only a
    // genuine transition may notify.
    // `Host.status` 是可变字段，必须先读后写：只有真实的状态跃迁才通知。
    bool known = false;
    for (final host in current) {
      if (host.id != id) continue;
      known = true;
      if (host.status == status) return;
      break;
    }
    if (!known) return;

    for (final host in current) {
      if (host.id == id) host.status = status;
    }
    // A new list instance is what makes the real transition reach listeners.
    // 新列表实例正是真实状态跃迁能送达监听者的原因。
    state = AsyncData(List<Host>.of(current));
  }

  /// Two-state shorthand for [setStatus], for callers that just observed a
  /// connection succeed or fail — a real measurement, so `false` means
  /// [HostStatus.offline] and not the unknown [HostStatus.unverified].
  /// [setStatus] 的两态简写，供刚刚观测到连接成功或失败的调用方使用——那是真实
  /// 的测量结果，因此 `false` 表示 [HostStatus.offline]，而不是表示未知的
  /// [HostStatus.unverified]。
  Future<void> setOnline(String id, bool online) =>
      setStatus(id, online ? HostStatus.online : HostStatus.offline);
}

// ---- Snippets / 代码片段 ----

/// Provider for the list of stored [Snippet] objects.
/// 已存储 [Snippet] 对象列表的提供者。
final snippetListProvider =
    AsyncNotifierProvider<SnippetListNotifier, List<Snippet>>(
      SnippetListNotifier.new,
    );

/// Async notifier managing the snippets list state.
/// 管理代码片段列表状态的异步通知器。
class SnippetListNotifier extends AsyncNotifier<List<Snippet>> {
  /// Build the initial list by querying the database.
  /// 通过查询数据库构建初始列表。
  @override
  Future<List<Snippet>> build() async {
    final db = await ref.watch(databaseProvider.future);
    final maps = await db.query('tb_snippets', orderBy: 'title');
    return maps.map((m) => Snippet.fromMap(m)).toList();
  }

  /// Insert a new [snippet] and refresh the list.
  /// 插入新的 [snippet] 并刷新列表。
  Future<void> addItem(Snippet snippet) async {
    final db = await ref.read(databaseProvider.future);
    await db.insert(
      'tb_snippets',
      snippet.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    ref.invalidateSelf();
  }

  /// Update an existing [snippet] and refresh the list.
  /// 更新已有的 [snippet] 并刷新列表。
  Future<void> updateItem(Snippet snippet) async {
    final db = await ref.read(databaseProvider.future);
    await db.update(
      'tb_snippets',
      snippet.toMap(),
      where: 'id = ?',
      whereArgs: [snippet.id],
    );
    ref.invalidateSelf();
  }

  /// Delete the snippet with the given [id] and refresh the list.
  /// 删除指定 [id] 的代码片段并刷新列表。
  ///
  /// Same shape as the other two `deleteItem`s: the refresh is in a `finally`,
  /// so a failed delete cannot leave a stale list behind.
  /// 与另外两个 `deleteItem` 同形：刷新放在 `finally` 中，失败的删除因此不可能留下
  /// 一份陈旧的列表。
  Future<void> deleteItem(String id) async {
    final db = await ref.read(databaseProvider.future);
    try {
      await db.delete('tb_snippets', where: 'id = ?', whereArgs: [id]);
    } finally {
      ref.invalidateSelf();
    }
  }

  /// Removes every snippet, refreshing once. See
  /// `CredentialListNotifier.clearAll` for why the per-item loop is not good
  /// enough for a bulk wipe.
  /// 删除全部片段，且只刷新一次。为何逐条循环不足以应付整批清空，见
  /// `CredentialListNotifier.clearAll`。
  Future<void> clearAll() async {
    final db = await ref.read(databaseProvider.future);
    await db.delete('tb_snippets');
    ref.invalidateSelf();
  }
}
