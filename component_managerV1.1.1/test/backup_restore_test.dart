import 'dart:io';

import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/bom_repository.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/core/services/export_service.dart';
import 'package:component_manager/models/bom.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 备份（buildBackupJson）与恢复（restoreBackupJson）往返契约。
/// 注意：两个库要用不同文件路径——sqflite 按路径缓存，':memory:' 会撞成同一个。
void main() {
  late Database db1;
  late Database db2;
  late Directory tmp;
  late ComponentRepository comp1;
  late BomRepository bom1;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cmp_backup_test');
    db1 = await AppDatabase.openAt(p.join(tmp.path, 'a.db'));
    db2 = await AppDatabase.openAt(p.join(tmp.path, 'b.db'));
    comp1 = ComponentRepository(db1);
    bom1 = BomRepository(db1);
  });

  tearDown(() async {
    await db1.close();
    await db2.close();
    await tmp.delete(recursive: true);
  });

  test('往返恢复：含已删墓碑与时间戳，明细 id 重映射到新库', () async {
    // 源库：活动元件（带位置/备注/时间戳）+ 已删元件（墓碑）+ BOM 明细
    final cid1 = await comp1.insert(Component(
      cid: 'C001',
      model: 'STM32F103C8T6',
      category: '单片机',
      quantity: 10,
      location: 'A3',
      note: '主力芯片',
      createdAt: 1000,
      updatedAt: 1500,
    ));
    await comp1.syncUpsert(Component(
      cid: 'C002',
      model: '旧料',
      category: '其他',
      quantity: 2,
      createdAt: 500,
      updatedAt: 900,
      deletedAt: 900,
    ));
    await bom1.saveBom('主板V1', [
      BomItem(bomId: 0, componentId: cid1, quantity: 3),
    ]);
    final realBom = (await bom1.listBoms()).single;

    final json = await buildBackupJson(components: comp1, boms: bom1);

    // 恢复到空库 db2
    final n = await restoreBackupJson(
      jsonText: json,
      components: ComponentRepository(db2),
      boms: BomRepository(db2),
    );
    expect(n, 2);

    // 记录源库实际存储值（insert() 会把新建元件时间戳刷新为 now，非传入的 1000）
    final src1 = (await comp1.byCid('C001')).component!;
    expect(src1.createdAt, isNot(1000));

    final comp2 = ComponentRepository(db2);
    final bom2 = BomRepository(db2);

    final lookup1 = await comp2.byCid('C001');
    expect(lookup1.status, LookupStatus.active);
    expect(lookup1.component!.model, 'STM32F103C8T6');
    expect(lookup1.component!.quantity, 10);
    expect(lookup1.component!.location, 'A3');
    expect(lookup1.component!.note, '主力芯片');
    expect(lookup1.component!.createdAt, src1.createdAt); // 时间戳逐位保留
    expect(lookup1.component!.updatedAt, src1.updatedAt);

    final lookup2 = await comp2.byCid('C002');
    expect(lookup2.status, LookupStatus.deleted); // 墓碑恢复
    expect(lookup2.component!.deletedAt, 900);

    final boms = await bom2.listBoms();
    expect(boms, hasLength(1));
    expect(boms.single.name, '主板V1');
    expect(boms.single.createdAt, realBom.createdAt);
    final items = await bom2.itemsForBom(boms.single.id!);
    expect(items, hasLength(1));
    expect(items.single.quantity, 3);
    // 明细 id 已重映射到新库的 C001
    final rows = await db2.query('components',
        where: 'id = ?', whereArgs: [items.single.componentId]);
    expect(rows.single['cid'], 'C001');
  });

  test('非法 JSON / schema 不匹配 → FormatException 且不破坏原库', () async {
    await comp1.syncUpsert(Component(
      cid: 'C001', model: 'M', category: '其他', quantity: 1,
      createdAt: 1, updatedAt: 1,
    ));

    await expectLater(
        restoreBackupJson(jsonText: 'not json', components: comp1, boms: bom1),
        throwsFormatException);
    await expectLater(
        restoreBackupJson(
            jsonText: '{"schema": 99, "components": []}',
            components: comp1,
            boms: bom1),
        throwsFormatException);

    // 两次失败后原库数据仍在
    expect((await comp1.all()).length, 1);
  });

  test('恢复是覆盖语义：多余旧数据被清掉', () async {
    await comp1.syncUpsert(Component(
      cid: 'OLD', model: 'M', category: '其他', quantity: 1,
      createdAt: 1, updatedAt: 1,
    ));
    const manual =
        '{"schema": 1, "components": [{"id": 1, "cid": "C001", "model": "M", '
        '"category": "其他", "quantity": 5, "created_at": 1, "updated_at": 2, '
        '"deleted_at": null}], "boms": [], "bom_items": []}';
    await restoreBackupJson(jsonText: manual, components: comp1, boms: bom1);

    final all = await comp1.all(includeDeleted: true);
    expect(all, hasLength(1));
    expect(all.single.cid, 'C001');
  });
}
