import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/component.dart';
import '../utils/category_recognizer.dart';
import '../widgets/category_filter.dart';
import '../widgets/component_card.dart';
import '../widgets/component_search_bar.dart';
import 'add_component_dialog.dart';
import 'bom_import_screen.dart';

/// 首页：元件列表 + 搜索 / 分类筛选 / 排序 / 统计 + 添加入口。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();

  List<Component> _components = []; // 数据库中的全部元件
  bool _loading = true;
  String _query = '';
  String _category = AppCategories.filterAll;

  /// true：按数量升序（缺货排前面）；false：按创建时间倒序（最新录入在前）。
  bool _sortByQuantity = true;

  @override
  void initState() {
    super.initState();
    _loadComponents();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ================ 数据加载 ================

  /// 从数据库加载全部元件（内存量级对个人库存足够，筛选/排序在内存完成）。
  Future<void> _loadComponents() async {
    setState(() => _loading = true);
    try {
      final list = await DatabaseHelper.instance.getAllComponents();
      if (!mounted) return;
      setState(() => _components = list);
    } catch (e) {
      if (mounted) _toast('加载元件失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 按当前搜索词 / 分类过滤，并按排序方式排列。
  List<Component> get _filteredComponents {
    final q = _query.trim().toLowerCase();
    final result = _components.where((c) {
      final matchCategory =
          _category == AppCategories.filterAll || c.category == _category;
      final matchQuery = q.isEmpty ||
          c.model.toLowerCase().contains(q) ||
          c.cid.toLowerCase().contains(q);
      return matchCategory && matchQuery;
    }).toList();

    result.sort((a, b) {
      if (_sortByQuantity) {
        // 数量升序：缺货（0 个）自然排在最前面
        final byQty = a.quantity.compareTo(b.quantity);
        if (byQty != 0) return byQty;
      }
      // 次级/主排序：创建时间倒序（ISO8601 字符串可直接按字典序比较）
      return b.createdAt.compareTo(a.createdAt);
    });
    return result;
  }

  // ================ 交互动作 ================

  /// 打开「手动添加元件」对话框。
  Future<void> _openAddDialog() async {
    final saved = await AddComponentDialog.show(context);
    if (saved == true) await _loadComponents();
  }

  /// 打开「编辑元件」对话框。
  Future<void> _openEditDialog(Component c) async {
    final saved = await AddComponentDialog.show(context, initial: c);
    if (saved == true) await _loadComponents();
  }

  /// 删除确认 + 执行删除。
  Future<void> _confirmDelete(Component c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除元件'),
        content: Text('确定删除「${c.model}」（CID: ${c.cid}）吗？\n此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await DatabaseHelper.instance.deleteComponent(c.id!);
      await _loadComponents();
      if (mounted) _toast('已删除「${c.model}」');
    } catch (e) {
      if (mounted) _toast('删除失败：$e', error: true);
    }
  }

  /// 轻提示（SnackBar）。
  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? const Color(0xFFD32F2F) : null,
        duration: Duration(seconds: error ? 4 : 2),
      ),
    );
  }

  // ================ UI ================

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredComponents;
    return Scaffold(
      appBar: AppBar(
        title: const Text('元件库存管理'),
        actions: [
          IconButton(
            tooltip: 'BOM 库存对比（第二阶段）',
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BOMImportScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索框 + 分类筛选
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: ComponentSearchBar(
                    controller: _searchController,
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 8),
                CategoryFilter(
                  value: _category,
                  onChanged: (v) => setState(() => _category = v),
                ),
              ],
            ),
          ),
          _buildStatsBar(),
          _buildResultBar(filtered.length),
          Expanded(child: _buildList(filtered)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddDialog,
        icon: const Icon(Icons.add),
        label: const Text('添加元件'),
      ),
    );
  }

  /// 库存统计栏：元件种类 / 库存总数 / 缺货种类。
  Widget _buildStatsBar() {
    final totalQty = _components.fold<int>(0, (sum, c) => sum + c.quantity);
    final outOfStock = _components.where((c) => c.isOutOfStock).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _buildStatItem('元件种类', '${_components.length}'),
          _buildStatItem('库存总数', '$totalQty'),
          _buildStatItem(
            '缺货种类',
            '$outOfStock',
            valueColor:
                outOfStock > 0 ? const Color(0xFFD32F2F) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, {Color? valueColor}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: valueColor ?? Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 结果条：匹配数量 + 排序切换按钮。
  Widget _buildResultBar(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 0),
      child: Row(
        children: [
          Text(
            '共 $count 项',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () =>
                setState(() => _sortByQuantity = !_sortByQuantity),
            icon: Icon(
              _sortByQuantity ? Icons.low_priority : Icons.schedule,
              size: 15,
            ),
            label: Text(
              _sortByQuantity ? '缺货优先' : '最新录入',
              style: const TextStyle(fontSize: 12),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    );
  }

  /// 元件列表主体。
  Widget _buildList(List<Component> filtered) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (filtered.isEmpty) return _buildEmpty();
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 88),
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final c = filtered[i];
        return ComponentCard(
          component: c,
          onTap: () => _openEditDialog(c),
          onEdit: () => _openEditDialog(c),
          onDelete: () => _confirmDelete(c),
        );
      },
    );
  }

  /// 空状态。
  Widget _buildEmpty() {
    final isFiltering =
        _query.trim().isNotEmpty || _category != AppCategories.filterAll;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inventory_2_outlined,
              size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            _components.isEmpty ? '暂无元件' : '没有匹配的元件',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            _components.isEmpty ? '点击右下角「添加元件」开始入库' : '换个关键词或分类试试',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          if (isFiltering) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() {
                _query = '';
                _searchController.clear();
                _category = AppCategories.filterAll;
              }),
              child: const Text('清除筛选条件'),
            ),
          ],
        ],
      ),
    );
  }
}
