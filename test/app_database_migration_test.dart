import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/database/app_database.dart';
import 'package:sqflite/sqflite.dart';

/// Records every statement a migration issues, and answers the one query the
/// migration makes.
/// 记录迁移发出的每条语句，并回答迁移所做的那一次查询。
///
/// Only [execute] and [rawQuery] are reachable from the migration; everything
/// else is forwarded to `noSuchMethod`. This is the real migration code under
/// test — only the database engine is faked.
class _RecordingDb implements DatabaseExecutor {
  _RecordingDb({this.existingColumns = const []});

  /// Column names `PRAGMA table_info` should report.
  final List<String> existingColumns;

  final List<String> statements = [];

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    statements.add(sql);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    if (sql.startsWith('PRAGMA table_info(')) {
      return [
        for (final name in existingColumns) {'name': name},
      ];
    }
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

/// Statements that would destroy or rewrite data the user cannot recreate.
/// 会销毁或重写用户无法重建的数据的语句。
///
/// The migration runs once per install, against hosts and credentials the user
/// has no other copy of. It is allowed to create tables and to add a column; it
/// is never allowed to do any of these.
/// 本迁移每次安装只运行一次，作用于用户没有其它副本的主机与凭据。它可以用建表与加列，
/// 但绝不允许做下面任何一件事。
const _destructive = ['DROP ', 'DELETE FROM', 'UPDATE ', 'TRUNCATE'];

void _expectNothingDestructive(List<String> statements) {
  for (final sql in statements) {
    final upper = sql.toUpperCase();
    for (final bad in _destructive) {
      expect(
        upper.contains(bad),
        isFalse,
        reason:
            'a migration must never destroy data the user cannot recreate, '
            'but it issued: ${sql.trim()}',
      );
    }
  }
}

void main() {
  group('migrate — v3 to v4 adds the host group column', () {
    test('issues one ALTER TABLE ADD COLUMN per column it needs', () async {
      // A v3 database is two schema versions behind now, so it gains both
      // columns — the group it was missing and the jump host that arrived with
      // v5. What the assertion is really about is the *shape* of the work: one
      // cheap ALTER per column, no table rewrite, nothing else.
      final db = _RecordingDb(
        existingColumns: const [
          'id',
          'alias',
          'ip_address',
          'port',
          'credential_id',
          'os_type',
        ],
      );

      await AppDatabase().migrate(db, 3, AppDatabase.schemaVersion);

      expect(db.statements, hasLength(2));
      expect(db.statements.every((s) => s.contains('ALTER TABLE tb_hosts')), isTrue);
      expect(
        db.statements.join(' '),
        contains('ADD COLUMN group_name TEXT'),
      );
      expect(
        db.statements.join(' '),
        contains('ADD COLUMN jump_host_id TEXT'),
      );
      _expectNothingDestructive(db.statements);
    });

    test('is skipped when the column is already there', () async {
      // The cases this protects are the ones sqflite's transaction does not
      // cover — a database restored between builds, or a hand-edited file whose
      // user_version disagrees with its schema. Without the check those throw
      // "duplicate column name" from inside openDatabase and the app cannot open
      // its database at all: no host list, not even Settings to restore a backup.
      final db = _RecordingDb(
        existingColumns: const ['id', 'group_name', 'jump_host_id'],
      );

      await AppDatabase().migrate(db, 3, AppDatabase.schemaVersion);

      expect(db.statements, isEmpty);
    });
  });

  group('migrate — older versions catch up', () {
    test('v1 runs every step and still destroys nothing', () async {
      final db = _RecordingDb(existingColumns: const ['id']);

      await AppDatabase().migrate(db, 1, AppDatabase.schemaVersion);

      final joined = db.statements.join('\n');
      expect(joined, contains('tb_settings'));
      expect(joined, contains('tb_known_hosts'));
      expect(joined, contains('ADD COLUMN group_name TEXT'));
      _expectNothingDestructive(db.statements);
    });

    test('an already-current database issues nothing', () async {
      final db = _RecordingDb(existingColumns: const ['id', 'group_name']);

      await AppDatabase().migrate(
        db,
        AppDatabase.schemaVersion,
        AppDatabase.schemaVersion,
      );

      expect(db.statements, isEmpty);
    });

    test('every create is IF NOT EXISTS, so a rerun is harmless', () async {
      // sqflite rolls an interrupted upgrade back whole, but a database copied
      // between builds can carry a table without the version that implies it.
      final db = _RecordingDb(existingColumns: const ['id']);

      await AppDatabase().migrate(db, 1, AppDatabase.schemaVersion);

      final creates = db.statements.where(
        (s) => s.trimLeft().toUpperCase().startsWith('CREATE TABLE'),
      );
      expect(creates, isNotEmpty);
      for (final sql in creates) {
        expect(
          sql.toUpperCase(),
          contains('IF NOT EXISTS'),
          reason: 'a CREATE without IF NOT EXISTS fails on a rerun: $sql',
        );
      }
    });
  });

  group('migrate — v4 to v5 adds the jump host column', () {
    test('one ALTER, and nothing else', () async {
      // The step a database that already has `group_name` still needs.
      final db = _RecordingDb(
        existingColumns: const [
          'id',
          'alias',
          'ip_address',
          'port',
          'credential_id',
          'os_type',
          'group_name',
        ],
      );

      await AppDatabase().migrate(db, 4, AppDatabase.schemaVersion);

      expect(db.statements, hasLength(1));
      expect(db.statements.single, contains('ALTER TABLE tb_hosts'));
      expect(db.statements.single, contains('ADD COLUMN jump_host_id TEXT'));
      _expectNothingDestructive(db.statements);
    });

    test('is skipped when the column is already there', () async {
      // A database restored between builds, or hand-edited, may already carry it
      // — and running the ALTER anyway would throw and take the whole migration
      // (and therefore the host list) with it.
      final db = _RecordingDb(
        existingColumns: const [
          'id',
          'alias',
          'ip_address',
          'port',
          'credential_id',
          'os_type',
          'group_name',
          'jump_host_id',
        ],
      );

      await AppDatabase().migrate(db, 4, AppDatabase.schemaVersion);

      expect(db.statements, isEmpty);
    });
  });

  group('the added column is the shape SQLite can add cheaply', () {
    test('nullable with no default', () async {
      // `ALTER TABLE ADD COLUMN` only avoids rewriting the table — and therefore
      // only cannot lose rows — for a column with no default and no UNIQUE or
      // PRIMARY KEY. A default would force SQLite to write a value into every
      // existing row; nullable-with-no-default is what lets existing rows simply
      // read NULL, which is also exactly what "ungrouped" means.
      final db = _RecordingDb(existingColumns: const ['id']);
      await AppDatabase().migrate(db, 3, AppDatabase.schemaVersion);

      // Every column this migration adds, not just the first one: the v5 column
      // has to be the same cheap shape, for the same reason.
      expect(db.statements, isNotEmpty);
      for (final statement in db.statements) {
        final sql = statement.toUpperCase();
        expect(sql, contains('ADD COLUMN'));
        expect(sql, isNot(contains('NOT NULL')));
        expect(sql, isNot(contains('DEFAULT')));
        expect(sql, isNot(contains('UNIQUE')));
        expect(sql, isNot(contains('PRIMARY KEY')));
      }
      expect(
        db.statements.join(' ').toUpperCase(),
        contains('GROUP_NAME TEXT'),
      );
      expect(
        db.statements.join(' ').toUpperCase(),
        contains('JUMP_HOST_ID TEXT'),
      );
    });
  });
}
