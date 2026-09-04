import 'package:flutter/material.dart';

import '../core/services/ai_client.dart';
import '../core/services/ai_substitute_batch.dart';
import '../core/services/export_service.dart';
import '../core/services/import_parser.dart';
import '../core/services/lcsc_lookup.dart';
import '../core/utils/bom_compare.dart';
import '../core/utils/bom_substitute.dart';
import '../core/utils/classifier.dart';
import '../main.dart';
import '../models/component.dart';
import '../widgets/import_result_table.dart';
import '../widgets/substitute_sheet.dart';
import 'substitute_batch_screen.dart';

/// BOM 导入页：选文件（csv/xlsx）→ 列映射（自动识别表头可调）→ 对比库存
/// → 对比表 + 导出报告 / 生成采购清单 + AI 一键缺料替代。
///
/// AI 批量建议缓存在页内存 [ImportScreen._aiPlans]（改映射/换文件即作废），
/// 不写库、不参与局域网同步；行「替代」面板带出缓存方案，「对比」进电气参数页。
class ImportScreen extends StatefulWidget {
  final AppState state;

  /// AI 替代缝（测试注入；null = 走 aiRecommendSubstitutes 真实现）。
  final AiRecommendFetcher? aiFetcher;

  const ImportScreen({super.key, required this.state, this.aiFetcher});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  List<List<String>>? _rows; // 含表头的全部行
  ColumnMapping _mapping = const ColumnMapping(modelCol: -1, qtyCol: -1);
  List<BomCompareRow>? _results;
  List<Component>? _lastInventory; // 最近一次对比的库存快照（替代面板复用）
  Set<int> _matchedIds = const {}; // 各行已命中库存 id（替代不推荐自己/已匹配）
  String _bomName = '';
  bool _busy = false;
  String? _error;

  /// 行下标 → 批处理页回传的 AI 建议（网络 + 库存双方向，含原元件电气参数）。
  final Map<int, AiRowAdvice> _aiAdvices = {};

  bool get _hasFile => _rows != null;

  int get _columnCount {
    final rows = _rows;
    if (rows == null) return 0;
    var m = 0;
    for (final r in rows) {
      if (r.length > m) m = r.length;
    }
    return m;
  }

  List<String> get _header => _rows?.first ?? const [];

  // ---- 动作 ----

