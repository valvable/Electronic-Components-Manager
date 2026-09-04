import 'dart:async';

import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/ai_client.dart';
import 'package:component_manager/core/services/ai_substitute_batch.dart';
import 'package:component_manager/core/utils/bom_compare.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/substitute_batch_screen.dart';
import 'package:component_manager/screens/substitute_compare_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 双方向批处理页：逐行挂出（rowId 归位）、方向分组展示、单行重试、停止截断、
/// 返回时 AiRowAdvice 按 rowId 回传。
void main() {
  // 真实 async 区建库（testWidgets 的 fake-async 里 await 真 DB 会挂死）。
  late AppState state;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = await AppDatabase.openAt(inMemoryDatabasePath);
    state = AppState(db);
    addTearDown(db.close);
  });

  BomCompareRow rowOf(String model) => BomCompareRow(
        line: BomLine(model: model, qty: 5),
        matched: null,
        stockOnHand: 0,
        status: BomStatus.missing,
        shortBy: 5,
      );

  Future<void> openBatch(
    WidgetTester tester,
    AppState state,
    List<SubstituteBatchTask> tasks,
    Future<AiSubstitutePlan?> Function(
        SubDirection, int, AiSubstituteContext) fetch, {
    void Function(Map<int, AiRowAdvice>?)? onPopped,
    bool settle = true,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final r = await Navigator.push<Map<int, AiRowAdvice>>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SubstituteBatchScreen(
                          state: state, tasks: tasks, fetch: fetch),
                    ),
                  );
                  onPopped?.call(r);
                },
                child: const Text('go'),
              ),
            ),
          )),
    ));
    await tester.tap(find.text('go'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }
  }

  testWidgets('双方向全部成功 → 每行网络/库存两组建议；按 rowId 回传 advice',
      (tester) async {
    Map<int, AiRowAdvice>? popped;
    await openBatch(
      tester,
      state,
      [
        SubstituteBatchTask(rowId: 7, row: rowOf('PART-A')),
        SubstituteBatchTask(rowId: 9, row: rowOf('PART-B')),
      ],
      (d, i, c) async => AiSubstitutePlan(
        originalSpecs: {'型号': '原件-i$i'},
        suggestions: [
          AiSubstituteSuggestion(
              model: '${c.model}-${d.name}', risk: '可直接替代'),
        ],
      ),
      onPopped: (r) => popped = r,
    );

    expect(find.text('全部处理完成 · 共 2 个缺料元件'), findsOneWidget);
    expect(find.text('已给出 2 个建议'), findsNWidgets(2));
    // 方向小标题各出现两次（两行）。
    expect(find.text('网络替代 ×1'), findsNWidgets(2));
    expect(find.text('库存替代 ×1'), findsNWidgets(2));
    expect(find.text('PART-A-network'), findsOneWidget);
    expect(find.text('PART-B-inventory'), findsOneWidget);

    // 点某行建议的「对比」→ 电气参数对比页（原元件 specs 随行）
    await tester.tap(find.text('对比').first);
    await tester.pumpAndSettle();
    expect(find.byType(SubstituteCompareScreen), findsOneWidget);
    expect(find.text('原件-i0'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('batch_done_btn')));
    await tester.pumpAndSettle();
    expect(popped, isNotNull);
    expect(popped!.keys, {7, 9}); // rowId 归位
    expect(popped![7]!.netSuggestions.single.model, 'PART-A-network');
    expect(popped![7]!.localSuggestions.single.model, 'PART-A-inventory');
    expect(popped![7]!.suggestionCount, 2);
  });

  testWidgets('两方向都失败 → 可重试，成功后翻绿并出建议', (tester) async {
    var attempts = 0;
    await openBatch(
      tester,
      state,
      [SubstituteBatchTask(rowId: 0, row: rowOf('FAIL-FIRST'))],
      (d, i, c) async {
        attempts++;
        if (attempts <= 2) throw AiParseException(); // 首行两方向都失败
        return AiSubstitutePlan(suggestions: [
          const AiSubstituteSuggestion(model: 'OK-AT-LAST'),
        ]);
      },
    );

    expect(find.textContaining('无法解析'), findsWidgets);
    expect(find.byKey(const ValueKey('batch_retry_0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('batch_retry_0')));
    await tester.pumpAndSettle();
    expect(attempts, 4); // 重试再跑两方向
    expect(find.text('已给出 2 个建议'), findsOneWidget);
    expect(find.text('OK-AT-LAST'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('batch_retry_0')), findsNothing);
  });

  testWidgets('库存方向失败但网络成功：行不算失败，标橙色单行提示', (tester) async {
    await openBatch(
      tester,
      state,
      [SubstituteBatchTask(rowId: 0, row: rowOf('HALF-OK'))],
      (d, i, c) async {
        if (d == SubDirection.inventory) throw const AiNetworkException('x');
        return AiSubstitutePlan(suggestions: [
          const AiSubstituteSuggestion(model: 'NET-OK'),
        ]);
      },
    );
    expect(find.textContaining('库存方向失败'), findsOneWidget);
    expect(find.text('NET-OK'), findsOneWidget);
    expect(find.byKey(const ValueKey('batch_retry_0')), findsNothing); // 未失败
  });

  testWidgets('停止：剩余行不再请求，页头标注已手动停止', (tester) async {
    final gate = Completer<AiSubstitutePlan?>();
    var calls = 0;
    await openBatch(
      tester,
      state,
      [
        SubstituteBatchTask(rowId: 0, row: rowOf('BLOCKED-0')),
        SubstituteBatchTask(rowId: 1, row: rowOf('BLOCKED-1')),
      ],
      (d, i, c) async {
        calls++;
        return gate.future; // 挂起等放行（行内转圈，不能用 pumpAndSettle）
      },
      settle: false, // 首方向永远在途：只推几帧让 _start 跑到第一个 await
    );
    expect(calls, 1); // 第一行第一个方向在途，未发起后续（串行）

    await tester.tap(find.byKey(const ValueKey('batch_stop_btn')));
    await tester.pump();
    expect(find.textContaining('已手动停止 · 共 2 个缺料元件'), findsOneWidget);

    // 收尾：放行在途请求（第 1 行剩余方向用已完成的 future 立即返回），
    // 停止应在第 2 行开始前生效。
    gate.complete(AiSubstitutePlan(suggestions: [
      const AiSubstituteSuggestion(model: 'LATE'),
    ]));
    await tester.pumpAndSettle();
    expect(calls, 2); // 第 1 行两方向；第 2 行始终没跑
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
  });
}
