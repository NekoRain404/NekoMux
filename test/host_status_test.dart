import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/providers/providers.dart';
import 'package:neko_mux/widgets/host_card.dart';
import 'package:sqflite/sqflite.dart';

// Pins the three-state reachability model: what a silent background probe is
// allowed to conclude, and what it is not.
// 固定三态可达性模型：静默的后台探测可以得出什么结论，不可以得出什么结论。
//
// The probe never raises a trust prompt, so the interesting branch is the one
// where it refuses a key it has not seen before. Reporting that host as
// "offline" would be a claim nobody measured — and on first launch with four
// saved hosts it would be four of them at once.
// 探测绝不弹出信任提示，因此真正要紧的是「拒绝未曾见过的密钥」这条分支。把该主机
// 报成「离线」等于宣称一件无人测量过的事——而在首次启动、存有四台主机时，这会是
// 同时四台。

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

/// Builds a container whose host list holds a single host `h1`, loaded from the
/// database — hence starting out unverified, like every stored host.
/// 构建一个容器，其主机列表仅包含一台主机 `h1`，且由数据库载入——因此和所有已存储
/// 的主机一样，起步状态为待验证。
ProviderContainer _testContainer() => ProviderContainer.test(
  overrides: [
    databaseProvider.overrideWith(
      (ref) async => _FakeDatabase([
        {
          'id': 'h1',
          'alias': 'alpha',
          'ip_address': '10.0.0.1',
          'port': 22,
          'credential_id': 'c1',
          'os_type': 0,
        },
      ]),
    ),
    credentialListProvider.overrideWith(_NoCredentials.new),
  ],
);

Host _host({bool? isOnline, HostStatus status = HostStatus.unverified}) => Host(
  id: 'h1',
  alias: 'alpha',
  ipAddress: '10.0.0.1',
  credentialId: 'c1',
  status: status,
  isOnline: isOnline,
);

