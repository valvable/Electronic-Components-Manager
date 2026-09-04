import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/bom.dart';
import '../../models/component.dart';
import '../utils/bom_compare.dart';
import 'bom_repository.dart';
import 'component_repository.dart';

/// 导出服务：BOM 对比报告 / 采购清单 / 文件落盘 / 全量备份。
///
/// 报告与清单为纯文本构建（可单测）；[saveTextFile] 负责跨平台落盘。

/// 生成 BOM 对比报告（TXT）：每行三态标记 + 统计汇总。
String buildInventoryReportText(
  List<BomCompareRow> rows, {
  String bomName = 'BOM',
}) {
  final inStock = rows.where((r) => r.status == BomStatus.inStock).length;
  final short = rows.where((r) => r.status == BomStatus.short).length;
  final missing = rows.where((r) => r.status == BomStatus.missing).length;
  final totalQty = rows.fold<int>(0, (s, r) => s + r.line.qty);
  final shortQty = rows.fold<int>(0, (s, r) => s + r.shortBy);

  final buf = StringBuffer()
    ..writeln('元件库存对比报告 — $bomName')
    ..writeln('生成时间：${DateTime.now().toString().substring(0, 19)}')
    ..writeln('物料行数：${rows.length}　合计数量：$totalQty')
    ..writeln('库存充足 $inStock ／ 缺货 $short ／ 待采购 $missing　缺料合计 $shortQty')
    ..writeln('─' * 46);
  for (final r in rows) {
    final marker = switch (r.status) {
      BomStatus.inStock => '[✓ 充足]',
      BomStatus.short => '[⚠ 缺${r.shortBy}]',
      BomStatus.missing => '[🛒 待采购]',
    };
    final hit = r.matched == null
        ? '-'
        : '${r.matched!.model} (${r.matched!.cid}, 库存${r.stockOnHand})';
    buf.writeln('$marker ${r.line.model}　需 ${r.line.qty}　命中: $hit');
    if (r.line.designation != null) {
      buf.writeln('        位号: ${r.line.designation}');
    }
  }
  return buf.toString();
}

/// 生成采购清单（CSV，带 UTF-8 BOM 便于 Excel 打开中文）。
/// 仅含非充足行（缺货 + 待采购）。
String buildPurchaseListCsv(List<BomCompareRow> rows) {
  final buf = StringBuffer('﻿')
    ..writeln('型号,需求数量,库存,缺料数量,状态,位号,库存命中型号');
  for (final r in rows) {
    if (r.status == BomStatus.inStock) continue;
    final status = switch (r.status) {
      BomStatus.short => '缺货',
      BomStatus.missing => '待采购',
      BomStatus.inStock => '',
    };
    buf.writeln([
      _csvCell(r.line.model),
      '${r.line.qty}',
      '${r.stockOnHand}',
      '${r.shortBy}',
      status,
      _csvCell(r.line.designation ?? ''),
      _csvCell(r.matched?.model ?? ''),
    ].join(','));
  }
  return buf.toString();
}

/// CSV 单元格转义：含逗号/引号/换行时用双引号包裹并转义引号。
String _csvCell(String s) {
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

/// 把文本保存到用户位置。
/// - 桌面：系统保存对话框（file_picker 12.x 静态 [FilePicker.saveFile]，返回 file:// Uri）。
/// - Android：同样走 [FilePicker.saveFile]（SAF「另存为」，用户可选下载等目录）；
///   个别 ROM 无文档提供者时回退为写入应用临时目录。
/// - 其它移动平台：写入应用临时目录（返回路径供提示）。
/// [extension] 用于覆盖扩展名过滤（如 'json'）；缺省按文件名后缀判 csv/txt。
/// 返回实际路径或可展示的文件位置；用户取消保存返回 null。
Future<String?> saveTextFile(String suggestedName, String content,
    {String? extension}) async {
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    final isCsv = suggestedName.toLowerCase().endsWith('.csv');
    final ext = extension ?? (isCsv ? 'csv' : 'txt');
    final uri = await FilePicker.saveFile(
      dialogTitle: '保存',
      fileName: suggestedName,
      bytes: utf8.encode(content),
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    return uri?.toFilePath();
  }
  if (!kIsWeb && Platform.isAndroid) {
    // file_picker 12.x 的 Android saveFile 按文件名后缀自动定 MIME，
    // 经系统「另存为」写入用户所选位置（content:// Uri）。
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: '保存',
        fileName: suggestedName,
        bytes: utf8.encode(content),
      );
      if (uri == null) return null; // 用户取消
      return describeSavedUri(uri, fallbackName: suggestedName);
    } catch (e) {
      debugPrint('SAF 保存失败，回退应用目录：$e');
      // 落到下方临时目录回退，至少不丢数据
    }
  }
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, suggestedName));
  await file.writeAsString(content, flush: true);
  return file.path;
}

