/// OpenAI 兼容 `/chat/completions` AI 客户端（纯 Dart，零第三方依赖）。
///
/// 分层仿立创查料（lcsc_lookup.dart）：顶层函数 + 可选注入 seam + 独立纯解析函数。
/// 网络失败不吞 null（与立创查料场景不同——AI 兜底失败要明确告诉用户原因），
/// 用类型化 AiException 分层，UI 只需 `on AiException` + [friendlyAiError]。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/constants.dart';
import 'settings_store.dart';

/// 一次 AI 请求的静态配置（Base URL / 可选 Key / 模型名）。
class AiConfig {
  final String baseUrl;
  final String? apiKey;
  final String model;

  const AiConfig({required this.baseUrl, this.apiKey, required this.model});

  bool get hasKey => apiKey != null && apiKey!.trim().isNotEmpty;
}

/// 错误分层（UI 统一 catch [AiException] 映射文案）。
sealed class AiException implements Exception {
  const AiException();
}

/// 配置缺失（baseUrl / model 为空）——引导去设置页补配置。
class AiConfigException extends AiException {
  final List<String> missing;
  AiConfigException(this.missing);

  @override
  String toString() =>
      'AiConfigException(missing: ${missing.join(', ')})';
}

/// 网络层失败（socket / 超时 / 连接被拒等）。
class AiNetworkException extends AiException {
  final Object cause;
  const AiNetworkException(this.cause);

  @override
  String toString() => 'AiNetworkException($cause)';
}

/// 非 200 响应（[detail] 尽量取自响应体 error.message）。
class AiHttpException extends AiException {
  final int statusCode;
  final String? detail;
  AiHttpException(this.statusCode, {this.detail});

  @override
  String toString() => 'AiHttpException($statusCode${detail == null ? '' : ': $detail'})';
}

/// AI 返回内容无法解析（chat 响应无正文，或结构化字段不符合约定）。
class AiParseException extends AiException {
  @override
  String toString() => 'AiParseException';
}

/// 请求超时（连接后 [seconds] 秒内没拿到完整响应，已主动中止等待）。
class AiTimeoutException extends AiException {
  final int seconds;
  const AiTimeoutException(this.seconds);

  @override
  String toString() => 'AiTimeoutException(${seconds}s)';
}

/// 集中异常文案（功能失败提示 + 引导去设置页）。
String friendlyAiError(Object e) {
  if (e is AiConfigException) {
    return 'AI 未配置：请在「设置 → AI 查询」填写 Base URL 与模型名';
  }
  if (e is AiHttpException) {
    if (e.statusCode == 401 || e.statusCode == 403) {
      return 'AI 接口鉴权失败（HTTP ${e.statusCode}）：请检查设置页 API Key';
    }
    final detail = e.detail != null && e.detail!.isNotEmpty ? '：${e.detail}' : '';
    return 'AI 接口请求失败（HTTP ${e.statusCode}）$detail';
  }
  if (e is AiNetworkException) {
    return '无法连接 AI 服务：请检查网络与接口地址';
  }
  if (e is AiTimeoutException) {
    return 'AI 响应超时（超过 ${e.seconds} 秒），已中止等待：'
        '可稍后重试，或在「设置 → AI 查询」检查接口地址与模型名';
  }
  if (e is AiParseException) {
    return 'AI 返回内容无法解析，请重试';
  }
  return 'AI 查询失败：$e';
}

/// 网络 seam：低层函数可注入内存客户端（测试用），返回响应原始文本。
/// 实现负责把「服务端拒绝」以抛 [AiHttpException] 表达。
typedef AiFetch = Future<String> Function(
  Uri url, {
  required Map<String, String> headers,
  required String body,
});

/// 拼接 /chat/completions 端点。
/// - 剥尾斜杠；已含路径直接用；
/// - 无 scheme 前缀 `https://`（内网 http 需显式写 http://，已含 scheme 不再补）。
Uri chatCompletionsUri(String baseUrl) {
  var b = baseUrl.trim();
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  if (b.endsWith('/chat/completions')) return Uri.parse(b);
  if (!b.contains('://')) b = 'https://$b';
  return Uri.parse('$b/chat/completions');
}

/// 构造请求体（纯函数）。[maxTokens] 缺省不出现 `max_tokens` key
/// （兼容 gpt-4o 新旧 token 参数差异，交给服务端默认截断）。
Map<String, dynamic> buildChatBody({
  required String model,
  required List<Map<String, String>> messages,
  double temperature = 0.2,
  int? maxTokens,
}) {
  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'temperature': temperature,
  };
  if (maxTokens != null) body['max_tokens'] = maxTokens;
  return body;
}

