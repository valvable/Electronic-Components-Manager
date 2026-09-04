import 'package:flutter/material.dart';

import '../core/services/ai_client.dart';
import '../core/services/ai_substitute_batch.dart';
import '../core/utils/bom_compare.dart';
import '../main.dart';
import 'substitute_compare_screen.dart';

/// 一个待 AI 推荐的缺料行：[rowId] = 在 ImportScreen 结果列表中的下标
/// （批处理按 tasks 顺序跑，回传结果按 rowId 归位）。
class SubstituteBatchTask {
  final int rowId;
  final BomCompareRow row;
  final List<String> localModels; // 本地已展示的候选，提示网络方向别重复

  const SubstituteBatchTask({
    required this.rowId,
    required this.row,
    this.localModels = const [],
  });
}

enum _Phase { pending, running, done, failed }

/// 全屏 AI 缺料替代处理页：元件一个一个找、找到一个立刻挂出一个。
///
/// - **双方向**（都走 AI 接口，替换任务优先用设置页的 AI2 增强配置）：
///   「库存替代」把库存清单交给 AI 从已有元件里挑；「网络替代」让 AI 推荐
///   市面型号。顶部两个 FilterChip 可开关，中途改动只影响后续行；
/// - 顶部总进度（第 i/N 个 + 完成/失败计数）；每行卡片状态机
///   等待 → 正在分析… → 已给出建议（每方向前 2 条即时可见，点「对比」
///   进电气参数页）或 失败（friendlyAiError + 单行重试）；
/// - 「停止」随时中止剩余行（已完成的保留）；关页时把成功方案
///   `Map<rowId, AiRowAdvice>` 回传 ImportScreen 缓存（不写库）。
/// - [fetch] 注入缝（测试喂假实现；默认走设置页配置的 AI）。
class SubstituteBatchScreen extends StatefulWidget {
  final AppState state;
  final List<SubstituteBatchTask> tasks;

  /// 库存替代方向的库存摘要（"型号|分类|封装|数量"）与 型号→id 映射。
  final List<String> inventoryBrief;
  final Map<String, int> modelToId;

  final Future<AiSubstitutePlan?> Function(
      SubDirection direction, int index, AiSubstituteContext ctx)? fetch;

  const SubstituteBatchScreen({
    super.key,
    required this.state,
    required this.tasks,
    this.inventoryBrief = const [],
    this.modelToId = const {},
    this.fetch,
  });

  @override
  State<SubstituteBatchScreen> createState() => _SubstituteBatchScreenState();
}

class _SubstituteBatchScreenState extends State<SubstituteBatchScreen> {
  late final List<_Phase> _phase =
      List.filled(widget.tasks.length, _Phase.pending);
  final Map<int, BatchRowOutcome> _outcomes = {}; // key = task 下标

  /// 当前所跑方向（可变集合——批处理逐行现取，中途开关只影响后续行）。
  final Set<SubDirection> _dirs = {
    SubDirection.inventory,
    SubDirection.network,
  };

  bool _cancelled = false;
  bool _batchFinished = false;
  int _runningPos = -1;

  @override
  void initState() {
    super.initState();
    // post-frame 启动：_start 会同步走到第一次 setState（fetch 装填 running
    // 状态），直接在 initState 里调会撞上「build 期间 markNeedsBuild」。
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _cancelled = true; // 页面被销毁（含系统返回）→ 剩余行不再请求
    super.dispose();
  }

  /// 按 **task 下标**（不是 rowId！）构造请求上下文。
  AiSubstituteContext _ctxAt(int pos) {
    final task = widget.tasks[pos];
    final row = task.row;
    return AiSubstituteContext(
      model: row.line.model,
      qty: row.line.qty,
      designation: row.line.designation,
      localModels: task.localModels,
      inventoryBrief: widget.inventoryBrief,
      modelToId: widget.modelToId,
    );
  }

  Future<AiSubstitutePlan?> _defaultFetch(
      SubDirection d, int pos, AiSubstituteContext ctx) {
    if (d == SubDirection.network) {
      return aiRecommendSubstitutePlanFromSettings(
        widget.state.settings,
        model: ctx.model,
        qty: ctx.qty,
        designation: ctx.designation,
        localModels: ctx.localModels,
      );
    }
    return aiSubstituteFromInventoryFromSettings(
      widget.state.settings,
      model: ctx.model,
      qty: ctx.qty,
      category: ctx.category,
      package: ctx.package,
      designation: ctx.designation,
      inventoryBrief: ctx.inventoryBrief,
      modelToId: ctx.modelToId,
    );
  }

  Future<AiSubstitutePlan?> _fetchAt(
      SubDirection d, int pos, AiSubstituteContext ctx) {
    if (mounted) {
      setState(() {
        _runningPos = pos;
        _phase[pos] = _Phase.running;
      });
    }
    return (widget.fetch ?? _defaultFetch)(d, pos, ctx);
  }