void main() {
  group('Host.statusForProbe', () {
    test('a refused handshake is unverified, never offline', () {
      // The probe answered "no" to a key it has not seen. It learned nothing
      // about the machine, so "offline" would be an invented outage.
      // 探测对未曾见过的密钥回答了「否」。它对那台机器一无所知，报「离线」就是
      // 凭空捏造一次故障。
      expect(
        Host.statusForProbe(
          attempted: true,
          connected: false,
          trustRefused: true,
        ),
        HostStatus.unverified,
      );

      // A refusal is not evidence of reachability either, whatever the
      // connection object reports.
      // 拒绝同样不是可达的证据，无论连接对象报告什么。
      expect(
        Host.statusForProbe(
          attempted: true,
          connected: true,
          trustRefused: true,
        ),
        HostStatus.unverified,
      );
    });

    test('a probe that never ran is unverified', () {
      // No credential to connect with: no attempt, no measurement.
      // 没有可用凭据：没有尝试，就没有测量。
      expect(
        Host.statusForProbe(
          attempted: false,
          connected: false,
          trustRefused: false,
        ),
        HostStatus.unverified,
      );
      expect(
        Host.statusForProbe(
          attempted: false,
          connected: true,
          trustRefused: false,
        ),
        HostStatus.unverified,
      );
    });

    test('an allowed handshake reports what the host did', () {
      // Hands we were allowed to complete are real evidence, in both
      // directions.
      // 我们获准完成的握手是真实证据，两个方向都算。
      expect(
        Host.statusForProbe(
          attempted: true,
          connected: true,
          trustRefused: false,
        ),
        HostStatus.online,
      );
      expect(
        Host.statusForProbe(
          attempted: true,
          connected: false,
          trustRefused: false,
        ),
        HostStatus.offline,
      );
    });
  });

  group('Host three-state model', () {
    test('a freshly added host is unverified, not offline', () {
      final host = _host();
      expect(host.status, HostStatus.unverified);
      expect(
        host.status,
        isNot(HostStatus.offline),
        reason: 'never probed is not the same claim as known to be down',
      );
    });

    test('isOnline is a read-only view of status', () {
      expect(_host(status: HostStatus.online).isOnline, isTrue);
      expect(_host(status: HostStatus.unverified).isOnline, isFalse);
      expect(_host(status: HostStatus.offline).isOnline, isFalse);
    });

    test('the legacy boolean cannot invent an outage', () {
      expect(_host(isOnline: true).status, HostStatus.online);
      // `false` only ever meant "not known to be online" — the old field could
      // not tell that apart from "known to be down", and a caller holding the
      // weaker fact must not be turned into the stronger claim.
      // `false` 从来只表示「不确知在线」——旧字段无法把它与「确知宕机」区分开，
      // 持有较弱事实的调用方绝不能被升级成更强的断言。
      expect(_host(isOnline: false).status, HostStatus.unverified);
      expect(_host(status: HostStatus.offline).status, HostStatus.offline);
    });

    test('copyWith replaces status and keeps it when omitted', () {
      final host = _host(status: HostStatus.online);
      expect(
        host.copyWith(status: HostStatus.unverified).status,
        HostStatus.unverified,
      );
      expect(host.copyWith(alias: 'beta').status, HostStatus.online);
    });

    test('status is a runtime observation, not stored state', () {
      // Nothing is written to the database, so a host restored from a backup
      // cannot inherit an "online" that was true on another device.
      // 数据库里什么都不写，因此从备份恢复的主机不可能继承另一台设备上的「在线」。
      final host = Host.fromMap({
        'id': 'h1',
        'alias': 'alpha',
        'ip_address': '10.0.0.1',
        'port': 22,
        'credential_id': 'c1',
        'os_type': 0,
      });
      expect(host.status, HostStatus.unverified);
      expect(host.toMap().containsKey('status'), isFalse);
    });
  });

  group('HostListNotifier.setStatus', () {
    test('a repeated refusal does not notify listeners', () async {
      final container = _testContainer();
      await container.read(hostListProvider.future);
      final notifier = container.read(hostListProvider.notifier);

      final notifications = <HostStatus>[];
      container.listen(hostListProvider, (_, next) {
        if (next.hasValue && next.requireValue.isNotEmpty) {
          notifications.add(next.requireValue.single.status);
        }
      });

      // The probe re-refuses an untrusted key on every round and writes the
      // same status each time; every one of those rounds has to stay invisible.
      // 每一轮探测都会再次拒绝未受信的密钥并写入同样的状态；这些轮次必须全部
      // 不产生任何可见影响。
      for (var i = 0; i < 3; i++) {
        await notifier.setStatus('h1', HostStatus.unverified);
        await container.pump();
      }
      expect(
        notifications,
        isEmpty,
        reason: 're-refusing an untrusted host must not rebuild the list',
      );

      await notifier.setStatus('h1', HostStatus.online);
      await container.pump();
      await notifier.setStatus('h1', HostStatus.online);
      await container.pump();
      expect(notifications, [HostStatus.online]);

      // Back to unverified — e.g. the trusted key was removed — is a real
      // transition and must reach the UI.
      // 回到待验证——例如受信密钥被移除——是一次真实跃迁，必须送达界面。
      await notifier.setStatus('h1', HostStatus.unverified);
      await container.pump();
      expect(notifications, [HostStatus.online, HostStatus.unverified]);

      // An unknown id is a no-op as well.
      // 未知 id 同样是空操作。
      await notifier.setStatus('nope', HostStatus.offline);
      await container.pump();
      expect(notifications, [HostStatus.online, HostStatus.unverified]);
    });

    test('an unverified host is not counted as offline', () async {
      final container = _testContainer();
      final hosts = await container.read(hostListProvider.future);
      expect(hosts.single.status, HostStatus.unverified);
      expect(hosts.single.isOnline, isFalse);
    });
  });

  group('status rendering', () {
    final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32));

    test('three states, three labels, three colours', () {
      expect(hostStatusLabel(HostStatus.online), t('running'));
      expect(
        hostStatusLabel(HostStatus.unverified),
        t('host_status_unverified'),
      );
      expect(hostStatusLabel(HostStatus.offline), t('offline_status'));

      final colors = {
        for (final status in HostStatus.values)
          status: hostStatusColor(cs, status),
      };
      expect(
        colors.values.toSet(),
        hasLength(HostStatus.values.length),
        reason: 'the three states must not share a colour',
      );
    });

    test('unverified is not painted as an error', () {
      // Red means "down". Spending it on a host whose state we could not
      // determine is how the colour stops meaning anything.
      // 红色表示「宕机」。把它用在状态无法判定的主机上，这个颜色就不再表示任何东西。
      expect(hostStatusColor(cs, HostStatus.unverified), isNot(cs.error));
      expect(hostStatusColor(cs, HostStatus.offline), cs.error);
      expect(hostStatusColor(cs, HostStatus.online), cs.primary);
    });

    testWidgets('the card shows the unverified badge for an unverified host', (
      tester,
    ) async {
      for (final status in HostStatus.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HostCard(host: _host(status: status)),
            ),
          ),
        );
        expect(
          find.text(hostStatusLabel(status)),
          findsOneWidget,
          reason: 'the card must render $status as its own state',
        );
      }
    });
  });
}