/// 低层调用：POST /chat/completions 并返回 assistant 文本（剥空白）。
/// 配置缺失 → [AiConfigException]；网络层失败 → [AiNetworkException]；
/// 非 200 → [AiHttpException]；响应无正文 → [AiParseException]；
/// 超过 [timeout]（缺省 [aiRequestTimeoutSeconds]）仍无完整响应 →
/// [AiTimeoutException]（连接已建立但服务端不回包时不再无限等待）。
Future<String> aiChat(
  AiConfig cfg, {
  required List<Map<String, String>> messages,
  double temperature = 0.2,
  int? maxTokens,
  Duration? timeout,
  AiFetch? fetchImpl,
}) async {
  final base = cfg.baseUrl.trim();
  final model = cfg.model.trim();
  if (base.isEmpty || model.isEmpty) {
    throw AiConfigException([
      if (base.isEmpty) 'Base URL',
      if (model.isEmpty) '模型名',
    ]);
  }
  final limit = timeout ?? const Duration(seconds: aiRequestTimeoutSeconds);
  final uri = chatCompletionsUri(base);
  final body =
      jsonEncode(buildChatBody(model: model, messages: messages, temperature: temperature, maxTokens: maxTokens));
  final headers = <String, String>{
    'Content-Type': 'application/json',
  };
  final key = cfg.apiKey?.trim();
  if (key != null && key.isNotEmpty) {
    headers['Authorization'] = 'Bearer $key';
  }

  final String raw;
  try {
    final pending = fetchImpl != null
        ? fetchImpl(uri, headers: headers, body: body)
        : _httpPost(uri, headers: headers, body: body, timeout: limit);
    raw = await pending.timeout(limit);
  } on AiException {
    rethrow; // 注入实现已表达的服务端拒绝原样透出
  } on SocketException catch (e) {
    throw AiNetworkException(e);
  } on HttpException catch (e) {
    throw AiNetworkException(e);
  } on IOException catch (e) {
    throw AiNetworkException(e);
  } on TimeoutException catch (_) {
    throw AiTimeoutException(limit.inSeconds);
  } catch (e) {
    throw AiNetworkException(e); // 注入实现抛的其它异常按网络失败处理
  }

  final text = extractAssistantText(raw);
  if (text == null) throw AiParseException();
  return text;
}

/// 真实 HttpClient POST：连接超时与响应超时共用 [timeout]；
/// finally 里 force close——超时路径下也要掐掉在途连接，不留悬空 socket。
Future<String> _httpPost(
  Uri uri, {
  required Map<String, String> headers,
  required String body,
  required Duration timeout,
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout;
  try {
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType.json;
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'content-type') continue;
      req.headers.set(e.key, e.value);
    }
    req.write(body);
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != 200) {
      final raw = await utf8.decodeStream(resp).timeout(timeout);
      throw AiHttpException(resp.statusCode, detail: _extractHttpDetail(raw));
    }
    final raw = await utf8.decodeStream(resp).timeout(timeout);
    return raw;
  } finally {
    client.close(force: true);
  }
}

/// 从错误响应体提取 error.message（宽容；非 JSON 返回 null）。
String? _extractHttpDetail(String raw) {
  try {
    final d = jsonDecode(raw);
    if (d is Map<String, dynamic>) {
      final err = d['error'];
      if (err is Map<String, dynamic>) {
        final msg = err['message'];
        if (msg is String && msg.trim().isNotEmpty) return msg;
      }
    }
  } catch (_) {}
  return null;
}

/// 由设置库现取配置（不放 AppState）；配置为空 → [AiConfigException]。
/// [secondary] 为 true 时取「AI2 增强」配置（未配置自动回退 AI1）——元件替换用。
Future<String> aiChatFromSettings(
  SettingsStore store, {
  required List<Map<String, String>> messages,
  double temperature = 0.2,
  int? maxTokens,
  Duration? timeout,
  bool secondary = false,
  AiFetch? fetchImpl,
}) async {
  final cfg = secondary
      ? await store.loadSubstituteAiConfig()
      : await store.loadAiConfig();
  return aiChat(
    AiConfig(baseUrl: cfg.baseUrl ?? '', apiKey: cfg.apiKey, model: cfg.model ?? ''),
    messages: messages,
    temperature: temperature,
    maxTokens: maxTokens,
    timeout: timeout,
    fetchImpl: fetchImpl,
  );
}

