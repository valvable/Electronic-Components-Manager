import '../../models/scan_result.dart';

/// 立创商城二维码解析器（纯 Dart，可单测）。
///
/// 真实样例（花括号包裹的无引号 key:value，逗号分隔，`mc:` 为空值）：
/// ```
/// {on:SO26081518766,pc:C2977076,pm:XL-1608UPC-06,qty:250,mc:,cc:1,pdi:231298193,hp:11}
/// ```
/// - `pc` → CID，`pm` → 型号，`qty` → 数量（可预填）。
///
/// 解析优先级：立创花括号格式 > pc=/pm= 参数 > 裸 CID token > 仅型号兜底。
final RegExp _cidPattern = RegExp(r'^C\d{5,}$');

/// 判断字符串是否形如立创 CID（C + 至少 5 位数字）。
bool looksLikeCid(String s) => _cidPattern.hasMatch(s.trim());

/// 主入口：解析任意扫码文本。
ScannedQr parseQr(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return const ScannedQr();

  // 1) 立创花括号格式：{k:v,k:v,...}，值内可含 ':'，每块按第一个冒号切分。
  if (t.startsWith('{') && t.endsWith('}')) {
    final inner = t.substring(1, t.length - 1);
    final Map<String, String> kv = {};
    for (final part in inner.split(',')) {
      final ci = part.indexOf(':'); // 第一个冒号；空值如 "mc:" 得空串，不偏移字段
      if (ci == -1) continue;
      kv[part.substring(0, ci).trim()] = part.substring(ci + 1).trim();
    }
    var cid = kv['pc'];
    final model = kv['pm'];
    final qty = int.tryParse(kv['qty'] ?? '');
    if ((cid == null || cid.isEmpty) && model != null && looksLikeCid(model)) {
      cid = model; // pc 缺失但 pm 形如 CID → 兜底
    }
    return ScannedQr(cid: (cid == null || cid.isEmpty) ? null : cid, model: model?.isEmpty ?? true ? null : model, qty: qty);
  }

  // 2) 参数格式：pc=...&pm=...（URL query 或嵌入文本）
  if (t.contains('=')) {
    final params = _parseQuery(t);
    var cid = params['pc'];
    final model = params['pm'];
    if ((cid == null || cid.isEmpty) && model != null && looksLikeCid(model)) {
      cid = model;
    }
    final qty = int.tryParse(params['qty'] ?? '');
    if (cid != null || model != null) {
      return ScannedQr(cid: cid, model: model, qty: qty);
    }
  }

  // 3) 裸 CID token 任意位置（纯 CID 一行 / 两行 CID+型号 / 嵌入）
  final m = RegExp(r'C\d{5,}').firstMatch(t);
  if (m != null) {
    // 同行可能带型号：取整行剩下的非 CID 文本作 model（去空白）
    final cid = m.group(0);
    // 两行时第二行可能就是型号
    final model = _candidateModel(t, cid!);
    return ScannedQr(cid: cid, model: model?.isNotEmpty == true ? model : null, qty: null);
  }

  // 4) 仅型号兜底
  return ScannedQr(cid: null, model: t, qty: null);
}

Map<String, String> _parseQuery(String s) {
  // 只取 '?' 之后（或整串）作为 query 段；去掉 '#' 片段。
  var q = s;
  final hash = q.indexOf('#');
  if (hash != -1) q = q.substring(0, hash);
  final qm = q.indexOf('?');
  if (qm != -1) q = q.substring(qm + 1);
  final Map<String, String> out = {};
  for (final pair in q.split(RegExp(r'[&;]'))) {
    final ei = pair.indexOf('=');
    if (ei == -1) continue;
    var key = pair.substring(0, ei).trim();
    // URL 无 '?' 时 key 可能带着路径前缀，如 https://item.szlcsc.com/pc=C → key='pc'
    final slash = key.lastIndexOf('/');
    if (slash != -1) key = key.substring(slash + 1);
    out[key] =
        Uri.decodeComponent(pair.substring(ei + 1).trim()).replaceAll('+', ' ');
  }
  return out;
}

String? _candidateModel(String t, String cid) {
  final lines = t
      .split(RegExp(r'[\r\n,;\s]+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && l != cid && !looksLikeCid(l))
      .toList();
  return lines.isEmpty ? null : lines.first;
}