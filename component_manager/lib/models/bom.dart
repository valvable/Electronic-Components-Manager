/// BOM 清单模型，对应数据库 `boms` 表。
///
/// 第二阶段 BOM 导入功能使用：一次导入的 BOM 表保存为一条 Bom 记录，
/// 表内每一行物料对应一条 [BomItem]（bom_items 表）。
class Bom {
  final int? id;
  final String name; // BOM 名称，如「平衡小车主板 v1.2」
  final String createdAt; // 创建时间（ISO8601 字符串）

  const Bom({
    this.id,
    required this.name,
    required this.createdAt,
  });

  factory Bom.fromMap(Map<String, Object?> map) {
    return Bom(
      id: map['id'] as int?,
      name: (map['name'] as String?) ?? '',
      createdAt: (map['created_at'] as String?) ?? '',
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'created_at': createdAt,
    };
  }
}
