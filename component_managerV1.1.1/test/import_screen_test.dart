import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/import_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// import_screen 冒烟：空态渲染。文件选择依赖平台通道，驱动逻辑由
/// import_parser_test / export_service_test / bom_compare_test 覆盖。
void main() {
  testWidgets('空态渲染：显示选择 BOM 文件入口', (tester) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = (await tester.runAsync(
        () => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);

    await tester.pumpWidget(MaterialApp(home: ImportScreen(state: AppState(db))));
    await tester.pump();

    expect(find.byType(ImportScreen), findsOneWidget);
    expect(find.text('选择 BOM 文件'), findsOneWidget);
    expect(find.textContaining('CSV / XLSX'), findsOneWidget);
  });
}
