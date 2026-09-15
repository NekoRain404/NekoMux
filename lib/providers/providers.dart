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
  Future<void> deleteItem(String id) async {
    final db = await ref.read(databaseProvider.future);
    await db.delete('tb_credentials', where: 'id = ?', whereArgs: [id]);
    await SecureStorage.deleteCredential(id);
    ref.invalidateSelf();
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
  Future<void> deleteItem(String id) async {
    final db = await ref.read(databaseProvider.future);
    await db.delete('tb_hosts', where: 'id = ?', whereArgs: [id]);
    ref.invalidateSelf();
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
  Future<void> deleteItem(String id) async {
    final db = await ref.read(databaseProvider.future);
    await db.delete('tb_snippets', where: 'id = ?', whereArgs: [id]);
    ref.invalidateSelf();
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
