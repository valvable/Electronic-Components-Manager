import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/services/component_repository.dart';
import '../core/utils/component_grouping.dart';
import '../main.dart';
import '../models/component.dart';
import '../widgets/component_card.dart';
import '../widgets/quantity_badge.dart';
import 'add_component_dialog.dart';
import 'detail_screen.dart';

/// 同型号元件组明细页（首页双列瓦片点进来）。
///
/// 顶部汇总卡：型号 / 分类 / 合计数量 / 条数与品牌数；
/// 下方逐行复用 [ComponentCard] 展示**每个品牌的单独数量**、CID/位置等，
/// 支持编辑、软删、复制 CID、进详情——操作后自动重聚合。
class ModelGroupScreen extends StatefulWidget {
  final AppState state;
  final ComponentGroup group;

  const ModelGroupScreen({super.key, required this.state, required this.group});

  @override
  State<ModelGroupScreen> createState() => _ModelGroupScreenState();
}

class _ModelGroupScreenState extends State<ModelGroupScreen> {
  late List<Component> _items = List.of(widget.group.items);

  ComponentRepository get _repo => widget.state.components;

  int get _total => _items.fold(0, (s, c) => s + c.quantity);

  Future<void> _reload() async {
    final ids = _items.map((c) => c.id).toSet();
    final all = await _repo.all();
    if (!mounted) return;
    setState(() {
      // 保留仍存在的行；编辑后型号改到别的组则从本页消失。
      _items = all.where((c) => ids.contains(c.id)).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    });
  }

  Future<void> _openDetail(Component c) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => DetailScreen(state: widget.state, component: c),
      ),
    );
    if (changed == true && mounted) await _reload();
  }

  Future<void> _openEdit(Component c) async {
    await showAddComponentDialog(context, repo: _repo, existing: c);
    if (mounted) await _reload();
  }

  Future<void> _copyCid(Component c) async {
    await Clipboard.setData(ClipboardData(text: c.cid));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('CID ${c.cid} 已复制')));
  }

  Future<void> _confirmDelete(Component c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除元件'),
        content: Text('确定将「${c.model}」（${c.brand?.isNotEmpty == true ? c.brand : '未填品牌'}）'
            '移入回收站吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _repo.delete(c.id!);
    if (!mounted) return;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.group.model)),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${widget.group.category} · ${_items.length} 条'
                          '（$_brandCount 种品牌写法）',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '同型号不同品牌/批次各自一行，这里显示各自数量',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('合计', style: theme.textTheme.labelSmall),
                      QuantityBadge(quantity: _total),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('该组元件都已移出'))
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 24),
                    itemCount: _items.length,
                    itemBuilder: (ctx, i) {
                      final c = _items[i];
                      return ComponentCard(
                        component: c,
                        onTap: () => _openDetail(c),
                        onEdit: () => _openEdit(c),
                        onDeleteOrRestore: () => c.isDeleted
                            ? _repo.restore(c.id!).then((_) => _reload())
                            : _confirmDelete(c),
                        onCopyCid: () => _copyCid(c),
                        onDetail: () => _openDetail(c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  int get _brandCount => _items
      .map((c) => (c.brand?.trim().isEmpty ?? true) ? '' : c.brand!.trim())
      .toSet()
      .length;
}
