import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/known_hosts_store.dart';
import 'package:sqflite/sqflite.dart';

/// In-memory stand-in for the known-hosts table: a `Map` of host to row.
/// 已知主机表的内存替身：以主机为键、行为值的 `Map`。
///
/// It applies the `where` / `whereArgs` / `orderBy` it is given instead of
/// ignoring them, so a store that forgets to ask for an ordering or a filter
/// gets back what such a query really returns — the difference is what the
/// tests below are about. `key_type` and `trusted_at` are kept because
/// [KnownHostsStore.all] hands whole rows to the UI.
/// 它会真正应用收到的 `where` / `whereArgs` / `orderBy`，而不是忽略它们，因此忘记
/// 要求排序或过滤的存储层拿到的就是这种查询真实的结果——下面几条测试正是围绕这一
/// 差别。保留 `key_type` 与 `trusted_at`，是因为 [KnownHostsStore.all] 会把整行交给
/// 界面。
class _FakeKnownHostsDb implements Database {
  final Map<String, Map<String, Object?>> rows = {};

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

/// Tests for the decision logic behind host key trust.
///
/// The decision is deliberately separated from persistence so it can be tested
/// without a database. What matters is the three-way outcome: a key we have
/// never seen, a key we already trust, and a key that CHANGED for a host we
/// already know — the last one is the only signal that a machine-in-the-middle
/// may be present, and the previous in-memory-only implementation could not
/// represent it at all.
void main() {
  group('evaluateHostKey', () {
    test('reports unknown for a host we have never recorded', () {
      final verdict = evaluateHostKey(
        storedFingerprint: null,
        presentedFingerprint: 'MD5:aa:bb',
      );

      expect(verdict, HostKeyVerdict.unknown);
    });

    test('reports trusted when the presented key matches the stored one', () {
      final verdict = evaluateHostKey(
        storedFingerprint: 'MD5:aa:bb',
        presentedFingerprint: 'MD5:aa:bb',
      );

      expect(verdict, HostKeyVerdict.trusted);
    });

    test('reports changed when the host presents a different key', () {
      final verdict = evaluateHostKey(
        storedFingerprint: 'MD5:aa:bb',
        presentedFingerprint: 'MD5:cc:dd',
      );

      expect(verdict, HostKeyVerdict.changed);
    });

    test('treats an empty stored fingerprint as unknown, not as changed', () {
      // A blank row is a storage artefact, not evidence of a key swap. Calling
      // it "changed" would train users to click through the one warning that
      // actually matters.
      final verdict = evaluateHostKey(
        storedFingerprint: '',
        presentedFingerprint: 'MD5:aa:bb',
      );

      expect(verdict, HostKeyVerdict.unknown);
    });

    test('comparison is exact, not case-insensitive', () {
      // Fingerprints are hex; a case difference means something garbled the
      // value in transit through storage, which deserves a fresh prompt rather
      // than a silent pass.
      final verdict = evaluateHostKey(
        storedFingerprint: 'MD5:AA:BB',
        presentedFingerprint: 'MD5:aa:bb',
      );

      expect(verdict, HostKeyVerdict.changed);
    });
  });

  group('hostKeyFor', () {
    test(
      'combines address and port so two ports on one host stay separate',
      () {
        expect(hostKeyFor('10.0.0.5', 22), '10.0.0.5:22');
        expect(hostKeyFor('10.0.0.5', 2222), '10.0.0.5:2222');
        expect(
          hostKeyFor('10.0.0.5', 22),
          isNot(equals(hostKeyFor('10.0.0.5', 2222))),
        );
      },
    );

    test('handles IPv6 literals without losing the port', () {
      // The exact string, brackets and all. The previous `endsWith(':22')`
      // plus `contains('fe80::1')` also passed for the bracket-less
      // `fe80::1:22` — which is precisely the ambiguity the bracketing exists
      // to remove, since a record for the host `fe80::1` on port 22 would then
      // be indistinguishable from one for the address `fe80::1:22`.
      // 断言完整的字符串，方括号在内。此前的 `endsWith(':22')` 加
      // `contains('fe80::1')` 对无方括号的 `fe80::1:22` 同样成立——而这正是加方
      // 括号要消除的歧义：那样一来，`fe80::1` 上 22 端口的记录会与地址
      // `fe80::1:22` 的记录无从区分。
      expect(hostKeyFor('fe80::1', 22), '[fe80::1]:22');
      expect(hostKeyFor('fe80::1', 2222), '[fe80::1]:2222');
      expect(hostKeyFor('fe80::1', 22), isNot(hostKeyFor('fe80::1', 2222)));
    });
  });

  group('KnownHostsStore', () {
    late _FakeKnownHostsDb db;
    late KnownHostsStore store;

    setUp(() {
      db = _FakeKnownHostsDb();
      store = KnownHostsStore(db);
    });

    Future<void> trust(String host, String fingerprint) =>
        store.trust(host: host, keyType: 'ssh-ed25519', fingerprint: fingerprint);

    test('forget makes the next connection prompt again', () async {
      // The user's only remedy after a changed-key warning: without it, a key
      // the user has just been told changed stays trusted forever and the
      // warning can never be acted on.
      // 用户在「密钥已变更」警告之后唯一的补救手段：没有它，一条刚被告知已变更的
      // 密钥会永远受信，那条警告也就永远无法被处理。
      await trust('10.0.0.5:22', 'MD5:aa:bb');

      expect(
        await store.check(host: '10.0.0.5:22', fingerprint: 'MD5:aa:bb'),
        HostKeyVerdict.trusted,
      );

      await store.forget('10.0.0.5:22');

      expect(
        await store.check(host: '10.0.0.5:22', fingerprint: 'MD5:aa:bb'),
        HostKeyVerdict.unknown,
        reason: 'a forgotten key must be asked about again, not silently used',
      );
      expect(db.rows, isEmpty);
    });

    test('forget drops one host and leaves the others alone', () async {
      await trust('10.0.0.5:22', 'MD5:aa:bb');
      await trust('10.0.0.6:22', 'MD5:cc:dd');

      await store.forget('10.0.0.5:22');

      expect(db.rows.keys, ['10.0.0.6:22']);
      expect(
        await store.check(host: '10.0.0.6:22', fingerprint: 'MD5:cc:dd'),
        HostKeyVerdict.trusted,
        reason: 'forgetting one host must not forget the rest',
      );
    });

    test('forget on a host that was never recorded is harmless', () async {
      await trust('10.0.0.6:22', 'MD5:cc:dd');

      await store.forget('10.0.0.5:22');

      expect(db.rows.keys, ['10.0.0.6:22']);
    });

    test('all lists every record, ordered by host', () async {
      // Inserted out of order on purpose: the query is what has to sort them,
      // and a stable order is what keeps the list from reshuffling itself
      // between rebuilds.
      // 有意乱序插入：排序必须由查询完成，而稳定的顺序正是列表在多次重建之间不会
      // 自行重排的原因。
      await trust('10.0.0.6:22', 'MD5:cc:dd');
      await trust('10.0.0.5:22', 'MD5:aa:bb');
      await trust('fe80::1:2222', 'MD5:ee:ff');

      final all = await store.all();

      expect(
        all.map((row) => row['host']).toList(),
        ['10.0.0.5:22', '10.0.0.6:22', 'fe80::1:2222'],
      );
      expect(all.first['fingerprint'], 'MD5:aa:bb');
      expect(all.first['key_type'], 'ssh-ed25519');
      // The row carries when it was trusted, which is what the UI shows.
      expect(all.first['trusted_at'], isA<String>());
    });

    test('recordFor answers with the stored row, or null', () async {
      // What the console's identity card reads: the key this device decided to
      // trust for the host it is connected to. It is the screen a user opens
      // when they suspect interception, so the lookup has to answer for a host
      // that has a record and stay quiet for one that does not.
      await trust('10.0.0.5:22', 'MD5:aa:bb');

      final record = await store.recordFor('10.0.0.5:22');
      expect(record, isNotNull);
      expect(record!['fingerprint'], 'MD5:aa:bb');
      expect(record['key_type'], 'ssh-ed25519');

      expect(
        await store.recordFor('10.0.0.9:22'),
        isNull,
        reason: 'a host with no record must not borrow another host\'s key',
      );
    });

    test('all is empty on a store with no records', () async {
      expect(await store.all(), isEmpty);
    });

    test('trust replaces the previous key for the same host', () async {
      await trust('10.0.0.5:22', 'MD5:aa:bb');
      await trust('10.0.0.5:22', 'MD5:cc:dd');

      expect(db.rows, hasLength(1));
      expect(
        await store.check(host: '10.0.0.5:22', fingerprint: 'MD5:cc:dd'),
        HostKeyVerdict.trusted,
      );
      expect(
        await store.check(host: '10.0.0.5:22', fingerprint: 'MD5:aa:bb'),
        HostKeyVerdict.changed,
      );
    });
  });
}