/// 从 /chat/completions 响应体提取 assistant 文本。
/// content 缺省时回退 `choices[0].text`（部分兼容端点）。
String? extractAssistantText(String responseBodyJson) {
  Object? decoded;
  try {
    decoded = jsonDecode(responseBodyJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final first = choices[0];
  if (first is! Map<String, dynamic>) return null;
  final msg = first['message'];
  if (msg is Map<String, dynamic>) {
    final content = msg['content'];
    if (content is String && content.trim().isNotEmpty) return content.trim();
  }
  final text = first['text'];
  if (text is String && text.trim().isNotEmpty) return text.trim();
  return null;
}

/// 剥 ```json…```（或 ``` ```）Markdown 围栏后取正文；无围栏原样 trim。
String stripJsonFence(String raw) {
  final t = raw.trim();
  final m =
      RegExp(r'^```[a-zA-Z]*\s*(.*?)\s*```$', dotAll: true).firstMatch(t);
  if (m == null) return t;
  return m.group(1)!.trim();
}

/// 宽容解析 AI 结构化 JSON：剥围栏 → 整串 decode → 失败取首个 `{`/`[` 子串 decode。
/// 全部失败返回 null（不做病态括号平衡）。
Object? decodeModelJsonText(String raw) {
  final text = stripJsonFence(raw);
  if (text.isEmpty) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    decoded = null;
  }
  if (decoded != null) return decoded;

  final start = _firstJsonStart(text);
  if (start != null) {
    try {
      decoded = jsonDecode(text.substring(start));
    } on FormatException {
      decoded = null;
    }
  }
  return decoded;
}

int? _firstJsonStart(String s) {
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '{' || ch == '[') return i;
  }
  return null;
}

/// AI 分类建议（型号 → 应用分类），字段宽容读取。
class AiClassifySuggestion {
  final String category;
  final String? package;
  final String? note;
  final String? reason;
  final String? model; // 规范厂商型号（AI 认为更准确的写法；可空=没把握）
  final String? brand; // 品牌/厂商（可空）
  final double? confidence;

  const AiClassifySuggestion({
    required this.category,
    this.package,
    this.note,
    this.reason,
    this.model,
    this.brand,
    this.confidence,
  });
}

/// 解析分类 JSON。category 非空即返回（是否 ∈ [allowed] 由调用方校验并兜底）；
/// decode 失败但正文恰为 allowed 之一 → 仅分类兜底。
AiClassifySuggestion? parseAiClassify(String raw, {required List<String> allowed}) {
  final decoded = decodeModelJsonText(raw);
  if (decoded is Map<String, dynamic>) {
    final rawCat = decoded['category'];
    if (rawCat is! String || rawCat.trim().isEmpty) return null;
    String? str(String k) =>
        decoded[k] is String ? (decoded[k] as String).trim() : null;
    return AiClassifySuggestion(
      category: rawCat.trim(),
      package: str('package'),
      note: str('note'),
      reason: str('reason'),
      model: str('model'),
      brand: str('brand'),
      confidence:
          decoded['confidence'] is num ? (decoded['confidence'] as num).toDouble() : null,
    );
  }
  // AI 只回了分类名裸文本
  final text = stripJsonFence(raw);
  if (allowed.map((a) => a.trim()).contains(text)) {
    return AiClassifySuggestion(category: text);
  }
  return null;
}

/// AI 替代料建议。[specs] 为电气参数表（参数名 → 带单位值，保持模型给的顺序）；
/// [diff] 一句话关键差异；[risk] ∈ 可直接替代 / 需确认 / 不建议（模型自由文本，UI 容错着色）。
class AiSubstituteSuggestion {
  final String model;
  final String? brand;
  final String? package;
  final String? reason;
  final double? confidence;
  final Map<String, String> specs;
  final String? diff;
  final String? risk;

  const AiSubstituteSuggestion({
    required this.model,
    this.brand,
    this.package,
    this.reason,
    this.confidence,
    this.specs = const {},
    this.diff,
    this.risk,
  });
}

/// 一行的完整替代方案：原元件电气参数 + 候选列表（供电气参数对比页渲染两列表格）。
class AiSubstitutePlan {
  final Map<String, String> originalSpecs;
  final List<AiSubstituteSuggestion> suggestions;

  const AiSubstitutePlan({
    this.originalSpecs = const {},
    required this.suggestions,
  });

  bool get isEmpty => suggestions.isEmpty;
}

