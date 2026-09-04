import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/services/ai_client.dart';
import '../core/utils/bom_compare.dart';
import '../core/utils/bom_substitute.dart';

/// 电气参数对比页：原元件 vs 某个候选，逐参数两列表格（"类似表格"那一层）。
///
/// - 顶部 [ChoiceChip] 切换候选（AI 候选在前，本地库存候选在后）；
/// - 表格行 = 两侧参数名并序（原件键优先）：两侧都有且不等 → 橙 ⚠ 高亮；
///   相等 → 绿 ✓；单侧缺 → 灰 —。参数数据来自 AI 方案（[AiSubstitutePlan]）；
/// - 本地候选无电气参数：用分类/封装/库存/位置拼可比行，并标注说明；
/// - 底部展示候选的 risk / diff / reason。纯展示页，不落库。
class SubstituteCompareScreen extends StatefulWidget {
  final BomCompareRow row;
  final AiSubstitutePlan? plan;
  final List<LocalSubstitute> locals;

  const SubstituteCompareScreen({
    super.key,
    required this.row,
    this.plan,
    this.locals = const [],
  });

  @override
  State<SubstituteCompareScreen> createState() =>
      _SubstituteCompareScreenState();
}

/// 统一渲染模型：AI 候选与本地候选收敛到同一结构。
class _Cand {
  final String model;
  final Map<String, String> specs;
  final String? risk;
  final String? diff;
  final String? reason;
  final double? confidence;
  final String sourceLabel; // 'AI 推荐' | '本地库存'

  const _Cand({
    required this.model,
    required this.specs,
    this.risk,
    this.diff,
    this.reason,
    this.confidence,
    required this.sourceLabel,
  });
}

class _SubstituteCompareScreenState extends State<SubstituteCompareScreen> {
  int _selected = 0;

  List<_Cand> get _cands {
    return [
      for (final s in widget.plan?.suggestions ?? const <AiSubstituteSuggestion>[])
        _Cand(
          model: s.model,
          specs: s.specs,
          risk: s.risk,
          diff: s.diff,
          reason: s.reason,
          confidence: s.confidence,
          sourceLabel: 'AI 推荐',
        ),
      for (final l in widget.locals)
        _Cand(
          model: l.component.model,
          specs: _localSpecs(l),
          reason: l.reason,
          confidence: l.confidence,
          sourceLabel: '本地库存',
        ),
    ];
  }

  /// 本地候选可对比行：库存视角的基础信息（无电气参数，页内标注）。
  Map<String, String> _localSpecs(LocalSubstitute l) {
    final c = l.component;
    return {
      if (c.category.isNotEmpty) '分类': c.category,
      if (c.package?.isNotEmpty == true) '封装': c.package!,
      '库存': '${c.quantity}',
      if (c.location?.isNotEmpty == true) '位置': c.location!,
    };
  }

  /// 原元件参数行：AI 给的 specs 优先；补充型号与库存信息（有命中时）。
  Map<String, String> get _originalSpecs {
    final out = <String, String>{
      '型号': widget.row.line.model,
      if (widget.row.matched != null) '库存': '${widget.row.matched!.quantity}',
    };
    final ai = widget.plan?.originalSpecs ?? const <String, String>{};
    if (ai.isEmpty && widget.row.matched != null) {
      final m = widget.row.matched!;
      if (m.category.isNotEmpty) out['分类'] = m.category;
      if (m.package?.isNotEmpty == true) out['封装'] = m.package!;
    }
    ai.forEach((k, v) {
      // AI 给的参数覆盖同名基础行。
      out[k] = v;
    });
    return out;
  }

  /// 两侧参数名并序：原件键在前，候选独有的追加。
  List<String> _paramKeys(_Cand cand) {
    final keys = <String>{..._originalSpecs.keys, ...cand.specs.keys};
    return keys.toList();
  }

  static String _norm(String v) =>
      v.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  (IconData, Color) _rowMark(String? a, String? b) {
    if (a == null || b == null || a.isEmpty || b.isEmpty) {
      return (Icons.remove_rounded, Colors.grey);
    }
    return _norm(a) == _norm(b)
        ? (Icons.check_circle_outline, Colors.green.shade700)
        : (Icons.error_outline, Colors.orange.shade800);
  }

  Color _riskColor(String? risk) {
    if (risk == null) return Colors.grey;
    if (risk.contains('可直接') || risk.contains('兼容')) return Colors.green;
    if (risk.contains('不建议') || risk.contains('不可')) return Colors.red;
    return Colors.orange; // 需确认 / 其它自由文本按"需确认"着色
  }

