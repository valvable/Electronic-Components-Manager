import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/component.dart';

/// 数据库操作类（单例模式）。
///
/// 用法：`DatabaseHelper.instance.getAllComponents()`
///
/// 说明：
/// - Windows/Linux 桌面端 sqflite 官方实现不可用，
///   已在 `main.dart` 中按平台把全局 `databaseFactory` 切换为 FFI 实现；
/// - `cid` 不设 UNIQUE 约束：需求要求「CID 已存在时可选择合并或新增」，
///   因此允许同一 CID 存在多条记录（例如放在不同位置），
///   重复检测在应用层（保存对话框）中完成；
/// - 时间字段统一使用 ISO8601 字符串存储，便于排序与阅读。
class DatabaseHelper {
  // ---------- 单例 ----------
  DatabaseHelper._internal();

  static final DatabaseHelper _instance = DatabaseHelper._internal();

  factory DatabaseHelper() => _instance;

  static DatabaseHelper get instance => _instance;

  static const String _dbName = 'component_manager.db';
  static const int _dbVersion = 1;

  Database? _db;

  /// 懒加载数据库连接：首次访问时打开（不存在则建表）。
  Future<Database> get database async {
    _db ??= await _init();
    return _db!;
  }

  /// 打开数据库。文件存放在系统应用支持目录：
  /// - Windows: `%APPDATA%/<org>/<app>/component_manager.db`
  /// - Android: `/data/data/<包名>/files/.../component_manager.db`
  Future<Database> _init() async {
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 开启 SQLite 外键约束（bom_items -> boms/components）。
  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// 首次创建数据库：建三张表 + 常用索引。
  Future<void> _onCreate(Database db, int version) async {
    // 表 1：元件库存
    await db.execute('''
      CREATE TABLE components (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cid TEXT NOT NULL,
        model TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT '其他',
        package TEXT,
        quantity INTEGER NOT NULL DEFAULT 1,
        location TEXT,
        note TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    // 常用查询建立索引（cid 为普通索引，原因见类注释）
    await db.execute('CREATE INDEX idx_components_cid ON components(cid)');
    await db.execute('CREATE INDEX idx_components_model ON components(model)');
    await db.execute(
        'CREATE INDEX idx_components_category ON components(category)');

    // 表 2：BOM 清单（第二阶段 BOM 导入使用，提前建表）
    await db.execute('''
      CREATE TABLE boms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    // 表 3：BOM 明细
    await db.execute('''
      CREATE TABLE bom_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bom_id INTEGER NOT NULL,
        component_id INTEGER,
        quantity INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (bom_id) REFERENCES boms (id) ON DELETE CASCADE,
        FOREIGN KEY (component_id) REFERENCES components (id) ON DELETE SET NULL
      )
    ''');
  }

  /// 数据库版本升级迁移（预留）。
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 后续版本如需加列/改表，在此根据 oldVersion 编写迁移逻辑。
  }

  // ================ components 表 CRUD ================

  /// 查询全部元件（默认按 id 倒序，列表内的筛选/排序在 UI 层完成）。
  Future<List<Component>> getAllComponents() async {
    final db = await database;
    final rows = await db.query('components', orderBy: 'id DESC');
    return rows.map(Component.fromMap).toList();
  }

  /// 按 CID 精确查找元件（忽略大小写），找不到返回 null。
  Future<Component?> findByCid(String cid) async {
    final db = await database;
    final rows = await db.query(
      'components',
      where: 'cid = ? COLLATE NOCASE',
      whereArgs: [cid.trim()],
      limit: 1,
    );
    return rows.isEmpty ? null : Component.fromMap(rows.first);
  }

  /// 新增元件，返回新记录 id。
  Future<int> insertComponent(Component component) async {
    final db = await database;
    return db.insert('components', component.toMap());
  }

  /// 更新元件（按 id），返回受影响行数。
  Future<int> updateComponent(Component component) async {
    final db = await database;
    return db.update(
      'components',
      component.toMap(),
      where: 'id = ?',
      whereArgs: [component.id],
    );
  }

  /// 删除元件（按 id），返回受影响行数。
  Future<int> deleteComponent(int id) async {
    final db = await database;
    return db.delete('components', where: 'id = ?', whereArgs: [id]);
  }

  /// 合并数量：在现有库存基础上累加（CID 重复选择"合并"时使用）。
  Future<int> increaseQuantity(int id, int delta) async {
    final db = await database;
    return db.rawUpdate(
      'UPDATE components SET quantity = quantity + ?, updated_at = ? WHERE id = ?',
      [delta, DateTime.now().toIso8601String(), id],
    );
  }

  /// 关闭数据库连接（一般测试或退出时使用）。
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
