// Completer 供超时用例使用（永不完成的响应 = 服务端连上不回包）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/ai_client.dart';
import 'package:component_manager/core/services/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// AI 客户端：uri 拼接 / 请求体 / 注入 fetchImpl 的分层异常 / 容错解析 /
/// 提示词内容 / 功能级入口（ffi settings）聚合与 AiParseException 转换。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const okBody =
      '{"choices":[{"message":{"content":"回复 OK"}}]}';

  /// 把「内容 JSON」包进 chat-completions 响应外壳。
  String envelope(String content) =>
      '{"choices":[{"message":{"content":${jsonEncode(content)}}}]}';

  AiFetch echo(
    Future<String> Function(Uri uri, Map<String, String> headers, String body)
        impl) {
    return (uri, {required headers, required body}) => impl(uri, headers, body);
  }

  group('chatCompletionsUri', () {
    test('裸 host 补 https', () {
      expect(chatCompletionsUri('api.openai.com/v1').toString(),
          'https://api.openai.com/v1/chat/completions');
    });
    test('带 scheme 剥尾斜杠再拼', () {
      expect(chatCompletionsUri('https://api.openai.com/v1/').toString(),
          'https://api.openai.com/v1/chat/completions');
    });
    test('已含 /chat/completions 直接用', () {
      expect(chatCompletionsUri('https://x.example/v1/chat/completions').toString(),
          'https://x.example/v1/chat/completions');
    });
    test('内网 http scheme 保留', () {
      expect(chatCompletionsUri('http://192.168.1.10:11434/v1').toString(),
          'http://192.168.1.10:11434/v1/chat/completions');
    });
    test('空白前后缀剥除', () {
      expect(chatCompletionsUri('  https://api.deepseek.com  ').toString(),
          'https://api.deepseek.com/chat/completions');
    });
  });

  group('buildChatBody', () {
    test('含 model/messages/temperature；maxTokens 缺省不出现 key', () {
      final body = buildChatBody(
          model: 'gpt-4o-mini',
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ]);
      expect(body['model'], 'gpt-4o-mini');
      expect(body['temperature'], 0.2);
      expect(body['messages'], isA<List<dynamic>>());
      expect(body.containsKey('max_tokens'), isFalse);

      final withMax = buildChatBody(model: 'm', messages: const [], maxTokens: 100);
      expect(withMax['max_tokens'], 100);
    });
  });

  group('aiChat（注入 fetchImpl）', () {
    test('成功返回 message.content（剥空白）', () async {
      final text = await aiChat(
        const AiConfig(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm'),
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        fetchImpl: echo((uri, headers, body) async => '{"choices":[{"message":{"content":"  回复 OK  "}}]}'),
      );
      expect(text, '回复 OK');
    });

    test('content 缺省回退 choices[0].text', () async {
      final text = await aiChat(
        const AiConfig(baseUrl: 'https://x/v1', model: 'm'),
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        fetchImpl: echo((uri, headers, body) async => '{"choices":[{"text":"ok"}]}'),
      );
      expect(text, 'ok');
    });

    test('请求体含 model/messages，uri 正确', () async {
      Uri? gotUri;
      String? gotBody;
      await aiChat(
        const AiConfig(
            baseUrl: 'https://api.example/v1', apiKey: 'k', model: 'deepseek-chat'),
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        fetchImpl: echo((uri, headers, body) async {
          gotUri = uri;
          gotBody = body;
          return okBody;
        }),
      );
      expect(gotUri, Uri.parse('https://api.example/v1/chat/completions'));
      final decoded = jsonDecode(gotBody!);
      expect(decoded['model'], 'deepseek-chat');
      expect((decoded['messages'] as List).single['content'], 'hi');
    });

    test('apiKey 非空发 Bearer；为空不发 Authorization', () async {
      Map<String, String>? got;
      await aiChat(
        const AiConfig(baseUrl: 'https://x/v1', model: 'm'),
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        fetchImpl: echo((uri, headers, body) async {
          got = headers;
          return okBody;
        }),
      );
      expect(got!['Authorization'], isNull);

      await aiChat(
        const AiConfig(baseUrl: 'https://x/v1', apiKey: 'sk-1', model: 'm'),
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        fetchImpl: echo((uri, headers, body) async {
          got = headers;
          return okBody;
        }),
      );
      expect(got!['Authorization'], 'Bearer sk-1');
    });

    test('注入抛 AiHttpException → 原样透出（detail 保留）', () async {
      await expectLater(
        aiChat(
          const AiConfig(baseUrl: 'https://x/v1', model: 'm'),
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          fetchImpl: echo((uri, headers, body) async {
            throw AiHttpException(401, detail: 'bad key');
          }),
        ),
        throwsA(isA<AiHttpException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.detail, 'detail', 'bad key')),
      );
    });

    test('注入抛 SocketException → AiNetworkException', () async {
      await expectLater(
        aiChat(
          const AiConfig(baseUrl: 'https://x/v1', model: 'm'),
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          fetchImpl: echo((uri, headers, body) async {
            throw const SocketException('conn refused');
          }),
        ),
        throwsA(isA<AiNetworkException>()),
      );
    });

    test('配置空 model / baseUrl → AiConfigException', () async {
      await expectLater(
        aiChat(
          const AiConfig(baseUrl: '', apiKey: 'k', model: ''),
          messages: const [],
        ),
        throwsA(isA<AiConfigException>()),
      );
    });

    test('响应无正文 → AiParseException', () async {
      await expectLater(
        aiChat(
          const AiConfig(baseUrl: 'https://x/v1', model: 'm'),
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          fetchImpl: echo((uri, headers, body) async => '不是 JSON'),
        ),
        throwsA(isA<AiParseException>()),
      );
    });

    test('超过 timeout 无响应 → AiTimeoutException（不再无限转圈）', () async {
      final never = Completer<String>(); // 永不完成：模拟连上不回包
      await expectLater(
        aiChat(
          const AiConfig(baseUrl: 'https://x/v1', model: 'm'),
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          timeout: const Duration(milliseconds: 30),
          fetchImpl: echo((uri, headers, body) => never.future),
        ),
        throwsA(isA<AiTimeoutException>()),
      );
    });
  });

  group('aiChatFromSettings（ffi）', () {
    test('未配置 → AiConfigException', () async {
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final store = SettingsStore(db);
      await expectLater(
        aiChatFromSettings(store, messages: const [
          {'role': 'user', 'content': 'hi'},
        ]),
        throwsA(isA<AiConfigException>()),
      );
    });

    test('已配置 → 经注入 seam 返回 content', () async {
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final store = SettingsStore(db);
      await store.saveAiConfig(
          baseUrl: 'https://api.example/v1', apiKey: 'k', model: 'm');
      final text = await aiChatFromSettings(
        store,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        fetchImpl: echo((uri, headers, body) async => okBody),
      );
      expect(text, '回复 OK');
    });
  });

  group('decodeModelJsonText', () {
    test('围栏 / 前缀垃圾 / 非 JSON 返回 null', () {
      expect(decodeModelJsonText('{"a":1}'), {'a': 1});
      expect(decodeModelJsonText('```json\n{"a":1}\n```'), {'a': 1});
      expect(decodeModelJsonText('```\n[1,2]\n```'), [1, 2]);
      expect(decodeModelJsonText('结果如下：\n{"a":1}'), {'a': 1}); // 首个 { 子串
      expect(decodeModelJsonText('结果如下：\n[1,2]'), [1, 2]);
      expect(decodeModelJsonText('不是 JSON'), isNull);
      expect(decodeModelJsonText(''), isNull);
    });
  });

  group('extractAssistantText', () {
    test('content / text 回退 / 异常返回 null', () {
      expect(extractAssistantText('{"choices":[{"message":{"content":" hi "}}]}'), 'hi');
      expect(extractAssistantText('{"choices":[{"text":"ok"}]}'), 'ok');
      expect(extractAssistantText('{"choices":[]}'), isNull);
      expect(extractAssistantText('{}'), isNull);
      expect(extractAssistantText('not json'), isNull);
    });
  });

  group('parseAiClassify', () {
    const allowed = ['电阻', '电容', 'IC'];
    test('合法分类 + 宽容字段', () {
      final sug = parseAiClassify(
          '{"category":"电容","package":"0805","note":"10uF","reason":"X","confidence":0.9}',
          allowed: allowed)!;
      expect(sug.category, '电容');
      expect(sug.package, '0805');
      expect(sug.note, '10uF');
      expect(sug.confidence, 0.9);
    });
    test('未知分类仍返回（调用方兜底）', () {
      final sug = parseAiClassify('{"category":"电阻器"}', allowed: allowed)!;
      expect(sug.category, '电阻器');
    });
    test('裸正文恰为 allowed → 仅分类', () {
      final sug = parseAiClassify('电容', allowed: allowed)!;
      expect(sug.category, '电容');
      expect(sug.package, isNull);
    });
    test('裸正文不在 allowed / 垃圾 → null', () {
      expect(parseAiClassify('元器件', allowed: allowed), isNull);
      expect(parseAiClassify('不是 json', allowed: allowed), isNull);
      expect(parseAiClassify('{"note":"无分类"}', allowed: allowed), isNull);
    });
  });

  group('parseAiSubstitutes', () {
    test('顶层数组', () {
      final arr = parseAiSubstitutes('[{"model":"A1","reason":"同封装"}]')!;
      expect(arr.single.model, 'A1');
      expect(arr.single.reason, '同封装');
    });
    test('{"suggestions":[...]} 包裹', () {
      final wrapped =
          parseAiSubstitutes('{"suggestions":[{"model":"B1","confidence":0.8}]}')!;
      expect(wrapped.single.model, 'B1');
      expect(wrapped.single.confidence, 0.8);
    });
    test('单对象', () {
      final single = parseAiSubstitutes('{"model":"C1","brand":"ST"}')!;
      expect(single.single.brand, 'ST');
    });
    test('无有效条目 / 垃圾 → null', () {
      expect(parseAiSubstitutes('{"suggestions":[{"reason":"x"}]}'), isNull);
      expect(parseAiSubstitutes('不是 json'), isNull);
      expect(parseAiSubstitutes('{}'), isNull);
    });
  });

  group('parseAiSubstitutePlan', () {
    test('新格式：original.specs + 候选 specs/risk/diff', () {
      final plan = parseAiSubstitutePlan(
          '{"original":{"model":"RC0603FR","specs":{"阻值":"10kΩ","精度":"±1%" }},'
          '"suggestions":[{"model":"ERJ-3EKF1002","specs":{"阻值":"10kΩ","精度":"±1%"},'
          '"risk":"可直接替代","diff":"卷盘包装不同","confidence":0.92}]}')!;
      expect(plan.originalSpecs['阻值'], '10kΩ');
      final s = plan.suggestions.single;
      expect(s.model, 'ERJ-3EKF1002');
      expect(s.specs['精度'], '±1%');
      expect(s.risk, '可直接替代');
      expect(s.diff, '卷盘包装不同');
      expect(s.confidence, 0.92);
    });
    test('旧裸数组兼容：originalSpecs 为空', () {
      final plan = parseAiSubstitutePlan('[{"model":"A1"}]')!;
      expect(plan.originalSpecs, isEmpty);
      expect(plan.suggestions.single.model, 'A1');
    });
    test('specs List-of-{name,value} / {k,v} 形态亦收', () {
      final plan = parseAiSubstitutePlan(
          '{"original":{"specs":[{"name":"容值","value":"100nF"}]},'
          '"suggestions":[{"model":"X1","specs":[{"k":"容值","v":"100nF"}]}]}')!;
      expect(plan.originalSpecs['容值'], '100nF');
      expect(plan.suggestions.single.specs['容值'], '100nF');
    });
    test('无候选 / 垃圾 → null', () {
      expect(parseAiSubstitutePlan('{"original":{"specs":{"a":"b"}}}'), isNull);
      expect(parseAiSubstitutePlan('不是 json'), isNull);
    });
  });

  group('提示词', () {
    test('classifyMessages 含分类清单与 JSON 要求', () {
      final msgs = classifyMessages(
          model: 'STM32F103', cid: 'C12345', categories: const ['电阻', '单片机']);
      final sys = msgs.first['content']!;
      expect(sys, contains('电阻'));
      expect(sys, contains('单片机'));
      expect(sys, contains('只输出 JSON'));
      expect(msgs.last['content'], contains('STM32F103'));
    });

    test('substituteMessages 含位号与本地候选、缺料量', () {
      final msgs = substituteMessages(
          model: 'RC0603FR-0710KL', qty: 5, designation: 'R12', localModels: const ['旧件']);
      expect(msgs.first['content'], contains('R12'));
      expect(msgs.first['content'], contains('旧件'));
      expect(msgs.last['content'], contains('RC0603FR-0710KL'));
      expect(msgs.last['content'], contains('5'));
    });

    test('classifyMessages：依据在前 + 前缀规则 + 易混辨析 + 逐字匹配', () {
      final sys = classifyMessages(
              model: 'M', categories: const ['电阻', '单片机'])
          .first['content']!;
      expect(sys, contains('"reason"')); // reason 键在 category 之前（链式推理）
      expect(sys, contains('"reason":"识别依据","category"'));
      expect(sys, contains('逐字'));
      expect(sys, contains('易混辨析'));
      expect(sys, contains('STM32F103C8T6')); // few-shot
    });

    test('substituteMessages：电气参数协议（original/specs/risk）', () {
      final sys = substituteMessages(model: 'X', qty: 1).first['content']!;
      expect(sys, contains('"original"'));
      expect(sys, contains('specs'));
      expect(sys, contains('可直接替代'));
      expect(sys, contains('需确认'));
      expect(sys, contains('不建议'));
    });
  });

  group('功能级入口（ffi + 注入 seam）', () {
    Future<SettingsStore> newStore() async {
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final store = SettingsStore(db);
      await store.saveAiConfig(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm');
      return store;
    }

    test('aiClassifyFromSettings：成功返回建议', () async {
      final store = await newStore();
      final sug = await aiClassifyFromSettings(
        store,
        model: 'STM32F103',
        categories: const ['电阻', '单片机'],
        fetchImpl:
            echo((uri, headers, body) async => envelope('{"category":"单片机","confidence":0.9}')),
      );
      expect(sug.category, '单片机');
      expect(sug.confidence, 0.9);
    });

    test('aiClassifyFromSettings：解析失败 → AiParseException', () async {
      final store = await newStore();
      await expectLater(
        aiClassifyFromSettings(
          store,
          model: 'STM32F103',
          categories: const ['电阻', '单片机'],
          fetchImpl: echo((uri, headers, body) async => '我不确定'),
        ),
        throwsA(isA<AiParseException>()),
      );
    });

    test('aiRecommendSubstitutes：成功返回列表', () async {
      final store = await newStore();
      final list = await aiRecommendSubstitutes(
        store,
        model: 'C25704',
        qty: 5,
        fetchImpl: echo(
            (uri, headers, body) async => envelope('[{"model":"替代件","reason":"ok"}]')),
      );
      expect(list.single.model, '替代件');
    });

    test('aiRecommendSubstitutes：空列表 → AiParseException', () async {
      final store = await newStore();
      await expectLater(
        aiRecommendSubstitutes(
          store,
          model: 'C25704',
          qty: 5,
          fetchImpl: echo((uri, headers, body) async => envelope('{"suggestions":[]}')),
        ),
        throwsA(isA<AiParseException>()),
      );
    });

    test('aiRecommendSubstitutePlanFromSettings：带电气参数方案', () async {
      final store = await newStore();
      final plan = await aiRecommendSubstitutePlanFromSettings(
        store,
        model: 'RC0603FR',
        qty: 5,
        fetchImpl: echo((uri, headers, body) async => envelope(
            '{"original":{"specs":{"阻值":"10kΩ"}},'
            '"suggestions":[{"model":"S1","risk":"可直接替代"}]}')),
      );
      expect(plan.originalSpecs['阻值'], '10kΩ');
      expect(plan.suggestions.single.risk, '可直接替代');
    });
  });

  group('friendlyAiError', () {
    test('异常类型 → 集中文案', () {
      expect(friendlyAiError(AiConfigException(['Base URL'])), contains('设置'));
      expect(friendlyAiError(AiHttpException(401)), contains('API Key'));
      expect(friendlyAiError(AiHttpException(500, detail: 'boom')), contains('HTTP 500'));
      expect(friendlyAiError(AiHttpException(500, detail: 'boom')), contains('boom'));
      expect(friendlyAiError(const AiNetworkException('x')), contains('无法连接'));
      expect(friendlyAiError(const AiTimeoutException(90)), contains('超时'));
      expect(friendlyAiError(AiParseException()), contains('无法解析'));
      expect(friendlyAiError(StateError('zz')), contains('AI 查询失败'));
    });
  });
}