/// 替代方案完整解析：支持新格式
/// `{"original":{"specs":{…}},"suggestions":[…,{specs,diff,risk}]}`，
/// 也兼容旧格式 顶层数组 / `{"suggestions":[…]}` / 单对象（此时 originalSpecs 为空）。
/// 无有效候选返回 null（功能级入口转抛 [AiParseException]）。
AiSubstitutePlan? parseAiSubstitutePlan(String raw) {
  final decoded = decodeModelJsonText(raw);
  final List<dynamic>? list;
  final Object? original;
  if (decoded is List) {
    list = decoded;
    original = null;
  } else if (decoded is Map<String, dynamic>) {
    final s = decoded['suggestions'];
    if (s is List) {
      list = s;
    } else if (decoded.containsKey('model')) {
      list = [decoded]; // 单对象包一层
    } else {
      list = null;
    }
    original = decoded['original'];
  } else {
    list = null;
    original = null;
  }
  if (list == null) return null;

  final out = <AiSubstituteSuggestion>[];
  for (final item in list) {
    if (item is! Map<String, dynamic>) continue;
    final model = item['model'];
    if (model is! String || model.trim().isEmpty) continue;
    String? str(String k) =>
        item[k] is String ? (item[k] as String).trim() : null;
    out.add(AiSubstituteSuggestion(
      model: model.trim(),
      brand: str('brand'),
      package: str('package'),
      reason: str('reason'),
      confidence:
          item['confidence'] is num ? (item['confidence'] as num).toDouble() : null,
      specs: _parseSpecsMap(item['specs']),
      diff: str('diff'),
      risk: str('risk'),
    ));
  }
  if (out.isEmpty) return null;
  final originalSpecs =
      original is Map<String, dynamic> ? _parseSpecsMap(original['specs']) : const <String, String>{};
  return AiSubstitutePlan(originalSpecs: originalSpecs, suggestions: out);
}

/// 宽容读取参数表：Map{k:v}（值转字符串）或 List of {name,value}/{k,v}；保序。
Map<String, String> _parseSpecsMap(Object? v) {
  final out = <String, String>{};
  if (v is Map) {
    for (final e in v.entries) {
      final k = e.key is String ? (e.key as String).trim() : '';
      final val = e.value?.toString().trim() ?? '';
      if (k.isEmpty || val.isEmpty) continue;
      out[k] = val;
    }
  } else if (v is List) {
    for (final item in v) {
      if (item is! Map) continue;
      final k = (item['name'] ?? item['k'] ?? item['key'])?.toString().trim() ?? '';
      final val = (item['value'] ?? item['v'])?.toString().trim() ?? '';
      if (k.isEmpty || val.isEmpty) continue;
      out[k] = val;
    }
  }
  return out;
}

/// 兼容旧入口：仅取候选列表（新代码请用 [parseAiSubstitutePlan]）。
List<AiSubstituteSuggestion>? parseAiSubstitutes(String raw) =>
    parseAiSubstitutePlan(raw)?.suggestions;

