import 'package:component_manager/core/services/ai_client.dart';
import 'package:component_manager/core/services/ai_substitute_batch.dart';
import 'package:flutter_test/flutter_test.dart';

/// 双方向批量编排：逐行逐方向顺序、单方向失败隔离、无结果 ≠ 失败、取消截断。
void main() {
  AiSubstitutePlan planOf(String model) =>
      AiSubstitutePlan(suggestions: [AiSubstituteSuggestion(model: model)]);

  AiSubstituteContext ctx(String model) =>
      AiSubstituteContext(model: model, qty: 5);

  test('双方向全成功：每行完成即回调，advice 两向齐全', () async {
    final done = <BatchRowOutcome>[];
    final order = <String>[];
    final got = await runSubstituteBatch(
      tasks: [ctx('A'), ctx('B')],
      directions: {SubDirection.inventory, SubDirection.network},
      fetch: (d, i, c) async {
        order.add('${c.model}/${d.name}');
        return planOf('${c.model}-${d.name}');
      },
      onRowDone: done.add,
    );
    expect(order, ['A/inventory', 'A/network', 'B/inventory', 'B/network']);
    expect(got.length, 2);
    expect(done.length, 2);
    expect(got.first.advice.netSuggestions.single.model, 'A-network');
    expect(got.first.advice.localSuggestions.single.model, 'A-inventory');
    expect(got.every((o) => o.ok && !o.failed), isTrue);
  });

  test('单方向失败：另一方向照常，行不算 failed', () async {
    final got = await runSubstituteBatch(
      tasks: [ctx('A')],
      directions: {SubDirection.inventory, SubDirection.network},
      fetch: (d, i, c) async {
        if (d == SubDirection.network) throw const AiNetworkException('boom');
        return planOf('inv');
      },
      onRowDone: (_) {},
    );
    final o = got.single;
    expect(o.failed, isFalse);
    expect(o.ok, isTrue);
    expect(o.advice.netError, isA<AiNetworkException>());
    expect(o.advice.localSuggestions.length, 1);
  });

  test('两方向都失败 → failed', () async {
    final got = await runSubstituteBatch(
      tasks: [ctx('A')],
      directions: {SubDirection.inventory, SubDirection.network},
      fetch: (d, i, c) async => throw AiConfigException(['Base URL']),
      onRowDone: (_) {},
    );
    final o = got.single;
    expect(o.failed, isTrue);
    expect(o.ok, isFalse);
    expect(o.dirs.length, 2);
  });

  test('方向返回 null（无可靠替代）：不算失败、无建议', () async {
    final got = await runSubstituteBatch(
      tasks: [ctx('A')],
      directions: {SubDirection.inventory},
      fetch: (d, i, c) async => null,
      onRowDone: (_) {},
    );
    expect(got.single.failed, isFalse);
    expect(got.single.ok, isFalse);
    expect(got.single.advice.hasAny, isFalse);
    expect(got.single.advice.netError, isNull);
  });

  test('取消：回调计数后停止，剩余行不请求', () async {
    var started = 0;
    final done = <int>[];
    final got = await runSubstituteBatch(
      tasks: [ctx('A'), ctx('B'), ctx('C')],
      directions: {SubDirection.network},
      fetch: (d, i, c) async {
        started++;
        return planOf(c.model);
      },
      onRowDone: (o) {
        done.add(o.index);
      },
      cancelled: () => done.length >= 2,
    );
    expect(started, 2);
    expect(done, [0, 1]);
    expect(got.length, 2);
  });

  test('dirs 只跑所选方向；未跑方向的 error 槽保持 null', () async {
    final got = await runSubstituteBatch(
      tasks: [ctx('A')],
      directions: {SubDirection.network},
      fetch: (d, i, c) async => throw const AiNetworkException('x'),
      onRowDone: (_) {},
    );
    expect(got.single.dirs, {SubDirection.network});
    expect(got.single.advice.localError, isNull);
    expect(got.single.failed, isTrue); // 单方向全失败也算 failed
  });
}
