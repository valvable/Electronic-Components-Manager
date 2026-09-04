import 'package:component_manager/core/services/export_service.dart';
import 'package:component_manager/core/utils/bom_compare.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Component comp({String cid = 'C1', String model = 'M', int qty = 0}) =>
      Component(
        cid: cid,
        model: model,
        category: '其他',
        quantity: qty,
        createdAt: 0,
        updatedAt: 0,
      );

  List<BomCompareRow> rows() => [
        BomCompareRow(
          line: const BomLine(model: 'A', qty: 5),
          matched: comp(qty: 10),
          stockOnHand: 10,
          status: BomStatus.inStock,
          shortBy: 0,
        ),
        BomCompareRow(
          line: const BomLine(model: 'B', qty: 5),
          matched: comp(model: 'B2', qty: 2),
          stockOnHand: 2,
          status: BomStatus.short,
          shortBy: 3,
        ),
        BomCompareRow(
          line: const BomLine(model: 'C', qty: 8),
          matched: null,
          stockOnHand: 0,
          status: BomStatus.missing,
          shortBy: 8,
        ),
      ];

  group('buildInventoryReportText', () {
    test('含标题、统计与三态标记', () {
      final text = buildInventoryReportText(rows(), bomName: '测试BOM');
      expect(text, contains('测试BOM'));
      expect(text, contains('库存充足 1 ／ 缺货 1 ／ 待采购 1'));
      expect(text, contains('缺料合计 11')); // 3 + 8
      expect(text, contains('[✓ 充足]'));
      expect(text, contains('[⚠ 缺3]'));
      expect(text, contains('[🛒 待采购]'));
    });

    test('缺货行标注命中元件与库存', () {
      final text = buildInventoryReportText(rows());
      expect(text, contains('B2 (C1, 库存2)'));
    });
  });

  group('buildPurchaseListCsv', () {
    test('只含非充足行且转义正确', () {
      final csv = buildPurchaseListCsv(rows());
      expect(csv, startsWith('﻿')); // UTF-8 BOM，Excel 打开中文不乱码
      expect(csv, contains('B,5,2,3,缺货,,')); // 位号与命中型号为空
      expect(csv, contains('C,8,0,8,待采购,,'));
      expect(csv.contains(',A,'), isFalse); // 充足行不在清单
    });

    test('含逗号/引号的单元格被转义', () {
      final special = [
        BomCompareRow(
          line: const BomLine(model: 'RES, 0805', qty: 2),
          matched: null,
          stockOnHand: 0,
          status: BomStatus.missing,
          shortBy: 2,
        ),
      ];
      final csv = buildPurchaseListCsv(special);
      expect(csv, contains('"RES, 0805"'));
    });
  });
}
