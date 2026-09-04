import '../config/constants.dart';
import '../utils/classifier.dart';
import 'lcsc_lookup.dart';

/// 立创购物车导出解析（纯逻辑可单测）。
///
/// 购物车 CSV/XLSX 常见 11 列表头：
/// `购买类型 / 商品编号(物料编码) / 商品分类 / 名称 / 商品型号 / 品牌 /
/// 封装规格 / 单个毛重 / 购买数量 / 商品单价(元) / 金额(元)`。
/// 与 BOM 不同，购物车以 **C 号（商品编号）** 为唯一键：行解析成 [CartItem]，
/// 入库时同 C 号合并数量（见 [ComponentRepository.importCart]）。
///
/// CSV 解析复用 [import_parser.parseImportFile]（UTF-8/GBK 剥 BOM、XLSX 取首个
/// sheet、行尾空列裁剪），这里只处理「表头识别 + 行 → CartItem」两件事。

/// 购物车行（解析结果）。`code` 为立创 C 号，入库时作为唯一键。
class CartItem {
  final String code; // 商品编号 / C 号
  final String model; // 商品型号（缺失回退 名称，再回退 code 保底）
  final String category; // ∈ inventoryCategories
  final String? package; // 封装规格
  final String? brand; // 品牌（v4 起写 components.brand 列，不再挤进备注）
  final String? note; // 名称等补充信息（仅全新入库行写入）
  final int qty; // 购买数量

  const CartItem({
    required this.code,
    required this.model,
    required this.category,
    this.package,
    this.brand,
    this.note,
    required this.qty,
  });
}

/// 表头 → 购物车列的映射（-1 = 未识别/未选择）。
class CartColumnMapping {
  final int codeCol; // 商品编号/物料编码
  final int modelCol; // 商品型号
  final int qtyCol; // 购买数量
  final int categoryCol; // 商品分类（可选，仅帮助归类）
  final int packageCol; // 封装规格（可选）
  final int brandCol; // 品牌（可选，进 note）
  final int nameCol; // 名称（可选：型号兜底 + 分类 hint + note）
  final int priceCol; // 单价（可选，仅预览用，不写库）

  const CartColumnMapping({
    this.codeCol = -1,
    this.modelCol = -1,
    this.qtyCol = -1,
    this.categoryCol = -1,
    this.packageCol = -1,
    this.brandCol = -1,
    this.nameCol = -1,
    this.priceCol = -1,
  });

  /// 入库最低要求：能定位编号与数量。型号缺失会回退名称/编号，不阻塞入库。
  bool get isComplete => codeCol >= 0 && qtyCol >= 0;

  /// 实际取型号的列：型号列缺省时把「名称」当型号用。
  int get effectiveModelCol => modelCol >= 0 ? modelCol : nameCol;
}

/// 解析结果：入库行 + 被跳过行（原因附带 1-based 行号，供 UI 提示）。
class CartParseResult {
  final List<CartItem> items;
  final int skipped; // 被跳过的数据行数
  final List<String> skipReasons; // 每行原因（第 N 行：…）

  const CartParseResult({
    required this.items,
    required this.skipped,
    required this.skipReasons,
  });

  bool get isEmpty => items.isEmpty;
}

/// 按常见表头关键字自动识别购物车列（用户可在 UI 调整）。
///
/// 同一列不会命中两个角色（已用列跳过）。识别顺序：
/// 编号 → 型号 → 数量 → 品牌 → 封装 → 分类 → 名称 → 单价。
CartColumnMapping detectCartMapping(List<String> header) {
  final norm = header
      .map((h) => h.trim().toLowerCase().replaceAll(' ', ''))
      .toList();
  final used = <int>{};

  int pick(List<String> keys) {
    for (var i = 0; i < norm.length; i++) {
      if (used.contains(i)) continue;
      final h = norm[i];
      if (h.isEmpty) continue;
      if (keys.any(h.contains)) {
        used.add(i);
        return i;
      }
    }
    return -1;
  }

  return CartColumnMapping(
    codeCol: pick(const [
      '商品编号', '物料编码', '商品编码', '物料号', '编号', '编码', 'partnumber',
      'partno', 'mpn', 'productnumber', 'lcsc', 'code',
    ]),
    modelCol: pick(const ['商品型号', '厂商型号', '器件型号', '型号', 'model']),
    qtyCol: pick(const ['购买数量', '数量', 'qty', 'quantity', '用量']),
    brandCol: pick(const ['品牌', 'brand', '制造商', 'manufacturer', 'vendor']),
    packageCol: pick(const ['封装', 'package', 'encap', 'footprint', '规格']),
    categoryCol: pick(const ['分类', '类别', 'category', 'catalog']),
    nameCol: pick(const ['名称', '品名', 'name', '描述', 'desc', 'description', '产品']),
    priceCol: pick(const ['单价', '价格', 'price']),
  );
}

