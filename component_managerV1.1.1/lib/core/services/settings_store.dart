import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// 全局设置存取：key-value 落库到 settings 表（sqflite，跨桌面/手机一致）。
///
/// 值统一存字符串；上层（如主题枚举）负责解析。当前条目：
/// - `theme_mode`：`dark` / `light`（默认 light）
/// - `ai_base_url` / `ai_api_key` / `ai_model`：AI 查询配置（第十四轮 AI 功能）
/// - `custom_categories`：用户自创分类名 JSON 数组（在系统 29 类之外）
/// - `sync_last_host_*`：局域网同步最近一次成功主机（IP/端口/名称/令牌），
///   供下次进页面回填免输入（令牌明文存储，与 AI key 同级，仅限可信局域网）。
class SettingsStore {
  final Database db;

  SettingsStore(this.db);

  static const String themeKey = 'theme_mode';
  static const String aiBaseUrlKey = 'ai_base_url';
  static const String aiApiKeyKey = 'ai_api_key';
  static const String aiModelKey = 'ai_model';
  // AI2（增强）：元件替换专用；未配置回退 AI1。分类/命名等轻任务仍用 AI1。
  static const String ai2BaseUrlKey = 'ai2_base_url';
  static const String ai2ApiKeyKey = 'ai2_api_key';
  static const String ai2ModelKey = 'ai2_model';
  static const String customCategoriesKey = 'custom_categories';
  static const String lastHostIpKey = 'sync_last_host_ip';
  static const String lastHostPortKey = 'sync_last_host_port';
  static const String lastHostNameKey = 'sync_last_host_name';
  static const String lastHostTokenKey = 'sync_last_host_token';

  Future<String?> get(String key) async {
    final rows = await db.query('settings',
        columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> set(String key, String value) async {
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---- 主题 ----
  Future<String> loadThemeMode() async =>
      (await get(themeKey)) ?? 'light'; // 'dark' | 'light'

  Future<void> saveThemeMode(String mode) => set(themeKey, mode);

  // ---- AI 配置 ----
  Future<({String? baseUrl, String? apiKey, String? model})>
      loadAiConfig() async {
    final values = await Future.wait([
      get(aiBaseUrlKey),
      get(aiApiKeyKey),
      get(aiModelKey),
    ]);
    return (
      baseUrl: values[0],
      apiKey: values[1],
      model: values[2],
    );
  }

  Future<void> saveAiConfig({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    await set(aiBaseUrlKey, baseUrl);
    await set(aiApiKeyKey, apiKey);
    await set(aiModelKey, model);
  }

  // ---- AI2 配置（增强，替换任务专用；同结构独立一组）----
  Future<({String? baseUrl, String? apiKey, String? model})>
      loadAi2Config() async {
    final values = await Future.wait([
      get(ai2BaseUrlKey),
      get(ai2ApiKeyKey),
      get(ai2ModelKey),
    ]);
    return (
      baseUrl: values[0],
      apiKey: values[1],
      model: values[2],
    );
  }

  Future<void> saveAi2Config({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    await set(ai2BaseUrlKey, baseUrl);
    await set(ai2ApiKeyKey, apiKey);
    await set(ai2ModelKey, model);
  }

  /// 替换任务的生效配置：AI2 填全了（baseUrl+model）用 AI2，否则回退 AI1。
  Future<({String? baseUrl, String? apiKey, String? model})>
      loadSubstituteAiConfig() async {
    final second = await loadAi2Config();
    if ((second.baseUrl ?? '').trim().isNotEmpty &&
        (second.model ?? '').trim().isNotEmpty) {
      return second;
    }
    return loadAiConfig();
  }

  // ---- 自创分类（JSON 数组；在系统 29 类之外）----
  Future<List<String>> loadCustomCategories() async {
    final raw = await get(customCategoriesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<void> saveCustomCategories(List<String> names) async {
    await set(customCategoriesKey, jsonEncode(names));
  }

  // ---- 局域网同步最近主机（成功同步后记录，供下次回填）----
  Future<({String? ip, int? port, String? name, String? token})>
      loadLastHost() async {
    final values = await Future.wait([
      get(lastHostIpKey),
      get(lastHostPortKey),
      get(lastHostNameKey),
      get(lastHostTokenKey),
    ]);
    return (
      ip: values[0],
      port: int.tryParse(values[1] ?? ''),
      name: values[2],
      token: values[3],
    );
  }

  /// 记录最近一次成功同步的主机。[name]/[token] 为空时不写（不清旧值）。
  Future<void> saveLastHost({
    required String ip,
    required int port,
    String? name,
    String? token,
  }) async {
    await set(lastHostIpKey, ip);
    await set(lastHostPortKey, '$port');
    if (name != null && name.isNotEmpty) {
      await set(lastHostNameKey, name);
    }
    if (token != null && token.isNotEmpty) {
      await set(lastHostTokenKey, token);
    }
  }
}
