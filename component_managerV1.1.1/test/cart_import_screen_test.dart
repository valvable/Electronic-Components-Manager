import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/cart_import_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 购物车导入页入口：首页 AppBar 导入菜单 → 立创购物车入库页（空态渲染）。
/// 文件选择与解析驱动的流程由 cart_parser_test / import_parser 通路覆盖。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('导入菜单含两项；购物车项进入购物车导入页', (tester) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = (await tester.runAsync(
        () => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);

    await tester.pumpWidget(ComponentManagerApp(AppState(db)));
    await settle(tester);

    // 打开首页「导入」弹出菜单
    await tester.tap(find.byTooltip('导入（BOM 比对 / 购物车入库）'));
    await settle(tester);
    expect(find.text('BOM 比对库存'), findsOneWidget);
    expect(find.text('立创购物车入库'), findsOneWidget);

    // 选「立创购物车入库」→ 进入购物车导入页
    await tester.tap(find.text('立创购物车入库'));
    await settle(tester);
    expect(find.byType(CartImportScreen), findsOneWidget);
    expect(find.text('选择购物车文件'), findsOneWidget);
    expect(find.textContaining('CSV / XLSX'), findsOneWidget);
    expect(find.textContaining('同 C 号自动合并数量'), findsOneWidget);
  });
}
