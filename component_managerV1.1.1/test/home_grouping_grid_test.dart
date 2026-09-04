import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/models/component.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/home_screen.dart';
import 'package:component_manager/screens/model_group_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 首页双列聚合链路：同型号两品牌 → 一个瓦片显示合计；点进组明细看各自数量。
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

  Future<AppState> seed(WidgetTester tester, List<Component> comps) async {
    final db =
        (await tester.runAsync(() => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);
    final state = AppState(db);
    await tester.runAsync(() async {
      for (final c in comps) {
        await state.components.insert(c);
      }
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(state: state)));
    await settle(tester);
    return state;
  }

  int seq = 100000;

  Component part(String model, String brand, int qty) => Component(
        cid: 'C${seq++}', // 同型号多品牌各自一行：cid 唯一，model 相同
        model: model,
        category: '电阻',
        brand: brand,
        quantity: qty,
        createdAt: Component.now(),
        updatedAt: Component.now(),
      );

  testWidgets('同型号双品牌聚合为一个瓦片，数量=合计', (tester) async {
    await seed(tester, [
      part('RC0805-10K', '国巨', 10),
      part('RC0805-10K', '三星', 5),
    ]);

    expect(find.text('RC0805-10K'), findsOneWidget); // 聚合后只一条
    expect(find.textContaining('2 条 · 2 个品牌'), findsOneWidget);
    expect(find.textContaining('共 2 个元件 · 1 组'), findsOneWidget);
    expect(find.text('15'), findsOneWidget); // 合计数量角标
  });

  testWidgets('点聚合瓦片 → 组明细页逐品牌显示单独数量', (tester) async {
    await seed(tester, [
      part('RC0805-10K', '国巨', 10),
      part('RC0805-10K', '三星', 5),
    ]);

    await tester.tap(find.text('RC0805-10K'));
    await tester.pumpAndSettle();
    expect(find.byType(ModelGroupScreen), findsOneWidget);
    expect(find.textContaining('合计'), findsOneWidget);
    // 明细里两行各自带品牌与数量。
    expect(find.textContaining('国巨'), findsWidgets);
    expect(find.textContaining('三星'), findsWidgets);
    expect(find.text('10'), findsWidgets);
    expect(find.text('5'), findsWidgets);
  });

  testWidgets('单条元件点瓦片直接进详情', (tester) async {
    await seed(tester, [part('LONE-01', 'WURTH', 3)]);
    await tester.tap(find.text('LONE-01'));
    await tester.pumpAndSettle();
    expect(find.byType(ModelGroupScreen), findsNothing);
    expect(find.text('元件详情'), findsOneWidget);
  });
}
