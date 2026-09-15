import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/pages/credential_list_page.dart';
import 'package:neko_mux/providers/providers.dart';
import 'package:sqflite/sqflite.dart';

/// Deleting a credential used to ask a generic "delete this?" question, even
/// when hosts pointed at it. The database does not enforce the declared foreign
/// key, so those hosts silently became orphans that could never connect again
/// and explained nothing. These tests pin the warning that now precedes it.
/// 删除凭据过去只会问一句笼统的「确定删除吗？」，即使有主机正引用它。数据库并不强制
/// 声明的外键，那些主机会静默变成再也无法连接、也说不清原因的孤儿。这里固定住现在
/// 删除之前给出的警告。

/// In-memory stand-in for the sqflite [Database] the host notifier reads.
/// Only `query` is exercised by `HostListNotifier.build`.
/// sqflite [Database] 的内存替身，`HostListNotifier.build` 只会用到 `query`。
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

/// Credential notifier serving a fixed list and recording deletions, so the
/// tests never touch the database or the secure storage.
/// 返回固定列表并记录删除操作的凭据通知器，测试因此不接触数据库与安全存储。
class _FixedCredentials extends CredentialListNotifier {
  _FixedCredentials(this.rows);

  final List<Credential> rows;

  @override
  Future<List<Credential>> build() async => rows;

  @override
  Future<void> deleteItem(String id) async => deleted.add(id);
}

/// Ids passed to `deleteItem` since the last reset.
/// 自上次重置以来传给 `deleteItem` 的 id。
final List<String> deleted = <String>[];

Credential _credential(String id, String name) => Credential(
  id: id,
  name: name,
  authType: 0,
  username: 'root',
  secretData: 'secret',
);

/// A host row pointing at [credentialId].
/// 一条指向 [credentialId] 的主机行。
Map<String, Object?> _hostRow(String id, String credentialId) => {
  'id': id,
  'alias': 'host $id',
  'ip_address': '10.0.0.1',
  'port': 22,
  'credential_id': credentialId,
  'os_type': 0,
};

Widget _app({
  required List<Map<String, Object?>> hostRows,
  required List<Credential> credentials,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWith((ref) async => _FakeDatabase(hostRows)),
      credentialListProvider.overrideWith(() => _FixedCredentials(credentials)),
    ],
    child: const MaterialApp(home: CredentialListPage()),
  );
}

/// Opens the tile's overflow menu and taps Delete.
/// 打开列表项的溢出菜单并点击删除。
Future<void> _tapDelete(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  await tester.tap(find.text(t('delete')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    AppStrings.setLang('en');
    deleted.clear();
  });
  tearDown(() => AppStrings.setLang('zh'));

  group('confirmation text', () {
    test('is the plain question when no host uses the credential', () {
      expect(
        credentialDeleteConfirmation('prod-root', 0),
        t('confirm_delete_credential').replaceAll('{0}', 'prod-root'),
      );
      expect(
        credentialDeleteConfirmation('prod-root', -1),
        t('confirm_delete_credential').replaceAll('{0}', 'prod-root'),
      );
    });

    test('names the host count when hosts use the credential', () {
      final message = credentialDeleteConfirmation('prod-root', 3);
      expect(
        message,
        startsWith(
          t('confirm_delete_credential').replaceAll('{0}', 'prod-root'),
        ),
      );
      // The count line uses its own key rather than being assembled from
      // `my_hosts`, so it can read as a sentence in every language.
      // 数量那一行使用专用键，而不是用 `my_hosts` 拼出来，这样它在每种语言里都能
      // 读成一句完整的话。
      expect(
        message,
        contains(t('credential_used_by_hosts').replaceAll('{0}', '3')),
      );
    });

    test('is translated, not assembled from English', () {
      AppStrings.setLang('zh');
      final message = credentialDeleteConfirmation('生产服务器', 2);
      expect(
        message,
        contains(t('confirm_delete_credential').replaceAll('{0}', '生产服务器')),
      );
      expect(
        message,
        contains(t('credential_used_by_hosts').replaceAll('{0}', '2')),
      );
      expect(message, isNot(contains('My Hosts')));
      expect(message, isNot(contains('Hosts using')));
    });
  });

  group('delete dialog', () {
    testWidgets('says how many hosts will be affected', (tester) async {
      await tester.pumpWidget(
        _app(
          hostRows: [
            _hostRow('h1', 'c1'),
            _hostRow('h2', 'c1'),
            _hostRow('h3', 'other'),
          ],
          credentials: [_credential('c1', 'prod-root')],
        ),
      );
      await tester.pumpAndSettle();

      await _tapDelete(tester);

      expect(
        find.text(credentialDeleteConfirmation('prod-root', 2)),
        findsOneWidget,
      );
      expect(deleted, isEmpty);
    });

    testWidgets('stays a plain question when nothing references it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          hostRows: [_hostRow('h1', 'other')],
          credentials: [_credential('c1', 'prod-root')],
        ),
      );
      await tester.pumpAndSettle();

      await _tapDelete(tester);

      expect(
        find.text(credentialDeleteConfirmation('prod-root', 0)),
        findsOneWidget,
      );
    });

    testWidgets('still deletes once the warning is accepted', (tester) async {
      await tester.pumpWidget(
        _app(
          hostRows: [_hostRow('h1', 'c1')],
          credentials: [_credential('c1', 'prod-root')],
        ),
      );
      await tester.pumpAndSettle();

      await _tapDelete(tester);
      await tester.tap(find.text(t('delete')));
      await tester.pumpAndSettle();

      expect(deleted, ['c1']);
    });

    testWidgets('does not delete when the warning is dismissed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          hostRows: [_hostRow('h1', 'c1')],
          credentials: [_credential('c1', 'prod-root')],
        ),
      );
      await tester.pumpAndSettle();

      await _tapDelete(tester);
      await tester.tap(find.text(t('cancel')));
      await tester.pumpAndSettle();

      expect(deleted, isEmpty);
    });
  });
}
