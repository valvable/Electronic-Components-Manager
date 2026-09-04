import 'package:component_manager/core/services/ai_client.dart';
import 'package:component_manager/core/services/ai_substitute_batch.dart';
import 'package:component_manager/core/utils/bom_compare.dart';
import 'package:component_manager/core/utils/bom_substitute.dart';
import 'package:component_manager/models/component.dart';
import 'package:component_manager/widgets/substitute_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 替代面板：离线粗筛候选 + AI 双方向（库存/网络）独立按钮、缓存预载、错误提示。
void main() {
  Component comp(String model, {int qty = 12, String cat = '电容'}) => Component(
        cid: 'C-$model',
        model: model,
        category: cat,
        package: '0805',
        quantity: qty,
        createdAt: 1,
        updatedAt: 1,
      );

  BomCompareRow missingRow(String model, {int qty = 5}) => BomCompareRow(
        line: BomLine(model: model, qty: qty),
        matched: null,
        stockOnHand: 0,
        status: BomStatus.missing,
        shortBy: qty,
      );

  LocalSubstitute sub(Component c, double conf, String reason) =>
      LocalSubstitute(component: c, confidence: conf, reason: reason);

  Future<void> pumpSheet(
    WidgetTester tester, {
    required List<LocalSubstitute> locals,
    AiRecommendFetcher? aiFetcher,
    AiPlanFetcher? planFetcher,
    AiInventoryPlanFetcher? localPlanFetcher,
    AiSubstitutePlan? initialPlan,
    AiRowAdvice? initialAdvice,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SubstituteSheet(
          row: missingRow('LM358N'),
          locals: locals,
          aiFetcher: aiFetcher ?? (_) async => const [],
          planFetcher: planFetcher,
          localPlanFetcher: localPlanFetcher,
          initialPlan: initialPlan,
          initialAdvice: initialAdvice,
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('本地候选：型号/理由/置信度渲染 + 双方向按钮在位', (tester) async {
    await pumpSheet(tester, locals: [
      sub(comp('LM358P'), 0.95, '同分类：电容；型号相近；库存 12'),
      sub(comp('NE5532'), 0.7, '同分类：电容；库存 3'),
    ]);

    expect(find.text('LM358N的替代方案'), findsOneWidget); // 标题 = 行型号
    expect(find.text('待采购'), findsOneWidget); // 状态徽章
    expect(find.text('本地库存替代（离线粗筛）'), findsOneWidget);
    expect(find.text('LM358P'), findsOneWidget);
    expect(find.text('NE5532'), findsOneWidget);
    expect(find.text('同分类：电容；型号相近；库存 12'), findsOneWidget);
    expect(find.text('95%'), findsOneWidget); // 置信度
    expect(find.text('70%'), findsOneWidget);
    expect(find.text('AI 网络替代'), findsOneWidget);
    expect(find.text('AI 库存替代'), findsOneWidget);
    // 未注入库存实现时其按钮禁用（不误触发 StateError）。
    final invBtn = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'AI 库存替代'));
    expect(invBtn.onPressed, isNull);
  });

  testWidgets('点本地候选 → 复制型号 toast', (tester) async {
    await pumpSheet(tester, locals: [
      sub(comp('LM358P'), 0.95, '同分类：电容；库存 12'),
    ]);

    await tester.tap(find.text('LM358P'));
    await tester.pump();

    expect(find.textContaining('已复制'), findsOneWidget);
  });

  testWidgets('无本地候选 → 提示引导（双方向文案）', (tester) async {
    await pumpSheet(tester, locals: const []);

    expect(
        find.text('本地暂无可靠替代。可用下方 AI 双方向推荐（需已在设置页配置 AI 接口）。'),
        findsOneWidget);
  });

  testWidgets('网络方向：假 fetcher 结果追加「AI 网络替代」组', (tester) async {
    await pumpSheet(
      tester,
      locals: const [],
      aiFetcher: (_) async => const [
        AiSubstituteSuggestion(
            model: 'LM358DR',
            brand: 'TI',
            package: 'SOIC-8',
            reason: '同参数同封装',
            confidence: 0.88),
      ],
    );

    await tester.tap(find.text('AI 网络替代'));
    await tester.pump(); // busy 帧
    await tester.pump(); // 结果帧

    expect(find.text('AI 网络替代（市面可购型号）'), findsOneWidget);
    expect(find.text('LM358DR'), findsOneWidget);
    expect(find.text('TI · 封装 SOIC-8 · 同参数同封装'), findsOneWidget);
    expect(find.text('88%'), findsOneWidget);
  });

  testWidgets('库存方向：localPlanFetcher 出「AI 库存替代」组', (tester) async {
    await pumpSheet(
      tester,
      locals: const [],
      localPlanFetcher: (_) async => const AiSubstitutePlan(
        originalSpecs: {'型号': 'LM358N'},
        suggestions: [
          AiSubstituteSuggestion(
              model: 'LM358P', reason: '库存有 12 个', confidence: 0.9),
        ],
      ),
    );

    await tester.tap(find.text('AI 库存替代'));
    await tester.pump();
    await tester.pump();

    expect(find.text('AI 库存替代（选自我的库存）'), findsOneWidget);
    expect(find.text('LM358P'), findsOneWidget);
    expect(find.text('库存有 12 个'), findsOneWidget);
  });

  testWidgets('fetcher 抛 AiHttpException(401) → 网络方向红字，可重试',
      (tester) async {
    await pumpSheet(
      tester,
      locals: const [],
      aiFetcher: (_) async => throw AiHttpException(401),
    );

    await tester.tap(find.text('AI 网络替代'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('网络方向'), findsOneWidget);
    expect(find.textContaining('鉴权失败'), findsOneWidget);
    expect(find.text('AI 网络替代（市面可购型号）'), findsNothing); // 无成功组
    final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'AI 网络替代'));
    expect(btn.onPressed, isNotNull); // 错误后仍可重试
  });

  testWidgets('initialAdvice 预载双方向缓存（免请求直接展示）', (tester) async {
    await pumpSheet(
      tester,
      locals: const [],
      initialAdvice: const AiRowAdvice(
        net: AiSubstitutePlan(
          originalSpecs: {'供电电压': '±15V'},
          suggestions: [
            AiSubstituteSuggestion(
                model: 'LM358DR', specs: {'供电电压': '±15V'}, risk: '可直接替代'),
          ],
        ),
        local: AiSubstitutePlan(suggestions: [
          AiSubstituteSuggestion(model: 'NE5532', reason: '库存 3'),
        ]),
      ),
    );

    expect(find.text('AI 网络替代（市面可购型号）'), findsOneWidget);
    expect(find.text('AI 库存替代（选自我的库存）'), findsOneWidget);
    expect(find.text('LM358DR'), findsOneWidget);
    expect(find.text('NE5532'), findsOneWidget);
    expect(find.textContaining('⚑ 可直接替代'), findsOneWidget);

    // 点对比 → 电气参数对比页（原件 specs 来自方案）
    await tester.tap(find.byKey(const ValueKey('ai_compare_LM358DR')));
    await tester.pumpAndSettle();
    expect(find.text('电气参数对比'), findsOneWidget);
    expect(find.text('±15V'), findsNWidgets(2)); // 原件列 + 候选列
  });

  testWidgets('planFetcher 优先于 aiFetcher：走方案版接口', (tester) async {
    var planCalled = 0, listCalled = 0;
    await pumpSheet(
      tester,
      locals: const [],
      aiFetcher: (_) async {
        listCalled++;
        return const [];
      },
      planFetcher: (_) async {
        planCalled++;
        return const AiSubstitutePlan(
          originalSpecs: {'容值': '100nF'},
          suggestions: [AiSubstituteSuggestion(model: 'C-CAND')],
        );
      },
    );

    await tester.tap(find.text('AI 网络替代'));
    await tester.pump();
    await tester.pump();

    expect(planCalled, 1);
    expect(listCalled, 0);
    expect(find.text('C-CAND'), findsOneWidget);
  });
}
