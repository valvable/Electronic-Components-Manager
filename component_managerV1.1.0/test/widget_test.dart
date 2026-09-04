// 说明：本文件用于覆盖 `flutter create .` 自动生成的默认模板测试
// （模板引用不存在的 MyApp，会导致 `flutter test` 编译失败）。
// 放置纯逻辑单元测试：分类识别器 + 二维码解析器。
import 'package:flutter_test/flutter_test.dart';

import 'package:component_manager/utils/category_recognizer.dart';
import 'package:component_manager/utils/qr_code_parser.dart';

void main() {
  group('CategoryRecognizer 分类识别', () {
    test('电阻', () {
      expect(CategoryRecognizer.recognize('RC0603FR-070RL'),
          AppCategories.resistor);
      expect(CategoryRecognizer.recognize('R10'), AppCategories.resistor);
      expect(CategoryRecognizer.recognize('插件电阻'), AppCategories.resistor);
    });

    test('电容', () {
      expect(CategoryRecognizer.recognize('CL10B104KB8NNNC'),
          AppCategories.capacitor);
      expect(
          CategoryRecognizer.recognize('C0603X7R'), AppCategories.capacitor);
      expect(CategoryRecognizer.recognize('100nF 0805'), AppCategories.capacitor);
    });

    test('IC', () {
      expect(CategoryRecognizer.recognize('LM358DR'), AppCategories.ic);
      expect(CategoryRecognizer.recognize('MAX232'), AppCategories.ic);
      expect(
          CategoryRecognizer.recognize('STM32F103C8T6'), AppCategories.ic);
      expect(CategoryRecognizer.recognize('74HC595D'), AppCategories.ic);
    });

    test('二极管', () {
      expect(CategoryRecognizer.recognize('1N4007'), AppCategories.diode);
      expect(CategoryRecognizer.recognize('1N4148W'), AppCategories.diode);
      expect(CategoryRecognizer.recognize('肖特基二极管'), AppCategories.diode);
    });

    test('三极管', () {
      expect(CategoryRecognizer.recognize('S8050'), AppCategories.transistor);
      expect(CategoryRecognizer.recognize('SS8550'), AppCategories.transistor);
      expect(CategoryRecognizer.recognize('2N3904'), AppCategories.transistor);
    });

    test('连接器', () {
      expect(CategoryRecognizer.recognize('Header-2.54-2P'),
          AppCategories.connector);
      expect(
          CategoryRecognizer.recognize('USB-A母座'), AppCategories.connector);
      expect(CategoryRecognizer.recognize('XH2.54-2P 排针'),
          AppCategories.connector);
    });

    test('晶振', () {
      expect(CategoryRecognizer.recognize('X32250MSB4SI'),
          AppCategories.crystal);
      expect(CategoryRecognizer.recognize('16MHz 无源晶振'), AppCategories.crystal);
      expect(CategoryRecognizer.recognize('32.768kHz'), AppCategories.crystal);
    });

    test('其他', () {
      expect(CategoryRecognizer.recognize('FOO-BAR-123'), AppCategories.other);
      expect(CategoryRecognizer.recognize(''), AppCategories.other);
    });
  });

  group('QRCodeParser 二维码解析', () {
    test('纯 CID', () {
      final r = QRCodeParser.parse('C25704');
      expect(r.cid, 'C25704');
      expect(r.isValid, isTrue);
    });

    test('JSON 格式', () {
      final r = QRCodeParser.parse('{"cid":"C25704","model":"LM358"}');
      expect(r.cid, 'C25704');
      expect(r.model, 'LM358');
    });

    test('键值对格式（中文冒号/分号）', () {
      final r = QRCodeParser.parse('CID：C25704；型号：LM358');
      expect(r.cid, 'C25704');
      expect(r.model, 'LM358');
    });

    test('立创链接', () {
      final r = QRCodeParser.parse('https://item.szlcsc.com/25704.html');
      expect(r.cid, 'C25704');
    });

    test('纯型号文本', () {
      final r = QRCodeParser.parse('LM358DR');
      expect(r.cid, isNull);
      expect(r.model, 'LM358DR');
    });

    test('空内容', () {
      final r = QRCodeParser.parse('  ');
      expect(r.isValid, isFalse);
    });
  });
}
