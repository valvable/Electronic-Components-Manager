import 'package:flutter/material.dart';

/// 元件分类常量与筛选选项（全项目统一使用，避免魔法字符串）。
class AppCategories {
  static const String resistor = '电阻';
  static const String capacitor = '电容';
  static const String ic = 'IC';
  static const String diode = '二极管';
  static const String transistor = '三极管';
  static const String connector = '连接器';
  static const String crystal = '晶振';
  static const String other = '其他';

  /// 全部分类（不含「全部」）。
  static const List<String> all = [
    resistor,
    capacitor,
    ic,
    diode,
    transistor,
    connector,
    crystal,
    other,
  ];

  /// 「全部」筛选标签。
  static const String filterAll = '全部';

  /// 筛选下拉选项（含「全部」）。
  static const List<String> filterOptions = [filterAll, ...all];
}

/// 型号分类自动识别器（规则版，按优先级依次匹配，命中即返回）。
///
/// ⚠️ 注意：只对「型号」字段调用识别，不要用 CID（如 C25704）识别——
/// 立创料号以 C 开头，会被误判为电容。
///
/// 匹配优先级：电阻 → 电容 → IC → 二极管 → 三极管 → 连接器 → 晶振 → 其他。
/// 关键词规则集中在下方 `recognize` 方法中，按需增删即可。
class CategoryRecognizer {
  CategoryRecognizer._();

  /// 识别型号对应的分类，无法匹配时返回「其他」。
  static String recognize(String rawModel) {
    final model = rawModel.trim();
    if (model.isEmpty) return AppCategories.other;
    final lower = model.toLowerCase();

    // ---------- 1. 电阻：RC 开头 / R+数字 / Resistor / Ω ----------
    if (_match(model, r'^rc\d') ||
        _match(model, r'^r\d') ||
        lower.contains('resistor') ||
        model.contains('电阻') ||
        model.contains('Ω')) {
      return AppCategories.resistor;
    }

    // ---------- 2. 电容：CL/CC/C+数字 / Capacitor / μF pF nF uF ----------
    // CL 系（三星 MLCC）、CC 系（国巨）等常见贴片电容系列一并覆盖。
    if (_match(model, r'^(cl|cc|c)\d') ||
        lower.contains('capacitor') ||
        model.contains('电容') ||
        lower.contains('μf') ||
        lower.contains('uf') ||
        lower.contains('pf') ||
        lower.contains('nf')) {
      return AppCategories.capacitor;
    }

    // ---------- 3. IC：IC/U+数字 开头 / 74xx / CD4xxx / LM MAX STM / 芯片 ----------
    if (_match(model, r'^ic') ||
        _match(model, r'^u\d') ||
        _match(model, r'^74') || // 74HC595 等逻辑芯片
        _match(model, r'^cd\d') || // CD4017 等 4000 系列芯片
        lower.contains('lm') ||
        lower.contains('max') ||
        lower.contains('stm') ||
        model.contains('芯片')) {
      return AppCategories.ic;
    }

    // ---------- 4. 二极管：D+数字 开头 / 1N+数字 / Diode / 二极管 ----------
    if (_match(model, r'^d\d') ||
        _match(model, r'1n\d') || // 1N4007、1N4148 等
        lower.contains('diode') ||
        model.contains('二极管')) {
      return AppCategories.diode;
    }

    // ---------- 5. 三极管：Q+数字 / S8050 S8550 SS8050 SS8550 / 2N+数字 / Triode / MOSFET ----------
    if (_match(model, r'^q\d') ||
        _match(model, r'^2n\d') || // 2N3904、2N2222 等
        _match(model, r'^s8\d') || // S8050、S8550
        _match(model, r'^ss8\d') || // SS8050、SS8550
        lower.contains('triode') ||
        model.contains('三极管') ||
        lower.contains('mosfet') ||
        model.contains('场效应')) {
      return AppCategories.transistor;
    }

    // ---------- 6. 连接器：Header / CONN / USB / 排针 排母 连接器 端子 ----------
    if (lower.contains('header') ||
        lower.contains('conn') ||
        lower.contains('usb') ||
        model.contains('排针') ||
        model.contains('排母') ||
        model.contains('连接器') ||
        model.contains('端子')) {
      return AppCategories.connector;
    }

    // ---------- 7. 晶振：X+数字 开头 / MHz kHz / Crystal / 晶振 ----------
    if (_match(model, r'^x\d') ||
        lower.contains('mhz') ||
        lower.contains('khz') ||
        lower.contains('crystal') ||
        model.contains('晶振')) {
      return AppCategories.crystal;
    }

    // ---------- 8. 其他：无法匹配 ----------
    return AppCategories.other;
  }

  /// 正则辅助：不区分大小写地匹配 `pattern`（用于 ^ 开头的锚定规则）。
  static bool _match(String input, String pattern) {
    return RegExp(pattern, caseSensitive: false).hasMatch(input);
  }

  /// 分类对应的主题色（用于列表左侧标识与分类标签）。
  static Color categoryColor(String category) {
    switch (category) {
      case AppCategories.resistor:
        return const Color(0xFFEF6C00); // 橙
      case AppCategories.capacitor:
        return const Color(0xFF1565C0); // 蓝
      case AppCategories.ic:
        return const Color(0xFF6A1B9A); // 紫
      case AppCategories.diode:
        return const Color(0xFF00838F); // 青
      case AppCategories.transistor:
        return const Color(0xFF2E7D32); // 绿
      case AppCategories.connector:
        return const Color(0xFF6D4C41); // 棕
      case AppCategories.crystal:
        return const Color(0xFF3949AB); // 靛
      default:
        return const Color(0xFF546E7A); // 蓝灰
    }
  }

  /// 分类缩写标识（沿用电路图位号习惯：R/C/U/D/Q/J/X）。
  static String shortLabel(String category) {
    switch (category) {
      case AppCategories.resistor:
        return 'R';
      case AppCategories.capacitor:
        return 'C';
      case AppCategories.ic:
        return 'U';
      case AppCategories.diode:
        return 'D';
      case AppCategories.transistor:
        return 'Q';
      case AppCategories.connector:
        return 'J';
      case AppCategories.crystal:
        return 'X';
      default:
        return '?';
    }
  }
}
