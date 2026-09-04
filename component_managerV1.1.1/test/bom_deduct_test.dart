import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// BOM 扣库存：按 id 扣减、下限 0、跳过已删/不存在/扣无可扣，刷新 updated_at。
void main() {
  late ComponentRepository repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final db = await AppDatabase.openAt(inMemoryDatabasePath);
    repo = ComponentRepository(db);
    addTearDown(db.close);
  });

  test('deductForBom：正常扣减 + 下限 0 + 不动已删行', () async {
    final a = await repo.insert(Component(
        cid: 'C100001', model: 'A', category: '电阻',
        quantity: 100, createdAt: Component.now(), updatedAt: Component.now()));
    final b = await repo.insert(Component(
        cid: 'C100002', model: 'B', category: '电阻',
        quantity: 3, createdAt: Component.now(), updatedAt: Component.now()));
    final d = await repo.insert(Component(
        cid: 'C100003', model: 'D', category: '电阻',
        quantity: 50, createdAt: Component.now(), updatedAt: Component.now()));
    await repo.delete(d); // 已删行不参与扣减

    final changed = await repo.deductForBom({
      a: 40, // 100 → 60
      b: 10, // 3 → 0（下限）
      d: 5, // 已删跳过
      999: 1, // 不存在跳过
    });
    expect(changed, 2);
    expect((await repo.byCid('C100001')).component!.quantity, 60);
    expect((await repo.byCid('C100002')).component!.quantity, 0);
    expect((await repo.byCid('C100003')).component!.quantity, 50); // 未动
  });

  test('扣满/非正数不产生变更行', () async {
    final a = await repo.insert(Component(
        cid: 'C100004', model: 'E', category: '电阻',
        quantity: 7, createdAt: Component.now(), updatedAt: Component.now()));
    final before = (await repo.byCid('C100004')).component!;
    final changed = await repo.deductForBom({a: 0, 999: -5});
    expect(changed, 0);
    expect((await repo.byCid('C100004')).component!.quantity, before.quantity);
  });
}

