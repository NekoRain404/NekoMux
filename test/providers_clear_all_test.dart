import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/providers/providers.dart';
import 'package:sqflite/sqflite.dart';

/// `CredentialListNotifier.clearAll` makes two claims that nothing watched
/// before: it refreshes the list *once* rather than once per credential, and it
/// removes the secrets *before* the rows.
/// `CredentialListNotifier.clearAll` 有两条此前无人看守的声明：它只刷新列表**一次**
/// 而不是每删一条刷一次，并且**先**删密钥再删行。
///
/// Both are observable without a database or a device. The refresh count comes
/// from the notifier's own `build`; the ordering comes from the secure storage
/// method channel, mocked exactly as `haptics_test.dart` mocks the haptics one,
/// with both halves writing into one ordered event log.
/// 两者都无需数据库或设备即可观测。刷新次数来自通知器自身的 `build`；顺序则来自安全
/// 存储的方法通道——像 `haptics_test.dart` 模拟触感通道那样模拟它，并让两半写入同一
/// 份有序事件日志。

/// Events recorded since the last reset, in the order they happened.
/// 自上次重置以来按发生顺序记录的事件。
final List<String> events = <String>[];

/// The channel `flutter_secure_storage` sends `delete` over.
/// `flutter_secure_storage` 发送 `delete` 所用的通道。
const MethodChannel secrets = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

/// The rows `clearAll` is given to work through.
/// 交给 `clearAll` 处理的行。
const List<Map<String, Object?>> credentialRows = [
  {'id': 'c1', 'secret_data': 'secure_storage'},
  {'id': 'c2', 'secret_data': 'secure_storage'},
];

/// Stand-in for the sqflite [Database]: records the calls, answers the two the
/// notifier makes.
/// sqflite [Database] 的替身：记录调用，并回答通知器会发出的那两种。
class _FakeDatabase implements Database {
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
  }) async {
    events.add('rows:query:$table');
    return credentialRows;
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs})
      async {
    events.add('rows:delete:$table');
    return credentialRows.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counts how many times the notifier has been (re)built, which is how the
/// "refreshing once" claim is observed: `invalidateSelf()` is what schedules a
/// rebuild, so N invalidations are N rebuilds.
/// 统计通知器被（重）构建的次数——这正是观测「只刷新一次」的方式：
/// `invalidateSelf()` 会安排一次重建，因此 N 次作废就是 N 次重建。
class _CountingCredentials extends CredentialListNotifier {
  int builds = 0;

  @override
  Future<List<Credential>> build() async {
    builds++;
    return const <Credential>[];
  }
}

class _CountingHosts extends HostListNotifier {
  int builds = 0;

  @override
  Future<List<Host>> build() async {
    builds++;
    return const <Host>[];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingCredentials credentials;
  late _CountingHosts hosts;
  late ProviderContainer container;

  setUp(() {
    events.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secrets, (call) async {
          events.add('secret:${call.method}:${call.arguments['key']}');
          return null;
        });

    container = ProviderContainer.test(
      overrides: [
        databaseProvider.overrideWith((ref) async => _FakeDatabase()),
        credentialListProvider.overrideWith(() {
          credentials = _CountingCredentials();
          return credentials;
        }),
        hostListProvider.overrideWith(() {
          hosts = _CountingHosts();
          return hosts;
        }),
      ],
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secrets, null);
  });

  test('clearAll removes every secret before it removes the rows', () async {
    // The order is the whole point: an interruption between the two steps
    // leaves a credential whose secret is gone — visible, and already handled
    // as an empty secret elsewhere — rather than a secret with no row pointing
    // at it, which nothing would ever clean up.
    // 顺序正是关键：两步之间被打断时，留下的是「密钥已丢失的凭据」（可见，且其它地方
    // 已按空密钥处理），而不是「没有任何行指向的密钥」——后者将永远无人清理。
    container.listen(credentialListProvider, (_, _) {});
    await container.read(credentialListProvider.future);
    await credentials.clearAll();
    await container.pump();

    expect(events, [
      'rows:query:tb_credentials',
      'secret:delete:cred_c1',
      'secret:delete:cred_c2',
      'rows:delete:tb_credentials',
    ]);
  });

  test('clearAll is one statement and one refresh, not one per row', () async {
    // The regression this guards is the per-item loop: `deleteItem` deletes one
    // keyed row and refreshes, so looping over it deleted the rows one
    // statement at a time and re-queried both tables through the host notifier
    // that watches this one.
    // 本条防范的回归是逐条循环：`deleteItem` 的职责是删除一行并刷新，因此循环调用它
    // 会一行一条语句地删，并经由 watch 本通知器的主机通知器反复重查两张表。
    //
    // What is asserted is the work, not the rebuild *count*: Riverpod coalesces
    // invalidations issued between two pumps, so a `clearAll` that invalidates
    // twice rebuilds exactly as often as one that invalidates once — a count
    // here would be an assertion that cannot fail, which is what this
    // remediation exists to remove. The loop is caught by the number of
    // statements below instead.
    // 断言的是实际工作量，而不是重建**次数**：Riverpod 会合并两次 pump 之间发出的
    // 作废，因此作废两次的 `clearAll` 与作废一次的 `clearAll` 重建次数完全相同——此处
    // 断言次数等于一条不可能失败的断言，而本次整改正是要清除这类测试。逐条循环改由下面
    // 的语句条数捕获。
    container.listen(credentialListProvider, (_, _) {});
    await container.read(credentialListProvider.future);
    expect(credentials.builds, 1);

    await credentials.clearAll();
    await container.pump();

    expect(
      events.where((event) => event == 'rows:delete:tb_credentials'),
      hasLength(1),
      reason: 'the wipe must be one DELETE, not one per credential',
    );
    expect(
      credentials.builds,
      2,
      reason:
          'clearAll must refresh the list — leaving deleted credentials on '
          'screen is worse than a slow wipe',
    );
  });

  test('HostListNotifier.clearAll wipes the table and refreshes', () async {
    container.listen(hostListProvider, (_, _) {});
    await container.read(hostListProvider.future);
    expect(hosts.builds, 1);

    await hosts.clearAll();
    await container.pump();

    expect(events, ['rows:delete:tb_hosts']);
    expect(hosts.builds, 2);
  });
}