/// SAF content Uri → 用户可读的位置描述。
///
/// 例：`content://…/document/primary%3ADownload%2F报告.csv` → `Download/报告.csv`；
/// 解析不了则回退 [fallbackName]。
String describeSavedUri(Uri uri, {required String fallbackName}) {
  final raw = uri.toString();
  final marker = '/document/';
  final idx = raw.indexOf(marker);
  if (idx == -1) return fallbackName;
  // 注意：Android 端 native 返回的可能是未带 scheme 的路径串
  // （形如 /document/primary:Download/报告.csv）。
  final doc = Uri.decodeComponent(raw.substring(idx + marker.length));
  final rel = doc.startsWith('primary:') ? doc.substring('primary:'.length) : doc;
  return rel.isEmpty ? fallbackName : rel;
}

/// 全量备份为 JSON 字符串（含已删除元件 + BOM 单据与明细），设置页恢复用。
Future<String> buildBackupJson({
  required ComponentRepository components,
  required BomRepository boms,
}) async {
  final comps = await components.all(includeDeleted: true);
  final bomList = await boms.listBoms();
  final items = <Map<String, dynamic>>[];
  for (final b in bomList) {
    final its = await boms.itemsForBom(b.id!);
    items.addAll(its.map((i) => i.toJson()));
  }
  return const JsonEncoder.withIndent('  ').convert({
    'schema': 1,
    'created_at': Component.now(),
    'components': comps.map((c) => c.toJson()).toList(),
    'boms': bomList.map((b) => b.toJson()).toList(),
    'bom_items': items,
  });
}

/// 从备份 JSON 全量恢复：清空三表后按备份重建。
/// - 元件/单据保留备份里的时间戳与软删墓碑；明细经旧 id → 新 id 重映射。
/// - 格式校验失败抛 [FormatException]（不落任何数据，保持原库不动）。
/// - 不动 sync_meta（设备 ID）等非业务表。返回恢复的元件数。
Future<int> restoreBackupJson({
  required String jsonText,
  required ComponentRepository components,
  required BomRepository boms,
}) async {
  final Map<String, dynamic> data;
  try {
    final decoded = jsonDecode(jsonText);
    data = decoded is Map<String, dynamic>
        ? decoded
        : throw const FormatException('备份文件格式不正确');
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('备份文件不是有效的 JSON');
  }
  if ((data['schema'] as num?)?.toInt() != 1) {
    throw const FormatException('备份格式版本不兼容，请用同版本应用导出的备份');
  }

  final compJson = (data['components'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final bomJson =
      (data['boms'] as List? ?? const []).cast<Map<String, dynamic>>();
  final itemJson =
      (data['bom_items'] as List? ?? const []).cast<Map<String, dynamic>>();

  final db = components.db;
  return db.transaction((txn) async {
    await txn.delete('bom_items');
    await txn.delete('boms');
    await txn.delete('components');

    final compIdMap = <int, int>{};
    for (final j in compJson) {
      final c = Component.fromJson(j);
      final newId = await txn.insert('components', c.toMap()..remove('id'));
      compIdMap[j['id'] as int] = newId;
    }
    final bomIdMap = <int, int>{};
    for (final j in bomJson) {
      final b = Bom.fromJson(j);
      final newId = await txn.insert('boms', b.toMap()..remove('id'));
      bomIdMap[j['id'] as int] = newId;
    }
    for (final j in itemJson) {
      final it = BomItem.fromJson(j);
      final newBomId = bomIdMap[it.bomId];
      final newCompId = compIdMap[it.componentId];
      if (newBomId == null || newCompId == null) continue; // 孤儿条目跳过
      await txn.insert('bom_items', {
        'bom_id': newBomId,
        'component_id': newCompId,
        'quantity': it.quantity,
      });
    }
    return compJson.length;
  });
}
