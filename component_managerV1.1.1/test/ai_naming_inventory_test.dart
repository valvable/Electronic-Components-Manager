import 'dart:convert';

import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/ai_client.dart';
import 'package:component_manager/core/services/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v1.1.x AI 扩展：命名（单条/批量）解析、库存替代 prompt/映射、
/// AI2 增强配置回退、分类建议新增 model/brand 字段解析。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  String envelope(String content) =>
      '{"choices":[{"message":{"content":${jsonEncode(content)}}}]}';

  AiFetch echo(
    Future<String> Function(Uri uri, Map<String, String> headers, String body)
        impl,
  ) {
    return (uri, {required headers, required body}) => impl(uri, headers, body);
  }

  group('parseAiModelSuggestion', () {
    test('JSON 主体 + brand/category 宽容', () {
      final s = parseAiModelSuggestion(
          '{"model":"STM32F103C8T6","brand":"ST","category":"单片机"}')!;
      expect(s.model, 'STM32F103C8T6');
      expect(s.brand, 'ST');
      expect(s.category, '单片机');
    });
    test('裸文本兜底为规范型号；过长/多行判无效', () {
      expect(parseAiModelSuggestion('RC0402FR-0710KL')!.model,
          'RC0402FR-0710KL');
      expect(parseAiModelSuggestion(''), isNull);
      expect(parseAiModelSuggestion('第一行\n第二行'), isNull);
      expect(parseAiModelSuggestion('{"brand":"只有品牌"}'), isNull);
    });
    test('围栏包裹可解；前缀+围栏混合体判无效（不做病态括号平衡）', () {
      final s = parseAiModelSuggestion('```json\n{"model":"LM358"}\n```')!;
      expect(s.model, 'LM358');
      expect(parseAiModelSuggestion('结果：\n```json\n{"model":"X"}\n```'),
          isNull);
    });
  });

  group('namingMessages / namingBatchMessages', () {
    test('单条含原始名称与 C 号', () {
      final m = namingMessages(rawModel: '贴片电阻 10K 1% 0805', cid: 'C25704');
      expect(m.first['content'], contains('厂商标准型号'));
      expect(m.last['content'], contains('贴片电阻 10K 1% 0805'));
      expect(m.first['content'], contains('C25704'));
    });
    test('批量：编号|名称行 + items 约定', () {
      final m = namingBatchMessages([
        (code: 'C1', raw: '电阻 10K'),
        (code: 'C2', raw: 'CL21 105K'),
      ]);
      expect(m.first['content'], contains('{"items":[{"code"'));
      expect(m.last['content'], contains('C1|电阻 10K'));
      expect(m.last['content'], contains('C2|CL21 105K'));
    });
  });

  test('parseAiModelBatch：大写归一 code、缺 model 跳过', () {
    final map = parseAiModelBatch(
        '{"items":[{"code":" c1 ","model":"RC0805","brand":"Yageo"},{"code":"C2"}]}');
    expect(map.keys, {'C1'});
    expect(map['C1']!.model, 'RC0805');
    expect(map['C1']!.brand, 'Yageo');
    expect(parseAiModelBatch('垃圾'), isEmpty);
  });

  test('aiNameCartItems：注入 seam 端到端', () async {
    final db = await AppDatabase.openAt(inMemoryDatabasePath);
    addTearDown(db.close);
    final store = SettingsStore(db);
    await store.saveAiConfig(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm');
    final map = await aiNameCartItems(
      store,
      entries: const [(code: 'C1', raw: '厚声 10K 电阻')],
      fetchImpl: echo((uri, headers, body) async =>
          envelope('{"items":[{"code":"C1","model":"RC0603FR-0710KL"}]}')),
    );
    expect(map['C1']!.model, 'RC0603FR-0710KL');
  });

  group('库存替代方向', () {
    test('prompt 含清单逐字约束与 JSON 格式', () {
      final m = inventorySubstituteMessages(
        model: 'LM358N',
        qty: 5,
        category: '放大器',
        inventoryBrief: ['LM358P|放大器|DIP-8|12', 'NE5532|放大器|DIP-8|3'],
      );
      final sys = m.first['content']!;
      expect(sys, contains('逐字'));
      expect(sys, contains('只输出 JSON'));
      expect(m.last['content'], contains('LM358P|放大器|DIP-8|12'));
    });

    test('aiSubstituteFromInventoryFromSettings：映射回库存、清单外候选丢弃',
        () async {
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final store = SettingsStore(db);
      await store.saveAiConfig(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm');
      final plan = await aiSubstituteFromInventoryFromSettings(
        store,
        model: 'LM358N',
        qty: 5,
        inventoryBrief: ['LM358P|放大器|DIP-8|12'],
        modelToId: {'lm358p': 7},
        fetchImpl: echo((uri, headers, body) async => envelope(
            '{"original":{"specs":{"供电电压":"±15V"}},"suggestions":['
            '{"model":"LM358P","risk":"可直接替代"},'
            '{"model":"清单没有的型号","risk":"需确认"}]}')),
      );
      expect(plan, isNotNull);
      expect(plan!.suggestions, hasLength(1)); // 清单外的被丢弃
      expect(plan.suggestions.single.model, 'LM358P');
      expect(plan.originalSpecs['供电电压'], '±15V');
    });

    test('全部候选对不上库存 → null（无结果不算错误）', () async {
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final store = SettingsStore(db);
      await store.saveAiConfig(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm');
      final plan = await aiSubstituteFromInventoryFromSettings(
        store,
        model: 'X',
        qty: 1,
        inventoryBrief: const [],
        modelToId: const {},
        fetchImpl: echo((uri, headers, body) async =>
            envelope('[{"model":"Y"}]')),
      );
      expect(plan, isNull);
    });
  });

  test('parseAiClassify 读取 model/brand', () {
    final s = parseAiClassify(
        '{"reason":"R 前缀","category":"电阻","model":"RC0805FR","brand":"风华"}',
        allowed: const ['电阻'])!;
    expect(s.model, 'RC0805FR');
    expect(s.brand, '风华');
  });

  test('loadSubstituteAiConfig：AI2 填全用 AI2，否则回退 AI1', () async {
    final db = await AppDatabase.openAt(inMemoryDatabasePath);
    addTearDown(db.close);
    final store = SettingsStore(db);
    await store.saveAiConfig(baseUrl: 'https://a1/v1', apiKey: 'k1', model: 'm1');

    var got = await store.loadSubstituteAiConfig();
    expect(got.baseUrl, 'https://a1/v1'); // AI2 未配置 → 回退

    await store.saveAi2Config(baseUrl: '', apiKey: 'x', model: '');
    got = await store.loadSubstituteAiConfig();
    expect(got.baseUrl, 'https://a1/v1'); // AI2 半配置 → 仍回退

    await store.saveAi2Config(baseUrl: 'https://a2/v1', apiKey: 'k2', model: 'm2');
    got = await store.loadSubstituteAiConfig();
    expect(got.baseUrl, 'https://a2/v1');
    expect(got.model, 'm2');
  });

  test('替换请求走 AI2、分类请求走 AI1（按 body 的 model 字段区分）', () async {
    final db = await AppDatabase.openAt(inMemoryDatabasePath);
    addTearDown(db.close);
    final store = SettingsStore(db);
    await store.saveAiConfig(baseUrl: 'https://a1/v1', apiKey: 'k1', model: 'm1');
    await store.saveAi2Config(baseUrl: 'https://a2/v1', apiKey: 'k2', model: 'm2');

    String? seenModel;
    Future<String> capture(Uri uri, Map<String, String> h, String body) async {
      seenModel = (jsonDecode(body) as Map)['model'] as String;
      // 按请求内容分派：替代提示词回数组方案，分类提示词回 category。
      return body.contains('替代')
          ? envelope('[{"model":"X"}]')
          : envelope('{"category":"其他"}');
    }

    await aiRecommendSubstitutes(store,
        model: 'A', qty: 1, fetchImpl: echo(capture));
    expect(seenModel, 'm2'); // 替换 → AI2

    await aiClassifyFromSettings(
        store,
        model: 'A',
        categories: const ['其他'],
        fetchImpl: echo(capture));
    expect(seenModel, 'm1'); // 分类 → AI1
  });
}
