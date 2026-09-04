import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/core/utils/classifier.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/models/component.dart';
import 'package:component_manager/screens/scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// scan_screen 冒烟 + 扫码流程 E2E。
///
/// 与 widget_test.dart 同款的 FakeAsync 处理：sqflite ffi 的后台 isolate 需要
/// 真实事件循环，所以 DB 读写全部放进 [tester.runAsync]，帧推进用 pump（假时钟），
/// 交替 [settle] 直到稳定；**不要对含 DB 的界面用 pumpAndSettle**。
///
/// 测试直接调用 [ScanScreenState.handleScannedText] 喂文本，绕开摄像头
/// （桌面 / flutter_tester 均无摄像头，scan_screen 自动走降级界面）。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
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

  testWidgets('桌面无摄像头 → 降级界面给出粘贴 / 手动输入入口', (tester) async {
    final state = await openState(tester);
    await tester.pumpWidget(MaterialApp(home: ScanScreen(state: state)));
    await tester.pump();

    expect(find.text('从剪贴板粘贴二维码内容'), findsOneWidget);
    expect(find.text('手动输入 CID / 型号'), findsOneWidget);
    expect(find.byType(ScanScreen), findsOneWidget);
  });

  testWidgets('扫码新元件（真实样例）→ 确认入库 → 保存（分类/数量/型号正确）', (tester) async {
    final state = await openState(tester);
    await tester.pumpWidget(MaterialApp(home: ScanScreen(state: state)));
    await tester.pump();

    final scanState = tester.state<ScanScreenState>(find.byType(ScanScreen));
    final flow = scanState.handleScannedText(
        '{on:SO26081518766,pc:C2977076,pm:XL-1608UPC-06,qty:250,mc:,cc:1,pdi:231298193,hp:11}');

    await settle(tester); // 让 byCid 落地 → 确认弹窗出现
    expect(find.text('确认入库'), findsOneWidget);
    expect(find.text('250'), findsOneWidget); // 数量预填自二维码 qty

    await tester.tap(find.text('保存'));
    await settle(tester); // insert 落地 → 弹窗关闭 → 成功提示
    await tester.runAsync(() => flow);

    final lookup =
        (await tester.runAsync(() => state.components.byCid('C2977076')))!;
    expect(lookup.status, LookupStatus.active);
    expect(lookup.component!.model, 'XL-1608UPC-06');
    expect(lookup.component!.quantity, 250);
    expect(lookup.component!.category, classify('XL-1608UPC-06'));
    expect(find.textContaining('已保存'), findsOneWidget);
  });

  testWidgets('扫码已存在元件 → 确认增加数量（累加）', (tester) async {
    final state = await openState(tester);
    final now = Component.now();
    await tester.runAsync(() => state.components.insert(Component(
          cid: 'C10001',
          model: 'TEST-RES-10K',
          category: '电阻',
          quantity: 5,
          createdAt: now,
          updatedAt: now,
        )));

    await tester.pumpWidget(MaterialApp(home: ScanScreen(state: state)));
    await tester.pump();

    final scanState = tester.state<ScanScreenState>(find.byType(ScanScreen));
    final flow = scanState.handleScannedText('{pc:C10001,pm:TEST-RES-10K,qty:10,mc:}');

    await settle(tester);
    expect(find.text('该元件已存在'), findsOneWidget);
    expect(find.textContaining('当前数量：5'), findsOneWidget);

    await tester.tap(find.text('确认增加'));
    await settle(tester);
    await tester.runAsync(() => flow);

    final lookup =
        (await tester.runAsync(() => state.components.byCid('C10001')))!;
    expect(lookup.status, LookupStatus.active);
    expect(lookup.component!.quantity, 15); // 5 + 10
  });

  testWidgets('扫码回收站元件 → 确认恢复并增加数量', (tester) async {
    final state = await openState(tester);
    final now = Component.now();
    final id = (await tester.runAsync(() => state.components.insert(Component(
          cid: 'C10002',
          model: 'OLD-IC',
          category: 'IC',
          quantity: 3,
          createdAt: now,
          updatedAt: now,
        ))))!;
    await tester.runAsync(() => state.components.delete(id));

    await tester.pumpWidget(MaterialApp(home: ScanScreen(state: state)));
    await tester.pump();

    final scanState = tester.state<ScanScreenState>(find.byType(ScanScreen));
    final flow = scanState.handleScannedText('{pc:C10002,pm:OLD-IC,qty:7,mc:}');

    await settle(tester);
    expect(find.text('该元件已在回收站'), findsOneWidget);

    await tester.tap(find.text('确认增加'));
    await settle(tester);
    await tester.runAsync(() => flow);

    final lookup =
        (await tester.runAsync(() => state.components.byCid('C10002')))!;
    expect(lookup.status, LookupStatus.active); // 已自动恢复
    expect(lookup.component!.quantity, 10); // 3 + 7
  });

  testWidgets('空 / 无法识别的内容给出提示', (tester) async {
    final state = await openState(tester);
    await tester.pumpWidget(MaterialApp(home: ScanScreen(state: state)));
    await tester.pump();

    final scanState = tester.state<ScanScreenState>(find.byType(ScanScreen));
    final flow = scanState.handleScannedText('');

    await settle(tester);
    await tester.runAsync(() => flow);
    expect(find.textContaining('未识别到有效二维码内容'), findsOneWidget);
  });
}
