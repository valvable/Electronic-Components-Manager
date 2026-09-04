import 'package:component_manager/core/utils/component_grouping.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';

/// 同型号聚合：分组键、总量、品牌数、分类序、qty 排序按组总量。
void main() {
  Component c(
    int id,
    String model, {
    String cat = '电阻',
    String? brand,
    int qty = 5,
    int created = 100,
  }) =>
      Component(
        id: id,
        cid: 'C${100000 + id}',
        model: model,
        category: cat,
        brand: brand,
        quantity: qty,
        createdAt: created,
        updatedAt: created,
      );

  test('大小写/空白不敏感合并；不同分类不合并', () {
    final g = groupComponents([
      c(1, 'RC0805', brand: '国巨', qty: 10),
      c(2, 'rc0805 ', brand: '三星', qty: 5),
      c(3, 'RC0805', cat: '电容', qty: 7),
    ]);
    expect(g, hasLength(2));
    final res = g.firstWhere((x) => x.category == '电阻');
    expect(res.items, hasLength(2));
    expect(res.totalQty, 15);
    expect(res.brandCount, 2);
    expect(g.firstWhere((x) => x.category == '电容').totalQty, 7);
  });

  test('单行组 isSingle；空品牌与有名计为两种写法', () {
    final g = groupComponents([c(1, 'A'), c(2, 'A', brand: 'TDK')]);
    expect(g.single.items, hasLength(2));
    expect(g.single.isSingle, isFalse);
    expect(g.single.brandCount, 2); // '' 与 'TDK'
  });

  test('created_desc 按分类表顺序分区（表外分类垫底）', () {
    final g = groupComponents(
      [
        c(1, 'X', cat: '自定义A', created: 300),
        c(2, 'Y', cat: '电容', created: 100),
        c(3, 'Z', cat: '电阻', created: 200),
      ],
      categoryOrder: ['电阻', '电容'],
    );
    expect(g.map((e) => e.category), ['电阻', '电容', '自定义A']);
  });

  test('qty_desc 平铺按组总量排序（不受分类序影响）', () {
    final g = groupComponents(
      [
        c(1, 'small', cat: '电阻', qty: 5),
        c(2, 'big', cat: '电容', qty: 100),
        c(3, 'big2', cat: '电容', qty: 100),
        c(4, 'big', cat: '电容', qty: 50), // 与 C2 同组 → 总量 150
      ],
      sort: 'qty_desc',
      categoryOrder: ['电阻', '电容'],
    );
    expect(g.map((e) => e.totalQty), [150, 100, 5]);
    expect(g.first.model, 'big');
  });

  test('展示写法取更新时间最新的行的写法；条目按 created 降序', () {
    final newer =
        c(2, 'RC0805', created: 50, brand: 'B').copyWith(updatedAt: 500);
    final g = groupComponents([
      c(1, 'rc0805 ', created: 100),
      newer,
    ]);
    expect(g, hasLength(1)); // 大小写/空白归一后同组
    expect(g.single.model, 'RC0805'); // updatedAt 更晚的写法胜出
    expect(g.single.items.first.id, 1); // created 降序
  });
}
