import 'package:component_manager/core/config/constants.dart';
import 'package:component_manager/core/utils/classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('分类优先级冲突（关键）：STM32 应为单片机而非 IC', () {
    test('STM32F103C8 → 单片机', () {
      expect(classify('STM32F103C8'), '单片机');
    });
    test('ESP32 / ATmega328 → 单片机', () {
      expect(classify('ESP32-WROOM'), '单片机');
      expect(classify('ATmega328P'), '单片机');
    });
  });

  group('接口芯片优先于宽泛 IC 和连接器', () {
    test('CH340 → 接口芯片', () => expect(classify('CH340G'), '接口芯片'));
    test('MAX232 / RS232 → 接口芯片', () {
      expect(classify('MAX232'), '接口芯片');
      expect(classify('RS232 电平转换'), '接口芯片');
    });
  });

  group('USB / Type-C 归类', () {
    test('USB3.1 → 接口芯片', () => expect(classify('USB3.1'), '接口芯片'));
    test('Type-C 连接器 → 连接器', () {
      expect(classify('USB-C 连接器'), '连接器');
    });
  });

  group('基础元件分类', () {
    test('RC 0603 电阻 → 电阻', () => expect(classify('RC-0603FR-10KL'), '电阻'));
    test('CL 电容 → 电容', () => expect(classify('CL-0805-10uF'), '电容'));
    test('电解电容 → 电容', () => expect(classify('铝电解电容'), '电容'));
    test('未知 XYZ → 其他', () => expect(classify('XYZ-UNKNOWN'), '其他'));
  });

  group('回归：返回值必须 ∈ inventoryCategories', () {
    final samples = [
      'STM32F103C8', 'CH340G', 'MAX232', 'RC-0603FR-10KL', 'CL-0805-10uF',
      'XL-1608UPC-06', 'LED-RGB', 'LM358', 'LM393', '74HC08', 'AT24C02',
      'S8050', 'SS34', 'MOSFET-IRF540', 'IGBT-XX', 'TLP521', 'SRD-05VDC',
      '12.000MHz 晶振', '排针 2.54', 'USB-C 连接器', 'FUSE-2A', '轻触开关',
      'CR2032', 'DHT11', 'MPU6050', 'TPS5430', 'ABC-完全未知',
    ];
    for (final s in samples) {
      test('classify($s) 命中合法分类', () {
        final c = classify(s);
        expect(inventoryCategories, contains(c), reason: '$s → $c 不在分类表');
      });
    }
  });
}