import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/bom_repository.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/models/bom.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 仓储集成测试（sqflite_common_ffi 内存库，任意主机可跑）。
/// 注意（用户审查 #1）：库连接一律来自 [AppDatabase.openAt]，复用生产同一套
/// onCreate 建表 SQL 与 PRAGMA foreign_keys=ON，保证 RESTRICT/CASCADE 真实生效；
/// 绝不在测试里手写建表语句。
/// 测试隔离（用户审查 #7）：每个测试新建内存库、tearDown 关闭。
void main() {
  late Database db;
  late ComponentRepository repo;
  late BomRepository bomRepo;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await AppDatabase.openAt(inMemoryDatabasePath);
    repo = ComponentRepository(db);
    bomRepo = BomRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Component comp({
    String cid = 'C10001',
    String model = 'RES-0805-10K',
    int qty = 10,
    String category = '电阻',
  }) {
    final now = Component.now();
    return Component(
      cid: cid,
      model: model,
      category: category,
      quantity: qty,
      createdAt: now,
      updatedAt: now,
    );
  }

  group('CRUD 与三态 byCid', () {
    test('insert 后 byCid 返回 active', () async {
      final id = await repo.insert(comp());
      expect(id, greaterThan(0));
      final lookup = await repo.byCid('C10001');
      expect(lookup.status, LookupStatus.active);
      expect(lookup.component!.quantity, 10);
    });

    test('重复 cid 插入被 UNIQUE 拒绝', () async {
      await repo.insert(comp());
      await expectLater(
        repo.insert(comp()),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('不存在的 cid 返回 notFound', () async {
      final lookup = await repo.byCid('C99999');
      expect(lookup.status, LookupStatus.notFound);
      expect(lookup.component, isNull);
    });

    test('update 保留 created_at 并刷新 quantity', () async {
      await repo.insert(comp());
      final saved = (await repo.byCid('C10001')).component!;
      await repo.update(saved.copyWith(quantity: 25));
      final updated = (await repo.byCid('C10001')).component!;
      expect(updated.quantity, 25);
      expect(updated.createdAt, saved.createdAt);
      expect(updated.updatedAt, greaterThanOrEqualTo(saved.updatedAt));
    });

    test('delete 后 all() 不含、byCid 返回 deleted', () async {
      final id = await repo.insert(comp());
      await repo.delete(id);
      final lookup = await repo.byCid('C10001');
      expect(lookup.status, LookupStatus.deleted);
      final list = await repo.all();
      expect(list, isEmpty);
      final withDeleted = await repo.all(includeDeleted: true);
      expect(withDeleted.single.isDeleted, isTrue);
    });

    test('restore 后回到 active', () async {
      final id = await repo.insert(comp());
      await repo.delete(id);
      await repo.restore(id);
      expect((await repo.byCid('C10001')).status, LookupStatus.active);
      expect((await repo.all()).length, 1);
    });
  });

  group('insertOrAddQty（扫码累加）', () {
    test('不存在时 INSERT', () async {
      final c = await repo.insertOrAddQty('C50001', add: 1);
      expect(c.quantity, 1);
      expect((await repo.byCid('C50001')).status, LookupStatus.active);
    });

    test('未删时数量累加', () async {
      await repo.insert(comp(qty: 10));
      await repo.insertOrAddQty('C10001', add: 5);
      expect((await repo.byCid('C10001')).component!.quantity, 15);
    });

    test('已删时自动恢复并累加', () async {
      final id = await repo.insert(comp(qty: 10));
      await repo.delete(id);
      await repo.insertOrAddQty('C10001', add: 5);
      final lookup = await repo.byCid('C10001');
      expect(lookup.status, LookupStatus.active); // 已自动恢复
      expect(lookup.component!.quantity, 15);
      expect((await repo.all()).length, 1);
    });
  });

  group('purge 双保险（RESTRICT 保护，用户审查 #10）', () {
    test('未被 BOM 引用的组件可彻底删除', () async {
      final id = await repo.insert(comp());
      await repo.purge(id);
      expect((await repo.byCid('C10001')).status, LookupStatus.notFound);
    });

    test('被 BOM 引用时前置检查拒绝并抛业务异常', () async {
      final id = await repo.insert(comp());
      final bomId = await bomRepo.saveBom('测试BOM',
          [BomItem(bomId: 0, componentId: id, quantity: 2)]);
      expect(bomId, greaterThan(0));
      expect(
        () => repo.purge(id),
        throwsA(isA<ComponentDeletionException>()),
      );
      // 元件仍在库中（RESTRICT 兜底，即使跳过前置检查也删不掉）
      expect((await repo.byCid('C10001')).status, LookupStatus.active);
    });
  });

  group('分类筛选 + 排序 + 全部哨兵（用户审查 #6）', () {
    test('“全部”哨兵被忽略，返回全部', () async {
      await repo.insert(comp(cid: 'C1', category: '电阻'));
      await repo.insert(comp(cid: 'C2', model: 'CL-10uF', category: '电容', qty: 3));
      final list = await repo.all(category: '全部');
      expect(list.length, 2);
    });

    test('指定分类只返回该类元件', () async {
      await repo.insert(comp(cid: 'C1', category: '电阻'));
      await repo.insert(comp(cid: 'C2', model: 'CL-10uF', category: '电容', qty: 3));
      final list = await repo.all(category: '电容');
      expect(list.length, 1);
      expect(list.single.cid, 'C2');
    });

    test('排序：qty_asc 缺货优先 / qty_desc / created_desc', () async {
      await repo.insert(comp(cid: 'C1', qty: 0));
      await repo.insert(comp(cid: 'C2', qty: 50));
      await repo.insert(comp(cid: 'C3', qty: 10));
      final asc = await repo.all(sort: 'qty_asc');
      expect(asc.map((c) => c.cid).toList(), ['C1', 'C3', 'C2']);
      final desc = await repo.all(sort: 'qty_desc');
      expect(desc.first.cid, 'C2');
      final created = await repo.all(sort: 'created_desc');
      expect(created.first.cid, 'C3'); // 最新创建在前
    });
  });

  group('模糊搜索（LIKE + Levenshtein）', () {
    test('% / _ 特殊字符被转义，不匹配全表（用户审查 #4）', () async {
      await repo.insert(comp(cid: 'C1', model: 'RES-100K'));
      await repo.insert(comp(cid: 'C2', model: 'CAP-10uF'));
      // 搜 % 不会把所有记录都捞出来
      final list = await repo.search('%');
      expect(list, isEmpty);
      final underscore = await repo.search('_');
      expect(underscore, isEmpty);
    });

    test('LIKE 候选池 + Levenshtein 排序', () async {
      await repo.insert(comp(cid: 'C1', model: 'STM32F103C8'));
      await repo.insert(comp(cid: 'C2', model: 'STM32F103R8'));
      await repo.insert(comp(cid: 'C3', model: 'RES-0805'));
      final list = await repo.search('STM32F103');
      expect(list, isNotEmpty);
      expect(list.first.model, startsWith('STM32')); // 距离最小在前
    });

    test('CID 精确搜索', () async {
      await repo.insert(comp(cid: 'C2977076', model: 'XL-1608UPC-06'));
      final list = await repo.search('C2977076');
      expect(list.single.cid, 'C2977076');
    });

    test('countByCategory / quantitiesBelow', () async {
      await repo.insert(comp(cid: 'C1', qty: 0, category: '电阻'));
      await repo.insert(comp(cid: 'C2', qty: 5, category: '电阻'));
      await repo.insert(comp(cid: 'C3', qty: 100, category: '电容'));
      final counts = await repo.countByCategory();
      expect(counts['电阻'], 2);
      expect(counts['电容'], 1);
      final low = await repo.quantitiesBelow(10);
      expect(low.length, 2);
    });
  });
}