/// 元件数据模型，对应数据库 `components` 表。
///
/// 字段说明：
/// - [cid]      立创商城料号（如 C25704）
/// - [model]    型号（如 STM32F103C8T6）
/// - [category] 分类（电阻/电容/IC/二极管/三极管/连接器/晶振/其他）
/// - [package]  封装（如 0805、SOP-8）。注意：`package` 不是 Dart 保留字，可直接用作字段名
/// - [quantity] 库存数量
/// - [location] 存放位置（如 元件柜 A-3）
/// - [note]     备注
/// - [createdAt]/[updatedAt] ISO8601 格式时间字符串
class Component {
  final int? id;
  final String cid;
  final String model;
  final String category;
  final String? package;
  final int quantity;
  final String? location;
  final String? note;
  final String createdAt;
  final String updatedAt;

  const Component({
    this.id,
    required this.cid,
    required this.model,
    required this.category,
    this.package,
    this.quantity = 1,
    this.location,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 从数据库查询结果构造模型（对空值做了兜底，避免脏数据导致崩溃）。
  factory Component.fromMap(Map<String, Object?> map) {
    return Component(
      id: map['id'] as int?,
      cid: (map['cid'] as String?) ?? '',
      model: (map['model'] as String?) ?? '',
      category: (map['category'] as String?) ?? '其他',
      package: map['package'] as String?,
      quantity: (map['quantity'] as int?) ?? 0,
      location: map['location'] as String?,
      note: map['note'] as String?,
      createdAt: (map['created_at'] as String?) ?? '',
      updatedAt: (map['updated_at'] as String?) ?? '',
    );
  }

  /// 转为数据库插入/更新用的 Map。
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'cid': cid,
      'model': model,
      'category': category,
      'package': package,
      'quantity': quantity,
      'location': location,
      'note': note,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  /// 复制并按需覆盖部分字段（编辑保存时使用）。
  Component copyWith({
    int? id,
    String? cid,
    String? model,
    String? category,
    String? package,
    int? quantity,
    String? location,
    String? note,
    String? createdAt,
    String? updatedAt,
  }) {
    return Component(
      id: id ?? this.id,
      cid: cid ?? this.cid,
      model: model ?? this.model,
      category: category ?? this.category,
      package: package ?? this.package,
      quantity: quantity ?? this.quantity,
      location: location ?? this.location,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 是否缺货（数量为 0）。
  bool get isOutOfStock => quantity <= 0;

  /// 是否低库存（1~10 个），用于列表数量标橙提醒。
  bool get isLowStock => quantity > 0 && quantity <= 10;
}
