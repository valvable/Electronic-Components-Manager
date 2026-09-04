import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/config/constants.dart';
import '../core/services/ai_client.dart';
import '../core/services/ai_substitute_batch.dart';
import '../core/utils/bom_compare.dart';
import '../core/utils/bom_substitute.dart';
import '../screens/substitute_compare_screen.dart';

/// 缺料/待采购行的替代方案底部面板。三个来源：
///
/// 1. **本地库存替代（离线粗筛）**：[locals] 由导入页用 [topLocalSubstitutes]
///    纯字符串打分算好，完全不联网；
/// 2. **AI 库存替代**：[localPlanFetcher] 把库存清单交给 AI（默认 AI2 增强
///    接口），从已有元件里挑真正参数兼容的——比离线粗筛准；
/// 3. **AI 网络替代**：[planFetcher] 推荐市面可购型号，带电气参数与 risk。
///
/// 两个 AI 方向独立按钮、独立错误，超时（[aiRequestTimeoutSeconds]）自动中止。
/// [initialAdvice]：批处理页缓存直接带出（免重复请求）；[inventoryBrief]/
/// [modelToId] 供库存替代方向构造请求。
Future<void> showSubstituteSheet(
  BuildContext context, {
  required BomCompareRow row,
  required List<LocalSubstitute> locals,
  required AiRecommendFetcher aiFetcher,
  AiPlanFetcher? planFetcher,
  AiInventoryPlanFetcher? localPlanFetcher,
  AiSubstitutePlan? initialPlan,
  AiRowAdvice? initialAdvice,
  List<String> inventoryBrief = const [],
  Map<String, int> modelToId = const {},
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => SubstituteSheet(
      row: row,
      locals: locals,
      aiFetcher: aiFetcher,
      planFetcher: planFetcher,
      localPlanFetcher: localPlanFetcher,
      initialPlan: initialPlan,
      initialAdvice: initialAdvice,
      inventoryBrief: inventoryBrief,
      modelToId: modelToId,
    ),
  );
}

/// 替代面板内容（独立 StatefulWidget，可脱离导入页单独测试）。
class SubstituteSheet extends StatefulWidget {
  final BomCompareRow row;
  final List<LocalSubstitute> locals;
  final AiRecommendFetcher aiFetcher;
  final AiPlanFetcher? planFetcher;
  final AiInventoryPlanFetcher? localPlanFetcher;
  final AiSubstitutePlan? initialPlan;
  final AiRowAdvice? initialAdvice;
  final List<String> inventoryBrief;
  final Map<String, int> modelToId;

  const SubstituteSheet({
    super.key,
    required this.row,
    required this.locals,
    required this.aiFetcher,
    this.planFetcher,
    this.localPlanFetcher,
    this.initialPlan,
    this.initialAdvice,
    this.inventoryBrief = const [],
    this.modelToId = const {},
  });

  @override
  State<SubstituteSheet> createState() => _SubstituteSheetState();
}

class _SubstituteSheetState extends State<SubstituteSheet> {
  bool _netBusy = false;
  bool _localBusy = false;
  List<AiSubstituteSuggestion>? _netResults;
  List<AiSubstituteSuggestion>? _localResults;
  AiSubstitutePlan? _netPlan; // 含原元件电气参数（网络方向）
  AiSubstitutePlan? _localPlan; // 库存方向也带回原件 specs（供对比页）
  String? _netError;
  String? _localError;

  @override
  void initState() {
    super.initState();
    final advice = widget.initialAdvice;
    final preset = advice?.net ?? widget.initialPlan;
    if (preset != null && preset.suggestions.isNotEmpty) {
      _netPlan = preset;
      _netResults = preset.suggestions;
    }
    final local = advice?.local;
    if (local != null && local.suggestions.isNotEmpty) {
      _localPlan = local;
      _localResults = local.suggestions;
    }
  }

  AiSubstituteContext get _ctx => AiSubstituteContext(
        model: widget.row.line.model,
        qty: widget.row.line.qty,
        designation: widget.row.line.designation,
        category: widget.row.matched?.category,
        package: widget.row.matched?.package,
        localModels: [
          for (final l in widget.locals) l.component.model,
        ],
        inventoryBrief: widget.inventoryBrief,
        modelToId: widget.modelToId,
      );

  /// 原元件电气参数：网络方案优先，其次库存方案。
  Map<String, String> get _originalSpecs =>
      _netPlan?.originalSpecs.isNotEmpty == true
          ? _netPlan!.originalSpecs
          : _localPlan?.originalSpecs ?? const {};

  Future<void> _recommendNetwork() async {
    if (_netBusy) return;
    setState(() {
      _netBusy = true;
      _netError = null;
    });
    try {
      final ctx = _ctx;
      final planFetcher = widget.planFetcher;
      if (planFetcher != null) {
        final plan = await planFetcher(ctx);
        if (!mounted) return;
        setState(() {
          _netPlan = plan;
          _netResults = plan.suggestions;
        });
      } else {
        final list = await widget.aiFetcher(ctx);
        if (!mounted) return;
        setState(() {
          _netPlan = null;
          _netResults = list;
        });
      }
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() => _netError = friendlyAiError(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _netError = 'AI 推荐失败：$e');
    } finally {
      if (mounted) setState(() => _netBusy = false);
    }
  }

