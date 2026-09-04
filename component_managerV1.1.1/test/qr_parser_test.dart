import 'package:component_manager/core/utils/qr_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('qr_parser 立创花括号格式', () {
    const lcscSample =
        '{on:SO26081518766,pc:C2977076,pm:XL-1608UPC-06,qty:250,mc:,cc:1,pdi:231298193,hp:11}';

    test('真实样例解析出 cid / model / qty', () {
      final r = parseQr(lcscSample);
      expect(r.cid, 'C2977076');
      expect(r.model, 'XL-1608UPC-06');
      expect(r.qty, 250);
    });

    test('空值字段 mc: 不偏移后续字段', () {
      final r = parseQr(lcscSample);
      expect(r.cid, 'C2977076'); // 若 md: 偏移则这里会出错
      expect(r.model, 'XL-1608UPC-06');
    });

    test('缺 qty 时返回 null（UI 默认 1）', () {
      final r = parseQr('{pc:C11111,pm:RES-0805-10K}');
      expect(r.cid, 'C11111');
      expect(r.model, 'RES-0805-10K');
      expect(r.qty, isNull);
    });

    test('pc 为空但 pm 形如 CID 时兜底 cid', () {
      final r = parseQr('{pc:,pm:C123456}');
      expect(r.cid, 'C123456');
      expect(r.model, 'C123456');
    });

    test('首尾空白被 trim', () {
      final r = parseQr('  $lcscSample  ');
      expect(r.cid, 'C2977076');
      expect(r.model, 'XL-1608UPC-06');
    });
  });

  group('qr_parser 兜底格式', () {
    test('纯 CID 一行', () {
      final r = parseQr('C2977076');
      expect(r.cid, 'C2977076');
      expect(r.model, isNull);
    });

    test('URL 参数 pc= & pm=', () {
      final r = parseQr('https://item.szlcsc.com/pc=C2977076&pm=XL-1608UPC-06');
      expect(r.cid, 'C2977076');
      expect(r.model, 'XL-1608UPC-06');
    });

    test('两行 CID+型号', () {
      final r = parseQr('C2977076\nXL-1608UPC-06');
      expect(r.cid, 'C2977076');
      expect(r.model, 'XL-1608UPC-06');
    });

    test('仅型号兜底', () {
      final r = parseQr('XL-1608UPC-06');
      expect(r.cid, isNull);
      expect(r.model, 'XL-1608UPC-06');
    });

    test('空串返回空结果', () {
      final r = parseQr('');
      expect(r.cid, isNull);
      expect(r.model, isNull);
    });
  });
}