import 'dart:io';

import 'package:component_manager/core/config/constants.dart';
import 'package:component_manager/core/services/lcsc_lookup.dart';
import 'package:flutter_test/flutter_test.dart';

/// 立创国际站 C 号解析契约。fixture 为线上 C25704 商品页真实快照。
/// 分类映射返回值必须在 [inventoryCategories]（与 classifier 同一约束）。
void main() {
  final html = File('test/fixtures/lcsc_c25704.html').readAsStringSync();

  group('parseLcscPage', () {
    test('C25704 商品页 → 提取型号/品牌/分类/封装/简介/PDF', () {
      final info = parseLcscPage(html);
      expect(info, isNotNull);
      expect(info!.productCode, 'C25704');
      expect(info.productModel, '1210W3J0563T5E');
      expect(info.brandName, 'UNI-ROYAL');
      expect(info.catalogName, contains('Resistor'));
      expect(info.package, '1210');
      expect(info.description, contains('56k'));
      expect(info.datasheetUrl, startsWith('https://datasheet.lcsc.com'));
    });

    test('空 / 非商品页 HTML → null', () {
      expect(parseLcscPage(''), isNull);
      expect(parseLcscPage('<html><body>404</body></html>'), isNull);
      expect(parseLcscPage('<script id="__NEXT_DATA__">not json</script>'),
          isNull);
      // 有 __NEXT_DATA__ 但无 webData（如登录页）
      const noProduct =
          '<script id="__NEXT_DATA__" type="application/json">{"props":{}}</script>';
      expect(parseLcscPage(noProduct), isNull);
    });
  });

  group('lookupLcsc（注入 fetch）', () {
    test('成功：走解析返回数据', () async {
      final info = await lookupLcsc('c25704',
          fetchImpl: (_) async => html);
      expect(info, isNotNull);
      expect(info!.productModel, '1210W3J0563T5E');
    });

    test('网络异常 → null', () async {
      final info = await lookupLcsc('C25704',
          fetchImpl: (_) async => throw const SocketException('offline'));
      expect(info, isNull);
    });

    test('非 200（fetch 抛）→ null', () async {
      final info =
          await lookupLcsc('C25704', fetchImpl: (_) async => throw StateError('404'));
      expect(info, isNull);
    });

    test('非 C 号直接拒绝，不发请求', () async {
      var called = false;
      final info = await lookupLcsc('STMF103',
          fetchImpl: (_) async {
            called = true;
            return html;
          });
      expect(info, isNull);
      expect(called, isFalse);
    });
  });

  group('isLcscCode / normalizeLcscCode', () {
    test('合法 C 号（大小写/空白宽容）', () {
      expect(isLcscCode('C25704'), isTrue);
      expect(isLcscCode(' c25704 '), isTrue);
      expect(isLcscCode('C2977076'), isTrue);
      expect(normalizeLcscCode(' c25704 '), 'C25704');
    });
    test('非法', () {
      expect(isLcscCode('C123'), isFalse); // 少于 5 位
      expect(isLcscCode('STM32'), isFalse);
      expect(isLcscCode('C2570A'), isFalse);
      expect(isLcscCode(''), isFalse);
    });
  });

  group('categoryFromLcsc（catalog → 应用分类）', () {
    // 关键字直命中
    test('电阻/电容/单片机/LED', () {
      expect(categoryFromLcsc('Chip Resistor - Surface Mount'), '电阻');
      expect(categoryFromLcsc('Multilayer Ceramic Capacitors MLCC - SMD'),
          '电容');
      expect(categoryFromLcsc('Microcontrollers / Microprocessors - MCU'),
          '单片机');
      expect(categoryFromLcsc('Light Emitting Diodes (LED)'), 'LED');
      expect(categoryFromLcsc('Voltage Regulators - LDO'), '电源管理');
      expect(categoryFromLcsc('DC-DC Converters'), '电源管理');
      expect(categoryFromLcsc('Pin Headers'), '排针排母');
      expect(categoryFromLcsc('USB Connectors'), 'USB');
      expect(categoryFromLcsc('Wire to Board Connectors'), '连接器');
    });

    test('未命中 catalog 时按型号 hint 兜底 classify', () {
      expect(categoryFromLcsc('Cable Assemblies', hint: 'stm32f103'),
          '单片机');
    });

    test('catalog 与 hint 都拿不准 → 其他', () {
      expect(categoryFromLcsc('Cable Assemblies', hint: 'XYZ-UNKNOWN'), '其他');
      expect(categoryFromLcsc(null), '其他');
    });

    test('返回值必须 ∈ inventoryCategories', () {
      for (final c in ['Chip Resistor - Surface Mount', 'LED', 'Cable Assemblies',
          'Microcontrollers / Microprocessors - MCU', 'Battery Holders']) {
        expect(inventoryCategories, contains(categoryFromLcsc(c, hint: 'hint')));
      }
    });
  });
}
