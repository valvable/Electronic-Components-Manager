import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/ai_client.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 扫码确认弹窗的 AI 能力：
/// - 弹窗里有「AI 查询分类」按钮（任何分类都可手动）；
/// - 本地 classify 判为「其他」→ 自动触发一次；确定性分类（≠其他）不自动；
/// - AI 给出清单外新分类 → 确认后创建为自创分类并采用（保存落库）；
/// - AI 未配置（无 seam、设置空）→ 自动触发只提示一次，不打断入库。
///
/// 与 scan_screen_test 同款：DB 走真 ffi、帧用 pump、网络一律经 seam。
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

  String dropdownValue(WidgetTester tester) =>
      tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>)).value!;

  /// 喂一条能进 notFound 分支、型号固定的二维码（[model] 决定本地分类）。
  /// 注意：handleScannedText 内部走真 DB，调用方不要 await，靠 [settle] 驱动。

  Future<ScanScreenState> pumpAndScan(
    WidgetTester tester,
    AppState state, {
    String model = 'RC0603FR-0710KL',
    String cid = 'C910001',
    AiClassifyLookup? aiLookup,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: ScanScreen(state: state, aiClassifyLookup: aiLookup),
    ));
    await tester.pump();
    final scanState = tester.state<ScanScreenState>(find.byType(ScanScreen));
    // 不 await：handleScannedText 内部走真 DB，靠 settle 驱动
    scanState.handleScannedText('{pc:$cid,pm:$model,qty:5,mc:}');
    return scanState;
  }

  testWidgets('确定性分类（≠其他）不自动触发；按钮可手动 AI 修正分类', (tester) async {
    final state = await openState(tester);
    var calls = 0;
    await pumpAndScan(
      tester,
      state,
      model: 'RC0603FR-0710KL', // classify → 电阻
      aiLookup: (model, cid) async {
        calls++;
        return const AiClassifySuggestion(category: '电容');
      },
    );
    await settle(tester);

    expect(find.text('确认入库'), findsOneWidget);
    expect(find.byKey(const ValueKey('scan_ai_query_btn')), findsOneWidget);
    expect(find.text('AI 查询分类'), findsOneWidget);
    expect(calls, 0); // 确定性高 → 不自动打扰

    await tester.tap(find.byKey(const ValueKey('scan_ai_query_btn')));
    await settle(tester);
    expect(calls, 1);
    expect(dropdownValue(tester), '电容');
  });

  testWidgets('本地 classify=其他 → 自动触发一次并落地（不用点按钮）', (tester) async {
    final state = await openState(tester);
    var calls = 0;
    await pumpAndScan(
      tester,
      state,
      model: '杂样-1', // 无关键字 → classify 兜底「其他」
      cid: 'C910002',
      aiLookup: (model, cid) async {
        calls++;
        return const AiClassifySuggestion(category: '电容');
      },
    );
    await settle(tester);

    expect(calls, 1); // 只自动一次
    expect(dropdownValue(tester), '电容'); // 已落地

    // 直接保存 → 行入库且分类=AI 结果
    await tester.tap(find.text('保存'));
    await settle(tester);
    final row =
        (await tester.runAsync(() => state.components.byCid('C910002')))!;
    expect(row.status, LookupStatus.active);
    expect(row.component!.category, '电容');
  });

  testWidgets('AI 给出清单外新分类 → 确认创建为自创分类并采用；保存落库', (tester) async {
    final state = await openState(tester);
    await pumpAndScan(
      tester,
      state,
      model: '杂样-2',
      cid: 'C910003',
      aiLookup: (model, cid) async =>
          const AiClassifySuggestion(category: '钽电容'), // 不在 29+自创
    );
    await settle(tester);

    // 自动 → 新分类 → 弹窗确认创建
    expect(find.text('使用新分类？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('scan_ai_create_category_ok')));
    await settle(tester);

    expect(dropdownValue(tester), '钽电容'); // 已创建并采用
    final customs =
        (await tester.runAsync(() => state.settings.loadCustomCategories()))!;
    expect(customs, contains('钽电容'));

    await tester.tap(find.text('保存'));
    await settle(tester);
    final row =
        (await tester.runAsync(() => state.components.byCid('C910003')))!;
    expect(row.component!.category, '钽电容');
  });

  testWidgets('AI 未配置（设置空）→ 自动触发只提示一次，仍可手动保存', (tester) async {
    final state = await openState(tester);
    await pumpAndScan(
      tester,
      state,
      model: '杂样-3', // classify → 其他 → 自动触发（走真设置，读到空配置）
      cid: 'C910004',
    );
    await settle(tester);

    expect(find.textContaining('AI 未配置'), findsOneWidget);
    // 分类保持兜底「其他」，入库仍可用
    expect(dropdownValue(tester), '其他');
    expect(find.text('保存'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await settle(tester);
    final row =
        (await tester.runAsync(() => state.components.byCid('C910004')))!;
    expect(row.status, LookupStatus.active);
    expect(row.component!.category, '其他');
  });
}
