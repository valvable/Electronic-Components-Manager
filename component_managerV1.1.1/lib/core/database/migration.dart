import 'package:sqflite/sqflite.dart';

/// 建表与迁移。
///
/// 当前 schema（v4）四张表：
/// - components：含软删字段 [deleted_at]（null=未删，非 null=删除时间戳）
///   与 brand（品牌，v4 起，可空——同型号不同品牌各自一行，外层列表聚合总量）
/// - boms：BOM 单据
/// - bom_items：bom_id 外键 ON DELETE CASCADE（删 BOM 级联清条目，不留孤儿）；\n///   component_id 外键 ON DELETE RESTRICT（保护被 BOM 引用的组件）
/// - settings：全局 key-value（主题模式、AI 配置等）
///
/// 迁移策略：bump [migrationVersion] 并在 [onUpgrade] 加 `if (oldV < N)` 逐级步骤，
/// 已上架的版本绝不改写 onCreate。
Future<void> onCreate(Database db, int version) async {
  await db.execute('''
    CREATE TABLE components(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      cid TEXT UNIQUE NOT NULL,
      model TEXT NOT NULL,
      category TEXT NOT NULL,
      package TEXT,
      brand TEXT,
      quantity INTEGER NOT NULL DEFAULT 0,
      location TEXT,
      note TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      deleted_at INTEGER
    )
  ''');
  await db.execute('CREATE INDEX idx_components_cid ON components(cid)');
  await db.execute(
      'CREATE INDEX idx_components_updated ON components(updated_at)');
  await db.execute('CREATE INDEX idx_components_deleted ON components(deleted_at)');

  await db.execute('''
    CREATE TABLE boms(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE bom_items(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      bom_id INTEGER NOT NULL REFERENCES boms(id) ON DELETE CASCADE,
      component_id INTEGER NOT NULL REFERENCES components(id) ON DELETE RESTRICT,
      quantity INTEGER NOT NULL
    )
  ''');
  await db.execute('CREATE INDEX idx_bom_items_bom ON bom_items(bom_id)');

  // v3：全局设置 key-value（主题模式、AI 配置等跨设备持久化项）。
  await db.execute('''
    CREATE TABLE settings(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
}

/// 版本升级：逐级迁移模板。
///
/// v2：v1 时代曾原地修改 onCreate（新增 deleted_at）而未 bump 版本，导致部分已存在
/// 的库结构仍是 v1 旧版、缺少 deleted_at 列。迁移用 `PRAGMA table_info` 防御式补列，
/// 对结构已完整（后来才建）的库安全跳过。
Future<void> onUpgrade(Database db, int oldVersion, int newVersion) async {
  if (oldVersion < 2) {
    final cols = await db.rawQuery('PRAGMA table_info(components)');
    final names = cols.map((c) => c['name']).toSet();
    if (!names.contains('deleted_at')) {
      await db.execute('ALTER TABLE components ADD COLUMN deleted_at INTEGER');
    }
    final idxs = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='components'");
    final idxNames = idxs.map((r) => r['name']).toSet();
    if (!idxNames.contains('idx_components_deleted')) {
      await db.execute(
          'CREATE INDEX idx_components_deleted ON components(deleted_at)');
    }
  }
  // v3：settings 表（主题、AI 配置等全局 key-value）。
  if (oldVersion < 3) {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }
  // v4：components 加 brand 列（防御式补列，同 v2 手法——已含该列的库安全跳过）。
  if (oldVersion < 4) {
    final cols = await db.rawQuery('PRAGMA table_info(components)');
    final names = cols.map((c) => c['name']).toSet();
    if (!names.contains('brand')) {
      await db.execute('ALTER TABLE components ADD COLUMN brand TEXT');
    }
  }
}