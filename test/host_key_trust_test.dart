import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/services/host_key_trust.dart';
import 'package:neko_mux/services/known_hosts_store.dart';
import 'package:sqflite/sqflite.dart';

/// Minimal in-memory stand-in for the known-hosts table. Only `query` and
/// `insert` are reachable from [KnownHostsStore]; everything else is forwarded
/// to `noSuchMethod` so the class satisfies `Database` without pulling in a
/// database engine. This is the real decision code under test — only storage is
/// faked.
class _FakeKnownHostsDb implements Database {
  final Map<String, String> rows = {};

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
    final host = whereArgs!.first! as String;
    final fingerprint = rows[host];
    if (fingerprint == null) return const [];
    return [
      {'fingerprint': fingerprint},
    ];
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    rows[values['host']! as String] = values['fingerprint']! as String;
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used by this test');
}

void main() {
  const fingerprint = 'MD5:aa:bb:cc';
  const otherFingerprint = 'MD5:11:22:33';

  late _FakeKnownHostsDb db;
  late List<HostKeyVerdict> prompts;

  setUp(() {
    db = _FakeKnownHostsDb();
    prompts = [];
  });

  Future<bool> Function(String) verifierFor(
    Future<bool> Function(String, HostKeyVerdict) onPrompt,
  ) {
    return buildHostKeyVerifier(
      db: db,
      address: '10.0.0.5',
      port: 22,
      onPrompt: onPrompt,
    );
  }

  test('a trusted key is accepted without prompting the user', () async {
    db.rows['10.0.0.5:22'] = fingerprint;

    final accepted = await verifierFor((_, v) async {
      prompts.add(v);
      return false; // would reject if it were ever asked
    })(fingerprint);

    expect(accepted, isTrue);
    expect(prompts, isEmpty, reason: 'a known key must not interrupt the user');
  });

  test('an unknown key prompts, and accepting it records the key', () async {
    final accepted = await verifierFor((_, v) async {
      prompts.add(v);
      return true;
    })(fingerprint);

    expect(accepted, isTrue);
    expect(prompts, [HostKeyVerdict.unknown]);
    expect(db.rows['10.0.0.5:22'], fingerprint);
  });

  test('an unknown key that the user rejects is not recorded', () async {
    final accepted = await verifierFor((_, v) async {
      prompts.add(v);
      return false;
    })(fingerprint);

    expect(accepted, isFalse);
    expect(db.rows, isEmpty, reason: 'a rejected key must never be stored');
  });

  test('a CHANGED key is surfaced as changed, not as a first contact', () async {
    db.rows['10.0.0.5:22'] = fingerprint;

    final accepted = await verifierFor((_, v) async {
      prompts.add(v);
      return false;
    })(otherFingerprint);

    expect(accepted, isFalse);
    expect(
      prompts,
      [HostKeyVerdict.changed],
      reason:
          'reusing the first-contact prompt here would hide the only signal '
          'that the connection may be intercepted',
    );
    expect(
      db.rows['10.0.0.5:22'],
      fingerprint,
      reason: 'rejecting must leave the original record intact',
    );
  });

  test('accepting a changed key replaces the stored one', () async {
    db.rows['10.0.0.5:22'] = fingerprint;

    final accepted = await verifierFor((_, v) async {
      prompts.add(v);
      return true;
    })(otherFingerprint);

    expect(accepted, isTrue);
    expect(prompts, [HostKeyVerdict.changed]);
    expect(db.rows['10.0.0.5:22'], otherFingerprint);
  });

  test('two ports on one host keep independent records', () async {
    db.rows['10.0.0.5:22'] = fingerprint;

    // Same address, different port: a different server, so an unknown key.
    final accepted = await buildHostKeyVerifier(
      db: db,
      address: '10.0.0.5',
      port: 2222,
      onPrompt: (_, v) async {
        prompts.add(v);
        return true;
      },
    )(otherFingerprint);

    expect(accepted, isTrue);
    expect(prompts, [HostKeyVerdict.unknown]);
    expect(db.rows['10.0.0.5:22'], fingerprint);
    expect(db.rows['10.0.0.5:2222'], otherFingerprint);
  });
}
