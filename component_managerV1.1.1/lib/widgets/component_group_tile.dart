import 'package:flutter/material.dart';

import '../core/utils/component_grouping.dart';
import 'quantity_badge.dart';

/// 首页双列网格的元件组瓦片：同型号聚合为一条（数量 = 组内总量）。
///
/// - 单行组：与旧列表卡同义（型号/CID/品牌/位置），点击进详情；
/// - 多行组（多品牌/多批次）：副标题标「N 个品牌 · M 条」，点击进入组明细页，
///   明细里逐行看各品牌数量；
/// - 数量 ≤0 灰显「缺货」；长按弹操作菜单（同列表卡）。
class ComponentGroupTile extends StatelessWidget {
  final ComponentGroup group;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const ComponentGroupTile({
    super.key,
    required this.group,
    required this.onTap,
    this.onLongPress,
  });

  static const _avatarColors = [
    Colors.blue,
    Colors.teal,
    Colors.orange,
    Colors.purple,
    Colors.brown,
    Colors.cyan,
    Colors.indigo,
    Colors.pink,
  ];

  static String _singleLine(ComponentGroup group) {
    final c = group.primary;
    final parts = [
      if (c.hasLcscCid) c.cid,
      if (c.brand?.trim().isNotEmpty == true) c.brand!.trim(),
      if (c.location?.trim().isNotEmpty == true) '位置 ${c.location!.trim()}',
    ];
    return parts.isEmpty ? '无 C 号' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = group.primary;
    final out = !c.isDeleted && group.totalQty <= 0;
    final avatarColor =
        _avatarColors[group.category.hashCode.abs() % _avatarColors.length];

    return Opacity(
      opacity: out ? 0.6 : 1.0,
      child: Card(
        margin: const EdgeInsets.all(4),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: avatarColor.withValues(alpha: 0.15),
                      child: Text(
                        group.category.isEmpty ? '?' : group.category[0],
                        style: TextStyle(
                            color: avatarColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        group.model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    QuantityBadge(quantity: group.totalQty),
                  ],
                ),
                const Spacer(),
                Text(
                  group.category,
                  maxLines: 1,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                Text(
                  group.isSingle
                      ? _singleLine(group)
                      : '${group.items.length} 条 · ${group.brandCount} 个品牌',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: group.isSingle
                        ? theme.colorScheme.outline
                        : theme.colorScheme.tertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
