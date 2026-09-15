import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/i18n/strings.dart';
import 'package:neko_mux/core/theme/app_fonts.dart';
import 'package:neko_mux/pages/known_hosts_page.dart';
import 'package:neko_mux/pages/settings_page.dart';
import 'package:neko_mux/providers/providers.dart';
import 'package:neko_mux/services/known_hosts_store.dart';
import 'package:neko_mux/widgets/app_ui.dart';
import 'package:sqflite/sqflite.dart';

/// The screen that shows what the app trusts.
/// 展示应用信任了什么的界面。
///
/// `tb_known_hosts` decides whether a connection is verified, warned about or
/// silently accepted, and until this page existed none of it could be seen or
/// undone from the app. These tests pin the parts a user can observe: what an
/// accepted key looks like on screen, what a broken row looks like, and what
/// forgetting actually does to the table.
/// `tb_known_hosts` 决定一次连接是被验证、被警告还是被静默接受；在本页出现之前，
/// 这些内容在应用里既看不到也无法撤销。以下测试固定住用户能观察到的部分：一条已接受
/// 的密钥在屏幕上是什么样、一条坏记录是什么样、以及「删除」对数据表究竟做了什么。

/// In-memory stand-in for the known-hosts table, the same shape as the fake in
/// `known_hosts_test.dart`: it applies the `where` / `whereArgs` / `orderBy` it
/// is handed instead of ignoring them, so a page that asked for something else
/// would see the difference. Deletes can be made to fail, because a forget that
/// did not happen is one of the states this page has to report.
/// 已知主机表的内存替身，与 `known_hosts_test.dart` 中的假实现同形：它会真正应用收到
/// 的 `where` / `whereArgs` / `orderBy` 而不是忽略它们，因此一个要求别的东西的页面会
/// 看到差别。删除可以设置为失败，因为「删除没有发生」正是本页必须报告的状态之一。
class _FakeKnownHostsDb implements Database {
  final Map<String, Map<String, Object?>> rows = {};
  bool failDeletes = false;
  bool failQueries = false;

  /// Puts a row in the table with exactly the columns given, which is how a
  /// blank `key_type` or an unreadable `trusted_at` gets in front of the page.
  /// A column left as null is absent, as far as the reader is concerned.
  /// 按给定列原样写入一行；空白的 `key_type` 或无法解析的 `trusted_at` 就是这样被送到
  /// 页面面前的。留作 null 的列对读取方来说等同于缺席。
  void seed(
    String host, {
    Object? keyType,
    Object? fingerprint,
    Object? trustedAt,
  }) {
    rows[host] = {
      'host': host,
      'key_type': keyType,
      'fingerprint': fingerprint,
      'trusted_at': trustedAt,
    };
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    rows[values['host']! as String] = Map<String, Object?>.of(values);
    return 1;
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    if (failDeletes) throw Exception('disk offline');
    if (where == null) {
      final n = rows.length;
      rows.clear();
      return n;
    }
    // Only the one shape the store uses: `host = ?`.
    expect(where, 'host = ?', reason: 'the store must filter by host');
    expect(whereArgs, hasLength(1));
    return rows.remove(whereArgs!.single! as String) == null ? 0 : 1;
  }

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
    if (failQueries) throw Exception('database is locked');

    // The database is shared: the Settings page that links here reads
    // `tb_settings` from it, and only the known-hosts table is faked.
    // 数据库是共用的：链接到本页的设置页会从同一个数据库读取 `tb_settings`，
    // 而这里只伪造已知主机表。
    if (table != KnownHostsStore.table) return const [];

    var matched = rows.values.where((row) {
      if (where == null) return true;
      expect(where, 'host = ?');
      return row['host'] == whereArgs!.single;
    }).toList();

    if (orderBy != null) {
      expect(orderBy, 'host', reason: 'the store must order by host');
      matched.sort(
        (a, b) => (a['host']! as String).compareTo(b['host']! as String),
      );
    }
    return matched.map(Map<String, Object?>.of).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not used by this test',
  );
}

/// The page, reading through the real provider and the real store, backed by
/// [_FakeKnownHostsDb] instead of sqflite.
/// 真实 provider 与真实存储层之上的本页，底层用 [_FakeKnownHostsDb] 取代 sqflite。
Widget _app(_FakeKnownHostsDb db) {
  return ProviderScope(
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: const MaterialApp(home: KnownHostsPage()),
  );
}

