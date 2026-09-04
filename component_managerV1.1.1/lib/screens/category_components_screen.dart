import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/services/component_repository.dart';
import '../main.dart';
import '../models/component.dart';
import '../widgets/component_card.dart';
import 'add_component_dialog.dart';
import 'detail_screen.dart';

/// 分类内元件页：从分类卡片「放大铺满」进入，标题为该分类名。
///
/// - 顶部搜索框：防抖搜索「该分类内的元件」（repo.search + category 过滤，
///   仅显示未删除行）。
/// - 复用 [ComponentCard]：点卡片进详情、长按菜单、编辑、软删、复制 C 号
///   与「全部元件」页一致。
class CategoryComponentsScreen extends StatefulWidget {
  final AppState state;
  final String category;

  const CategoryComponentsScreen({
    super.key,
    required this.state,
    required this.category,
  });

  @override
  State<CategoryComponentsScreen> createState() =>
      _CategoryComponentsScreenState();
}

class _CategoryComponentsScreenState extends State<CategoryComponentsScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  List<Component> _components = const [];
  bool _loading = true;

  ComponentRepository get _repo => widget.state.components;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  Future<void> _load() async {
    try {
      final q = _searchController.text.trim().toLowerCase();
      final list = q.isEmpty
          ? await _repo.all(category: widget.category)
          : await _repo.search(q, category: widget.category);
      if (!mounted) return;
      setState(() {
        // search 会带上已软删行；本页无回收站，一律只显示活动行。
        _components = list.where((c) => !c.isDeleted).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载失败: $e')));
    }
  }

  // ---- 操作 ----

  Future<void> _openDetail(Component c) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => DetailScreen(state: widget.state, component: c),
      ),
    );
    if (changed == true && mounted) _load();
  }

  Future<void> _openEdit(Component c) async {
    await showAddComponentDialog(context, repo: _repo, existing: c);
    if (mounted) _load();
  }

  Future<void> _copyCid(Component c) async {
    await Clipboard.setData(ClipboardData(text: c.cid));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('CID ${c.cid} 已复制')));
  }

  Future<void> _softDelete(Component c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除元件'),
        content: Text('确定将「${c.model}」移入回收站吗？\n\n可到「全部元件 → 回收站」恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
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
    if (mounted) _load();
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.category}（共 ${_components.length} 件）'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索「${widget.category}」内的元件…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _searchController.clear(),
                      ),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_components.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.category_outlined, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              '「${widget.category}」分类暂无元件',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: _components.length,
      itemBuilder: (ctx, i) {
        final c = _components[i];
        return ComponentCard(
          component: c,
          onTap: () => _openDetail(c),
          onEdit: () => _openEdit(c),
          onDeleteOrRestore: () => _softDelete(c),
          onCopyCid: () => _copyCid(c),
          onDetail: () => _openDetail(c),
        );
      },
    );
  }
}
