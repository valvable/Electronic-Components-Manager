import 'ai_client.dart';

/// 批量 AI 缺料替代：编排结果统一类型（纯逻辑可单测，UI 在
/// `screens/substitute_batch_screen.dart`）。
///
/// 语义：缺料元件**一个一个找**——每行按所选方向（库存替代 / 网络替代，
/// 均走 AI 接口，替换任务默认用 AI2 增强配置）串行请求，完成一个立刻经
/// [onRowDone] 回调一个；用户可随时经 [cancelled] 停止，剩余行不再请求。

/// 替代推荐的两个方向。
enum SubDirection {
  /// 库存替代：把本机库存清单交给 AI，从**已有元件**里挑可替代的。
  inventory,

  /// 网络替代：AI 推荐市面可采购的替代型号。
  network,
}

/// 一行（一个元件）跨方向的完整建议。方向未跑/没结果时对应字段为 null；
/// 请求失败记在对应的 error 上（互不影响，单方向可重试）。
class AiRowAdvice {
  final AiSubstitutePlan? net;
  final Object? netError;
  final AiSubstitutePlan? local;
  final Object? localError;

  const AiRowAdvice({
    this.net,
    this.netError,
    this.local,
    this.localError,
  });

  List<AiSubstituteSuggestion> get netSuggestions => net?.suggestions ?? const [];
  List<AiSubstituteSuggestion> get localSuggestions =>
      local?.suggestions ?? const [];

  int get suggestionCount => netSuggestions.length + localSuggestions.length;

  bool get hasAny => suggestionCount > 0;

  /// 两个所选方向是否都失败（UI 判「失败行」；有任一方向成功/无结果都不算）。
  bool get allFailed =>
      netError != null && localError != null;

  Object? errorFor(SubDirection d) =>
      d == SubDirection.network ? netError : localError;

  AiRowAdvice mergeForDirection(SubDirection d,
      {AiSubstitutePlan? plan, Object? error}) {
    return d == SubDirection.network
        ? AiRowAdvice(
            net: plan, netError: error, local: local, localError: localError)
        : AiRowAdvice(
            net: net, netError: netError, local: plan, localError: error);
  }
}

/// 一行批处理完成后的结果。[dirs] = 本行实际请求的方向（重试与失败判定用）。
class BatchRowOutcome {
  /// 在提交给 [runSubstituteBatch] 的 tasks 中的下标。
  final int index;
  final AiRowAdvice advice;
  final Set<SubDirection> dirs;

  const BatchRowOutcome(this.index, this.advice, {required this.dirs});

  /// 至少一个方向出了建议。
  bool get ok => advice.hasAny;

  /// 所有本行请求过的方向都失败（无建议且全报错）→ failed。
  bool get failed =>
      !ok && dirs.isNotEmpty && dirs.every((d) => advice.errorFor(d) != null);
}

/// 串行批量入口：按 tasks 顺序逐行、行内按 [directions] 顺序逐方向调 [fetch]，
/// 整行各方向都处理完（成功/无结果/失败）才经 [onRowDone] 回调。
/// - 单方向异常被捕获进 advice 的对应 error，另一方向照常进行；
/// - fetch 返回 null = 该方向「没有可用建议」（不算失败）；
/// - [cancelled] 在每行开始前检查，为 true 则停止（已开始的一行会跑完并回调）；
/// - 返回已完成行的结果列表（取消时是部分结果）。
Future<List<BatchRowOutcome>> runSubstituteBatch({
  required List<AiSubstituteContext> tasks,
  required Set<SubDirection> directions,
  required Future<AiSubstitutePlan?> Function(
      SubDirection direction, int index, AiSubstituteContext ctx)
      fetch,
  required void Function(BatchRowOutcome outcome) onRowDone,
  bool Function()? cancelled,
}) async {
  final results = <BatchRowOutcome>[];
  for (var i = 0; i < tasks.length; i++) {
    if (cancelled?.call() == true) break;
    var advice = const AiRowAdvice();
    for (final d in directions) {
      try {
        final plan = await fetch(d, i, tasks[i]);
        advice = advice.mergeForDirection(d, plan: plan);
      } catch (e) {
        advice = advice.mergeForDirection(d, error: e);
      }
    }
    final outcome = BatchRowOutcome(i, advice, dirs: Set.of(directions));
    results.add(outcome);
    onRowDone(outcome);
  }
  return results;
}
