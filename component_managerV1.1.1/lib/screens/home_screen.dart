import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/config/constants.dart';
import '../core/services/component_repository.dart';
import '../core/utils/component_grouping.dart';
import '../main.dart';
import '../models/component.dart';
import '../widgets/component_card.dart';
import '../widgets/component_group_tile.dart';
import 'add_component_dialog.dart';
import 'cart_import_screen.dart';
import 'detail_screen.dart';
import 'import_screen.dart';
import 'model_group_screen.dart';
import 'scan_screen.dart';
import 'sync_screen.dart';

/// 主列表（底部三页的「全部元件」）：**双列网格 + 按分类分区**。
///
/// - 默认排序（创建时间）下按「系统 29 + 自创」分类顺序自上而下分区，
///   每区双列瓦片；切「数量排序」则全库双列平铺（按组总量排）。
/// - 同型号（含不同品牌/批次）聚合为一个瓦片，数量显示**合计**；
///   点聚合瓦片进组明细页看各品牌单独数量，单条瓦点直接进详情。
/// - 搜索同样双列聚合（组瓦点按；结果里的行操作走组明细）。
/// - 回收站视图保持单列原始行（逐条恢复/彻底删除，不聚合）。
class HomeScreen extends StatefulWidget {
  final AppState state;

  const HomeScreen({super.key, required this.state});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

/// 公开 State：底部外壳 [MainShell] 切到本页时经 GlobalKey 调用 [reload]，
/// 刷新其它页（分类改名/合并）造成的列表变化。
class HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  String _sort = 'created_desc'; // qty_asc | qty_desc | created_desc
  bool _showDeleted = false;
  List<Component> _components = const [];
  bool _loading = true;

  /// 分类展示顺序（系统 29 + 自创；自创变化时随 _load 刷新）。
  List<String> _categoryOrder = inventoryCategories;

