import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// settings_screen 冒烟：入口渲染。备份/恢复动作依赖文件对话框，其逻辑由
/// backup_restore_test / export_service_test 覆盖。
void main() {
  testWidgets('设置页渲染：备份/恢复/AI 表单/安全说明', (tester) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db =
        (await tester.runAsync(() => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(state: AppState(db))));
    // initState 会异步回填 AI 配置，需让出真实事件循环等其完成
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('恢复备份'), findsOneWidget);
    expect(find.text('AI 查询'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget); // AI 表单输入框首屏可见
    expect(find.text('保存'), findsOneWidget);

    // AI 表单比旧占位高，「关于」卡被推到视口下方，滚动后可见
    await tester.dragUntilVisible(
      find.textContaining('Base64'),
      find.byType(ListView),
      const Offset(0, -100),
    );
    expect(find.textContaining('Base64'), findsOneWidget);
  });
}
