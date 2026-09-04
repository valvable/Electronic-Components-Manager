import 'package:component_manager/core/utils/fuzzy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('levenshtein', () {
    test('相同串距离 0', () {
      expect(levenshtein('STM32F103', 'STM32F103'), 0);
    });
    test('接近但不同的型号距离小', () {
      expect(levenshtein('STM32F103', 'STM32F103C8'), lessThanOrEqualTo(3));
    });
    test('相差很远距离大', () {
      expect(levenshtein('STM32F103', 'led-rgb'), greaterThan(4));
    });
    test('空串边界', () {
      expect(levenshtein('', 'abc'), 3);
      expect(levenshtein('abc', ''), 3);
    });
  });

  group('similarityScore / buildSearchClause', () {
    test('取型号与 cid 二者较小值', () {
      final s = similarityScore('XL-1608UPC-06', 'C2977076', 'C2977076');
      expect(s, 0); // cid 精确命中
    });
    test('纯 CID 只查 cid 列', () {
      final (where, args) = buildSearchClause('C2977076');
      expect(where, 'cid LIKE ?');
      expect(args, ['%C2977076%']);
    });
    test('非纯 CID 查 model 或 cid 两列', () {
      final (where, args) = buildSearchClause('STM32');
      expect(where, contains('model LIKE ?'));
      expect(where, contains('cid LIKE ?'));
      expect(args.length, 2);
    });
  });
}