  Future<void> _pickFile() async {
    final file = await pickImportFile(['csv', 'xlsx']);
    if (file == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await parseImportFile(file);
      if (rows.isEmpty) throw const FormatException('文件没有内容');
      final mapping = detectColumnMapping(rows.first);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _mapping = mapping;
        _bomName = file.name;
        _results = null;
        _aiAdvices.clear(); // 换文件：旧行下标建议作废
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '解析失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _compare() async {
    final rows = _rows;
    if (rows == null || !_mapping.isComplete) return;
    setState(() => _busy = true);
    try {
      final lines = buildBomLines(rows, _mapping);
      if (lines.isEmpty) {
        _toast('没有可对比的有效物料行（请检查列映射）');
        return;
      }
      final inventory = await widget.state.components.all(category: null);
      final results = compareAgainstInventory(lines, inventory);
      if (!mounted) return;
      setState(() {
        _results = results;
        _lastInventory = inventory;
        // 各命中元件的 id：替代推荐时排除（不把自己/已用库存当替代）
        _matchedIds = {
          for (final r in results)
            if (r.matched?.id != null) r.matched!.id!,
        };
      });
    } catch (e) {
      _toast('对比失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportReport() async {
    final results = _results;
    if (results == null) return;
    final text = buildInventoryReportText(results, bomName: _bomName);
    final path = await saveTextFile('BOM对比报告_${_stamp()}.txt', text);
    if (path != null) _toast('报告已保存：$path');
  }

  Future<void> _exportPurchaseList() async {
    final results = _results;
    if (results == null) return;
    final csv = buildPurchaseListCsv(results);
    final path = await saveTextFile('采购清单_${_stamp()}.csv', csv);
    if (path != null) _toast('采购清单已保存：$path');
  }

  /// 某行的本地替代候选（离线纯函数）；行级提示逻辑与批处理共用一份。
  List<LocalSubstitute> _localsFor(BomCompareRow row, List<Component> inventory) {
    final matched = row.matched;
    // 分类提示：命中库存元件分类优先；否则非 C 号按型号分类器推，C 号不猜分类
    final categoryHint = matched?.category ??
        (isLcscCode(row.line.model) ? null : classify(row.line.model));
    return topLocalSubstitutes(
      model: row.line.model,
      categoryHint: categoryHint,
      packageHint: matched?.package,
      inventory: inventory,
      excludeIds: _matchedIds,
    );
  }

  /// 库存摘要（"型号|分类|封装|数量"，仅活动且有存货）与 型号→id 映射，
  /// 供「AI 库存替代」方向请求；行数封顶防爆 prompt（按数量降序截断）。
  List<String> get _inventoryBrief {
    final inv = _lastInventory;
    if (inv == null) return const [];
    final usable = inv.where((c) => !c.isDeleted && c.quantity > 0).toList()
      ..sort((a, b) => b.quantity.compareTo(a.quantity));
    return [
      for (final c in usable.take(400))
        '${c.model}|${c.categoryOrOther}|${c.package ?? ''}|${c.quantity}',
    ];
  }

  Map<String, int> get _modelToId {
    final inv = _lastInventory;
    if (inv == null) return const {};
    final out = <String, int>{};
    for (final c in inv) {
      if (c.isDeleted || c.id == null) continue;
      out.putIfAbsent(c.model.trim().toLowerCase(), () => c.id!);
    }
    return out;
  }

  /// 打开某行的替代面板：离线粗筛 + AI 双方向（库存/网络，各带电气参数）。
  /// 批处理已有该行的缓存建议则直接带出（initialAdvice），免重复请求。
  Future<void> _openSubstitute(BomCompareRow row) async {
    final inventory = _lastInventory;
    if (inventory == null) return;
    final locals = _localsFor(row, inventory);
    final idx = _results?.indexOf(row) ?? -1;
    final injected = widget.aiFetcher;
    await showSubstituteSheet(
      context,
      row: row,
      locals: locals,
      // 注入缝（测试）优先；线上默认走方案版 planFetcher，aiFetcher 仅兜底。
      aiFetcher: injected ?? (_) async => const [],
      planFetcher: injected != null
          ? null
          : (AiSubstituteContext ctx) => aiRecommendSubstitutePlanFromSettings(
                widget.state.settings,
                model: ctx.model,
                qty: ctx.qty,
                designation: ctx.designation,
                localModels: ctx.localModels,
              ),
      localPlanFetcher: injected != null
          ? null
          : (AiSubstituteContext ctx) => aiSubstituteFromInventoryFromSettings(
                widget.state.settings,
                model: ctx.model,
                qty: ctx.qty,
                category: ctx.category,
                package: ctx.package,
                designation: ctx.designation,
                inventoryBrief: ctx.inventoryBrief,
                modelToId: ctx.modelToId,
              ),
      initialAdvice: idx >= 0 ? _aiAdvices[idx] : null,
      inventoryBrief: _inventoryBrief,
      modelToId: _modelToId,
    );
  }

  /// 一键 AI：所有非充足行打包进全屏批处理页（双方向、一个一个找、
  /// 出一个挂一个），返回的建议按行下标缓存进 [_aiAdvices]。
  Future<void> _runAiBatch() async {
    final results = _results;
    final inventory = _lastInventory;
    if (results == null || inventory == null) return;
    final tasks = <SubstituteBatchTask>[];
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      if (r.status == BomStatus.inStock) continue;
      tasks.add(SubstituteBatchTask(
        rowId: i,
        row: r,
        localModels: [
          for (final l in _localsFor(r, inventory)) l.component.model,
        ],
      ));
    }
    if (tasks.isEmpty) return;
    final got = await Navigator.push<Map<int, AiRowAdvice>>(
      context,
      MaterialPageRoute(
        builder: (_) => SubstituteBatchScreen(
          state: widget.state,
          tasks: tasks,
          inventoryBrief: _inventoryBrief,
          modelToId: _modelToId,
        ),
      ),
    );
    if (got == null || got.isEmpty || !mounted) return;
    setState(() => _aiAdvices.addAll(got));
    _toast('已收到 ${got.length} 个元件的 AI 建议');
  }

  /// 按对比结果扣库存：命中库存的行扣该行需求量（同元件多行累加），
  /// 二次确认后单事务落库（刷新 updated_at 参与同步），随后自动重新对比。
  Future<void> _deductStock() async {
    final results = _results;
    if (results == null) return;
    final deduct = <int, int>{};
    var rows = 0;
    for (final r in results) {
      final id = r.matched?.id;
      if (id == null) continue; // 待采购行没命中库存，不扣
      rows++;
      deduct[id] = (deduct[id] ?? 0) + r.line.qty;
    }
    if (deduct.isEmpty) {
      _toast('没有命中库存的行，无需扣减');
      return;
    }
    final totalPieces = deduct.values.fold<int>(0, (s, v) => s + v);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('按对比结果扣减库存'),
        content: Text(
          '将对 $rows 行命中库存的元件扣减共 $totalPieces 个（同型号多行累加；'
          '待采购行不扣）。\n\n扣减后自动重新对比。此操作等同于出库记录，'
          '可再手动改数量回滚。确定扣减？',
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            key: const ValueKey('deduct_confirm_btn'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认扣减'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final changed =
          await widget.state.components.deductForBom(deduct);
      _aiAdvices.clear(); // 库存已变，旧建议缓存作废
      if (!mounted) return;
      await _compare();
      if (!mounted) return;
      _toast('已扣减 $changed 个元件库存并重新对比');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('扣减失败：$e');
    }
  }

  String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)}';
  }

