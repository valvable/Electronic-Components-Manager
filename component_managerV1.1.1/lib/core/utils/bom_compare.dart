import '../../models/component.dart';
import 'fuzzy.dart';

/// BOM 行（导入解析后的一条物料）。纯数据。
class BomLine {
  final String? designation; // 位号，如 R1,R2（可选）
  final String model;
  final int qty;

  const BomLine({this.designation, required this.model, required this.qty});
}

/// BOM 对比状态：库存充足 / 缺货 / 待采购。
enum BomStatus { inStock, short, missing }

/// BOM 对比结果（一行）。含命中的库存数、差额、模糊匹配的候选。
class BomCompareRow {
  final BomLine line;
  final Component? matched; // 精确 CID 或模糊型号命中的库存元件
  final int stockOnHand; // 命中库存数；未命中为 0
  final BomStatus status;
  final int shortBy; // max(0, qty - stock)；充足时为 0

  const BomCompareRow({
    required this.line,
    required this.matched,
    required this.stockOnHand,
    required this.status,
    required this.shortBy,
  });

  String get statusLabel {
    switch (status) {
      case BomStatus.inStock:
        return '库存充足';
      case BomStatus.short:
        return '缺货';
      case BomStatus.missing:
        return '待采购';
    }
  }
}

/// 将导入的 BOM 行与库存对比。
///
/// 每行：先精确 CID 匹配库存，否则型号模糊匹配（Levenshtein ≤ [fuzzyMatchMax]）
/// 取最近候选。状态判定：
/// - stock >= qty → inStock
/// - 0 < stock < qty → short（shortBy = qty - stock）
/// - 未命中（stock == 0）→ missing（待采购）
List<BomCompareRow> compareAgainstInventory(
  List<BomLine> lines,
  List<Component> inventory, {
  int fuzzyMatchMax = 2,
}) {
  final byCid = <String, Component>{
    for (final c in inventory) c.cid: c,
  };
  final results = <BomCompareRow>[];
  for (final line in lines) {
    Component? matched;
    // 1) 精确 CID 匹配（优先）
    matched = byCid[line.model];
    // 2) 型号模糊匹配
    if (matched == null && inventory.isNotEmpty) {
      Component? best;
      int bestScore = fuzzyMatchMax + 1;
      for (final c in inventory) {
        final score = similarityScore(c.model.toLowerCase(), c.cid.toLowerCase(),
            line.model.toLowerCase());
        if (score <= fuzzyMatchMax && score < bestScore) {
          bestScore = score;
          best = c;
        }
      }
      matched = best;
    }

    final int stock = matched?.quantity ?? 0;
    BomStatus status;
    final int shortBy;
    if (stock >= line.qty) {
      status = BomStatus.inStock;
      shortBy = 0;
    } else if (stock > 0) {
      status = BomStatus.short;
      shortBy = line.qty - stock;
    } else {
      status = BomStatus.missing;
      shortBy = line.qty;
    }
    results.add(BomCompareRow(
      line: line,
      matched: matched,
      stockOnHand: stock,
      status: status,
      shortBy: shortBy,
    ));
  }
  return results;
}