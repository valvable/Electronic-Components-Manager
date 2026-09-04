import 'package:sqflite/sqflite.dart';

import '../../models/bom.dart';

/// BOM 仓储：单据与明细读写。
/// 删除 BOM 依赖 bom_items.bom_id 的 ON DELETE CASCADE 级联清条目（不留孤儿）；
/// 组件被彻底删除时受 component_id 的 ON DELETE RESTRICT 保护。
class BomRepository {
  final Database db;
  BomRepository(this.db);

  /// 整单保存/替换（事务）：存在 [bomId] 则更新名称并整单替换明细，
  /// 否则新建单据。返回 bomId。
  Future<int> saveBom(String name, List<BomItem> items, {int? bomId}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return db.transaction((txn) async {
      final int id;
      if (bomId != null) {
        await txn.update('boms', {'name': name}, where: 'id = ?', whereArgs: [bomId]);
        id = bomId;
      } else {
        id = await txn.insert('boms', {'name': name, 'created_at': now});
      }
      await txn.delete('bom_items', where: 'bom_id = ?', whereArgs: [id]);
      for (final it in items) {
        await txn.insert('bom_items', it.toMap()..remove('id')..['bom_id'] = id);
      }
      return id;
    });
  }

  Future<List<Bom>> listBoms() async {
    final rows = await db.query('boms', orderBy: 'created_at DESC');
    return rows.map(Bom.fromMap).toList();
  }

  Future<List<BomItem>> itemsForBom(int bomId) async {
    final rows = await db.query(
      'bom_items',
      where: 'bom_id = ?',
      whereArgs: [bomId],
    );
    return rows.map(BomItem.fromMap).toList();
  }

  /// 删除 BOM（事务）：bom_items 经 ON DELETE CASCADE 级联清理。
  Future<void> deleteBom(int id) async {
    await db.delete('boms', where: 'id = ?', whereArgs: [id]);
  }

  // ---- 同步助手 ----

  /// 按 名称+创建时间 查找 BOM（同步去重键），找不到返回 null。
  Future<int?> findBomByKey(String name, int createdAt) async {
    final rows = await db.query(
      'boms',
      where: 'name = ? AND created_at = ?',
      whereArgs: [name, createdAt],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  /// 插入 BOM，返回新 id。
  Future<int> insertBom(String name, int createdAt) async {
    return db.insert('boms', {'name': name, 'created_at': createdAt});
  }

  /// 明细去重插入：同 (bom_id, component_id, quantity) 已存在则跳过。
  Future<void> insertBomItemIfAbsent(int bomId, int componentId, int quantity) async {
    final rows = await db.query(
      'bom_items',
      where: 'bom_id = ? AND component_id = ? AND quantity = ?',
      whereArgs: [bomId, componentId, quantity],
      limit: 1,
    );
    if (rows.isEmpty) {
      await db.insert('bom_items', {
        'bom_id': bomId,
        'component_id': componentId,
        'quantity': quantity,
      });
    }
  }
}