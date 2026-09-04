import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/core/services/lcsc_lookup.dart';
import 'package:component_manager/models/component.dart';
import 'package:component_manager/screens/add_component_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 添加对话框「C 号查料自动填充」：注入假 lookup，验证成功填充 / 失败保持 / 编辑态隐藏。
/// DB 走 ffi，沿用 scan 的 settle 模式（runAsync 真 I/O + pump 假时钟交替）。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  const fakeInfo = LcscPartInfo(
    productCode: 'C25704',
    productModel: '1210W3J0563T5E',
    brandName: 'UNI-ROYAL',
    catalogName: 'Chip Resistor - Surface Mount',
    package: '1210',
    description: '56kΩ ±5% 333mW 1210 Thick Film Resistor',
  );

  String fieldText(WidgetTester tester, int index) =>
      tester.widget<TextFormField>(find.byType(TextFormField).at(index)).controller!.text;

  Future<void> openDialog(
    WidgetTester tester, {
    Future<LcscPartInfo?> Function(String)? lookup,
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
                lcscLookup: lookup,
              ),
              child: const Text('打开添加'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开添加'));
    await tester.pumpAndSettle();
  }

  testWidgets('合法 C 号出现按钮；点查料成功 → 型号/分类/封装/备注自动填充', (tester) async {
    await openDialog(tester, lookup: (_) async => fakeInfo);

    expect(find.text('从立创查料自动填充'), findsNothing); // 未输 CID 前不显示

    await tester.enterText(find.byType(TextFormField).at(1), 'C25704');
    await settle(tester); // 等 byCid 三态完成 → setState 出现按钮
    expect(find.text('从立创查料自动填充'), findsOneWidget);

    await tester.tap(find.text('从立创查料自动填充'));
    await settle(tester);

    expect(fieldText(tester, 0), '1210W3J0563T5E'); // 型号
    expect(fieldText(tester, 2), '1210'); // 封装
    expect(fieldText(tester, 5), contains('56kΩ')); // 备注=简介
    expect(fieldText(tester, 3), 'UNI-ROYAL'); // 品牌独立字段（v4，不再挤备注）
    // 分类 = catalog 映射；须真正显示在下拉框当前值上（防 IndexedStack 常驻文本误匹配）
    final dd = tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
    expect(dd.value, '电阻');
    expect(find.textContaining('已填充 C25704'), findsOneWidget); // 成功提示
  });

  testWidgets('非法 C 号不显示按钮', (tester) async {
    await openDialog(tester);
    await tester.enterText(find.byType(TextFormField).at(1), 'STMF103');
    await settle(tester);
    expect(find.text('从立创查料自动填充'), findsNothing);
  });

  testWidgets('查料失败 → 提示且不覆盖已有输入', (tester) async {
    await openDialog(tester, lookup: (_) async => null);
    await tester.enterText(find.byType(TextFormField).at(1), 'C99999');
    await settle(tester);
    await tester.tap(find.text('从立创查料自动填充'));
    await settle(tester);

    expect(find.textContaining('没查到'), findsOneWidget);
    expect(fieldText(tester, 0), isEmpty); // 型号未被乱填
    expect(fieldText(tester, 2), isEmpty);
  });

  testWidgets('编辑态 CID 锁定 → 不出现查料按钮', (tester) async {
    await openDialog(
      tester,
      existing: Component(
        cid: 'C25704',
        model: '旧型号',
        category: '其他',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    expect(find.text('编辑元件'), findsOneWidget);
    await settle(tester);
    expect(find.text('从立创查料自动填充'), findsNothing);
  });
}
