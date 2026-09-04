import 'package:flutter/material.dart';

import '../main.dart';
import 'categories_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

/// 底部三页外壳：全部元件 / 分类 / 设置，三者平级。
/// 点底部标签或左右滑动 [PageView] 切换；每页经 [_KeepAlive] 保留各自状态
/// （首页滚动位置、设置里已填的表单等切页不丢）。
class MainShell extends StatefulWidget {
  final AppState state;

  const MainShell({super.key, required this.state});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final PageController _controller = PageController();
  int _index = 0;

  // 切到对应页时刷新其数据（分类改名 / 合并等可能已在别的页发生）。
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();
  final GlobalKey<CategoriesScreenState> _categoriesKey =
      GlobalKey<CategoriesScreenState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (i == _index) return;
    _controller.animateToPage(
      i,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _onPageChanged(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    if (i == 0) {
      _homeKey.currentState?.reload();
    } else if (i == 1) {
      _categoriesKey.currentState?.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _controller,
        onPageChanged: _onPageChanged,
        children: [
          _KeepAlive(child: HomeScreen(key: _homeKey, state: widget.state)),
          _KeepAlive(
              child: CategoriesScreen(
                  key: _categoriesKey, state: widget.state)),
          _KeepAlive(child: SettingsScreen(state: widget.state)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: '全部元件',
          ),
          NavigationDestination(
            icon: Icon(Icons.category_outlined),
            selectedIcon: Icon(Icons.category),
            label: '分类',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

/// 让 PageView 的非当前页保留 Element/State（配合 AutomaticKeepAliveClientMixin）。
class _KeepAlive extends StatefulWidget {
  final Widget child;

  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // 注册 keep-alive（返回值必须忽略）
    return widget.child;
  }
}
