import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// SQLite database manager providing singleton access to the app's local database.
/// SQLite 数据库管理器，以单例模式提供对应用本地数据库的访问。
class AppDatabase {
  static final AppDatabase _instance = AppDatabase._();
  factory AppDatabase() => _instance;
  AppDatabase._();

  /// Schema version this build expects. Kept as a named constant because the
  /// upgrade path is chosen by comparing against it, and a literal in two places
  /// is a literal that can disagree with itself.
  /// 本构建期望的表结构版本。写成具名常量，因为升级路径靠与它比较来选取，而写在两处的
  /// 字面量是可能自相矛盾的字面量。
  static const int schemaVersion = 5;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'neko_mux.db');

    return openDatabase(
      path,
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// v1 schema: credentials, hosts, snippets, settings tables.
  /// v2 added `tb_settings` for installs that predated it.
  /// v3 adds `tb_known_hosts` so accepted host keys survive a restart.
  /// v5 adds `tb_hosts.jump_host_id`, so a host can be reached through a bastion.
  ///
  /// v5 新增 `tb_hosts.jump_host_id`，使主机可以经由堡垒机访问。
  ///
  /// v4 adds `tb_hosts.group_name` so hosts can be grouped by role or
  /// environment.
  /// v1 表结构：凭据表、主机表、快捷指令表、设置表。
  /// v2 为早期安装补上 `tb_settings`。
  /// v3 新增 `tb_known_hosts`，让已接受的主机密钥能跨重启留存。
  /// v4 新增 `tb_hosts.group_name`，让主机可以按角色或环境分组。
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tb_credentials (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        auth_type INTEGER NOT NULL DEFAULT 0,
        username TEXT NOT NULL,
        secret_data TEXT NOT NULL
      )
    ''');

    // `group_name` is nullable and has no default on purpose: that is both what
    // "ungrouped" means and the one column shape SQLite can add to an existing
    // table without rewriting it (see [_addColumnIfMissing]).
    // `group_name` 可为空且没有默认值，这是刻意的：它既是「未分组」的含义，也是
    // SQLite 唯一能在不重写整表的前提下为已有表添加的列形态（见 [_addColumnIfMissing]）。
    await db.execute('''
      CREATE TABLE tb_hosts (
        id TEXT PRIMARY KEY,
        alias TEXT NOT NULL,
        ip_address TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        credential_id TEXT NOT NULL,
        os_type INTEGER NOT NULL DEFAULT 0,
        group_name TEXT,
        -- Another host to reach this one through, or NULL for a direct
        -- connection. Deliberately not a foreign key: deleting the bastion
        -- must not delete or block the hosts behind it, and a dangling id is
        -- handled where it is used (the host simply dials directly and says so).
        jump_host_id TEXT,
        FOREIGN KEY (credential_id) REFERENCES tb_credentials(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE tb_snippets (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        command TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE tb_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await _createKnownHosts(db);
  }

  /// Host keys the user has accepted, keyed by "address:port".
  /// 用户已接受的主机密钥，以 "地址:端口" 为键。
  ///
  /// Keyed by host rather than by fingerprint so that a key which *changes* for
  /// a host we already know can be told apart from a host seen for the first
  /// time. The fingerprint-only in-memory cache this replaces could not make
  /// that distinction, and lost everything on restart.
  /// 以主机而非指纹为键，这样「已知主机的密钥发生变化」才能与「首次见到该主机」
  /// 区分开。被取代的内存指纹缓存做不到这点，且重启即丢。
  Future<void> _createKnownHosts(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tb_known_hosts (
        host TEXT PRIMARY KEY,
        key_type TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        trusted_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    await migrate(db, oldVersion, newVersion);
  }

  /// Applies every migration needed to take [db] from [oldVersion] to
  /// [AppDatabase.schemaVersion].
  /// 应用把 [db] 从 [oldVersion] 带到 [AppDatabase.schemaVersion] 所需的全部迁移。
  ///
  /// Public — and separated from the [_onUpgrade] tear-off that feeds it to
  /// `openDatabase` — because this code runs exactly once per install, on the
  /// user's own unrepeatable data. A test can drive it against a database
  /// stand-in; the alternative is finding out whether it works on a phone
  /// that has already run it.
  /// 之所以公开——并与把它交给 `openDatabase` 的 [_onUpgrade] 分离——是因为这段代码
  /// 每次安装只运行一次，且作用于用户自己不可再生的数据。测试可以拿数据库替身驱动它；
  /// 否则只能在一台已经跑过它的手机上才知道它到底有没有用。
  ///
  /// Nothing here ever removes anything: the earlier steps are
  /// `CREATE TABLE IF NOT EXISTS`, and the v4 step only adds a column. That is
  /// what makes an upgrade safe to run over hosts the user cannot recreate.
  /// 这里从不删除任何东西：早期步骤是 `CREATE TABLE IF NOT EXISTS`，v4 步骤只添加
  /// 一列。正因如此，对用户无法重建的主机数据执行升级才是安全的。
  Future<void> migrate(
    DatabaseExecutor db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS tb_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      await _createKnownHosts(db);
    }
    // v4: `tb_hosts.group_name`, for hosts the user groups by role or
    // environment. Existing rows read NULL, which the model renders as "no
    // group" — the honest description of a host that has never been grouped.
    // v4：`tb_hosts.group_name`，供用户按角色或环境分组。已有行读到 NULL，模型将其
    // 呈现为「未分组」——这正是对从未被分组过的主机最诚实的描述。
    if (oldVersion < 4) {
      await _addColumnIfMissing(db, table: 'tb_hosts', column: 'group_name');
    }
    // v5: `tb_hosts.jump_host_id`, for hosts reached through a bastion. Existing
    // rows read NULL, which means "dialled directly" — true of every host that
    // existed before this column did.
    // v5：`tb_hosts.jump_host_id`，用于经堡垒机访问的主机。已有行读到 NULL，即「直连」
    // ——这对本列出现之前的每一台主机都成立。
    if (oldVersion < 5) {
      await _addColumnIfMissing(db, table: 'tb_hosts', column: 'jump_host_id');
    }
  }

  /// Adds `group_name TEXT` to [table] unless the column is already there.
  /// 除非 [table] 已有该列，否则为它添加 `group_name TEXT`。
  ///
  /// `ALTER TABLE ... ADD COLUMN` is the one schema change SQLite performs
  /// without rewriting the table — and therefore the one that cannot lose a
  /// user's hosts. It appends the column to the table's stored definition and
  /// touches no row: every existing row simply reads NULL for it. (The fast
  /// path requires exactly what this column is: nullable, no default, no
  /// UNIQUE/PRIMARY KEY.)
  /// `ALTER TABLE ... ADD COLUMN` 是 SQLite 唯一不重写整表就能完成的表结构变更，因此
  /// 也是唯一不可能让用户的主机丢失的一种。它把该列追加到表的存储定义上，不触碰任何
  /// 行：所有已有行读到的都是 NULL。（这条快路径要求的正是本列的形态：可空、无默认值、
  /// 非 UNIQUE/PRIMARY KEY。）
  ///
  /// Why the check, when sqflite already makes the upgrade atomic? Because the
  /// two failure modes are priced differently. sqflite runs `onUpgrade` and the
  /// `PRAGMA user_version` bump in one exclusive transaction, so an interrupted
  /// upgrade rolls back whole and reruns — this check is not what protects that
  /// case. It protects the cases the transaction does *not* cover: a database
  /// copied or restored between builds, a hand-edited file whose `user_version`
  /// disagrees with its schema, or a bug in a future migration that leaves the
  /// column behind. Without the check each of those throws "duplicate column
  /// name" from inside `openDatabase`, and the app cannot open its database at
  /// all — no host list, not even the settings page to restore a backup. With
  /// it, the migration is simply already done. The price is one `PRAGMA`
  /// read on a path that runs once per install, which is why this is worth
  /// paying; SQLite has no `ADD COLUMN IF NOT EXISTS`, so the read is the only
  /// way to ask.
  /// 为什么已经有 sqflite 的事务保证还要做这个检查？因为两种失败模式的代价不对等。
  /// sqflite 把 `onUpgrade` 与 `PRAGMA user_version` 的写入放在同一个独占事务里，因此
  /// 中途中断的升级会整体回滚并重新执行——本检查保护的并不是这种情况，而是事务**覆盖
  /// 不到**的情况：在不同构建之间拷贝或恢复的数据库、被手工编辑过因而 `user_version`
  /// 与表结构不一致的文件，或未来某次迁移留下的半成品。没有本检查时，这些情况都会在
  /// `openDatabase` 内部抛出「duplicate column name」，应用将完全无法打开数据库——
  /// 没有主机列表，连用来恢复备份的设置页都进不去。有了它，迁移只是「已经完成」而已。
  /// 代价是在每条安装只走一次的路径上多读一次 `PRAGMA`，因此值得；SQLite 没有
  /// `ADD COLUMN IF NOT EXISTS`，这次读取是唯一的问法。
  static Future<void> _addColumnIfMissing(
    DatabaseExecutor db, {
    required String table,
    required String column,
  }) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final alreadyThere = columns.any((row) => row['name'] == column);
    if (alreadyThere) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column TEXT');
  }
}
