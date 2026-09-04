import 'package:component_manager/core/utils/bom_compare.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Component comp({required String cid, required String model, int qty = 0}) {
    return Component(
      cid: cid,
      model: model,
      category: '其他',
      quantity: qty,
      createdAt: 0,
      updatedAt: 0,
    );
  }

  group('BOM 对比三态', () {
    test('库存充足 → inStock（shortBy=0）', () {
      final rows = compareAgainstInventory(
        [const BomLine(model: 'C10001', qty: 10)],
        [comp(cid: 'C10001', model: 'RES-10K', qty: 20)],
      );
      expect(rows.single.status, BomStatus.inStock);
      expect(rows.single.stockOnHand, 20);
      expect(rows.single.shortBy, 0);
    });

    test('0 < 库存 < 需求 → short（shortBy=qty-stock）', () {
      final rows = compareAgainstInventory(
        [const BomLine(model: 'C10001', qty: 10)],
        [comp(cid: 'C10001', model: 'RES-10K', qty: 4)],
      );
      expect(rows.single.status, BomStatus.short);
      expect(rows.single.shortBy, 6);
    });

    test('未命中 → missing（待采购）', () {
      final rows = compareAgainstInventory(
        [const BomLine(model: 'C99999', qty: 5)],
        [comp(cid: 'C10001', model: 'RES-10K', qty: 50)],
      );
      expect(rows.single.status, BomStatus.missing);
      expect(rows.single.stockOnHand, 0);
      expect(rows.single.shortBy, 5);
    });

    test('无库存元件时全部待采购', () {
      final rows = compareAgainstInventory([const BomLine(model: 'C1', qty: 1)], const []);
      expect(rows.single.status, BomStatus.missing);
    });
  });

  group('模糊匹配兜底', () {
    test('CID 未命中但型号近似命中', () {
      final rows = compareAgainstInventory(
        [const BomLine(model: 'RC0603FR-10KL', qty: 3)],
        [comp(cid: 'C20001', model: 'RC0603FR-10K', qty: 8)],
      );
      expect(rows.single.status, BomStatus.inStock, reason: '型号近似 < 两个编辑距离');
    });
  });
}