  Future<void> _start() async {
    final tasks = [for (var p = 0; p < widget.tasks.length; p++) _ctxAt(p)];
    await runSubstituteBatch(
      tasks: tasks,
      directions: _dirs,
      fetch: _fetchAt,
      cancelled: () => _cancelled,
      onRowDone: (o) {
        if (!mounted) return;
        setState(() {
          _outcomes[o.index] = o;
          _phase[o.index] = o.failed ? _Phase.failed : _Phase.done;
          _runningPos = -1;
        });
      },
    );
    if (!mounted) return;
    setState(() => _batchFinished = true);
  }

  /// 批次结束后单行重试（沿用该行原方向集合；批处理在跑时禁用）。
  Future<void> _retry(int pos) async {
    if (_runningPos >= 0 || !_batchFinished || _cancelled) return;
    final dirs = _outcomes[pos]?.dirs ?? Set.of(_dirs);
    var advice = const AiRowAdvice();
    for (final d in dirs) {
      setState(() {
        _runningPos = pos;
        _phase[pos] = _Phase.running;
      });
      try {
        final plan = await _fetchAt(d, pos, _ctxAt(pos));
        advice = advice.mergeForDirection(d, plan: plan);
      } catch (e) {
        advice = advice.mergeForDirection(d, error: e);
      }
    }
    if (!mounted) return;
    final outcome = BatchRowOutcome(pos, advice, dirs: dirs);
    setState(() {
      _outcomes[pos] = outcome;
      _phase[pos] = outcome.failed ? _Phase.failed : _Phase.done;
      _runningPos = -1;
    });
  }

  Map<int, AiRowAdvice> _adviceResults() {
    final out = <int, AiRowAdvice>{};
    for (final e in _outcomes.entries) {
      if (e.value.advice.hasAny) {
        out[widget.tasks[e.key].rowId] = e.value.advice;
      }
    }
    return out;
  }

  int get _doneCount => _outcomes.values.where((o) => !o.failed).length;
  int get _failCount => _outcomes.values.where((o) => o.failed).length;

