import 'package:flutter/material.dart';

import '../models/component.dart';
import '../utils/category_recognizer.dart';

/// 单个元件的列表卡片（紧凑布局）。
///
/// 一行展示关键信息：
/// - 左侧：分类标识（颜色 + 位号字母 R/C/U/D/Q/J/X）
/// - 标题：型号 + 分类标签
/// - 副标题：CID / 封装 / 位置 / 备注
/// - 右侧：数量（缺货红色、低库存橙色）+ 操作菜单（编辑/删除）
class ComponentCard extends StatelessWidget {
  final Component component;
  final VoidCallback onTap; // 点击卡片（快捷打开编辑）
  final VoidCallback onEdit; // 菜单：编辑
  final VoidCallback onDelete; // 菜单：删除

  const ComponentCard({
    super.key,
    required this.component,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = component;
    final color = CategoryRecognizer.categoryColor(c.category);
    final qtyColor = c.isOutOfStock
        ? const Color(0xFFD32F2F)
        : c.isLowStock
            ? const Color(0xFFEF6C00)
            : Theme.of(context).colorScheme.onSurface;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: ListTile(
          dense: true,
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: color.withOpacity(0.14),
            child: Text(
              CategoryRecognizer.shortLabel(c.category),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  c.model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  c.category,
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 数量角标：缺货标红，1~10 标橙
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    c.isOutOfStock ? '缺货' : '${c.quantity}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: qtyColor,
                    ),
                  ),
                  Text(
                    c.isOutOfStock ? '待采购' : 'PCS',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
              // 操作菜单：编辑 / 删除
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'edit',
                    height: 40,
                    child: _MenuRow(icon: Icons.edit_outlined, label: '编辑'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    height: 40,
                    child: _MenuRow(
                        icon: Icons.delete_outline, label: '删除', danger: true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 副标题：把非空字段拼接成一行。
  String get _subtitle {
    final parts = <String>['CID: ${component.cid}'];
    if (component.package?.isNotEmpty == true) {
      parts.add('封装: ${component.package}');
    }
    if (component.location?.isNotEmpty == true) {
      parts.add('位置: ${component.location}');
    }
    if (component.note?.isNotEmpty == true) {
      parts.add('备注: ${component.note}');
    }
    return parts.join('  ·  ');
  }
}

/// 菜单项内容（图标 + 文字）。
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool danger;

  const _MenuRow({required this.icon, required this.label, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFD32F2F) : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 14, color: color)),
      ],
    );
  }
}
