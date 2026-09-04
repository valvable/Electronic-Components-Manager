import 'package:flutter/material.dart';

import '../core/config/constants.dart';
import '../core/services/component_repository.dart';
import '../core/services/settings_store.dart';
import '../main.dart';
import 'category_components_screen.dart';
import 'category_manage_screen.dart';

/// 分类卡片页（底部三页的「分类」）。
///
/// 展示分类 = 系统 29 类 + 用户自创分类，每张卡片显示分类名 + 当前在用件数。
/// 点卡片 → 以「放大铺满」转场进入该分类内元件页（可搜索该分类内的元件）。
/// 右上角「管理分类」进入独立管理页（新建/改名/删除自创分类）。
class CategoriesScreen extends StatefulWidget {
  final AppState state;

  const CategoriesScreen({super.key, required this.state});

  @override
  CategoriesScreenState createState() => CategoriesScreenState();
}

/// 公开 State：底部外壳切到本页时经 GlobalKey 调用 [reload] 刷新计数。
class CategoriesScreenState extends State<CategoriesScreen> {
  Map<String, int> _counts = const {};
  List<String> _customs = const [];
  bool _loading = true;

  ComponentRepository get _repo => widget.state.components;
  SettingsStore get _settings => widget.state.settings;

  /// 展示分类 = 系统 29 类 + 自创（loadCategoryOptions 同口径：去重去空去同名）。
  List<String> get _categories => [
        ...inventoryCategories,
        for (final c in _customs)
          if (!inventoryCategories.contains(c)) c,
      ];

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 重载分类与在用件数（首次进入 / 外壳切回本页 / 管理页返回后）。
  void reload() {
    _load();
  }

  Future<void> _load() async {
    try {
      final counts =
          await _repo.countByCategory(); // 仅统计未删除（deleted_at IS NULL）
      final customs = await _settings.loadCustomCategories();
      if (!mounted) return;
      setState(() {
        _counts = counts;
        _customs = customs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载失败: $e')));
    }
  }

  Future<void> _openManage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CategoryManageScreen(state: widget.state),
      ),
    );
    if (mounted) reload(); // 管理页增删改后刷新计数/自创清单
  }

  Future<void> _openCategory(String category) async {
    await Navigator.push(
      context,
      _categoryZoomRoute(CategoryComponentsScreen(
        state: widget.state,
        category: category,
      )),
    );
    if (mounted) reload(); // 页内编辑/软删可能改计数
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('分类'),
        actions: [
          IconButton(
            key: const ValueKey('category_manage_btn'),
            tooltip: '管理分类',
            icon: const Icon(Icons.tune),
            onPressed: _openManage,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildGrid(context),
    );
  }

  Widget _buildGrid(BuildContext context) {
    final categories = _categories;
    final theme = Theme.of(context);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 168,
        mainAxisExtent: 104,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: categories.length,
      itemBuilder: (ctx, i) {
        final name = categories[i];
        final count = _counts[name] ?? 0;
        final isCustom = _customs.contains(name);
        return _CategoryCard(
          name: name,
          count: count,
          isCustom: isCustom,
          theme: theme,
          onTap: () => _openCategory(name),
        );
      },
    );
  }
}

/// 点卡片 → 放大铺满的全屏转场（淡入 + 轻微缩放，模拟卡片边缘展开）。
Route<void> _categoryZoomRoute(Widget page) {
  return PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder:
        (context, animation, secondaryAnimation, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// 单张分类卡片：首字头像 + 分类名 + 在用件数 +（自创角标）。
class _CategoryCard extends StatelessWidget {
  final String name;
  final int count;
  final bool isCustom;
  final ThemeData theme;
  final VoidCallback onTap;

  static const _colors = [
    Colors.blue,
    Colors.teal,
    Colors.orange,
    Colors.purple,
    Colors.brown,
    Colors.cyan,
    Colors.indigo,
    Colors.pink,
  ];

  const _CategoryCard({
    required this.name,
    required this.count,
    required this.isCustom,
    required this.theme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = _colors[name.hashCode.abs() % _colors.length];
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: color.withValues(alpha: 0.15),
                  child: Text(
                    name.isEmpty ? '?' : name[0],
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count 件',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            if (isCustom)
              Positioned(
                top: 4,
                right: 6,
                child: Text(
                  '自创',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
