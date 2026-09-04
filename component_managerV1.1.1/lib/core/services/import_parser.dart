import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../utils/bom_compare.dart';

/// BOM 文件解析 + 列映射识别（纯逻辑可单测）。
///
/// - `parseCsv` / `parseXlsx` 各自独立可测；`parseImportFile` 按扩展名分派。
/// - CSV 仅支持 UTF-8（自动剥离 BOM）；GBK 旧文件请先在 Excel 另存为 UTF-8。
/// - XLSX 用 `Excel.decodeBytes`（excel 4.x 无 decodeExcel，无需回退路径）。
/// - 行内末尾空白列会去掉，保证表头列数与数据行一致。

/// 解析 CSV 文本 → 行（每行去尾空白列）。首行视为表头（调用方决定）。
List<List<String>> parseCsv(String content) {
  var s = content;
  if (s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF) s = s.substring(1); // 剥 BOM
  // dynamicTyping=false：所有单元格保持字符串，数量由 buildBomLines 解析。
  final rows = Csv(dynamicTyping: false).decode(s);
  return rows.map((r) => _trimRow(r)).toList();
}

/// 解析 XLSX 字节 → 行（取第一个 sheet）。
List<List<String>> parseXlsx(List<int> bytes) {
  final excel = Excel.decodeBytes(bytes);
  final sheet = excel.tables.values.isNotEmpty ? excel.tables.values.first : null;
  if (sheet == null) return const [];
  final rows = <List<String>>[];
  for (var i = 0; i < sheet.maxRows; i++) {
    rows.add(_trimRow(
        sheet.row(i).map((d) => d?.value?.toString() ?? '').toList()));
  }
  return rows;
}

/// 按扩展名分派读取与解析（file_picker 12.x 无 [PlatformFile.bytes] 字段，
/// 统一走 [PlatformFile.readAsBytes]；桌面由路径读、Android 由内存读）。
Future<List<List<String>>> parseImportFile(PlatformFile file) async {
  final name = file.name.toLowerCase();
  final bytes = await file.readAsBytes();
  if (name.endsWith('.csv')) return parseCsv(utf8.decode(bytes));
  if (name.endsWith('.xlsx') || name.endsWith('.xls')) return parseXlsx(bytes);
  throw const FormatException('不支持的文件格式，请选择 CSV 或 XLSX');
}

/// 选一个待导入文件；取消返回 null。
///
/// 桌面端保留 [FileType.custom] 扩展名过滤；Android 端改用 [FileType.any]：
/// file_picker 在 Android 把扩展名转成 MIME 交给系统文件选择器过滤，而微信/
/// QQ/浏览器等渠道收到的 csv/xlsx/json 常被登记为 octet-stream 等 MIME，
/// 文件会被选择器隐藏（表现为"选不到文件"）。故手机端放开过滤，由调用方
/// （[parseImportFile] / 恢复逻辑）按扩展名校验并给出明确报错。
Future<PlatformFile?> pickImportFile(List<String> desktopExtensions) async {
  final looseFilter = !kIsWeb && Platform.isAndroid;
  final picked = await FilePicker.pickFiles(
    type: looseFilter ? FileType.any : FileType.custom,
    allowedExtensions: looseFilter ? null : desktopExtensions,
  );
  return picked.isEmpty ? null : picked.first;
}

/// 去掉行尾的空串列（保证各行列数一致、便于表头检测）。
List<String> _trimRow(List<dynamic> raw) {
  final cells = raw.map((c) => c == null ? '' : c.toString().trim()).toList();
  while (cells.isNotEmpty && cells.last.isEmpty) {
    cells.removeLast();
  }
  return cells;
}

/// 表头 → BOM 列的映射（-1 = 未识别/未选择）。
class ColumnMapping {
  final int modelCol; // 型号 / Model / 名称
  final int qtyCol; // 数量 / Qty / Quantity
  final int designationCol; // 位号 / Designator（可选）

  const ColumnMapping({
    required this.modelCol,
    required this.qtyCol,
    this.designationCol = -1,
  });

  bool get isComplete => modelCol >= 0 && qtyCol >= 0;

  ColumnMapping copyWith({
    int? modelCol,
    int? qtyCol,
    int? designationCol,
  }) {
    return ColumnMapping(
      modelCol: modelCol ?? this.modelCol,
      qtyCol: qtyCol ?? this.qtyCol,
      designationCol: designationCol ?? this.designationCol,
    );
  }
}

/// 按常见表头关键字自动识别列（用户可在 UI 调整）。
///
/// 识别顺序：型号 → 数量 → 位号；同一列不会命中两个角色。
ColumnMapping detectColumnMapping(List<String> header) {
  final norm = header
      .map((h) => h.trim().toLowerCase().replaceAll(' ', ''))
      .toList();
  final used = <int>{};
  int model = -1, qty = -1, des = -1;

  bool matchAt(int i, List<String> keys) {
    if (used.contains(i)) return false;
    final h = norm[i];
    if (h.isEmpty) return false;
    return keys.any(h.contains);
  }

  for (var i = 0; i < norm.length; i++) {
    if (matchAt(i, ['型号', 'model', 'device', '名称', '品名', '物料',
        '规格', 'spec', 'part', '描述', 'description'])) {
      model = i;
      used.add(i);
      break;
    }
  }
  for (var i = 0; i < norm.length; i++) {
    if (matchAt(i, ['数量', 'qty', 'quantity', '用量', '个数', '总数', 'count'])) {
      qty = i;
      used.add(i);
      break;
    }
  }
  for (var i = 0; i < norm.length; i++) {
    if (matchAt(i, ['位号', 'designator', 'refdes', 'reference', 'ref', '编号'])) {
      des = i;
      used.add(i);
      break;
    }
  }
  return ColumnMapping(
    modelCol: model,
    qtyCol: qty,
    designationCol: des,
  );
}

/// 按映射把「含表头的行」抽成 [BomLine]。
///
/// - 跳过第 0 行（表头）。
/// - 型号为空、数量非法/≤0 的行跳过。
/// - 数量支持整数与小数（自动取整，如 "10.5" → 10）。
List<BomLine> buildBomLines(List<List<String>> rows, ColumnMapping mapping) {
  final lines = <BomLine>[];
  for (var i = 1; i < rows.length; i++) {
    final row = rows[i];
    if (row.length <= mapping.modelCol) continue;
    final model = row[mapping.modelCol].trim();
    if (model.isEmpty) continue;
    final qtyCell = row.length > mapping.qtyCol ? row[mapping.qtyCol] : '';
    final qtyNum = num.tryParse(qtyCell.trim());
    if (qtyNum == null || qtyNum <= 0) continue;
    final designation = mapping.designationCol >= 0 &&
            row.length > mapping.designationCol &&
            row[mapping.designationCol].trim().isNotEmpty
        ? row[mapping.designationCol].trim()
        : null;
    lines.add(BomLine(model: model, qty: qtyNum.toInt(), designation: designation));
  }
  return lines;
}
