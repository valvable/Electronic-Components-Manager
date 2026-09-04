import 'package:component_manager/core/services/import_parser.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCsv', () {
    test('基础 CSV：表头 + 数据 + 去尾空白列', () {
      const csv = '型号,数量,位号\nSTM32F103C8T6,10,R1;R2\nCH340,5\n';
      final rows = parseCsv(csv);
      expect(rows.length, 3);
      expect(rows[0], ['型号', '数量', '位号']);
      expect(rows[1], ['STM32F103C8T6', '10', 'R1;R2']);
      expect(rows[2], ['CH340', '5']); // 无位号 → 只留 2 列
    });

    test('引号包裹含逗号/换行的值', () {
      final rows = parseCsv('型号,数量\n"RES, 0805",3\n');
      expect(rows[1][0], 'RES, 0805');
    });

    test('UTF-8 BOM 剥离', () {
      final rows = parseCsv('﻿型号,数量\nA,1\n');
      expect(rows[0][0], '型号');
      expect(rows[0][1], '数量');
    });
  });

  group('parseXlsx', () {
    test('内存生成 xlsx → 解析出行（首表优先）', () {
      final excel = Excel.createExcel();
      final sheet = excel['Sheet1'];
      sheet.appendRow([
        TextCellValue('型号'),
        TextCellValue('数量'),
        TextCellValue('位号'),
      ]);
      sheet.appendRow([
        TextCellValue('RC0603-10K'),
        IntCellValue(20),
        TextCellValue('R1'),
      ]);
      final bytes = excel.encode();
      expect(bytes, isNotNull);

      final rows = parseXlsx(bytes!);
      expect(rows.length, 2);
      expect(rows[0], ['型号', '数量', '位号']);
      expect(rows[1], ['RC0603-10K', '20', 'R1']);
    });
  });

  group('detectColumnMapping', () {
    test('中文表头自动识别', () {
      final m = detectColumnMapping(['序号', '位号', '型号', '数量']);
      expect(m.modelCol, 2);
      expect(m.qtyCol, 3);
      expect(m.designationCol, 1);
      expect(m.isComplete, isTrue);
    });

    test('英文表头自动识别', () {
      final m = detectColumnMapping(['Designator', 'Model', 'Quantity']);
      expect(m.modelCol, 1);
      expect(m.qtyCol, 2);
      expect(m.designationCol, 0);
    });

    test('未识别列返回 -1 / isComplete 为假', () {
      final m = detectColumnMapping(['foo', 'bar']);
      expect(m.modelCol, -1);
      expect(m.qtyCol, -1);
      expect(m.isComplete, isFalse);
    });

    test('表头首尾空白忽略', () {
      final m = detectColumnMapping([' 型号 ', ' 数量']);
      expect(m.modelCol, 0);
      expect(m.qtyCol, 1);
    });
  });

  group('buildBomLines', () {
    const rows = [
      ['型号', '数量'],
      ['A', '10'],
      ['B', '5'],
      ['', '3'], // 型号为空 → 跳过
      ['C', 'abc'], // 数量非法 → 跳过
      ['D', '0'], // 数量 ≤ 0 → 跳过
    ];

    test('按映射抽取有效行', () {
      final lines = buildBomLines(
          rows, const ColumnMapping(modelCol: 0, qtyCol: 1));
      expect(lines.length, 2);
      expect(lines[0].model, 'A');
      expect(lines[0].qty, 10);
      expect(lines[1].model, 'B');
      expect(lines[1].qty, 5);
    });

    test('位号列抽取', () {
      const withDes = [
        ['型号', '数量', '位号'],
        ['A', '10', 'R1;R2'],
      ];
      final lines = buildBomLines(withDes,
          const ColumnMapping(modelCol: 0, qtyCol: 1, designationCol: 2));
      expect(lines.single.designation, 'R1;R2');
    });

    test('小数数量取整', () {
      const dec = [
        ['型号', '数量'],
        ['A', '10.5'],
      ];
      final lines = buildBomLines(
          dec, const ColumnMapping(modelCol: 0, qtyCol: 1));
      expect(lines.single.qty, 10);
    });
  });
}
