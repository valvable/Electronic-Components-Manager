import '../../models/component.dart';

/// 同型号元件聚合（多品牌/多批次各自一行，外层列表只显示一条 = 总数量）。
///
/// 纯函数，可单测；分组键 = 分类 + 型号（大小写/首尾空白不敏感）——
/// 同型号但分类不同（跨设备同步/AI 改动造成）视为两组，避免语义混乱。
class ComponentGroup {
  final String category;
  final String model; // 展示用：组内最新一行的型号写法
  final List<Component> items; // 按 created_at 降序（新条目在前）

  const ComponentGroup({
    required this.category,
    required this.model,
    required this.items,
  });

  int get totalQty => items.fold(0, (s, c) => s + c.quantity);

  bool get isSingle => items.length == 1;

  Component get primary => items.first;

  /// 组内不同品牌数（空品牌算「未填」一种）。>1 时外层显示「N 品牌」。
  int get brandCount =>
      items.map((c) => (c.brand?.trim().isEmpty ?? true) ? '' : c.brand!.trim()).toSet().length;

  /// 组内是否有已删除行（回收站视图聚合时标注）。
  bool get anyDeleted => items.any((c) => c.isDeleted);

  /// 数量角标口径：活动行合计；全为墓碑时用墓碑合计。
  bool get allDeleted => items.every((c) => c.isDeleted);
}

String _normModel(String m) => m.trim().toUpperCase();

/// 把元件列表聚合成组。[categoryOrder]（系统 29 + 自创）提供时，组按
/// 分类在该表中的下序排列、表外分类垫底（同类内保持传入序）。
/// [sort] 语义与 [ComponentRepository.all] 一致：qty 排序时按**组总量**排，
/// created_desc 按组内最新条目时间排。
List<ComponentGroup> groupComponents(
  List<Component> comps, {
  String sort = 'created_desc',
  List<String>? categoryOrder,
}) {
  final byKey = <String, ComponentGroup>{};
  final order = <String>[];
  for (final c in comps) {
    final key = '${c.categoryOrOther}|${_normModel(c.model)}';
    final g = byKey[key];
    if (g == null) {
      byKey[key] = ComponentGroup(
          category: c.categoryOrOther, model: c.model, items: [c]);
      order.add(key);
    } else {
      // 展示写法取更新时间最新的那行；items 维护 created 降序。
      byKey[key] = ComponentGroup(
        category: g.category,
        model: c.updatedAt >= g.primary.updatedAt ? c.model : g.model,
        items: _insertSorted(g.items, c),
      );
    }
  }
  final groups = [for (final k in order) byKey[k]!];

  int catIndex(String cat) {
    if (categoryOrder == null) return 0;
    final i = categoryOrder.indexOf(cat);
    return i < 0 ? categoryOrder.length : i;
  }

  int cmp(ComponentGroup a, ComponentGroup b) {
    // 分类分区视图（created_desc）才按分类表排序；qty 排序走全库平铺。
    if (categoryOrder != null && sort == 'created_desc') {
      final ci = catIndex(a.category).compareTo(catIndex(b.category));
      if (ci != 0) return ci;
    }
    return switch (sort) {
      'qty_asc' => a.totalQty.compareTo(b.totalQty),
      'qty_desc' => b.totalQty.compareTo(a.totalQty),
      // 新入库/更新的组排前；组内条目已按 created 降序，用首条目代表。
      _ => b.primary.createdAt.compareTo(a.primary.createdAt),
    };
  }

  groups.sort(cmp);
  return groups;
}

List<Component> _insertSorted(List<Component> items, Component c) {
  final out = List<Component>.of(items);
  var i = 0;
  while (i < out.length && out[i].createdAt >= c.createdAt) {
    i++;
  }
  out.insert(i, c);
  return out;
}
