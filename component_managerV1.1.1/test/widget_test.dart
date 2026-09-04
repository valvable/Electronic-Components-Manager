import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/add_component_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 桌面冒烟测试：空库渲染 HomeScreen → 经添加弹窗录入一个元件 → 列表出现。
///
/// sqflite ffi 在后台 isolate 执行 SQLite，消息往返需要真实事件循环；
/// testWidgets 默认 FakeAsync 时钟下永远不会完成。因此：
/// - 数据库打开/读写全部放进 [tester.runAsync]（真实异步）；
/// - 帧推进用 [tester.pump]（假时钟），真实 I/O 等待用 runAsync 里的
///   Future.delayed 让出事件循环，二者交替直到界面稳定。
void main() {
  /// 让出真实事件循环一小段 + 推进若干帧，使 DB Future 与界面动画都落地。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('空库首页 → 添加元件 → 列表出现', (tester) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final db = (await tester.runAsync(
        () => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);

    await tester.pumpWidget(ComponentManagerApp(AppState(db)));
    await settle(tester);

    // 空库提示
    expect(find.text('还没有元件，点击右下角添加'), findsOneWidget);

    // FAB → 添加弹窗
    await tester.tap(find.text('添加元件'));
    await tester.pump();
    await settle(tester);
    expect(find.byType(AddComponentDialog), findsOneWidget);

    // 在弹窗内填写型号与 CID（搜索框不属于弹窗，用 descendant 精确定位）
    final dialogFields = find.descendant(
        of: find.byType(AddComponentDialog), matching: find.byType(TextField));
    expect(dialogFields, findsNWidgets(7)); // 型号/CID/封装/品牌/数量/位置/备注
    await tester.enterText(dialogFields.at(0), 'RES-0805-10K');
    await tester.enterText(dialogFields.at(1), 'C10001');
    await tester.pump();

    await tester.tap(find.text('保存'));
    await settle(tester);

    // 弹窗关闭，列表出现新卡片
    expect(find.byType(AddComponentDialog), findsNothing);
    expect(find.text('RES-0805-10K'), findsOneWidget);
  });
}
