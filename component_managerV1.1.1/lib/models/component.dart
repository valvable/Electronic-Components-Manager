/// 元件模型。
///
/// [deletedAt] 为软删除墓碑：null = 未删，非 null = 删除时间戳（秒）。
/// 删除同步到远端后，远端同样置墓碑，双方删除一致（不残留副本）。
class Component {
  final int? id;
  final String cid; // 立创 CID 料号（唯一）
  final String model;
  final String category;
  final String? package;
  final String? brand; // 品牌/厂商（v4 起；同型号不同品牌各自一行，外层聚合显示总量）
  int quantity;
  final String? location;
  final String? note;
  final int createdAt; // epoch 秒
  final int updatedAt; // epoch 秒；同步 LWW 键
  final int? deletedAt; // epoch 秒；null = 未删

  Component({
    this.id,
    required this.cid,
    required this.model,
    required this.category,
    this.package,
    this.brand,
    this.quantity = 0,
    this.location,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

  String get categoryOrOther => category.isEmpty ? '其他' : category;

  /// 是否带真实立创 C 号（形如 C+≥5 位数字）。无 C 号手录元件的 cid 存的是
  /// 「内部隐藏编号」，界面一律不显示该编号，仅作库内身份/同步合并键。
  bool get hasLcscCid => RegExp(r'^C\d{5,}$').hasMatch(cid);

  /// 无 C 号条目（cid 为内部编号或空串）—— UI 上不暴露编号。
  bool get isNoCidEntry => !hasLcscCid;

  Component copyWith({
    int? id,
    String? cid,
    String? model,
    String? category,
    String? package,
    String? brand,
    int? quantity,
    String? location,
    String? note,
    int? createdAt,
    int? updatedAt,
    int? deletedAt,
    bool clearDeleted = false,
    bool clearBrand = false,
  }) {
    return Component(
      id: id ?? this.id,
      cid: cid ?? this.cid,
      model: model ?? this.model,
      category: category ?? this.category,
      package: package ?? this.package,
      brand: clearBrand ? null : (brand ?? this.brand),
      quantity: quantity ?? this.quantity,
      location: location ?? this.location,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeleted ? null : (deletedAt ?? this.deletedAt),
    );
  }

  /// 当前 epoch 秒。
  static int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  factory Component.fromMap(Map<String, Object?> m) {
    return Component(
      id: m['id'] as int?,
      cid: m['cid'] as String,
      model: m['model'] as String,
      category: m['category'] as String,
      package: m['package'] as String?,
      brand: m['brand'] as String?,
      quantity: (m['quantity'] as int?) ?? 0,
      location: m['location'] as String?,
      note: m['note'] as String?,
      createdAt: (m['created_at'] as int?) ?? 0,
      updatedAt: (m['updated_at'] as int?) ?? 0,
      deletedAt: m['deleted_at'] as int?,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'cid': cid,
      'model': model,
      'category': categoryOrOther,
      'package': package,
      'brand': brand,
      'quantity': quantity,
      'location': location,
      'note': note,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'deleted_at': deletedAt,
    };
  }

  /// 同步用 JSON（含软删墓碑字段，一并传输）。
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'cid': cid,
      'model': model,
      'category': categoryOrOther,
      'package': package,
      'brand': brand,
      'quantity': quantity,
      'location': location,
      'note': note,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'deleted_at': deletedAt,
    };
  }

  factory Component.fromJson(Map<String, dynamic> m) {
    return Component(
      id: m['id'] as int?,
      cid: m['cid'] as String,
      model: m['model'] as String,
      category: (m['category'] as String?) ?? '其他',
      package: m['package'] as String?,
      brand: m['brand'] as String?,
      quantity: (m['quantity'] as int?) ?? 0,
      location: m['location'] as String?,
      note: m['note'] as String?,
      createdAt: (m['created_at'] as int?) ?? 0,
      updatedAt: (m['updated_at'] as int?) ?? 0,
      deletedAt: m['deleted_at'] as int?,
    );
  }
}