/// The local-time rendering the page is expected to produce for [iso].
/// 页面针对 [iso] 应当给出的本地时间文本。
///
/// Computed here from the same instant rather than hardcoded, so the expectation
/// holds in whatever time zone the tests happen to run in — the conversion to
/// local time is the behaviour under test, not a fixed offset.
/// 这里用同一时刻现算，而不是写死，因此无论测试运行在哪个时区断言都成立——被测的
/// 行为是「换算到本地时间」，不是某个固定偏移。
String _localLabel(String iso) {
  final local = DateTime.parse(iso).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

const String _host = '10.0.0.5:22';
const String _fingerprint = 'SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd';

/// Taps the forget action of the row for [host] — the row's own button, so a
/// test with several rows forgets exactly the one it means.
/// 点击 [host] 那一行的「删除记录」操作——即该行自己的按钮，因此有多行时测试删除的
/// 正是它指定的那一条。
Future<void> _tapForget(WidgetTester tester, {String host = _host}) async {
  final row = find.ancestor(
    of: find.text(host),
    matching: find.byType(AppCard),
  );
  await tester.tap(
    find.descendant(
      of: row,
      matching: find.widgetWithText(TextButton, t('known_hosts_forget')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    AppStrings.setLang('en');
  });
  tearDown(() => AppStrings.setLang('zh'));

  group('reading a row', () {
    testWidgets('shows the host, the fingerprint and the local accept time', (
      tester,
    ) async {
      const iso = '2026-09-15T21:36:00.000Z';
      final db = _FakeKnownHostsDb()
        ..seed(
          _host,
          keyType: 'ssh-ed25519',
          fingerprint: _fingerprint,
          trustedAt: iso,
        );

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();

      expect(find.text(_host), findsOneWidget);
      expect(find.text(_fingerprint), findsOneWidget);
      // Local time, not the stored UTC string: the user compares this against
      // what they were doing at the time.
      expect(
        find.text('${t('known_hosts_trusted_at')} · ${_localLabel(iso)}'),
        findsOneWidget,
      );
      expect(
        find.textContaining(iso),
        findsNothing,
        reason: 'the stored UTC string is not what a user reads',
      );
      // The fingerprint is here to be compared against `ssh-keyscan` output,
      // so it has to be copyable and monospaced — and in the app's own mono
      // face, not the platform's, so a fingerprint lines up with every other
      // monospaced surface rather than changing shape from device to device.
      // Asserted against the constant, so it cannot drift from the face the app
      // actually bundles.
      // 指纹是拿来与 `ssh-keyscan` 输出比对的，因此必须可复制且等宽——而且是应用自带的
      // 等宽字体，而非系统等宽，这样指纹与其它等宽界面保持一致，不会因设备不同而变样。
      // 断言对着常量，因此不会与应用实际打包的字体脱节。
      final fingerprint = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(fingerprint.style?.fontFamily, AppFonts.mono);

      // The key type is shown when the row has one.
      expect(
        tester.widget<AppBadge>(find.byType(AppBadge)).label,
        'ssh-ed25519',
      );
    });

    testWidgets('lists every host in the order the query returned', (
      tester,
    ) async {
      final db = _FakeKnownHostsDb()
        ..seed('10.0.0.6:22', fingerprint: 'SHA256:bb')
        ..seed(_host, fingerprint: 'SHA256:aa');

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();

      final hosts = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .where((data) => data != null && data.endsWith(':22'))
          .toList();
      expect(hosts, [_host, '10.0.0.6:22']);
    });

    testWidgets('fits a phone-width screen with an IPv6 host and a key type', (
      tester,
    ) async {
      // A long host, a badge and the forget button on one line is the widest
      // this row gets; an overflow here would be a red banner on every device.
      // 长主机名、密钥类型标签与「删除」按钮挤在同一行，是这一行最宽的情形；
      // 这里溢出就意味着每台设备上都会出现红色警告条。
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = _FakeKnownHostsDb()
        ..seed(
          '2001:db8:85a3::8a2e:370:7334:2222',
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd',
          trustedAt: '2026-09-15T21:36:00.000Z',
        );

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('2001:db8:85a3::8a2e:370:7334:2222'), findsOneWidget);
      expect(find.text(t('known_hosts_forget')), findsOneWidget);
    });

    testWidgets('hints what forgetting does before the row is acted on', (
      tester,
    ) async {
      final db = _FakeKnownHostsDb()..seed(_host, fingerprint: _fingerprint);

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();

      // Present with rows on screen, not only in the confirmation dialog.
      expect(find.text(t('known_hosts_hint')), findsOneWidget);
    });
  });

  group('an incomplete row', () {
    testWidgets('omits a blank or absent key type instead of showing a chip', (
      tester,
    ) async {
      final db = _FakeKnownHostsDb()
        ..seed('10.0.0.8:22', keyType: '', fingerprint: _fingerprint)
        ..seed('10.0.0.7:22', fingerprint: 'SHA256:bb');

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();

      // An empty type is an absence, not a value: no empty badge anywhere.
      expect(find.byType(AppBadge), findsNothing);
      expect(find.text('10.0.0.7:22'), findsOneWidget);
    });

    testWidgets('shows an unreadable accept time verbatim, without throwing', (
      tester,
    ) async {
      // Both values genuinely fail `DateTime.tryParse`. Out-of-range components
      // do not: Dart normalises `2026-13-45` into a real date rather than
      // rejecting it, so such a value would be rendered, not shown verbatim.
      // 这两个值都确实无法通过 `DateTime.tryParse`。越界的字段不会失败：Dart 会把
      // `2026-13-45` 归一成一个真实日期而不是拒绝它，因此那种值会被渲染成日期，
      // 而不是按原文显示。
      final db = _FakeKnownHostsDb()
        ..seed(_host, fingerprint: _fingerprint, trustedAt: 'not-a-date')
        ..seed(
          '10.0.0.7:22',
          fingerprint: 'SHA256:bb',
          trustedAt: '2026/09/15 21:36',
        );

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();

      // A corrupt value comes out of the database; it may not take the page
      // down, and the row it belongs to stays visible.
      expect(tester.takeException(), isNull);
      expect(find.text(_host), findsOneWidget);
      expect(find.text(_fingerprint), findsOneWidget);
      expect(find.textContaining('not-a-date'), findsOneWidget);
      expect(find.textContaining('2026/09/15 21:36'), findsOneWidget);
    });

    testWidgets('leaves the accept-time line out when there is no value', (
      tester,
    ) async {
      final db = _FakeKnownHostsDb()
        ..seed(_host, fingerprint: _fingerprint, trustedAt: '');

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(_host), findsOneWidget);
      expect(
        find.textContaining(t('known_hosts_trusted_at')),
        findsNothing,
        reason: 'nothing is recorded, so nothing is claimed',
      );
    });

    testWidgets('tolerates a column that is not a string', (tester) async {
      // Defensive read: nothing the table can hold may make this page throw,
      // and a row that cannot be fully read must not take its neighbours down.
      // 防御性读取：数据表里存的是什么都不能让本页抛异常；读不全的那一行也不能把
      // 旁边的行一起拖垮。
      final db = _FakeKnownHostsDb()
        ..seed(_host, fingerprint: 42)
        ..seed('10.0.0.7:22', fingerprint: 'SHA256:bb');

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(_host), findsOneWidget);
      expect(find.text('10.0.0.7:22'), findsOneWidget);
      expect(find.text('SHA256:bb'), findsOneWidget);
    });
  });

  group('reaching it', () {
    testWidgets('from Settings, under System and next to About', (
      tester,
    ) async {
      final db = _FakeKnownHostsDb()
        ..seed(_host, fingerprint: _fingerprint, keyType: 'ssh-ed25519');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      // The settings list is long enough that the bottom rows are not built
      // until they are scrolled into view.
      // 设置列表足够长，底部的行在被滚动到之前不会构建。
      await tester.scrollUntilVisible(
        find.text(t('known_hosts_title')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      // The row says what it is: a list of what the app trusts.
      expect(find.text(t('known_hosts_title')), findsOneWidget);
      expect(find.text(t('known_hosts_sub')), findsOneWidget);
      expect(find.text(t('system')), findsOneWidget);

      await tester.tap(find.text(t('known_hosts_title')));
      await tester.pumpAndSettle();

      // Lands on the page itself, reading the record out of the table.
      expect(find.text(_host), findsOneWidget);
      expect(find.text(_fingerprint), findsOneWidget);
      expect(find.text(t('known_hosts_hint')), findsOneWidget);
      // And offers no way to turn verification off.
      expect(find.byType(Switch), findsNothing);
    });
  });

  group('a table that cannot be read', () {
    testWidgets('says so, and recovers when the user retries', (tester) async {
      // The database opens; it is the read that fails, so the page has an error
      // to report instead of a spinner.
      // 数据库能打开，失败的是这次读取，因此页面有错误可报，而不是一直转圈。
      final db = _FakeKnownHostsDb()
        ..seed(_host, fingerprint: _fingerprint)
        ..failQueries = true;

      await tester.pumpWidget(_app(db));
      // Not `pumpAndSettle`: a provider that fails is re-run on its own backoff,
      // and settling would race those re-runs instead of pinning the state under
      // test. The page renders the failure throughout — see the page's
      // `skipLoadingOnReload`.
      // 不用 `pumpAndSettle`：失败的 provider 会按自己的退避策略自动重跑，settle 会与
      // 这些重跑赛跑，而不是固定住被测状态。整段时间里页面都显示失败——见页面中的
      // `skipLoadingOnReload`。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));

      // Reported, not rendered as an empty list: "nothing is trusted" and "the
      // records could not be read" are different facts, and showing the first
      // when the second is true would hide every accepted key from the user.
      // 如实报告，而不是渲染成空列表：「尚未信任任何主机」与「读不出记录」是两件不同
      // 的事；在后者成立时显示前者，会把全部已接受的密钥从用户眼前藏起来。
      expect(find.textContaining('database is locked'), findsOneWidget);
      expect(find.text(t('known_hosts_empty')), findsNothing);

      db.failQueries = false;
      await tester.tap(find.text(t('retry')));
      await tester.pumpAndSettle();

      expect(find.text(_host), findsOneWidget);
      expect(find.text(_fingerprint), findsOneWidget);
    });
  });

  group('the empty state', () {
    testWidgets('says nothing is trusted yet and explains what forgetting is', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_FakeKnownHostsDb()));
      await tester.pumpAndSettle();

      expect(find.text(t('known_hosts_title')), findsOneWidget);
      expect(find.text(t('known_hosts_empty')), findsOneWidget);
      // The hint is readable in this state too, so it is available before there
      // is anything to act on.
      expect(find.text(t('known_hosts_hint')), findsOneWidget);
    });
  });

  group('forgetting a key', () {
    testWidgets('asks first, naming the host and the next-connection effect', (
      tester,
    ) async {
      final db = _FakeKnownHostsDb()..seed(_host, fingerprint: _fingerprint);

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();
      await _tapForget(tester);

      expect(
        find.text(t('known_hosts_forget_confirm').replaceAll('{0}', _host)),
        findsOneWidget,
      );
      // Nothing happens until the user commits.
      expect(db.rows, contains(_host));
    });

    testWidgets('drops the record when the confirmation is accepted', (
      tester,
    ) async {
      final db = _FakeKnownHostsDb()
        ..seed(_host, fingerprint: _fingerprint)
        ..seed('10.0.0.7:22', fingerprint: 'SHA256:bb');

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();
      await _tapForget(tester);
      await tester.tap(find.text(t('delete')));
      await tester.pumpAndSettle();

      // Gone from the table — the point of the action is that the next
      // connection asks again — and gone from the list with it.
      expect(db.rows.keys, ['10.0.0.7:22']);
      expect(find.text(_host), findsNothing);
      expect(find.text('10.0.0.7:22'), findsOneWidget);
    });

    testWidgets('keeps the record when the confirmation is dismissed', (
      tester,
    ) async {
      final db = _FakeKnownHostsDb()..seed(_host, fingerprint: _fingerprint);

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();
      await _tapForget(tester);
      await tester.tap(find.text(t('cancel')));
      await tester.pumpAndSettle();

      expect(db.rows, contains(_host));
      expect(find.text(_host), findsOneWidget);
    });

    testWidgets('reports a failed forget instead of silently doing nothing', (
      tester,
    ) async {
      final db = _FakeKnownHostsDb()
        ..seed(_host, fingerprint: _fingerprint)
        ..failDeletes = true;

      await tester.pumpWidget(_app(db));
      await tester.pumpAndSettle();
      await _tapForget(tester);
      await tester.tap(find.text(t('delete')));
      await tester.pumpAndSettle();

      // The user is told, and the row stays because the record is still there.
      expect(find.textContaining(t('error')), findsOneWidget);
      expect(db.rows, contains(_host));
      expect(find.text(_host), findsOneWidget);
    });
  });
}
