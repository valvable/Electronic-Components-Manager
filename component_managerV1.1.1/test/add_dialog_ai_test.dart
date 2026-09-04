import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/ai_client.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/core/services/settings_store.dart';
import 'package:component_manager/models/component.dart';
import 'package:component_manager/screens/add_component_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 添加对话框「AI 查询」：注入假 aiClassifyLookup，验证分类覆盖/空槽回填/
/// 未知分类兜底/失败保持/编辑态可用/与立创查料并存。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  String fieldText(WidgetTester tester, int index) =>
      tester.widget<TextFormField>(find.byType(TextFormField).at(index)).controller!.text;

  String dropdownValue(WidgetTester tester) =>
      tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>)).value!;

  Future<ComponentRepository> openDialog(
    WidgetTester tester, {
    AiClassifyLookup? aiLookup,
    Component? existing,
  }) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db =
        (await tester.runAsync(() => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);
    final repo = ComponentRepository(db);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () => showAddComponentDialog(
                ctx,
                repo: repo,
                existing: existing,
                aiClassifyLookup: aiLookup,
              ),
              child: const Text('打开添加'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开添加'));
    await tester.pumpAndSettle();
    return repo;
  }

  const fakeGood = AiClassifySuggestion(
      category: '电容', package: '0805', note: 'AI 备注', confidence: 0.9);

  testWidgets('输型号出现「AI 查询」；成功 → 分类覆盖、空槽才填、模型/CID 不变', (tester) async {
    await openDialog(tester, aiLookup: (model, cid) async => fakeGood);

    expect(find.text('AI 查询'), findsNothing); // 未输内容不显示

    await tester.enterText(find.byType(TextFormField).at(0), 'CL0805');
    await settle(tester);
    expect(find.text('AI 查询'), findsOneWidget);

    await tester.tap(find.text('AI 查询'));
    await settle(tester);

    expect(dropdownValue(tester), '电容');
    expect(fieldText(tester, 2), '0805'); // 封装空槽填入
    expect(fieldText(tester, 5), 'AI 备注'); // 备注空槽填入
    expect(fieldText(tester, 0), 'CL0805'); // 型号不变
    expect(fieldText(tester, 1), isEmpty); // CID 未被乱填
    expect(find.textContaining('AI：电容'), findsOneWidget);
    expect(find.textContaining('置信度 90%'), findsOneWidget);
  });

  testWidgets('封装/备注已有内容时 AI 不覆盖', (tester) async {
    await openDialog(tester, aiLookup: (model, cid) async => fakeGood);
    await tester.enterText(find.byType(TextFormField).at(0), 'CL0805');
    await settle(tester);
    await tester.enterText(find.byType(TextFormField).at(2), 'SOT-23');
    await settle(tester);

    await tester.tap(find.text('AI 查询'));
    await settle(tester);

    expect(fieldText(tester, 2), 'SOT-23'); // 已有封装保留
    expect(dropdownValue(tester), '电容');
  });

  testWidgets('AI 分类不在清单 → 确认后创建为自创分类并采用', (tester) async {
    final repo = await openDialog(
      tester,
      existing: Component(
        cid: 'C25704',
        model: 'RC0603FR-0710KL',
        category: '其他',
        createdAt: 1,
        updatedAt: 1,
      ),
      aiLookup: (model, cid) async =>
          const AiClassifySuggestion(category: '微控制器'), // 不在 29 类
    );
    await settle(tester);
    expect(find.text('AI 查询'), findsOneWidget); // 编辑态也显示

    await tester.tap(find.text('AI 查询'));
    await settle(tester);

    // 弹窗确认创建新自创分类
    expect(find.text('使用新分类？'), findsOneWidget);
    await tester.tap(find.text('创建并使用'));
    await settle(tester);

    expect(dropdownValue(tester), '微控制器'); // 采用 AI 新分类
    expect(fieldText(tester, 5), contains('已创建为自创分类')); // 备注空槽落说明
    expect(fieldText(tester, 0), 'RC0603FR-0710KL'); // 型号不变
    expect(fieldText(tester, 1), 'C25704'); // CID 不变

    // 落库成自创分类（不再只在本次弹窗里有效）
    final customs = (await tester.runAsync(
        () => SettingsStore(repo.db).loadCustomCategories()))!;
    expect(customs, contains('微控制器'));
  });

  testWidgets('AI 分类不在清单 → 取消创建则按型号兜底、不污染分类表', (tester) async {
    final repo = await openDialog(
      tester,
      existing: Component(
        cid: 'C25704',
        model: 'RC0603FR-0710KL', // classify → 电阻
        category: '其他',
        createdAt: 1,
        updatedAt: 1,
      ),
      aiLookup: (model, cid) async =>
          const AiClassifySuggestion(category: '微控制器'),
    );
    await settle(tester);

    await tester.tap(find.text('AI 查询'));
    await settle(tester);

    expect(find.text('使用新分类？'), findsOneWidget);
    await tester.tap(find.text('不创建'));
    await settle(tester);

    expect(dropdownValue(tester), '电阻'); // 兜底 classify(model)
    expect(fieldText(tester, 5), contains('未创建')); // 备注空槽落说明
    final customs = (await tester.runAsync(
        () => SettingsStore(repo.db).loadCustomCategories()))!;
    expect(customs, isEmpty); // 没写库
  });

  testWidgets('AI 抛异常 → 提示失败且字段不动', (tester) async {
    await openDialog(
      tester,
      aiLookup: (model, cid) async => throw AiHttpException(401),
    );
    await tester.enterText(find.byType(TextFormField).at(0), 'LM358N');
    await settle(tester);
    await tester.tap(find.text('AI 查询'));
    await settle(tester);

    expect(find.textContaining('AI 查询失败'), findsOneWidget);
    expect(find.textContaining('401'), findsOneWidget);
    expect(fieldText(tester, 0), 'LM358N'); // 型号未被覆盖
    expect(fieldText(tester, 2), isEmpty); // 封装未被乱填
  });

  testWidgets('新增 + 合法 C 号：AI 与立创查料按钮并存', (tester) async {
    await openDialog(tester, aiLookup: (model, cid) async => fakeGood);
    await tester.enterText(find.byType(TextFormField).at(1), 'C25704');
    await settle(tester);

    expect(find.text('AI 查询'), findsOneWidget);
    expect(find.text('从立创查料自动填充'), findsOneWidget);
  });
}
