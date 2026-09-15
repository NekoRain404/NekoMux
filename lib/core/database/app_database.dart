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
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// v1 schema: credentials, hosts, snippets, settings tables.
  /// v1 表结构：凭据表、主机表、快捷指令表、设置表。
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
  }
}
