import 'dart:convert';

/// 二维码解析结果。
class QRParseResult {
  final String? cid; // 立创料号（如 C25704），可能为 null
  final String? model; // 型号，可能为 null
  final String raw; // 原始二维码内容

  const QRParseResult({this.cid, this.model, required this.raw});

  /// 是否解析出有效信息（CID 或型号任一非空即可用）。
  bool get isValid =>
      (cid != null && cid!.isNotEmpty) || (model != null && model!.isNotEmpty);

  @override
  String toString() => 'QRParseResult(cid: $cid, model: $model, raw: $raw)';
}

/// 元件袋二维码内容解析器（第二阶段扫码功能使用）。
///
/// 兼容以下常见格式（按顺序尝试）：
/// 1. JSON：`{"cid":"C25704","model":"LM358"}`（键名大小写/中英文均兼容）
/// 2. 键值对：`CID:C25704;型号:LM358`（分隔符支持 ; ；，, | 换行）
/// 3. 立创链接：`https://item.szlcsc.com/25704.html` → 拼出 C25704
/// 4. 纯料号：`C25704`（或任意文本中含 C+4~9 位数字）
/// 5. 兜底：整串内容视为型号
///
/// 注：元件袋二维码格式以实际印刷为准，解析失败时可在 UI 层引导用户
/// 手动修正，本类会始终把原始内容带回（[QRParseResult.raw]）。
class QRCodeParser {
  QRCodeParser._();

  /// C + 4~9 位数字（立创 CID 形如 C25704）。
  static final RegExp _cidRegExp = RegExp(r'C\d{4,9}', caseSensitive: false);

  /// 键值对中的 CID：CID=C25704 / 料号：C25704。
  static final RegExp _cidKvRegExp = RegExp(
    r'(?:cid|料号)\s*[:：=]\s*([A-Za-z0-9_\-]+)',
    caseSensitive: false,
  );

  /// 键值对中的型号：model=LM358 / 型号：LM358。
  static final RegExp _modelKvRegExp = RegExp(
    r'(?:model|型号)\s*[:：=]\s*([^;；，,|\n\r]+)',
    caseSensitive: false,
  );

  /// 立创商品页链接中的数字 id。
  static final RegExp _lcscUrlRegExp = RegExp(
    r'szlcsc\.com/(?:\w+/)?(\d{4,9})\.html',
    caseSensitive: false,
  );

  /// 解析二维码原始文本。
  static QRParseResult parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return QRParseResult(raw: text);

    String? cid;
    String? model;

    // 1) JSON 格式
    if (text.startsWith('{')) {
      try {
        final obj = jsonDecode(text);
        if (obj is Map) {
          cid = _firstString(obj, const ['cid', 'CID', 'code', '料号', 'id']);
          model = _firstString(obj, const ['model', '型号', 'name', 'title', 'desc']);
        }
      } catch (_) {
        // 不是合法 JSON，忽略，继续走后面的规则
      }
    }

    // 2) 键值对格式
    cid ??= _cidKvRegExp.firstMatch(text)?.group(1);
    model ??= _modelKvRegExp.firstMatch(text)?.group(1)?.trim();

    // 3) 立创链接：用数字 id 拼出 CID
    final urlMatch = _lcscUrlRegExp.firstMatch(text);
    cid ??= urlMatch != null ? 'C${urlMatch.group(1)}' : null;

    // 4) 任意文本中的 C+数字 串（含纯料号场景）
    cid ??= _cidRegExp.firstMatch(text)?.group(0)?.toUpperCase();

    // 5) 兜底：整串视为型号；若已识别出 CID，则去掉 CID 后的剩余部分作为型号
    if (model == null || model.isEmpty) {
      if (cid != null) {
        final remain = text
            .replaceAll(RegExp(RegExp.escape(cid), caseSensitive: false), ' ')
            .trim();
        model = remain.isEmpty ? null : remain;
      } else {
        model = text;
      }
    }

    return QRParseResult(cid: cid, model: model, raw: text);
  }

  /// 从 Map 中按候选键顺序取第一个非空字符串。
  static String? _firstString(Map obj, List<String> keys) {
    for (final key in keys) {
      final v = obj[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }
}
