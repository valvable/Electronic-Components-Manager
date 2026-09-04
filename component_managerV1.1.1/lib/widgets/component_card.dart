import 'package:flutter/material.dart';

import '../models/component.dart';
import 'quantity_badge.dart';

/// 列表卡片：型号 / CID / 位置 / 分类标签 + 数量角标。
///
/// - 数量 ≤ 0 置灰并显示「缺货」角标（[QuantityBadge]）。
/// - 已删除（回收站视图）：整卡描红淡色 + 「已删除」角标。
/// - 长按弹出操作菜单：编辑 / 复制CID / 删除（或恢复） / 详情。
class ComponentCard extends StatelessWidget {
  final Component component;
  final VoidCallback onEdit;
  final VoidCallback onDeleteOrRestore;
  final VoidCallback onCopyCid;
  final VoidCallback onDetail;
  final VoidCallback? onTap;

  const ComponentCard({
    super.key,
    required this.component,
    required this.onEdit,
    required this.onDeleteOrRestore,
    required this.onCopyCid,
    required this.onDetail,
    this.onTap,
  });

  /// 分类首字作为圆形图标底色（简单色板循环）。
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

  Future<void> _showMenu(BuildContext context) async {
    final c = component;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(c.model),
              subtitle: Text(c.hasLcscCid ? 'CID: ${c.cid}' : '无 C 号（散料/内部编号）'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(ctx);
                onEdit();
              },
            ),
            if (c.hasLcscCid)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('复制 CID'),
                onTap: () {
                  Navigator.pop(ctx);
                  onCopyCid();
                },
              ),
            ListTile(
              leading: Icon(
                c.isDeleted ? Icons.restore_outlined : Icons.delete_outline,
                color: c.isDeleted ? Colors.teal : Colors.red,
              ),
              title: Text(c.isDeleted ? '恢复' : '删除（软删，可恢复）'),
              onTap: () {
                Navigator.pop(ctx);
                onDeleteOrRestore();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('详情'),
              onTap: () {
                Navigator.pop(ctx);
                onDetail();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = component;
    final deleted = c.isDeleted;
    final out = !deleted && c.quantity <= 0;
    final theme = Theme.of(context);

    final avatarColor =
        _avatarColors[c.category.hashCode.abs() % _avatarColors.length];
    final String subtitle = [
      if (c.hasLcscCid) 'CID: ${c.cid}',
      if (c.brand != null && c.brand!.isNotEmpty) c.brand,
      if (c.location != null && c.location!.isNotEmpty) '位置: ${c.location}',
      if (c.package != null && c.package!.isNotEmpty) c.package,
    ].join(' · ');

    return Opacity(
      opacity: deleted ? 1.0 : (out ? 0.6 : 1.0),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        color: deleted
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.25)
            : null,
        child: ListTile(
          onTap: onTap,
          onLongPress: () => _showMenu(context),
          leading: CircleAvatar(
            backgroundColor: avatarColor.withValues(alpha: 0.15),
            child: Text(
              c.categoryOrOther.isEmpty ? '?' : c.categoryOrOther[0],
              style: TextStyle(color: avatarColor, fontWeight: FontWeight.bold),
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  c.model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    decoration: deleted ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              QuantityBadge(quantity: c.quantity),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      c.categoryOrOther,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (c.isNoCidEntry)
                    Text(
                      '无 C 号',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  if (deleted && c.deletedAt != null)
                    Text(
                      '已删除 ${_fmtTime(c.deletedAt!)}',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtTime(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${p2(dt.month)}-${p2(dt.day)} ${p2(dt.hour)}:${p2(dt.minute)}';
  }
}
