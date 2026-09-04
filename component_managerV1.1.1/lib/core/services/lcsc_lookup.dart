import 'dart:convert';
import 'dart:io';

import '../config/constants.dart';
import '../utils/classifier.dart';

/// 立创(LCSC) C 号查询：输入 C25704 自动填充元件型号/分类/封装/简介。
///
/// 数据源：立创**国际站** `www.lcsc.com/product-detail/<C号>.html` 商品页内嵌的
/// `__NEXT_DATA__.props.pageProps.webData` JSON（免 Key，页面内嵌完整产品数据）。
/// 属页面结构解析（非官方承诺 API），页面改版可能失效；国内站 szlcsc 反爬更严不采用。
class LcscPartInfo {
  final String productCode;
  final String? productModel; // 型号（厂商料号）
  final String? brandName; // 品牌
  final String? catalogName; // LCSC 分类（英文，如 Chip Resistor - Surface Mount）
  final String? package; // 封装（encapStandard）
  final String? description; // 简介（productIntroEn / productNameEn 兜底）
  final String? datasheetUrl; // 数据手册 PDF

  const LcscPartInfo({
    required this.productCode,
    this.productModel,
    this.brandName,
    this.catalogName,
    this.package,
    this.description,
    this.datasheetUrl,
  });
}

/// C 号形如 `C` + 至少 5 位数字（与添加对话框 CID 校验一致）。
bool isLcscCode(String code) =>
    RegExp(r'^C\d{5,}$').hasMatch(code.trim().toUpperCase());

/// 规范化：去空白并大写。
String normalizeLcscCode(String raw) => raw.trim().toUpperCase();

/// 从国际站商品页 HTML 解析产品数据；结构不符 / 无 webData 返回 null。
LcscPartInfo? parseLcscPage(String html) {
  final m = RegExp(
    r'<script id="__NEXT_DATA__" type="application/json"[^>]*>(.*?)</script>',
    dotAll: true,
  ).firstMatch(html);
  if (m == null) return null;

  final Object? decoded;
  try {
    decoded = jsonDecode(m.group(1)!);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;

  final pageProps = decoded['props'];
  if (pageProps is! Map<String, dynamic>) return null;
  final webData = pageProps['pageProps'];
  if (webData is! Map<String, dynamic>) return null;
  final wd = webData['webData'];
  if (wd is! Map<String, dynamic>) return null;

  final code = (wd['productCode'] as String?) ?? '';
  if (code.isEmpty) return null; // 非商品页（404 等）

  return LcscPartInfo(
    productCode: code,
    productModel: wd['productModel'] as String?,
    brandName: wd['brandNameEn'] as String?,
    catalogName: wd['catalogName'] as String?,
    package: wd['encapStandard'] as String?,
    description: (wd['productIntroEn'] as String?) ??
        (wd['productNameEn'] as String?),
    datasheetUrl: wd['pdfUrl'] as String?,
  );
}

/// 拉取国际站商品页并解析。网络失败 / 非 200 / 非商品页返回 null（UI 提示不阻塞）。
/// [fetchImpl] 供测试注入内存客户端。
Future<LcscPartInfo?> lookupLcsc(
  String code, {
  Future<String> Function(Uri url)? fetchImpl,
}) async {
  final c = normalizeLcscCode(code);
  if (!isLcscCode(c)) return null;
  final uri = Uri.https('www.lcsc.com', '/product-detail/$c.html');

  final String body;
  if (fetchImpl != null) {
    try {
      body = await fetchImpl(uri);
    } catch (_) {
      return null;
    }
  } else {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(uri);
      // 国际站偶发校验 UA，带浏览器 UA 更稳。
      req.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      body = await utf8.decodeStream(resp);
    } on IOException {
      return null;
    } finally {
      client.close();
    }
  }
  return parseLcscPage(body);
}

/// LCSC 英文分类 → 应用中文分类（∈ [inventoryCategories]）。
/// 按序关键字命中；未命中回退 [classify]（用型号/简介 hint 试猜），再无兜底「其他」。
String categoryFromLcsc(String? catalogName, {String hint = ''}) {
  final fromCat = catalogName == null ? null : _matchCatalog(catalogName);
  if (fromCat != null) return fromCat;
  if (hint.trim().isNotEmpty) {
    final auto = classify(hint);
    if (auto != defaultCategory) return auto;
  }
  return defaultCategory;
}

/// catalogName 关键字规则（插入序 = 优先级）。值必须在 [inventoryCategories] 内。
String? _matchCatalog(String catalogName) {
  const rules = <String, String>{
    'resistor': '电阻',
    'capacitor': '电容',
    'microcontroller': '单片机',
    'mcu': '单片机',
    'processor': '单片机',
    'logic': '逻辑门',
    'op amp': '放大器',
    'amplifier': '放大器',
    'comparator': '比较器',
    'led': 'LED',
    'optocoupler': '光耦',
    'photocoupler': '光耦',
    'relay': '继电器',
    'transformer': '变压器',
    'inductor': '电感',
    'fuse': '保险丝',
    'switch': '按键开关',
    'battery': '电池',
    'crystal': '晶振',
    'oscillator': '晶振',
    'sensor': '传感器',
    'memory': '存储器',
    'flash': '存储器',
    'mosfet': '场效应管',
    'transistor': '三极管',
    'diode': '二极管',
    'voltage regulator': '电源管理',
    'ldo': '电源管理',
    'dc-dc': '电源管理',
    // usb/type-c/排针 需在泛化的 'connector' 之前命中（如 "USB Connectors"）。
    'usb': 'USB',
    'type-c': 'Type-C',
    'header': '排针排母',
    'connector': '连接器',
  };
  final s = catalogName.toLowerCase();
  for (final e in rules.entries) {
    if (s.contains(e.key)) return e.value;
  }
  return null;
}
