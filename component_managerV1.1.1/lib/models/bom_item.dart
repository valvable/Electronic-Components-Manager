/// BOM 明细模型，对应数据库 `bom_items` 表。
///
/// 第二阶段 BOM 导入功能使用：记录 BOM 中某个元件的需求数量，
/// [componentId] 关联 `components.id`；若 BOM 中元件库存里没有，则为 null（待采购）。
class BomItem {
  final int? id;
  final int bomId; // 所属 BOM 的 id（boms.id）
  final int? componentId; // 关联的元件 id（components.id），库存中没有该元件时为 null
  final int quantity; // BOM 需求数量

  const BomItem({
    this.id,
    required this.bomId,
    this.componentId,
    required this.quantity,
  });

  factory BomItem.fromMap(Map<String, Object?> map) {
    return BomItem(
      id: map['id'] as int?,
      bomId: (map['bom_id'] as int?) ?? 0,
      componentId: map['component_id'] as int?,
      quantity: (map['quantity'] as int?) ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'bom_id': bomId,
      'component_id': componentId,
      'quantity': quantity,
    };
  }
}
