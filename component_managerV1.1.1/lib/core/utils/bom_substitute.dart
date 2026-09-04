/// 本地库存替代候选：同分类 / 近型号 / 封装相近 的纯函数打分。
///
/// 完全离线可用（不碰 settings / 网络），是 BOM 缺料替代的第一层；
/// AI 仅在本地没有可靠候选时兜底。
library;

import '../../models/component.dart';
import 'fuzzy.dart';

/// 一条本地替代候选。
class LocalSubstitute {
  final Component component;
  final double confidence; // 0.0~1.0
  final String reason; // 中文，如「同分类：电容；封装一致 0805；库存 12」

  const LocalSubstitute({
    required this.component,
    required this.confidence,
    required this.reason,
  });
}

/// 从库存中挑 top N 个候选替代 [model] 的元件。
///
/// - [categoryHint]：目标行命中元件的分类，或按型号分类器推得（无目标时 null，
///   C 号行退化到仅按型号距离）。
/// - [packageHint]：目标行命中元件的封装（缺料行可用）；无则用型号文本兜底匹配。
/// - [excludeIds]：本行 matched 及其它行已占用 id，避免推荐自己或已匹配件。
/// - 过滤 `quantity > 0` 且未删除；保留同分类 或 型号距离 ≤ 2 的候选。
/// - 排序：同分类 > 型号近 > 封装相符 > 库存多。
List<LocalSubstitute> topLocalSubstitutes({
  required String model,
  String? categoryHint,
  String? packageHint,
  required List<Component> inventory,
  Set<int> excludeIds = const {},
  int topN = 3,
}) {
  final q = model.trim();
  if (q.isEmpty) return const [];
  final catTarget = categoryHint?.trim();
  final pkgTarget = packageHint?.trim();

  final candidates = <_Scored>[];
  for (final c in inventory) {
    if (c.isDeleted || c.quantity <= 0) continue;
    if (excludeIds.contains(c.id)) continue;
    final sameCat =
        catTarget != null && catTarget.isNotEmpty && c.category == catTarget;
    final dist = similarityScore(
      c.model.trim().toLowerCase(),
      c.cid.trim().toLowerCase(),
      q.toLowerCase(),
    );
    if (!sameCat && dist > 2) continue; // 既不同类又不相似 → 不作替代候选
    final pkg = _pkgMatch(
      c.package,
      (pkgTarget != null && pkgTarget.isNotEmpty) ? pkgTarget : q,
    );
    candidates.add(_Scored(c: c, sameCat: sameCat, dist: dist, pkg: pkg));
  }

  candidates.sort((a, b) {
    if (a.sameCat != b.sameCat) return a.sameCat ? -1 : 1;
    if (a.dist != b.dist) return a.dist.compareTo(b.dist);
    if (a.pkg != b.pkg) return a.pkg ? -1 : 1;
    return b.c.quantity.compareTo(a.c.quantity);
  });

  return [for (final s in candidates.take(topN)) _toSubstitute(s)];
}

/// 候选封装是否与目标相符：归一化包含判断 + 编辑距离兜底。
bool _pkgMatch(String? pkg, String target) {
  if (pkg == null) return false;
  final p = pkg.trim().toLowerCase();
  if (p.isEmpty) return false;
  final t = target.trim().toLowerCase();
  if (t.isEmpty) return false;
  if (t.contains(p)) return true;
  String norm(String s) => s.replaceAll(RegExp(r'[-_/. ()]'), '');
  return norm(t).contains(norm(p)) || levenshtein(p, t) <= 2;
}

class _Scored {
  final Component c;
  final bool sameCat;
  final int dist;
  final bool pkg;

  const _Scored({
    required this.c,
    required this.sameCat,
    required this.dist,
    required this.pkg,
  });
}

LocalSubstitute _toSubstitute(_Scored s) {
  final c = s.c;
  final parts = <String>[];
  if (s.sameCat) parts.add('同分类：${c.category}');
  if (s.dist <= 2) parts.add('型号相近');
  if (s.pkg) parts.add('封装一致 ${c.package}');
  parts.add('库存 ${c.quantity}');

  final double conf;
  if (s.sameCat && s.pkg && s.dist <= 2) {
    conf = 0.95;
  } else if (s.sameCat && (s.pkg || s.dist <= 2)) {
    conf = 0.85;
  } else if (s.sameCat) {
    conf = 0.7;
  } else {
    conf = 0.55; // 跨分类但型号很近
  }
  return LocalSubstitute(component: c, confidence: conf, reason: parts.join('；'));
}
