/// BOM 单据与明细模型。
library;

class Bom {
  final int? id;
  final String name;
  final int createdAt; // epoch 秒

  const Bom({this.id, required this.name, required this.createdAt});

  factory Bom.fromMap(Map<String, Object?> m) => Bom(
        id: m['id'] as int?,
        name: m['name'] as String,
        createdAt: (m['created_at'] as int?) ?? 0,
      );

  Map<String, Object?> toMap() => {'id': id, 'name': name, 'created_at': createdAt};

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'created_at': createdAt};

  factory Bom.fromJson(Map<String, dynamic> m) => Bom(
        id: m['id'] as int?,
        name: m['name'] as String,
        createdAt: (m['created_at'] as int?) ?? 0,
      );
}

class BomItem {
  final int? id;
  final int bomId;
  final int componentId;
  final int quantity;

  const BomItem({
    this.id,
    required this.bomId,
    required this.componentId,
    required this.quantity,
  });

  factory BomItem.fromMap(Map<String, Object?> m) => BomItem(
        id: m['id'] as int?,
        bomId: (m['bom_id'] as int?) ?? 0,
        componentId: (m['component_id'] as int?) ?? 0,
        quantity: (m['quantity'] as int?) ?? 0,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'bom_id': bomId,
        'component_id': componentId,
        'quantity': quantity,
      };

  Map<String, dynamic> toJson() =>
      {'id': id, 'bom_id': bomId, 'component_id': componentId, 'quantity': quantity};

  factory BomItem.fromJson(Map<String, dynamic> m) => BomItem(
        id: m['id'] as int?,
        bomId: (m['bom_id'] as int?) ?? 0,
        componentId: (m['component_id'] as int?) ?? 0,
        quantity: (m['quantity'] as int?) ?? 0,
      );
}