/// 分类提示词（纯函数，可单测）。[categories] 传入应用分类清单（inventoryCategories）。
///
/// 提准策略（v1.1.x）：角色设定 + 厂商料号前缀规则表 + 易混类辨析 +
/// 「reason 在前、category 在后」的 JSON 键序（自回归模型先生成依据再下结论，
/// 等效链式推理）+ 少量 tricky few-shot；调用侧 temperature 降到 0。
List<Map<String, String>> classifyMessages({
  required String model,
  String? cid,
  required List<String> categories,
  String? hint,
}) {
  final cidPart = (cid != null && cid.isNotEmpty) ? '（立创编号 $cid）' : '';
  final hintPart = (hint != null && hint.isNotEmpty) ? '\n补充信息：$hint' : '';
  return [
    {
      'role': 'system',
      'content': '你是资深电子元器件选型工程师，精通各厂商料号（MPN）命名规则。'
          '根据元件型号$cidPart判断它属于下面清单中的哪一类。$hintPart\n'
          '分类清单（category 必须逐字等于其中一项）：${categories.join('、')}。\n\n'
          '先在 reason 写识别依据，再给 category。常见厂商料号规律：\n'
          '· 电阻：RC/RL 前缀+封装数（RC0402、RC0603FR-07、r100k）、含 Ω/ohm、"电阻"\n'
          '· 电容：CL/CC 前缀+数字（CL21、CC0805）、C+封装数（C0805）、含 μF/nF/pF、"电容/钽电容"\n'
          '· 电感：LQ/SRM/SRD/CD32/CD54/SWPA/FB 前缀、磁珠、"电感"\n'
          '· 二极管：1N/LL/BAV/BAT/US/SS+数字（1N4148、SS34、BAV99）、肖特基/稳压/TVS/"二极管"\n'
          '· 三极管：2N/S8/SS8/BC/MMS/MMBT 前缀（2N3904、S8050、BC547）、"三极管"\n'
          '· 场效应管：AO/IRF/IRL/SI/NCE/2SK 前缀（AO3400、IRF540N、SI2302）、MOSFET/"场效应"\n'
          '· IGBT：FGA/FGH/G4PC/GT 前缀\n'
          '· LED：灯珠料号（含 IDC/UY/ASY 或 19-21 前缀）、"LED/发光"\n'
          '· 晶振：XO/SX/SG-/ABS- 前缀、32.768k、含 MHz/kHz 的谐振器/"晶振"\n'
          '· 逻辑门：74HC/74LS/74AHC/74HCT+编号、CD4xxx、HEF\n'
          '· 存储器：W25Q/GD25/N25Q/EN25/AT24/M24/24Cxx、EEPROM/Flash\n'
          '· 单片机：STM32/GD32/ATmega/ATtiny/ESP32/ESP8266/CH32/STM8\n'
          '· 电源管理：AMS1117/RT90xx/TPS/MP15/XL4015/XL6019/LM2596/MT3608/TP4056/TL431、'
          'LDO/DC-DC/降压/升压/充电/LED驱动(PT4103)\n'
          '· 放大器：LM358/LM324/NE5532/OPAx/TLE2/AD620、运放\n'
          '· 比较器：LM393/LM311/LM2903\n'
          '· 光耦：PC817/TLP521/TLP281/MOC30/EL357/6N137（PC817 是光耦，别被 "PC" 误导）\n'
          '· 接口芯片：CH340/CH341/CP210x/FT232/MAX232/MAX485/SP3485/SN65、RS232/RS485/CAN/USB转串口\n'
          '· 继电器：SRD/JQC/HR/HK 前缀+"继电器"；变压器：EE/EF/EFD 磁芯\n'
          '· 保险丝：FUS/保险丝/自恢复；按键开关：轻触/微动/SW-；电池：CR/LIR/18650\n'
          '· 传感器：DHT/SHT/BMP/MPU/ADS/HCSR04/霍尔/热电偶/"传感器"\n'
          '· 连接器：PH/XH/ZH/JST/杜邦/端子；排针排母：排针/排母/Pin Header/Female Header\n'
          '· USB / Type-C：USB-A/USB-C/Type-C 连接器座子（不是转换芯片）\n\n'
          '易混辨析：STM32/ESP 归单片机而不是 IC；运放/比较器/电源/存储/逻辑/接口'
          '都归各自细类，泛化 IC 只留给其余芯片；稳压二极管(1N47xx)是二极管、'
          '稳压器(AMS1117)是电源管理；CH340 是接口芯片、USB 座子是 USB；'
          '磁珠归电感。目标类别若不在清单中，就近选清单内最贴合的一项；'
          '完全无法判断给「其他」并在 reason 说明。\n'
          '除分类外可给出封装(package)、规范厂商型号(model，把握不大就省略)、'
          '品牌(brand)、一句话备注(note)、理由(reason)与置信度(confidence, 0~1)。\n'
          '示例：STM32F103C8T6→单片机；RC0402FR-0710KL→电阻；CL21A105KOFNNNE→电容；'
          '1N4148WS→二极管；AO3400→场效应管；CH340G→接口芯片；W25Q64BV→存储器；'
          'PC817C→光耦；74HC595D→逻辑门；XL4015E1→电源管理。\n'
          '只输出 JSON 不要其它文字，键顺序固定为：'
          '{"reason":"识别依据","category":"分类","package":"封装(可省)","model":"规范型号(可省)","brand":"品牌(可省)","note":"备注(可省)","confidence":0.9}',
    },
    {
      'role': 'user',
      'content': '型号：$model${cidPart.isEmpty ? '' : '，立创编号：$cid'}',
    },
  ];
}

/// 替代料推荐提示词（纯函数）。[localModels] 传已展示的本地候选型号，提示 AI 别重复。
///
/// v1.1.x：要求同时给出**原元件与每个候选的电气参数表**（统一中文参数名、值带单位），
/// 供「电气参数对比」页逐项渲染；候选带 risk（可直接替代/需确认/不建议）与 diff 关键差异。
List<Map<String, String>> substituteMessages({
  required String model,
  required int qty,
  String? designation,
  List<String> localModels = const [],
}) {
  final desigPart = (designation != null && designation.isNotEmpty)
      ? '本件位号：$designation。'
      : '';
  final localPart = localModels.isEmpty
      ? '无'
      : localModels.take(8).join('、');
  return [
    {
      'role': 'system',
      'content': '你是资深电子元器件替代选型专家。为缺货元件推荐可替代的主流真实型号，'
          '优先同封装同参数；宁可少推也不要推参数对不上的型号。$desigPart\n'
          '本地库存已查到的替代候选：$localPart（请勿重复推荐，除非你能补充更优选择）。\n\n'
          '对原元件和每个候选都给出电气参数表 specs：参数名用中文、值带单位，'
          '原元件与候选尽量使用同名参数以便逐项对比。按类别约定参数名：\n'
          '· 电阻：阻值/精度/功率/封装/温度系数；电容：容值/介质(X7R等)/耐压/误差/封装\n'
          '· 电感：感值/直流电阻/饱和电流/封装；二极管：类型(整流|肖特基|稳压)/反向耐压/正向电流/正向压降/封装\n'
          '· 三极管：极性(NPN|PNP)/耐压VCEO/电流IC/增益hFE/封装；场效应管：极性(N沟道|P沟道)/耐压VDS/电流ID/导通电阻RDS(on)/封装\n'
          '· IC/其他：功能/供电电压/关键参数(通道数、带宽、容量等)/封装/引脚兼容性(兼容|不兼容)\n'
          'risk 只能取「可直接替代」「需确认」「不建议」之一；'
          'diff 用一句话点出与原物的关键差异（参数或引脚）。\n'
          '只输出 JSON 不要其它文字，格式：\n'
          '{"original":{"model":"$model","specs":{"参数名":"值"}},'
          '"suggestions":[{"model":"候选型号","brand":"品牌(可省)","package":"封装(可省)",'
          '"specs":{"参数名":"值"},"diff":"关键差异","risk":"需确认",'
          '"reason":"替代理由","confidence":0.0}]}',
    },
    {
      'role': 'user',
      'content': '需要替代的元件型号：$model，缺料数量：$qty 个。',
    },
  ];
}

