import 'package:component_manager/core/services/ai_client.dart';
import 'package:component_manager/core/utils/bom_compare.dart';
import 'package:component_manager/core/utils/bom_substitute.dart';
import 'package:component_manager/models/component.dart';
import 'package:component_manager/screens/substitute_compare_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 电气参数对比页：两列表格逐项 ✓/⚠/—、候选 chip 切换、本地候选兜底说明。
void main() {
  BomCompareRow missingRow() => BomCompareRow(
        line: const BomLine(model: 'RC0603FR-0710KL', qty: 10, designation: 'R1'),
        matched: null,
        stockOnHand: 0,
        status: BomStatus.missing,
        shortBy: 10,
      );

  Future<void> pumpCompare(
    WidgetTester tester, {
    AiSubstitutePlan? plan,
    List<LocalSubstitute> locals = const [],
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: SubstituteCompareScreen(
          row: missingRow(), plan: plan, locals: locals),
    ));
    await tester.pump();
  }

  AiSubstitutePlan twoSuggestionPlan() => AiSubstitutePlan(
        originalSpecs: const {'阻值': '10kΩ', '精度': '±1%', '封装': '0603'},
        suggestions: const [
          AiSubstituteSuggestion(
            model: 'RK73H-B 10K',
            specs: {'阻值': '10kΩ', '精度': '±1%', '封装': '0805'},
            risk: '需确认',
            diff: '封装不同需确认焊盘',
            reason: '参数一致仅封装大一号',
            confidence: 0.8,
          ),
          AiSubstituteSuggestion(
            model: 'MCS0402 10K',
            specs: {'阻值': '10kΩ', '精度': '±0.5%', '封装': '0603'},
            risk: '可直接替代',
            confidence: 0.9,
          ),
        ],
      );

  testWidgets('两列对比：一致 ✓、差异 ⚠ 高亮、缺失 —，risk/diff/置信度呈现',
      (tester) async {
    await pumpCompare(tester, plan: twoSuggestionPlan());

    expect(find.text('电气参数对比'), findsOneWidget);
    // 默认选中第一个候选：列头显示对照双方
    expect(find.text('原元件 RC0603FR-0710KL'), findsOneWidget);
    expect(find.text('候选 RK73H-B 10K'), findsOneWidget);
    // 阻值/精度 两侧同值 → 绿 ✓ ×2；封装 0603 vs 0805 → 橙 ⚠ ×1
    expect(find.byIcon(Icons.check_circle_outline), findsNWidgets(2));
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    // 原件独有「型号」行 → 灰 —
    expect(find.byIcon(Icons.remove_rounded), findsOneWidget);
    expect(find.text('10kΩ'), findsNWidgets(2));
    expect(find.text('需确认'), findsOneWidget);
    expect(find.text('关键差异：封装不同需确认焊盘'), findsOneWidget);
    expect(find.textContaining('置信度 80%'), findsOneWidget);
    expect(find.textContaining('请以官方规格书核对'), findsOneWidget);
  });

  testWidgets('切换候选 chip 后表格换成该候选参数', (tester) async {
    await pumpCompare(tester, plan: twoSuggestionPlan());

    await tester.tap(find.byKey(const ValueKey('compare_cand_1')));
    await tester.pump();

    expect(find.text('候选 MCS0402 10K'), findsOneWidget);
    expect(find.text('±0.5%'), findsOneWidget);
    expect(find.text('可直接替代'), findsOneWidget);
    // 此候选封装一致、精度不同 → 仍 2✓1⚠，但差异行在精度
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byKey(const ValueKey('compare_row_精度')), findsOneWidget);
  });

  testWidgets('本地候选（无 AI 方案）：拼库存信息 + 无电气参数说明',
      (tester) async {
    final c = Component(
      cid: 'C-LOCAL',
      model: 'ERJ-3EKF1002',
      category: '电阻',
      package: '0603',
      quantity: 40,
      createdAt: 1,
      updatedAt: 1,
    );
    await pumpCompare(
      tester,
      locals: [
        LocalSubstitute(
            component: c, confidence: 0.85, reason: '同分类：电阻；封装一致 0603'),
      ],
    );

    expect(find.text('本地库存 · ERJ-3EKF1002'), findsOneWidget);
    expect(find.text('封装'), findsOneWidget);
    expect(find.text('40'), findsOneWidget); // 库存
    expect(find.textContaining('本地库存候选：无电气参数明细'), findsOneWidget);
  });

  testWidgets('无任何候选 → 空态文案', (tester) async {
    await pumpCompare(tester);
    expect(find.text('暂无可对比的候选'), findsOneWidget);
  });
}
