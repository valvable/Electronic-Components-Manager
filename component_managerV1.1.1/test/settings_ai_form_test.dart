import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 设置页 AI 配置表单：渲染/回填/保存持久化。不点「测试连接」（避免真网络）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  String fieldText(WidgetTester tester, String label) =>
      tester
          .widgetList<TextField>(find.byType(TextField))
          .firstWhere((t) => t.decoration?.labelText == label)
          .controller!
          .text;

  Future<AppState> openSettings(WidgetTester tester) async {
    final db =
        (await tester.runAsync(() => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);
    final state = AppState(db);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(state: state)));
    await settle(tester);
    return state;
  }

  testWidgets('渲染：AI 标题 + 三输入框 + 保存/测试连接', (tester) async {
    await openSettings(tester);
    expect(find.text('AI 查询'), findsOneWidget);
    expect(fieldText(tester, 'Base URL'), isEmpty);
    expect(fieldText(tester, 'API Key'), isEmpty);
    expect(fieldText(tester, '模型'), isEmpty);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);
  });

  testWidgets('已保存配置 → 进页自动回填（Key 掩码存储但回填原文）', (tester) async {
    final db =
        (await tester.runAsync(() => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);
    final state = AppState(db);
    await tester.runAsync(() => state.settings.saveAiConfig(
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-abc',
        model: 'deepseek-chat'));

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(state: state)));
    await settle(tester);

    expect(fieldText(tester, 'Base URL'), 'https://api.deepseek.com/v1');
    expect(fieldText(tester, 'API Key'), 'sk-abc');
    expect(fieldText(tester, '模型'), 'deepseek-chat');
    // Key 默认掩码
    expect(
        tester
            .widget<TextField>(find.byWidgetPredicate(
                (w) =>
                    w is TextField &&
                    w.decoration?.labelText == 'API Key'))
            .obscureText,
        isTrue);
  });

  testWidgets('改动保存 → loadAiConfig 读回新值', (tester) async {
    final state = await openSettings(tester);

    await tester.enterText(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Base URL'),
        'https://api.example.com/v1');
    await tester.enterText(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == '模型'),
        'gpt-4o-mini');
    await settle(tester);

    await tester.ensureVisible(find.text('保存'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await settle(tester);

    final cfg =
        await tester.runAsync(() => state.settings.loadAiConfig());
    expect(cfg!.baseUrl, 'https://api.example.com/v1');
    expect(cfg.model, 'gpt-4o-mini');
    expect(find.textContaining('已保存'), findsOneWidget);
  });

  testWidgets('全清空保存 → 清除配置', (tester) async {
    final state = await openSettings(tester);
    final url = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Base URL');
    final model = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '模型');

    await tester.enterText(url, 'x');
    await tester.enterText(model, 'm');
    await settle(tester);
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await settle(tester);

    await tester.enterText(url, '');
    await tester.enterText(model, '');
    await settle(tester);
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await settle(tester);

    final cfg = await tester.runAsync(() => state.settings.loadAiConfig());
    expect(cfg!.baseUrl, isEmpty);
    expect(cfg.model, isEmpty);
    expect(find.textContaining('已清除'), findsOneWidget);
  });
}