/// AI 替代上下文（纯数据，供 seam 与底部面板传递）。
/// [inventoryBrief] 库存摘要行（"型号|分类|封装|数量"）；[modelToId] 小写型号 →
/// components.id——库存替代方向把 AI 点名候选映射回库存行用。
class AiSubstituteContext {
  final String model;
  final int qty;
  final String? designation;
  final String? category; // 原元件分类提示（命中库存行/分类器推得，可空）
  final String? package; // 原元件封装提示（可空）
  final List<String> localModels;
  final List<String> inventoryBrief;
  final Map<String, int> modelToId;

  const AiSubstituteContext({
    required this.model,
    required this.qty,
    this.designation,
    this.category,
    this.package,
    this.localModels = const [],
    this.inventoryBrief = const [],
    this.modelToId = const {},
  });
}

/// 添加弹窗注入缝：型号/编号 → 分类建议（null = 无有效结果）。
typedef AiClassifyLookup = Future<AiClassifySuggestion?> Function(
    String model, String? cid);

/// AI 自动命名注入缝：原始名称/描述 → 规范型号建议（null = 没给出）。
typedef AiNameLookup = Future<AiModelSuggestion?> Function(
    String raw, String? cid);

/// BOM 替代 sheet 注入缝：上下文 → AI 建议列表（旧签名，兼容保留）。
typedef AiRecommendFetcher = Future<List<AiSubstituteSuggestion>> Function(
    AiSubstituteContext ctx);

/// BOM 替代方案注入缝：上下文 → 完整方案（含原元件电气参数，电气对比页用）。
typedef AiPlanFetcher = Future<AiSubstitutePlan> Function(
    AiSubstituteContext ctx);

/// 库存替代方向注入缝：上下文（含 inventoryBrief/modelToId）→ 方案；
/// null = AI 从库存里没挑出可靠替代（不算错误）。
typedef AiInventoryPlanFetcher = Future<AiSubstitutePlan?> Function(
    AiSubstituteContext ctx);

/// 分类功能级入口：现取设置 → 提示词 → AI → 解析。解析 null → [AiParseException]。
/// temperature 固定 0：分类要确定性，不要创造性。
Future<AiClassifySuggestion> aiClassifyFromSettings(
  SettingsStore store, {
  required String model,
  String? cid,
  required List<String> categories,
  Duration? timeout,
  AiFetch? fetchImpl,
}) async {
  final text = await aiChatFromSettings(
    store,
    messages: classifyMessages(model: model, cid: cid, categories: categories),
    temperature: 0,
    timeout: timeout,
    fetchImpl: fetchImpl,
  );
  final sug = parseAiClassify(text, allowed: categories);
  if (sug == null) throw AiParseException();
  return sug;
}

/// 替代功能级入口（旧签名，返回列表）：解析 null → [AiParseException]。
Future<List<AiSubstituteSuggestion>> aiRecommendSubstitutes(
  SettingsStore store, {
  required String model,
  required int qty,
  String? designation,
  List<String> localModels = const [],
  Duration? timeout,
  AiFetch? fetchImpl,
}) async {
  final plan = await aiRecommendSubstitutePlanFromSettings(
    store,
    model: model,
    qty: qty,
    designation: designation,
    localModels: localModels,
    timeout: timeout,
    fetchImpl: fetchImpl,
  );
  return plan.suggestions;
}