  void _updateMapping({int? modelCol, int? qtyCol, int? designationCol}) {
    setState(() {
      _mapping = _mapping.copyWith(
        modelCol: modelCol,
        qtyCol: qtyCol,
        designationCol: designationCol,
      );
      _results = null; // 映射变更后旧结果作废
      _aiAdvices.clear(); // 行下标随之变化，缓存建议一并作废
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BOM 导入')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : (_hasFile ? _buildEditor() : _buildEmpty()),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.upload_file, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              '选择 BOM 文件（CSV / XLSX）\n自动识别表头列并对比库存，可导出报告与采购清单',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('选择 BOM 文件'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor() {
    final rows = _rows!;
    final results = _results;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(_bomName, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('共 ${rows.length} 行'),
            trailing: TextButton(
              onPressed: _pickFile,
              child: const Text('重新选择'),
            ),
          ),
        ),
        if (_error != null)
          Card(
            color: Colors.red.shade50,
            child: ListTile(
              leading: Icon(Icons.error_outline, color: Colors.red.shade700),
              title: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
            ),
          ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('列映射（自动识别，可调整）',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _mappingDropdown('型号列', _mapping.modelCol,
                    (v) => _updateMapping(modelCol: v)),
                _mappingDropdown('数量列', _mapping.qtyCol,
                    (v) => _updateMapping(qtyCol: v)),
                _mappingDropdown('位号列（可选）', _mapping.designationCol,
                    (v) => _updateMapping(designationCol: v)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('数据预览',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                _buildPreview(rows),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _mapping.isComplete ? _compare : null,
          icon: const Icon(Icons.compare_arrows),
          label: const Text('对比库存'),
        ),
        if (results != null) ...[
          const SizedBox(height: 12),
          _buildSummary(results),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('对比结果（${results.length} 行）',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  const SizedBox(height: 4),
                  ImportResultTable(
                    rows: results,
                    onSubstitute: _openSubstitute,
                    aiCounts: {
                      for (final e in _aiAdvices.entries)
                        if (e.value.suggestionCount > 0)
                          e.key: e.value.suggestionCount,
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exportReport,
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('导出报告'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exportPurchaseList,
                  icon: const Icon(Icons.shopping_cart_outlined),
                  label: const Text('采购清单'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 自动扣减：命中库存的行按 BOM 需求量出库（事务 + 二次确认 + 重新对比）。
          OutlinedButton.icon(
            key: const ValueKey('deduct_stock_btn'),
            onPressed: _busy ? null : _deductStock,
            icon: const Icon(Icons.inventory_outlined),
            label: Text('按结果扣减库存（${results.where((r) => r.matched != null).length} 行命中）'),
          ),
          // 有缺料/待采购行时提供一键批量 AI（全屏逐个处理，可中途停止）。
          if (results.any((r) => r.status != BomStatus.inStock)) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: const ValueKey('ai_batch_btn'),
              onPressed: _busy ? null : _runAiBatch,
              icon: const Icon(Icons.auto_awesome),
              label: Text('AI 一键推荐缺料替代（${results.where((r) => r.status != BomStatus.inStock).length} 项）'),
            ),
            const SizedBox(height: 4),
            Text(
              '缺料元件逐个请求 AI，出一个建议挂一个，可随时停止；结果缓存在本页，'
              '点行「替代」→「对比」看电气参数逐项差异。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ],
      ],
    );
  }

  Widget _mappingDropdown(
      String label, int value, ValueChanged<int?> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<int?>(
        initialValue: value >= 0 ? value : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (var i = 0; i < _columnCount; i++) _columnItem(i),
        ],
        onChanged: onChanged,
      ),
    );
  }

  DropdownMenuItem<int> _columnItem(int i) {
    final label = (i < _header.length && _header[i].trim().isNotEmpty)
        ? '${_header[i].trim()}（第${i + 1}列）'
        : '第${i + 1}列';
    return DropdownMenuItem(value: i, child: Text(label, overflow: TextOverflow.ellipsis));
  }

  Widget _buildPreview(List<List<String>> rows) {
    final dataRows = rows.length > 1 ? rows.sublist(1, 1 + (rows.length - 1).clamp(0, 5)) : <List<String>>[];
    if (dataRows.isEmpty) {
      return Text('无数据行', style: TextStyle(color: Colors.grey.shade600));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in dataRows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(
              r.isEmpty ? '（空行）' : r.join('  |  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _buildSummary(List<BomCompareRow> results) {
    final inStock = results.where((r) => r.status == BomStatus.inStock).length;
    final short = results.where((r) => r.status == BomStatus.short).length;
    final missing = results.where((r) => r.status == BomStatus.missing).length;
    final shortQty = results.fold<int>(0, (s, r) => s + r.shortBy);
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _stat('充足', inStock, Colors.green.shade800),
            _stat('缺货', short, Colors.orange.shade800),
            _stat('待采购', missing, Colors.red.shade800),
            _stat('缺料合计', shortQty, Colors.red.shade800),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, int value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      ],
    );
  }
}