  ComponentRepository get _repo => widget.state.components;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), _load);
  }

  Future<void> _load() async {
    try {
      final q = _searchController.text.trim().toLowerCase();
      List<Component> list;
      if (_showDeleted) {
        // 回收站视图：全量含已删 + 内存过滤（不聚合，逐条恢复）。
        final all = await _repo.all(sort: _sort, includeDeleted: true);
        list = q.isEmpty
            ? all
            : all
                .where((c) =>
                    c.model.toLowerCase().contains(q) ||
                    c.cid.toLowerCase().contains(q))
                .toList();
      } else if (q.isNotEmpty) {
        list = await _repo.search(q);
      } else {
        list = await _repo.all(sort: _sort);
      }
      List<String> order = inventoryCategories;
      try {
        final customs = await widget.state.settings.loadCustomCategories();
        order = [
          ...inventoryCategories,
          for (final c in customs)
            if (!inventoryCategories.contains(c) && c.trim().isNotEmpty) c.trim(),
        ];
      } catch (_) {
        // 读设置失败仅影响自创分类的排序位置，保持系统序。
      }
      if (!mounted) return;
      setState(() {
        _components = list;
        _categoryOrder = order;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载失败: $e')));
    }
  }

  /// 底部外壳切回本页时刷新（分类改名/合并等可能已在别的页发生）。
  void reload() => _load();

  // ---- 操作 ----

  Future<void> _openAdd() async {
    final saved = await showAddComponentDialog(context, repo: _repo);
    if (saved == null || !mounted) return;
    await _load();
  }

  Future<void> _openEdit(Component c) async {
    await showAddComponentDialog(context, repo: _repo, existing: c);
    if (!mounted) return;
    await _load();
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
        content: Text('确定删除「${c.model}」吗？\n\n软删除不会丢失数据，可在回收站恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
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
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已删除（可在回收站恢复）')));
  }

  Future<void> _restore(Component c) async {
    await _repo.restore(c.id!);
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已恢复「${c.model}」')));
  }

  Future<void> _openScan() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ScanScreen(state: widget.state)),
    );
    if (!mounted) return;
    await _load(); // 扫码可能改动库存，返回后刷新
  }

  Future<void> _openImport() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ImportScreen(state: widget.state)),
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _openCartImport() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CartImportScreen(state: widget.state)),
    );
    if (!mounted) return;
    await _load(); // 入库可能改动库存，返回后刷新
  }

  Future<void> _openSync() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SyncScreen(state: widget.state)),
    );
    if (!mounted) return;
    await _load(); // 同步可能改动库存，返回后刷新
  }

  Future<void> _openDetail(Component c) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => DetailScreen(state: widget.state, component: c),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  /// 组瓦片点击：单条直接详情；聚合进组明细页。
  Future<void> _openGroup(ComponentGroup g) async {
    if (g.isSingle) {
      await _openDetail(g.primary);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ModelGroupScreen(state: widget.state, group: g),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  /// 组瓦片长按：单条给完整操作菜单；聚合先进明细页再逐条操作。
  Future<void> _showGroupMenu(ComponentGroup g) async {
    if (!g.isSingle) return _openGroup(g);
    final c = g.primary;
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
                _openEdit(c);
              },
            ),
            if (c.hasLcscCid)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('复制 CID'),
                onTap: () {
                  Navigator.pop(ctx);
                  _copyCid(c);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除（软删，可恢复）'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(c);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('详情'),
              onTap: () {
                Navigator.pop(ctx);
                _openDetail(c);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('电子元件管家'),
        actions: [
          IconButton(
            tooltip: Theme.of(context).brightness == Brightness.dark
                ? '切换到亮色'
                : '切换到黑夜模式',
            onPressed: () => widget.state.toggleDarkMode(),
            icon: Icon(
              Theme.of(context).brightness == Brightness.dark
                  ? Icons.dark_mode_outlined
                  : Icons.light_mode_outlined,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '导入（BOM 比对 / 购物车入库）',
            icon: const Icon(Icons.upload_file),
            onSelected: (v) {
              if (v == 'cart') {
                _openCartImport();
              } else {
                _openImport();
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'bom',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.compare_arrows),
                  title: Text('BOM 比对库存'),
                ),
              ),
              PopupMenuItem(
                value: 'cart',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.shopping_cart_outlined),
                  title: Text('立创购物车入库'),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: '扫码入库',
            onPressed: _openScan,
            icon: const Icon(Icons.qr_code_scanner),
          ),
          IconButton(
            tooltip: '局域网同步',
            onPressed: _openSync,
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: _showDeleted ? '回收站：开' : '回收站：关',
            onPressed: () {
              setState(() => _showDeleted = !_showDeleted);
              _load();
            },
            icon: Icon(
              _showDeleted ? Icons.delete_sweep : Icons.delete_outline,
              color: _showDeleted ? Colors.red : null,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (v) {
              setState(() => _sort = v);
              _load();
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'qty_asc', child: Text('缺货优先（数量升序）')),
              PopupMenuItem(value: 'qty_desc', child: Text('数量降序')),
              PopupMenuItem(value: 'created_desc', child: Text('创建时间（新→旧）')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: _showDeleted ? '搜索已删除元件…' : '搜索型号 / CID…',
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
      floatingActionButton: _showDeleted
          ? null
          : FloatingActionButton.extended(
              onPressed: _openAdd,
              icon: const Icon(Icons.add),
              label: const Text('添加元件'),
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
            Icon(
              _showDeleted ? Icons.delete_outline : Icons.inventory_2_outlined,
              size: 56,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Text(
              _showDeleted ? '回收站是空的' : '还没有元件，点击右下角添加',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }
    // 回收站：单列原始行；其余：双列聚合视图。
    if (_showDeleted) return _buildDeletedList();
    return _buildGroupedGrid();
  }

  Widget _buildDeletedList() {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 4, bottom: 88),
        itemCount: _components.length,
        itemBuilder: (ctx, i) {
          final c = _components[i];
          return ComponentCard(
            component: c,
            onTap: () => _openDetail(c),
            onEdit: () => _openEdit(c),
            onDeleteOrRestore: () =>
                c.isDeleted ? _restore(c) : _confirmDelete(c),
            onCopyCid: () => _copyCid(c),
            onDetail: () => _openDetail(c),
          );
        },
      ),
    );
  }

  static const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 250, // 手机 ≈ 双列，宽屏自动多列
    mainAxisExtent: 108,
    crossAxisSpacing: 2,
    mainAxisSpacing: 2,
  );

  /// 双列网格；默认排序下按分类加分区标题（按分类表顺序自上而下）。
  Widget _buildGroupedGrid() {
    final sectioned = _sort == 'created_desc';
    final groups = groupComponents(
      _components,
      sort: _sort,
      categoryOrder: sectioned ? _categoryOrder : null,
    );

    Widget tile(int i) {
      final g = groups[i];
      return ComponentGroupTile(
        key: ValueKey('group_${g.category}_${g.model}'),
        group: g,
        onTap: () => _openGroup(g),
        onLongPress: () => _showGroupMenu(g),
      );
    }

    if (!sectioned) {
      return RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 88),
              sliver: SliverGrid(
                gridDelegate: _gridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => tile(i),
                  childCount: groups.length,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 按分类分区（保持 groups 的分类序）。
    final sections = <String, List<ComponentGroup>>{};
    for (final g in groups) {
      (sections[g.category] ??= []).add(g);
    }
    final catNames = sections.keys.toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              child: Text(
                '共 ${_components.length} 个元件 · ${groups.length} 组（同型号已聚合）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          for (final cat in catNames) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Row(
                  children: [
                    Text(
                      cat,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${sections[cat]!.length} 组',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              sliver: SliverGrid(
                gridDelegate: _gridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    final g = sections[cat]![i];
                    return ComponentGroupTile(
                      key: ValueKey('group_${g.category}_${g.model}'),
                      group: g,
                      onTap: () => _openGroup(g),
                      onLongPress: () => _showGroupMenu(g),
                    );
                  },
                  childCount: sections[cat]!.length,
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 88)),
        ],
      ),
    );
  }
}