/// 替代方案功能级入口（含电气参数）：解析 null → [AiParseException]。
Future<AiSubstitutePlan> aiRecommendSubstitutePlanFromSettings(
  SettingsStore store, {
  required String model,
  required int qty,
  String? designation,
  List<String> localModels = const [],
  Duration? timeout,
  AiFetch? fetchImpl,
}) async {
  final text = await aiChatFromSettings(
    store,
    messages: substituteMessages(
        model: model, qty: qty, designation: designation, localModels: localModels),
    secondary: true,
    timeout: timeout,
    fetchImpl: fetchImpl,
  );
  final plan = parseAiSubstitutePlan(text);
  if (plan == null) throw AiParseException();
  return plan;
}

// ==================== 库存替代方向（双向 AI 之一） ====================

/// 库存内替代提示词：把本机库存清单交给 AI，让它判断哪些**库存里已有的元件**
/// 可替代缺料件（与网络替代方向相对）。输出复用 [parseAiSubstitutePlan] 的
/// JSON 约定（候选 model 必须逐字取自清单，便于映射回库存行）。
List<Map<String, String>> inventorySubstituteMessages({
  required String model,
  required int qty,
  String? category,
  String? package,
  String? designation,
  required List<String> inventoryBrief,
}) {
  final target = [
    '型号：$model',
    if (category != null && category.isNotEmpty) '分类：$category',
    if (package != null && package.isNotEmpty) '封装：$package',
    if (designation != null && designation.isNotEmpty) '位号：$designation',
  ].join('，');
  return [
    {
      'role': 'system',
      'content': '你是资深电子元器件替代选型专家。用户给出缺货元件和一份本机库存清单'
          '（每行格式：型号|分类|封装|数量）。从库存清单里挑出功能上可替代该缺料件的型号，'
          '按贴合度从高到低最多 5 个；宁缺毋滥，没有可靠替代就让 suggestions 为空数组。\n'
          '候选的 model 必须逐字来自清单（区分大小写照抄），不要推荐缺料件本身。\n'
          '对原元件和每个候选给出中文参数名、带单位的 specs（参数名尽量同名可比）；'
          'risk 只能取「可直接替代」「需确认」「不建议」；diff 一句话点出关键差异。\n'
          '只输出 JSON 不要其它文字，格式：\n'
          '{"original":{"model":"$model","specs":{"参数名":"值"}},'
          '"suggestions":[{"model":"清单内型号","specs":{"参数名":"值"},'
          '"diff":"关键差异","risk":"需确认","reason":"引用其库存分类/封装/数量","confidence":0.0}]}',
    },
    {
      'role': 'user',
      'content': '缺料元件（需补 $qty 个）：$target\n库存清单：\n${inventoryBrief.join('\n')}',
    },
  ];
}

/// 库存替代功能级入口：解析后把候选按型号（忽略大小写）映射回库存行 id，
/// 无匹配的候选丢弃。返回 null = AI 没给出任何可用库存替代（不算错误）。
Future<AiSubstitutePlan?> aiSubstituteFromInventoryFromSettings(
  SettingsStore store, {
  required String model,
  required int qty,
  String? category,
  String? package,
  String? designation,
  required List<String> inventoryBrief,
  required Map<String, int> modelToId, // lower-case model → components.id
  Duration? timeout,
  AiFetch? fetchImpl,
}) async {
  final text = await aiChatFromSettings(
    store,
    messages: inventorySubstituteMessages(
      model: model,
      qty: qty,
      category: category,
      package: package,
      designation: designation,
      inventoryBrief: inventoryBrief,
    ),
    secondary: true,
    timeout: timeout,
    fetchImpl: fetchImpl,
  );
  final plan = parseAiSubstitutePlan(text);
  if (plan == null) return null;
  final mapped = <AiSubstituteSuggestion>[];
  for (final s in plan.suggestions) {
    if (modelToId.containsKey(s.model.toLowerCase())) mapped.add(s);
  }
  if (mapped.isEmpty) return null;
  return AiSubstitutePlan(originalSpecs: plan.originalSpecs, suggestions: mapped);
}

// ==================== AI 自动命名（规范型号） ====================

/// AI 命名建议：规范厂商型号 + 可选品牌/分类。
class AiModelSuggestion {
  final String model;
  final String? brand;
  final String? category;

  const AiModelSuggestion({required this.model, this.brand, this.category});
}

