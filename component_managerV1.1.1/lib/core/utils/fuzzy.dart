/// 模糊匹配工具（纯 Dart，可单测）。
///
/// 搜索策略：SQL LIKE 在数据库层筛出候选池，再用内存 Levenshtein 在候选内
/// 排名取前 N。这样在几千行库存里，排名只作用于被 LIKE 过滤后的几十行，开销可控。
library;

/// 经典 Levenshtein 编辑距离。带距离上限提前退出，避免对很长的异串做全矩阵计算。
int levenshtein(String a, String b, {int maxDistance = 16}) {
  if (a == b) return 0;
  final int alen = a.length, blen = b.length;
  if (a.isEmpty) return blen;
  if (b.isEmpty) return alen;
  if ((alen - blen).abs() > maxDistance) return maxDistance + 1;

  // 用两行滚动 DP 节省内存。
  List<int> prev = List<int>.generate(blen + 1, (j) => j);
  for (int i = 0; i <= alen; i++) {
    if (i == 0) continue;
    final List<int> curr = List<int>.filled(blen + 1, 0);
    curr[0] = i;
    int rowMin = curr[0];
    for (int j = 1; j <= blen; j++) {
      final int cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final int del = prev[j] + 1;
      final int ins = curr[j - 1] + 1;
      final int sub = prev[j - 1] + cost;
      int v = del < ins ? del : ins;
      v = v < sub ? v : sub;
      curr[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > maxDistance) return maxDistance + 1; // 提前退出
    prev = curr;
  }
  return prev[blen];
}

/// 排序得分：取型号与关键字、CID 与关键字二者 Levenshtein 距离的较小者。
int similarityScore(String model, String cid, String query) {
  final int m = levenshtein(model, query);
  final int c = levenshtein(cid, query);
  return m < c ? m : c;
}

/// 构造 searchWhere 的 LIKE 子句与参数。
/// 纯 CID（如 C2977076）只查 cid 列；否则查 model 或 cid 两列模糊匹配。
(String where, List<String> args) buildSearchClause(String query) {
  final q = query.trim();
  final like = '%$q%';
  if (RegExp(r'^C\d+$').hasMatch(q)) {
    return ('cid LIKE ?', [like]);
  }
  return ('(model LIKE ? OR cid LIKE ?)', [like, like]);
}