  Future<void> _recommendInventory() async {
    if (_localBusy) return;
    setState(() {
      _localBusy = true;
      _localError = null;
    });
    try {
      final plan = await (widget.localPlanFetcher ?? _defaultInventoryFetch)(_ctx);
      if (!mounted) return;
      setState(() {
        _localPlan = plan;
        _localResults = plan?.suggestions ?? const [];
      });
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() => _localError = friendlyAiError(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _localError = 'AI 查询失败：$e');
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  /// 线上默认库存方向实现需要 store——面板不持有 AppState，由导入页注入
  /// [AiInventoryPlanFetcher]；未注入（如旧测试）时禁用按钮即可。
  Future<AiSubstitutePlan?> _defaultInventoryFetch(AiSubstituteContext ctx) async {
    throw StateError('未注入库存替代实现');
  }

  void _copy(String model) {
    Clipboard.setData(ClipboardData(text: model));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('「$model」已复制')));
  }

  /// 打开「电气参数对比」页：原件参数（任一方案携带）+ 该候选，聚焦单候选。
  void _openCompare(AiSubstituteSuggestion s) {
    showSubstituteCompare(
      context,
      row: widget.row,
      plan: AiSubstitutePlan(
        originalSpecs: _originalSpecs,
        suggestions: [s],
      ),
    );
  }

  static String _conf(double? c) =>
      c == null ? '' : '${(c * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = widget.row;
    final height = (MediaQuery.of(context).size.height * 0.72).clamp(260.0, 660.0);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(theme, row),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  Text('本地库存替代（离线粗筛）',
                      style: theme.textTheme.titleSmall),
                  if (widget.locals.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '本地暂无可靠替代。可用下方 AI 双方向推荐（需已在设置页配置 AI 接口）。',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    )
                  else ...[
                    const SizedBox(height: 4),
                    for (final l in widget.locals)
                      _LocalTile(
                        local: l,
                        onCopy: () => _copy(l.component.model),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '点击型号可复制',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  // 两个 AI 方向并排，各自独立请求/报错/超时中止。
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('ai_inventory_btn'),
                          onPressed: (_localBusy || widget.localPlanFetcher == null)
                              ? null
                              : _recommendInventory,
                          icon: _localBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.inventory_2_outlined, size: 18),
                          label: Text(_localBusy ? '库存分析中…' : 'AI 库存替代'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('ai_network_btn'),
                          onPressed: _netBusy ? null : _recommendNetwork,
                          icon: _netBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.public, size: 18),
                          label: Text(_netBusy ? '网络分析中…' : 'AI 网络替代'),
                        ),
                      ),
                    ],
                  ),
                  if (_netBusy || _localBusy)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '替换推荐走 AI2 增强接口（未配置则回退 AI1）；'
                        '最长 $aiRequestTimeoutSeconds 秒无响应自动中止，不会一直等。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ),
                  if (_localError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '库存方向：${_localError!}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                  if (_netError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '网络方向：${_netError!}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                  ..._aiGroup(
                    theme,
                    title: 'AI 库存替代（选自我的库存）',
                    results: _localResults,
                    busy: _localBusy,
                  ),
                  ..._aiGroup(
                    theme,
                    title: 'AI 网络替代（市面可购型号）',
                    results: _netResults,
                    busy: _netBusy,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一个 AI 方向的结果组（未请求且非忙时不占位）。
  List<Widget> _aiGroup(
    ThemeData theme, {
    required String title,
    required List<AiSubstituteSuggestion>? results,
    required bool busy,
  }) {
    if (results == null) return const [];
    if (results.isEmpty) {
      if (busy) return const [];
      return [
        const SizedBox(height: 12),
        Text('$title：没找到可靠替代',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ];
    }
    return [
      const SizedBox(height: 16),
      Text(title, style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      for (final r in results)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.auto_awesome,
              size: 18, color: theme.colorScheme.primary),
          title: Text(r.model),
          subtitle: Text([
            if (r.brand != null && r.brand!.isNotEmpty) r.brand!,
            if (r.package != null && r.package!.isNotEmpty)
              '封装 ${r.package}',
            if (r.reason != null && r.reason!.isNotEmpty) r.reason!,
          ].join(' · ')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_conf(r.confidence), style: theme.textTheme.labelMedium),
              IconButton(
                key: ValueKey('ai_compare_${r.model}'),
                tooltip: '电气参数对比',
                icon: const Icon(Icons.compare_arrows, size: 18),
                onPressed: () => _openCompare(r),
              ),
            ],
          ),
          onTap: () => _copy(r.model),
        ),
      // 有 specs/risk 时补摘要行。
      for (final r in results)
        if (r.specs.isNotEmpty || (r.risk != null && r.risk!.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: Text(
              [
                if (r.risk != null && r.risk!.isNotEmpty) '⚑ ${r.risk}',
                ...r.specs.entries
                    .take(3)
                    .map((e) => '${e.key} ${e.value}'),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '点型号复制 · 点右侧图标看与原件的电气参数逐项对比',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ),
    ];
  }

  Widget _buildHeader(ThemeData theme, BomCompareRow row) {
    final (bg, fg, label) = switch (row.status) {
      BomStatus.inStock => (Colors.green.shade50, Colors.green.shade800, '充足'),
      BomStatus.short => (Colors.orange.shade50, Colors.orange.shade800, '缺${row.shortBy}'),
      BomStatus.missing => (Colors.red.shade50, Colors.red.shade800, '待采购'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
      child: Row(
        children: [
          Icon(Icons.swap_horiz, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${row.line.model}的替代方案',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(label,
                style:
                    TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }
}

class _LocalTile extends StatelessWidget {
  final LocalSubstitute local;
  final VoidCallback onCopy;

  const _LocalTile({required this.local, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = local.component;
    final first = c.category.isEmpty ? '?' : c.category[0];
    final conf = '${(local.confidence * 100).round()}%';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Text(
          first,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
      ),
      title: Text(c.model, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        local.reason,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        conf,
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary),
      ),
      onTap: onCopy,
    );
  }
}
