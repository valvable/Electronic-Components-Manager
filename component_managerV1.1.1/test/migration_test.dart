import 'dart:io';

import 'package:component_manager/core/config/constants.dart';
import 'package:component_manager/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 迁移契约：开发期曾在 onCreate 原地加 deleted_at 却未 bump 版本号，
/// 导致部分已存在的 v1 库缺少该列，当前版本打开即报
/// `no such column deleted_at`（真实线上事故）。v2 起 onUpgrade 防御式补列。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cmp_migration_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  /// 手工构建 v1 旧库：components 无 deleted_at 列、无 deleted 索引。
  Future<Database> openLegacyV1(String path) async {
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE components(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              cid TEXT UNIQUE NOT NULL,
              model TEXT NOT NULL,
              category TEXT NOT NULL,
              package TEXT,
              quantity INTEGER NOT NULL DEFAULT 0,
              location TEXT,
              note TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await db.execute('CREATE INDEX idx_components_cid ON components(cid)');
          await db.execute(
              'CREATE INDEX idx_components_updated ON components(updated_at)');
        },
      ),
    );
  }

  test('v1 旧库（缺 deleted_at）用当前版本打开：自动补列补索引且数据保留', () async {
    final dbPath = p.join(tmp.path, 'legacy.db');
    final raw = await openLegacyV1(dbPath);
    await raw.insert('components', {
      'cid': 'C001',
      'model': '旧型号',
      'category': '其他',
      'quantity': 5,
      'created_at': 1000,
      'updated_at': 1500,
    });
    expect(await raw.getVersion(), 1);
    await raw.close();

    // 用生产同款 openAt（migrationVersion=2 + onUpgrade）打开 → 触发 v1→v2 迁移
    final db = await AppDatabase.openAt(dbPath);
    expect(await db.getVersion(), migrationVersion); // v1 → v3 逐级迁移

    // 补上 deleted_at 列
    final cols = await db.rawQuery('PRAGMA table_info(components)');
    final names = cols.map((c) => c['name']).toSet();
    expect(names, contains('deleted_at'));

    // 补上索引
    final idxs = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='components'");
    final idxNames = idxs.map((r) => r['name']).toSet();
    expect(idxNames, contains('idx_components_deleted'));

    // 数据完好，deleted_at 为 NULL（未删）
    final rows = await db.query('components');
    expect(rows, hasLength(1));
    expect(rows.single['cid'], 'C001');
    expect(rows.single['deleted_at'], isNull);
    await db.close();
  });

  test('结构已完整（含 deleted_at）的 v1 库：v2 打开幂等跳过，无副作用', () async {
    final dbPath = p.join(tmp.path, 'complete.db');
    final raw = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE components(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              cid TEXT UNIQUE NOT NULL,
              model TEXT NOT NULL,
              category TEXT NOT NULL,
              package TEXT,
              quantity INTEGER NOT NULL DEFAULT 0,
              location TEXT,
              note TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              deleted_at INTEGER
            )
          ''');
          await db.execute('CREATE INDEX idx_components_cid ON components(cid)');
          await db.execute('CREATE INDEX idx_components_deleted ON components(deleted_at)');
        },
      ),
    );
    await raw.insert('components', {
      'cid': 'C002',
      'model': 'M',
      'category': '其他',
      'quantity': 1,
      'created_at': 1,
      'updated_at': 1,
    });
    await raw.close();

    final db = await AppDatabase.openAt(dbPath);
    final rows = await db.query('components');
    expect(rows, hasLength(1));
    expect(rows.single['cid'], 'C002');
    expect(rows.single['deleted_at'], isNull);
    await db.close();
  });
}
