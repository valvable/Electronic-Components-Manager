import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'core/database/app_database.dart';
import 'core/services/bom_repository.dart';
import 'core/services/component_repository.dart';
import 'core/services/settings_store.dart';
import 'screens/main_shell.dart';

/// 全局应用状态：持有共享 [Database]、两个仓储与设置存取，经构造注入所有界面。
///
/// 仓储在此一次性创建并复用（同一连接），避免每屏各自打开数据库。
/// [themeMode] 为全局主题通知器：首页右上角切换后，MaterialApp 据此重建，
/// 值经 [SettingsStore] 持久化（默认亮色，测试直接构造 AppState 不受影响）。
class AppState {
  final Database db;
  late final ComponentRepository components = ComponentRepository(db);
  late final BomRepository boms = BomRepository(db);
  final SettingsStore settings;
  final ValueNotifier<ThemeMode> themeMode;

  AppState(this.db)
      : settings = SettingsStore(db),
        themeMode = ValueNotifier(ThemeMode.light);

  /// 读取持久化主题并应用；返回当前模式（供 main 首帧前设置）。
  Future<ThemeMode> loadPersistedTheme() async {
    final mode =
        await settings.loadThemeMode() == 'dark' ? ThemeMode.dark : ThemeMode.light;
    themeMode.value = mode;
    return mode;
  }

  /// 切换并持久化主题。
  Future<void> toggleDarkMode() async {
    final next = themeMode.value == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    themeMode.value = next;
    await settings.saveThemeMode(next == ThemeMode.dark ? 'dark' : 'light');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  final state = AppState(db);
  await state.loadPersistedTheme(); // 启动即应用记忆的黑夜/亮色
  runApp(ComponentManagerApp(state));
}

class ComponentManagerApp extends StatelessWidget {
  final AppState state;

  const ComponentManagerApp(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: state.themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: '电子元件管家',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: MainShell(state: state),
      ),
    );
  }
}