  @override
  Widget build(BuildContext context) {
    final cands = _cands;
    final theme = Theme.of(context);
    final cand = cands.isEmpty ? null : cands[_selected.clamp(0, cands.length - 1)];

    return Scaffold(
      appBar: AppBar(
        title: Text('电气参数对比'),
        actions: [
          if (cand != null)
            IconButton(
              tooltip: '复制候选型号',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: cand.model));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('「${cand.model}」已复制')));
              },
            ),
        ],
      ),
      body: cand == null
          ? Center(
              child: Text('暂无可对比的候选',
                  style: TextStyle(color: Colors.grey.shade600)),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _originalHeader(theme),
                const SizedBox(height: 8),
                // ---- 候选切换 ----
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < cands.length; i++)
                      ChoiceChip(
                        key: ValueKey('compare_cand_$i'),
                        selected: i == _selected,
                        onSelected: (_) => setState(() => _selected = i),
                        label: Text(
                            '${cands[i].sourceLabel} · ${cands[i].model}'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                // ---- 两列参数表 ----
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            const SizedBox(width: 28),
                            Expanded(
                                flex: 3,
                                child: Text('参数',
                                    style: theme.textTheme.labelMedium)),
                            Expanded(
                                flex: 4,
                                child: Text('原元件 ${widget.row.line.model}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                            fontWeight: FontWeight.w600))),
                            Expanded(
                                flex: 4,
                                child: Text('候选 ${cand.model}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color: theme.colorScheme.primary))),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      for (final k in _paramKeys(cand))
                        _paramRow(context, k,
                            _originalSpecs[k], cand.specs[k]),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // ---- 候选结论区：risk / diff / reason ----
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: _riskColor(cand.risk)
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                cand.risk ?? '未给出替代结论',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _riskColor(cand.risk),
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (cand.confidence != null)
                              Text(
                                '置信度 ${(cand.confidence! * 100).round()}%',
                                style: theme.textTheme.labelMedium
                                    ?.copyWith(
                                        color: theme.colorScheme.primary),
                              ),
                          ],
                        ),
                        if (cand.diff != null && cand.diff!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text('关键差异：${cand.diff}',
                              style: theme.textTheme.bodySmall),
                        ],
                        if (cand.reason != null && cand.reason!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text('理由：${cand.reason}',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant)),
                        ],
                        if (cand.sourceLabel == '本地库存') ...[
                          const SizedBox(height: 8),
                          Text(
                            '本地库存候选：无电气参数明细，仅按分类/封装/库存对比。'
                            '想要参数级对比请用「AI 智能推荐」。',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '数据由 AI 生成，替代下单前请以官方规格书核对。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
    );
  }

  Widget _originalHeader(ThemeData theme) {
    final r = widget.row;
    final (bg, fg, label) = switch (r.status) {
      BomStatus.inStock => (Colors.green.shade50, Colors.green.shade800, '充足'),
      BomStatus.short => (
          Colors.orange.shade50,
          Colors.orange.shade800,
          '缺${r.shortBy}'
        ),
      BomStatus.missing => (Colors.red.shade50, Colors.red.shade800, '待采购'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.line.model,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    '需求 ${r.line.qty} · 库存 ${r.stockOnHand}'
                    '${r.line.designation != null ? ' · 位号 ${r.line.designation}' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(label,
                  style: TextStyle(
                      color: fg,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _paramRow(BuildContext context, String key, String? a, String? b) {
    final theme = Theme.of(context);
    final (icon, color) = _rowMark(a, b);
    final differs =
        icon == Icons.error_outline; // 差异行整行淡橙底，扫一眼能定位
    return Container(
      key: ValueKey('compare_row_$key'),
      color: differs
          ? Colors.orange.shade50.withValues(alpha: 0.6)
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 12),
          Expanded(
              flex: 3,
              child: Text(key,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600))),
          Expanded(
              flex: 4,
              child: Text(a?.isNotEmpty == true ? a! : '—',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall)),
          Expanded(
              flex: 4,
              child: Text(b?.isNotEmpty == true ? b! : '—',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: differs ? Colors.orange.shade900 : null,
                      fontWeight:
                          differs ? FontWeight.w600 : FontWeight.normal))),
        ],
      ),
    );
  }
}

/// 便捷入口：从替代面板/批处理页 push 对比页。
Future<void> showSubstituteCompare(
  BuildContext context, {
  required BomCompareRow row,
  AiSubstitutePlan? plan,
  List<LocalSubstitute> locals = const [],
}) {
  return Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => SubstituteCompareScreen(
          row: row, plan: plan, locals: locals),
    ),
  );
}
