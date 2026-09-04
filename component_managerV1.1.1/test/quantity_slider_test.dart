import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/add_component_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数量控件：滑块 + 直接输入双路联动，且保存取最终值。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  final qtyInput = find.byKey(const ValueKey('qty_input'));
  final qtySlider = find.byKey(const ValueKey('qty_slider'));

  String qtyText(WidgetTester tester) =>
      tester.widget<TextField>(qtyInput).controller!.text;

  testWidgets('输入框改数量 → 滑块同步 → 保存用最新数量', (tester) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = (await tester.runAsync(
        () => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);
    final repo = ComponentRepository(db);

    await tester.pumpWidget(ComponentManagerApp(AppState(db)));
    await settle(tester);

    await tester.tap(find.text('添加元件'));
    await tester.pump();
    await settle(tester);
    expect(find.byType(AddComponentDialog), findsOneWidget);

    // 填写型号与 CID
    final dialogFields = find.descendant(
        of: find.byType(AddComponentDialog), matching: find.byType(TextField));
    await tester.enterText(dialogFields.at(0), 'QTY-TEST');
    await tester.enterText(dialogFields.at(1), 'C55501');
    await tester.pump();

    // 默认 1
    expect(qtyText(tester), '1');
    expect(tester.widget<Slider>(qtySlider).value, 1);

    // 输入框直接输入 37
    await tester.enterText(qtyInput, '37');
    await tester.pump();
    expect(tester.widget<Slider>(qtySlider).value, 37);

    // 滑块回调 200 → 输入框文本同步 200（last-win：滑块为准）
    tester.widget<Slider>(qtySlider).onChanged!(200);
    await tester.pump();
    expect(qtyText(tester), '200');
    expect(tester.widget<Slider>(qtySlider).value, 200);

    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(find.byType(AddComponentDialog), findsNothing);

    // 结尾 DB 验证须包在 runAsync 里，避免 FakeAsync 遗留真实 ffi 消息拖死 runner
    final saved = await tester
        .runAsync(() async => (await repo.byCid('C55501')).component);
    expect(saved!.quantity, 200);
    expect(saved.model, 'QTY-TEST');
  });

  testWidgets('非法输入被忽略，不覆盖当前数量', (tester) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = (await tester.runAsync(
        () => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);

    await tester.pumpWidget(ComponentManagerApp(AppState(db)));
    await settle(tester);
    await tester.tap(find.text('添加元件'));
    await tester.pump();
    await settle(tester);

    await tester.enterText(qtyInput, ''); // 清空输入
    await tester.pump();
    expect(qtyText(tester), ''); // 输入中留空可接受
    expect(tester.widget<Slider>(qtySlider).value, 1); // 数量仍 1
  });
}
