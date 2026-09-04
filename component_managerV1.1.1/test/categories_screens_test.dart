import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/models/component.dart';
import 'package:component_manager/screens/categories_screen.dart';
import 'package:component_manager/screens/category_components_screen.dart';
import 'package:component_manager/screens/category_manage_screen.dart';
import 'package:component_manager/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 底部三页外壳 + 分类卡片页 + 分类内元件页 + 分类管理页冒烟。
///
/// - MainShell：三 tab 可点可滑，切到分类/设置页各自加载；
/// - 分类卡片页：系统/自创卡片 + 件数，点卡片放大进该分类内元件页；
/// - 分类内元件页：页内搜索能过滤该分类的元件；
/// - 管理页：新建 / 改名（元件行同步改名）/ 删除在用被拒 / 删除空分类成功。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<AppState> openState(WidgetTester tester) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db =
        (await tester.runAsync(() => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);
    return AppState(db);
  }

  Future<void> seed(AppState state, {String? cid, required String model, required String category, int qty = 1}) async {
    final now = Component.now();
    await state.components.insert(Component(
      cid: cid ?? 'C${model.hashCode.abs() % 90000 + 10000}',
      model: model,
      category: category,
      quantity: qty,
      createdAt: now,
      updatedAt: now,
    ));
  }

  /// widget test 体内 DB 写必须经 runAsync（FakeAsync 下 ffi 消息不回来）。
  Future<void> seedIn(WidgetTester tester, AppState state,
          {String? cid, required String model, required String category, int qty = 1}) =>
      tester.runAsync(() => seed(state, cid: cid, model: model, category: category, qty: qty));

  Future<void> saveCustomsIn(WidgetTester tester, AppState state, List<String> names) =>
      tester.runAsync(() => state.settings.saveCustomCategories(names));

  Finder navLabel(String label) => find.descendant(
      of: find.byType(NavigationBar), matching: find.text(label));

  testWidgets('MainShell：三 tab 可点、可左右滑动切换并各自加载', (tester) async {
    final state = await openState(tester);
    await seedIn(tester, state, model: 'CL-0805-22U', category: '电容');
    await seedIn(tester, state, model: 'RC0603FR-0710KL', category: '电阻');

    await tester.pumpWidget(ComponentManagerApp(state));
    await settle(tester);

    // 默认全部元件页
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
    expect(find.text('电子元件管家'), findsOneWidget);

    // 点「分类」→ 分类页出现
    await tester.tap(navLabel('分类'));
    await settle(tester);
    expect(find.byType(CategoriesScreen), findsOneWidget);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);

    // 点「设置」→ 设置页出现
    await tester.tap(navLabel('设置'));
    await settle(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 2);

    // 回全部元件，再左滑回分类（PageView 滑动）
    await tester.tap(navLabel('全部元件'));
    await settle(tester);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pump(); // 开始滑动吸附
    await settle(tester); // 页面动画 + 分类页切到时 DB 重载一起收口
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
    expect(find.byType(CategoriesScreen), findsOneWidget);
  });

  testWidgets('分类卡片 → 点开该分类内元件页；页内搜索过滤', (tester) async {
    final state = await openState(tester);
    await seedIn(tester, state, model: 'CL-0805-22U', category: '电容');
    await seedIn(tester, state, model: 'CL-0805-10U', category: '电容');
    await seedIn(tester, state, model: 'RC0603FR-0710KL', category: '电阻');

    await tester.pumpWidget(MaterialApp(home: CategoriesScreen(state: state)));
    await settle(tester);

    // 电容卡片存在且件数正确
    expect(find.text('电容'), findsWidgets);
    expect(find.text('2 件'), findsWidgets);

    // 点卡片 → 分类内元件页（放大转场 + 页内 DB 加载都不能用 pumpAndSettle）
    await tester.tap(find.text('电容'));
    await tester.pump(); // 触发 push
    await settle(tester);
    expect(find.byType(CategoryComponentsScreen), findsOneWidget);
    expect(find.text('CL-0805-22U'), findsOneWidget);
    expect(find.text('CL-0805-10U'), findsOneWidget);
    // 其它分类不泄漏进来
    expect(find.text('RC0603FR-0710KL'), findsNothing);

    // 页内搜索：输入 22U → 只剩对应一条
    await tester.enterText(find.byType(TextField), '22U');
    await settle(tester);
    expect(find.text('CL-0805-22U'), findsOneWidget);
    expect(find.text('CL-0805-10U'), findsNothing);
  });

  testWidgets('管理页：新建自创分类', (tester) async {
    final state = await openState(tester);
    await tester.pumpWidget(MaterialApp(home: CategoryManageScreen(state: state)));
    await settle(tester);
    expect(find.textContaining('还没有自创分类'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('create_category_btn')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Type-C 公头');
    await tester.tap(find.text('确定'));
    await settle(tester);

    final customs =
        (await tester.runAsync(() => state.settings.loadCustomCategories()))!;
    expect(customs, contains('Type-C 公头'));
  });

  testWidgets('管理页：改名同步元件行', (tester) async {
    final state = await openState(tester);
    await saveCustomsIn(tester, state, ['钽电容']);
    await seedIn(tester, state, model: 'TC-330UF', category: '钽电容');

    await tester.pumpWidget(MaterialApp(home: CategoryManageScreen(state: state)));
    await settle(tester);
    expect(find.text('钽电容'), findsOneWidget);

    await tester.tap(find.byTooltip('改名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '固态钽电容');
    await tester.tap(find.text('确定'));
    await settle(tester);

    final customs =
        (await tester.runAsync(() => state.settings.loadCustomCategories()))!;
    expect(customs, isNot(contains('钽电容')));
    expect(customs, contains('固态钽电容'));
    // 在用元件行同步改名（只改活动行）
    final rows = (await tester.runAsync(() => state.components.all()))!;
    expect(rows.single.category, '固态钽电容');
  });

  testWidgets('管理页：仍被元件使用的分类禁止删除；空分类可删', (tester) async {
    final state = await openState(tester);
    await saveCustomsIn(tester, state, ['在用分类', '空闲分类']);
    await seedIn(tester, state, model: 'KEEP-1', category: '在用分类');

    await tester.pumpWidget(MaterialApp(home: CategoryManageScreen(state: state)));
    await settle(tester);

    // 在用分类的删除 → 拒绝
    Finder rowDelete(String name) => find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
        matching: find.byTooltip('删除'));
    await tester.tap(rowDelete('在用分类'));
    await tester.pumpAndSettle();
    expect(find.text('无法删除'), findsOneWidget);
    expect(find.textContaining('仍有 1 个元件使用「在用分类」'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    var customs =
        (await tester.runAsync(() => state.settings.loadCustomCategories()))!;
    expect(customs, contains('在用分类')); // 未被删

    // 空闲分类删除 → 成功
    await tester.tap(rowDelete('空闲分类'));
    await tester.pumpAndSettle();
    expect(find.text('删除分类'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await settle(tester);

    customs = (await tester.runAsync(() => state.settings.loadCustomCategories()))!;
    expect(customs, isNot(contains('空闲分类')));
    expect(customs, contains('在用分类'));
  });
}
