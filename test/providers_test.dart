import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/providers/providers.dart';
import 'package:sqflite/sqflite.dart';

/// In-memory stand-in for the sqflite [Database] the host notifier reads from.
/// Only `query` is exercised by `HostListNotifier.build`; everything else is a
/// forwarder.
/// sqflite [Database] 的内存替身。`HostListNotifier.build` 只会用到 `query`，
/// 其余成员交给 noSuchMethod 转发。
class _FakeDatabase implements Database {
  _FakeDatabase(this.hostRows);

  final List<Map<String, Object?>> hostRows;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async => hostRows;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Credential notifier that resolves to an empty list without touching the
/// database.
/// 不访问数据库、直接返回空列表的凭据通知器。
class _NoCredentials extends CredentialListNotifier {
  @override
  Future<List<Credential>> build() async => const <Credential>[];
}

/// Builds a container whose host list holds a single offline host `h1`.
/// 构建一个容器，其主机列表仅包含一台离线主机 `h1`。
ProviderContainer _testContainer() {
  final rows = <Map<String, Object?>>[
    {
      'id': 'h1',
      'alias': 'alpha',
      'ip_address': '10.0.0.1',
      'port': 22,
      'credential_id': 'c1',
      'os_type': 0,
    },
  ];
  return ProviderContainer.test(
    overrides: [
      databaseProvider.overrideWith((ref) async => _FakeDatabase(rows)),
      credentialListProvider.overrideWith(_NoCredentials.new),
    ],
  );
}

void main() {
  test('setOnline notifies only on a real transition', () async {
    final container = _testContainer();

    final initial = await container.read(hostListProvider.future);
    expect(initial, hasLength(1));
    expect(initial.single.isOnline, isFalse);

    // Record every value the provider pushes to its listeners.
    // 记录提供者推送给监听者的每一次取值。
    final notifications = <bool>[];
    container.listen(hostListProvider, (_, next) {
      if (next.hasValue && next.requireValue.isNotEmpty) {
        notifications.add(next.requireValue.single.isOnline);
      }
    });

    final notifier = container.read(hostListProvider.notifier);

    await notifier.setOnline('h1', true);
    await container.pump();
    expect(notifications, [
      true,
    ], reason: 'false -> true is a real transition and must notify');

    // Redundant writes must neither notify nor rebuild the list.
    // 冗余写入既不得通知，也不得重建列表。
    await notifier.setOnline('h1', true);
    await notifier.setOnline('h1', true);
    await notifier.setOnline('h1', true);
    await container.pump();
    expect(
      notifications,
      [true],
      reason: 'redundant setOnline writes must not notify listeners',
    );

    await notifier.setOnline('h1', false);
    await container.pump();
    expect(notifications, [
      true,
      false,
    ], reason: 'true -> false is a real transition and must notify');

    await notifier.setOnline('h1', false);
    await container.pump();
    expect(
      notifications,
      [true, false],
      reason: 'redundant setOnline writes must not notify listeners',
    );

    // An unknown id must not notify either.
    // 未知 id 同样不得触发通知。
    await notifier.setOnline('nope', true);
    await container.pump();
    expect(notifications, [true, false]);

    expect(
      container.read(hostListProvider).requireValue.single.isOnline,
      isFalse,
    );
  });

  test('setOnline keeps the list contents in sync', () async {
    final container = _testContainer();
    await container.read(hostListProvider.future);
    final notifier = container.read(hostListProvider.notifier);

    final before = container.read(hostListProvider).requireValue;
    await notifier.setOnline('h1', true);
    final after = container.read(hostListProvider).requireValue;

    expect(after.single.isOnline, isTrue);
    expect(
      identical(before, after),
      isFalse,
      reason: 'a real transition must publish a new list instance',
    );
  });
}
