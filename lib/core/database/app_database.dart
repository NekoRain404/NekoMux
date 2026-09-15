import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// SQLite database manager providing singleton access to the app's local database.
/// SQLite 数据库管理器，以单例模式提供对应用本地数据库的访问。
class AppDatabase {
  static final AppDatabase _instance = AppDatabase._();
  factory AppDatabase() => _instance;
  AppDatabase._();

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
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// v1 schema: credentials, hosts, snippets, settings tables.
  /// v2 added `tb_settings` for installs that predated it.
  /// v3 adds `tb_known_hosts` so accepted host keys survive a restart.
  /// v1 表结构：凭据表、主机表、快捷指令表、设置表。
  /// v2 为早期安装补上 `tb_settings`。
  /// v3 新增 `tb_known_hosts`，让已接受的主机密钥能跨重启留存。
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

    await db.execute('''
      CREATE TABLE tb_hosts (
        id TEXT PRIMARY KEY,
        alias TEXT NOT NULL,
        ip_address TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        credential_id TEXT NOT NULL,
        os_type INTEGER NOT NULL DEFAULT 0,
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
  Future<void> _createKnownHosts(Database db) async {
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
  }
}
