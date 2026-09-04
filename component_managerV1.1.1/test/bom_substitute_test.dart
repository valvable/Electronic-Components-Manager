import 'package:component_manager/core/utils/bom_substitute.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本地替代候选纯函数：过滤/排序/置信度分档/原因文案。
void main() {
  Component comp({
    int? id,
    required String cid,
    required String model,
    required String category,
    String? package,
    int quantity = 10,
    int? deletedAt,
  }) =>
      Component(
        id: id,
        cid: cid,
        model: model,
        category: category,
        package: package,
        quantity: quantity,
        createdAt: 1,
        updatedAt: 1,
        deletedAt: deletedAt,
      );

  List<int> ids(List<LocalSubstitute> subs) =>
      [for (final s in subs) s.component.id!];

  test('同分类优先于跨分类近型号', () {
    final inv = [
      comp(id: 1, cid: 'C1', model: 'AAAABBBB', category: '电容'), // 同分类但型号远
      comp(id: 2, cid: 'C2', model: 'RC0603FR-0710KL', category: '其他'), // 跨分类近型号
    ];
    final subs = topLocalSubstitutes(
        model: 'RC0603FR-0710KL', categoryHint: '电容', inventory: inv);
    expect(ids(subs), [1, 2]); // 同分类压前
    expect(subs[0].reason, contains('同分类：电容'));
    expect(subs[0].reason, contains('库存 10'));
    expect(subs[0].confidence, 0.7);
    expect(subs[1].reason, contains('型号相近'));
    expect(subs[1].confidence, 0.55);
  });

  test('excludeIds 剔除占用件', () {
    final inv = [
      comp(id: 1, cid: 'C1', model: 'ABC', category: '电阻'),
      comp(id: 2, cid: 'C2', model: 'ABC', category: '电阻'),
    ];
    final subs = topLocalSubstitutes(
        model: 'ABC', categoryHint: '电阻', inventory: inv, excludeIds: {1});
    expect(ids(subs), [2]);
  });

  test('数量 ≤0 与已删除剔除', () {
    final inv = [
      comp(id: 1, cid: 'C1', model: 'ABC', category: '电阻', quantity: 0),
      comp(id: 2, cid: 'C2', model: 'ABC', category: '电阻', quantity: -1),
      comp(id: 3, cid: 'C3', model: 'ABC', category: '电阻', deletedAt: 9),
      comp(id: 4, cid: 'C4', model: 'ABC', category: '电阻', quantity: 5),
    ];
    final subs = topLocalSubstitutes(
        model: 'ABC', categoryHint: '电阻', inventory: inv);
    expect(ids(subs), [4]);
  });

  test('同距离封装相符者在前；封装/型号打平后库存多者在前', () {
    final inv = [
      comp(id: 1, cid: 'C1', model: 'X1', category: '电阻', package: '0603', quantity: 1),
      comp(id: 2, cid: 'C2', model: 'X2', category: '电阻', quantity: 99),
      comp(id: 3, cid: 'C3', model: 'X9', category: '电阻', quantity: 5),
    ];
    // 目标 X1：id1 型号/封装都符 → 第一；id2/id3 同距同分类，按库存 99 > 5
    final subs = topLocalSubstitutes(
        model: 'X1', categoryHint: '电阻', packageHint: '0603', inventory: inv);
    expect(ids(subs), [1, 2, 3]);
    expect(subs[0].confidence, 0.95);
    expect(subs[0].reason, contains('封装一致 0603'));
  });

  test('置信度分档 0.95/0.85/0.7/0.55', () {
    final inv = [
      comp(id: 1, cid: 'C1', model: 'RC0603FR-0710KL', category: '电阻', package: '0603'), // 同分类+封装+近型号
      comp(id: 2, cid: 'C2', model: 'RC0603FR-0710KL', category: '电阻'), // 同分类+近型号
      comp(id: 3, cid: 'C3', model: 'ZZZZZZZZ', category: '电阻'), // 仅同分类
      comp(id: 4, cid: 'C4', model: 'RC0603FR-0710KL', category: '电容'), // 跨分类近型号
    ];
    final subs = topLocalSubstitutes(
        model: 'RC0603FR-0710KL',
        categoryHint: '电阻',
        packageHint: '0603',
        inventory: inv,
        topN: 4);
    expect(ids(subs), [1, 2, 3, 4]);
    expect(subs[0].confidence, closeTo(0.95, 1e-9));
    expect(subs[1].confidence, closeTo(0.85, 1e-9));
    expect(subs[2].confidence, closeTo(0.7, 1e-9));
    expect(subs[3].confidence, closeTo(0.55, 1e-9));
  });

  test('topN 截断', () {
    final inv = [
      for (var i = 1; i <= 5; i++)
        comp(id: i, cid: 'C$i', model: 'ABC', category: '电阻'),
    ];
    final subs = topLocalSubstitutes(
        model: 'ABC', categoryHint: '电阻', inventory: inv, topN: 2);
    expect(subs, hasLength(2));
  });

  test('无 categoryHint（C 号行）退化为仅近型号', () {
    final inv = [
      comp(id: 1, cid: 'C1', model: 'STM32F103C8T6', category: '电阻'), // 型号近但分类无关
      comp(id: 2, cid: 'C2', model: 'SOMETHING-ELSE', category: '单片机'), // 型号远
    ];
    final subs = topLocalSubstitutes(model: 'STM32F103C8T6', inventory: inv);
    expect(ids(subs), [1]); // 只保留近型号
    expect(subs.single.reason, contains('型号相近'));
  });

  test('空库存 / 空型号 / 全过滤 → 空结果', () {
    expect(topLocalSubstitutes(model: 'X', inventory: const []), isEmpty);
    expect(
        topLocalSubstitutes(model: '  ', categoryHint: '电阻', inventory: [
          comp(id: 1, cid: 'C1', model: 'X', category: '电阻'),
        ]),
        isEmpty);
    expect(
        topLocalSubstitutes(model: 'X', categoryHint: '电阻', inventory: [
          comp(id: 1, cid: 'C1', model: 'X', category: '电阻', quantity: 0),
        ]),
        isEmpty);
  });
}