  @override
  Widget build(BuildContext context) {
    final total = widget.tasks.length;
    final progress = total == 0 ? 1.0 : (_doneCount + _failCount) / total;
    final allSettled = _doneCount + _failCount >= total;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelled = true; // 返回即停剩余行
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AI 缺料替代推荐'),
          automaticallyImplyLeading: false,
          leading: IconButton(
            tooltip: '完成并返回',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context, _adviceResults()),
          ),
          actions: [
            if (!allSettled && !_cancelled)
              IconButton(
                key: const ValueKey('batch_stop_btn'),
                tooltip: '停止后续元件',
                icon: const Icon(Icons.stop_circle_outlined),
                onPressed: () {
                  setState(() => _cancelled = true);
                  _toast('已停止：不再请求剩余元件');
                },
              ),
          ],
        ),
        body: Column(
          children: [
            _progressHeader(context, total, progress),
            _directionBar(context),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                itemCount: total,
                itemBuilder: (ctx, i) => _rowCard(ctx, i),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('batch_done_btn'),
                    onPressed: () => Navigator.pop(context, _adviceResults()),
                    icon: const Icon(Icons.check),
                    label: Text(allSettled ? '完成（返回对比页）' : '返回（保留已获得建议）'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 方向开关：库存替代（AI 从自己库存挑）/ 网络替代（AI 推市面型号）。
  Widget _directionBar(BuildContext context) {
    final theme = Theme.of(context);
    void toggle(SubDirection d, bool on) {
      setState(() {
        if (on) {
          _dirs.add(d);
        } else if (_dirs.length > 1) {
          _dirs.remove(d);
        }
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Row(
        children: [
          FilterChip(
            key: const ValueKey('dir_inventory'),
            label: const Text('库存替代'),
            avatar: const Icon(Icons.inventory_2_outlined, size: 16),
            selected: _dirs.contains(SubDirection.inventory),
            onSelected: (v) => toggle(SubDirection.inventory, v),
          ),
          const SizedBox(width: 8),
          FilterChip(
            key: const ValueKey('dir_network'),
            label: const Text('网络替代'),
            avatar: const Icon(Icons.public, size: 16),
            selected: _dirs.contains(SubDirection.network),
            onSelected: (v) => toggle(SubDirection.network, v),
          ),
          const Spacer(),
          Text(
            '切换只影响后续行',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _progressHeader(BuildContext context, int total, double progress) {
    final theme = Theme.of(context);
    final settled = _doneCount + _failCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _cancelled
                      ? '已手动停止 · 共 $total 个缺料元件'
                      : settled >= total
                          ? '全部处理完成 · 共 $total 个缺料元件'
                          : '第 ${_runningPos >= 0 ? _runningPos + 1 : settled + 1}/$total 个：'
                              '${_runningPos >= 0 ? widget.tasks[_runningPos].row.line.model : ''}',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('✓$_doneCount',
                  style: TextStyle(color: Colors.green.shade700, fontSize: 12)),
              const SizedBox(width: 6),
              Text('✗$_failCount',
                  style: TextStyle(color: Colors.red.shade600, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress.clamp(0.0, 1.0), minHeight: 4),
        ],
      ),
    );
  }

  Widget _rowCard(BuildContext context, int pos) {
    final task = widget.tasks[pos];
    final row = task.row;
    final theme = Theme.of(context);
    final phase = _phase[pos];
    final outcome = _outcomes[pos];
    final advice = outcome?.advice;
    final rowDirs = outcome?.dirs ?? const <SubDirection>{};

    final (IconData icon, Color color, String statusText) = switch (phase) {
      _Phase.pending => (Icons.hourglass_empty, Colors.grey, '等待中'),
      _Phase.running => (Icons.autorenew, theme.colorScheme.primary, '正在分析（库存 + 网络双方向）…'),
      _Phase.done => (
          Icons.check_circle_outline,
          Colors.green.shade700,
          advice != null && advice.hasAny
              ? '已给出 ${advice.suggestionCount} 个建议'
              : '两个方向都没找到可靠替代',
        ),
      _Phase.failed => (
          Icons.error_outline,
          Colors.red.shade600,
          friendlyAiError(advice?.netError ?? advice?.localError ?? '未知错误'),
        ),
    };

    return Card(
      key: ValueKey('batch_row_$pos'),
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (phase == _Phase.running)
                  const SizedBox(
                      width: 18,
                      height: 18,
                      child:
                          CircularProgressIndicator(strokeWidth: 2))
                else
                  Icon(icon, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    row.line.model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text('缺 ${row.shortBy}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.error)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 2, bottom: 4),
              child: Text(
                statusText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: phase == _Phase.failed
                      ? Colors.red.shade600
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (advice != null)
              for (final d in rowDirs)
                ..._directionLines(context, row, advice, d),
            // 某方向单独失败（另一方向有结果）：只标一行橙字，整行失败的
            // 情况已由状态行红色 friendlyAiError 覆盖，不重复提示。
            if (advice != null &&
                phase != _Phase.running &&
                phase != _Phase.failed &&
                rowDirs.any((d) => advice.errorFor(d) != null))
              Padding(
                padding: const EdgeInsets.only(left: 30, bottom: 2),
                child: Text(
                  rowDirs
                      .where((d) => advice.errorFor(d) != null)
                      .map((d) =>
                          '${d == SubDirection.inventory ? '库存' : '网络'}方向失败：${friendlyAiError(advice.errorFor(d)!)}')
                      .join('；'),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: Colors.orange.shade800),
                ),
              ),
            if (phase == _Phase.failed && _batchFinished)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: ValueKey('batch_retry_$pos'),
                  onPressed: () => _retry(pos),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 一个方向的结果行：小标题 + 前 2 条建议（点「对比」进电气参数页）。
  List<Widget> _directionLines(
      BuildContext context, BomCompareRow row, AiRowAdvice advice, SubDirection d) {
    final theme = Theme.of(context);
    final plan = d == SubDirection.network ? advice.net : advice.local;
    final shown = plan?.suggestions ?? const <AiSubstituteSuggestion>[];
    if (shown.isEmpty) return const [];
    final label = d == SubDirection.network ? '网络替代' : '库存替代';
    final widgets = <Widget>[
      Padding(
        padding: const EdgeInsets.only(left: 30, top: 2),
        child: Row(
          children: [
            Icon(d == SubDirection.network ? Icons.public : Icons.inventory_2,
                size: 13, color: theme.colorScheme.outline),
            const SizedBox(width: 5),
            Text('$label ×${shown.length}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    ];
    for (final s in shown.take(2)) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Row(
            children: [
              Expanded(
                child: Text(s.model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ),
              if (s.risk != null && s.risk!.isNotEmpty)
                Text(s.risk!,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: _riskColor(s.risk),
                        fontWeight: FontWeight.w600)),
              TextButton(
                onPressed: () => showSubstituteCompare(
                  context,
                  row: row,
                  plan: AiSubstitutePlan(
                      originalSpecs: plan?.originalSpecs ?? const {},
                      suggestions: [s]),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('对比', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }
    if (shown.length > 2) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(left: 30, bottom: 2),
          child: Text(
            '… 另有 ${shown.length - 2} 条，去 BOM 对比页点该行「替代」查看全部',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      );
    }
    return widgets;
  }

  Color _riskColor(String? risk) {
    if (risk == null) return Colors.grey;
    if (risk.contains('可直接') || risk.contains('兼容')) return Colors.green;
    if (risk.contains('不建议') || risk.contains('不可')) return Colors.red;
    return Colors.orange;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}
