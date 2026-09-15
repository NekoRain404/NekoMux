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

  /// Mark a host as online or offline, updating state without a DB round-trip.
  /// 将主机标记为在线或离线，直接更新状态而不访问数据库。
  Future<void> setOnline(String id, bool online) async {
    final current = state.value;
    if (current == null) return;
    final updated = current.map((h) {
      if (h.id == id) h.isOnline = online;
      return h;
    }).toList();
    state = AsyncData(updated);
  }
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
}
