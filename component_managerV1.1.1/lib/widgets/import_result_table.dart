import 'package:flutter/material.dart';

import '../core/utils/bom_compare.dart';

/// BOM 对比结果表：状态徽章 + 型号 + 需求 + 库存 + 缺料。
/// 固定高度（默认 320），内部 [ListView] 可滚动，适配长 BOM。
class ImportResultTable extends StatelessWidget {
  final List<BomCompareRow> rows;
  final double height;

  /// 非「充足」行的替代入口回调（null 则整表不显示替代按钮）。
  final void Function(BomCompareRow row)? onSubstitute;

  /// 行下标 → 已缓存的 AI 建议数（批处理页回传），>0 时行内显示「AI×n」徽标。
  final Map<int, int>? aiCounts;

  const ImportResultTable({
    super.key,
    required this.rows,
    this.height = 320,
    this.onSubstitute,
    this.aiCounts,
  });

  @override
  Widget build(BuildContext context) {
    final style =
        Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.grey);
    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                SizedBox(width: 76, child: Text('状态', style: style)),
                Expanded(flex: 3, child: Text('型号', style: style)),
                SizedBox(
                    width: 52,
                    child: Text('需求', style: style, textAlign: TextAlign.right)),
                SizedBox(
                    width: 52,
                    child: Text('库存', style: style, textAlign: TextAlign.right)),
                SizedBox(
                    width: 52,
                    child: Text('缺料', style: style, textAlign: TextAlign.right)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (ctx, i) => _ResultRow(
                row: rows[i],
                onSubstitute: onSubstitute,
                aiCount: aiCounts?[i] ?? 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final BomCompareRow row;
  final void Function(BomCompareRow row)? onSubstitute;
  final int aiCount; // 已缓存 AI 建议数（>0 显示徽标）

  const _ResultRow({
    required this.row,
    this.onSubstitute,
    this.aiCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = switch (row.status) {
      BomStatus.inStock => (Colors.green.shade50, Colors.green.shade800, '充足'),
      BomStatus.short => (Colors.orange.shade50, Colors.orange.shade800, '缺${row.shortBy}'),
      BomStatus.missing => (Colors.red.shade50, Colors.red.shade800, '待采购'),
    };
    final theme = Theme.of(context);
    final showSub = row.status != BomStatus.inStock && onSubstitute != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 76,
            padding: const EdgeInsets.symmetric(vertical: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                  color: fg, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                row.line.model,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          if (showSub)
            TextButton(
              onPressed: () => onSubstitute!(row),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('替代',
                  style: TextStyle(fontSize: 12)),
            ),
          if (aiCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'AI×$aiCount',
                  key: ValueKey('ai_badge_${row.line.model}'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          SizedBox(
            width: 52,
            child: Text('${row.line.qty}',
                style: theme.textTheme.bodySmall, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 52,
            child: Text('${row.stockOnHand}',
                style: theme.textTheme.bodySmall, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 52,
            child: Text(row.shortBy == 0 ? '—' : '${row.shortBy}',
                style: theme.textTheme.bodySmall, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}