/// 按映射把「含表头的行」抽成 [CartItem]，同 C 号自动合并数量。
///
/// - 跳过第 0 行（表头）。
/// - 编号为空、购买数量非法/≤0 的行跳过并记原因。
/// - 分类归入 [inventoryCategories]：精确中文命中直接用；否则 LCSC 英文分类
///   关键词映射；再无则由型号/名称 hint 自动分类，兜底「其他」。
/// - 型号缺失时回退「名称」列，再回退编号本身（保证入库模型非空）。
/// - 品牌列写 [CartItem.brand]（v4 起独立字段）；名称列写备注。
CartParseResult buildCartItems(List<List<String>> rows, CartColumnMapping m) {
  final merged = <String, _Acc>{};
  final skipReasons = <String>[];

  for (var i = 1; i < rows.length; i++) {
    final row = rows[i];
    final lineNo = i + 1; // 人类可读的 1-based 行号
    String cell(int col) => (col >= 0 && row.length > col) ? row[col].trim() : '';

    final code = cell(m.codeCol);
    if (code.isEmpty) {
      skipReasons.add('第 $lineNo 行：商品编号为空');
      continue;
    }

    final qtyNum = num.tryParse(cell(m.qtyCol));
    if (qtyNum == null || qtyNum <= 0) {
      skipReasons.add('第 $lineNo 行：购买数量无效（${cell(m.qtyCol)}）');
      continue;
    }

    final modelCol = m.effectiveModelCol;
    final modelCell = cell(modelCol);
    final nameCell = cell(m.nameCol);
    // 分类 hint：真实型号 + 名称（名称即型号列时不重复）。模型缺失则不猜。
    final hint = (m.nameCol == -1 || m.nameCol == modelCol)
        ? modelCell
        : [modelCell, nameCell].where((s) => s.isNotEmpty).join(' ');
    final modelRaw = modelCell.isNotEmpty ? modelCell : nameCell;

    // model 为空时回退编号本身；此时 hint 为空，分类最多靠「商品分类」列。
    final fallbackToCode = modelRaw.isEmpty;
    final resolvedModel = fallbackToCode ? code : modelRaw;
    final category = fallbackToCode
        ? categoryFromCart(cell(m.categoryCol), '')
        : categoryFromCart(cell(m.categoryCol), hint);

    final package = cell(m.packageCol);
    final brand = cell(m.brandCol);
    final noteParts = <String>[];
    if (nameCell.isNotEmpty && nameCell != resolvedModel) noteParts.add(nameCell);

    final acc = merged.putIfAbsent(code, () => _Acc(code: code));
    acc.qty += qtyNum.toInt();
    // 首见写元数据；同 C 号重复行仅累加数量。
    if (acc.model.isEmpty) {
      acc.model = resolvedModel;
      acc.category = category;
      acc.package = package.isNotEmpty ? package : null;
      acc.brand = brand.isNotEmpty ? brand : null;
      acc.note = noteParts.isNotEmpty ? noteParts.join('；') : null;
    }
  }

  return CartParseResult(
    items: [
      for (final a in merged.values)
        CartItem(
          code: a.code,
          model: a.model,
          category: a.category,
          package: a.package,
          brand: a.brand,
          note: a.note,
          qty: a.qty,
        ),
    ],
    skipped: skipReasons.length,
    skipReasons: skipReasons,
  );
}

/// 「商品分类」或 LCSC 分类/hint → 应用中文分类（∈ [inventoryCategories]）。
///
/// 优先级：精确中文分类命中 → [categoryFromLcsc]（英文分类关键词 + hint 自动
/// 分类）→ hint 自动分类 → 「其他」。确保返回值永远在合法集合内。
String categoryFromCart(String? catalog, String hint) {
  if (catalog != null) {
    final c = catalog.trim();
    if (c.isNotEmpty) {
      if (inventoryCategories.contains(c)) return c;
      final fromLcsc = categoryFromLcsc(c, hint: hint);
      if (fromLcsc != defaultCategory) return fromLcsc;
    }
  }
  final auto = classify(hint);
  return auto == defaultCategory ? defaultCategory : auto;
}

/// 解析中合并同 C 号的内部累加器。
class _Acc {
  final String code;
  String model = '';
  String category = defaultCategory;
  String? package;
  String? brand;
  String? note;
  int qty = 0;

  _Acc({required this.code});
}