/// 单条命名提示词：把长描述/立创商品名/半截料号规范成厂商标准型号。
List<Map<String, String>> namingMessages({required String rawModel, String? cid}) {
  final cidPart = (cid != null && cid.isNotEmpty) ? '（立创编号 $cid）' : '';
  return [
    {
      'role': 'system',
      'content': '你是元器件料号规范化专家。用户给出元件的名称/描述/不完整料号$cidPart，'
          '把它规范成**厂商标准型号（MPN）**：去掉描述性文字、规格后缀里非型号部分、'
          '多余空格与包装后缀（如编带 -TR/-REEL、管装 -Tube），保留完整主体料号与关键后缀'
          '（精度/温度档/封装代码是有意义的就保留）。已经是规范型号就原样返回。\n'
          '同时尽量给出品牌(brand)与从清单角度最贴合的分类(category，可省)。\n'
          '只输出 JSON 不要其它文字：{"model":"规范型号","brand":"品牌(可省)","category":"分类(可省)"}',
    },
    {'role': 'user', 'content': '名称/描述：$rawModel'},
  ];
}

/// 解析命名 JSON：model 非空才有效；裸文本非 JSON 时整串当规范型号兜底。
AiModelSuggestion? parseAiModelSuggestion(String raw) {
  final decoded = decodeModelJsonText(raw);
  if (decoded is Map<String, dynamic>) {
    final m = decoded['model'];
    if (m is! String || m.trim().isEmpty) return null;
    String? str(String k) =>
        decoded[k] is String && (decoded[k] as String).trim().isNotEmpty
            ? (decoded[k] as String).trim()
            : null;
    return AiModelSuggestion(model: m.trim(), brand: str('brand'), category: str('category'));
  }
  final text = stripJsonFence(raw);
  if (text.isEmpty || text.length > 80 || text.contains('\n')) return null;
  return AiModelSuggestion(model: text);
}

/// 单条命名功能级入口：解析 null → [AiParseException]。
Future<AiModelSuggestion> aiNameFromSettings(
  SettingsStore store, {
  required String rawModel,
  String? cid,
  Duration? timeout,
  AiFetch? fetchImpl,
}) async {
  final text = await aiChatFromSettings(
    store,
    messages: namingMessages(rawModel: rawModel, cid: cid),
    temperature: 0,
    timeout: timeout,
    fetchImpl: fetchImpl,
  );
  final sug = parseAiModelSuggestion(text);
  if (sug == null) throw AiParseException();
  return sug;
}

/// 批量命名提示词（购物车导入一次调用规范整表）：[entries] 的 code 必须原样回传。
List<Map<String, String>> namingBatchMessages(
    List<({String code, String raw})> entries) {
  final lines = entries.map((e) => '${e.code}|${e.raw}').join('\n');
  return [
    {
      'role': 'system',
      'content': '你是元器件料号规范化专家。用户给出多行「编号|名称或描述」，'
          '为每行把名称规范成厂商标准型号（MPN，规则同料号清洗：去描述性文字与'
          '包装后缀，已是型号则原样），并尽量给品牌。\n'
          '只输出 JSON 不要其它文字，items 覆盖所有编号且 code 原样返回：\n'
          '{"items":[{"code":"…","model":"规范型号","brand":"品牌(可省)"}]}',
    },
    {'role': 'user', 'content': lines},
  ];
}

/// 解析批量命名响应：code（大写、剥空格）→ 建议；条目缺 model 则跳过该条。
Map<String, AiModelSuggestion> parseAiModelBatch(String raw) {
  final decoded = decodeModelJsonText(raw);
  final list = decoded is List
      ? decoded
      : decoded is Map<String, dynamic> && decoded['items'] is List
          ? decoded['items'] as List
          : null;
  final out = <String, AiModelSuggestion>{};
  if (list == null) return out;
  for (final item in list) {
    if (item is! Map<String, dynamic>) continue;
    final code = item['code'];
    final model = item['model'];
    if (code is! String || code.trim().isEmpty) continue;
    if (model is! String || model.trim().isEmpty) continue;
    String? brand =
        item['brand'] is String && (item['brand'] as String).trim().isNotEmpty
            ? (item['brand'] as String).trim()
            : null;
    out[code.trim().toUpperCase()] =
        AiModelSuggestion(model: model.trim(), brand: brand);
  }
  return out;
}

/// 购物车批量命名功能级入口：一次 AI 调用整表规范。
/// 返回 code → 建议（缺的 code 表示 AI 没给出，调用方保留原名）。
Future<Map<String, AiModelSuggestion>> aiNameCartItems(
  SettingsStore store, {
  required List<({String code, String raw})> entries,
  Duration? timeout,
  AiFetch? fetchImpl,
}) async {
  final text = await aiChatFromSettings(
    store,
    messages: namingBatchMessages(entries),
    temperature: 0,
    timeout: timeout,
    fetchImpl: fetchImpl,
  );
  final map = parseAiModelBatch(text);
  if (map.isEmpty) throw AiParseException();
  return map;
}
