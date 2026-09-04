import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/bom_repository.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 同步落库层（syncUpsert / BOM 同步助手）与真实 SQLite 的行为契约。
void main() {
  late Database db;
  late ComponentRepository components;
  late BomRepository boms;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await AppDatabase.openAt(inMemoryDatabasePath);
    components = ComponentRepository(db);
    boms = BomRepository(db);
  });

  tearDown(() => db.close());

  Component remote({required String cid, int qty = 1, int updatedAt = 1000}) =>
      Component(
        cid: cid,
        model: 'R-模型',
        category: '其他',
        quantity: qty,
        createdAt: 900,
        updatedAt: updatedAt,
        deletedAt: null,
      );

  group('syncUpsert', () {
    test('不存在则插入，保留远端时间戳', () async {
      await components.syncUpsert(remote(cid: 'C001', qty: 5, updatedAt: 1000));

      final lookup = await components.byCid('C001');
      expect(lookup.status, LookupStatus.active);
      expect(lookup.component!.quantity, 5);
      expect(lookup.component!.createdAt, 900);
      expect(lookup.component!.updatedAt, 1000);
      expect(lookup.component!.model, 'R-模型');
    });

    test('已存在则按 cid 覆盖字段，created_at 保留最早', () async {
      final local = await components.insert(
        Component(
          cid: 'C001',
          model: '本机型号',
          category: '电阻',
          quantity: 2,
          createdAt: Component.now(),
          updatedAt: Component.now(),
        ),
      );
      expect(local, greaterThan(0));

      // 远端同步版本：created_at 更早（远端时钟），应保留远端更早的创建时间。
      await components.syncUpsert(remote(cid: 'C001', qty: 5, updatedAt: 1000));

      final lookup = await components.byCid('C001');
      expect(lookup.status, LookupStatus.active);
      final got = lookup.component!;
      expect(got.quantity, 5);
      expect(got.model, 'R-模型');
      expect(got.createdAt, 900); // min(本机, 远端)
      expect(got.updatedAt, 1000);
      expect(got.id, isNotNull);
    });

    test('墓碑整体覆盖（删除传播）', () async {
      await components.syncUpsert(remote(cid: 'C001'));
      await components.syncUpsert(
        remote(cid: 'C001').copyWith(
          updatedAt: 2000,
          deletedAt: 2000,
        ),
      );

      final lookup = await components.byCid('C001');
      expect(lookup.status, LookupStatus.deleted);
    });
  });

  group('BOM 同步助手', () {
    test('findBomByKey / insertBom / 明细去重', () async {
      expect(await boms.findBomByKey('主板', 100), isNull);

      final id = await boms.insertBom('主板', 100);
      expect(id, greaterThan(0));
      expect(await boms.findBomByKey('主板', 100), id);

      // 不同创建时间的同名 BOM 是不同单据
      final id2 = await boms.insertBom('主板', 200);
      expect(await boms.findBomByKey('主板', 200), id2);

      // 明细去重插入
      final cid = (await components.insert(
            Component(
              cid: 'C009',
              model: 'M',
              category: '其他',
              createdAt: 1,
              updatedAt: 1,
            ),
          ));
      await boms.insertBomItemIfAbsent(id, cid, 3);
      await boms.insertBomItemIfAbsent(id, cid, 3); // 重复 → 跳过
      await boms.insertBomItemIfAbsent(id, cid, 4); // 数量不同 → 插入

      final items = await boms.itemsForBom(id);
      expect(items, hasLength(2));
      expect(items.map((i) => i.quantity).toSet(), {3, 4});
    });
  });
}
