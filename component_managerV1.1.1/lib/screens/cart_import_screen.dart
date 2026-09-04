import 'package:flutter/material.dart';

import '../core/services/ai_client.dart';
import '../core/services/cart_parser.dart';
import '../core/services/component_repository.dart';
import '../core/services/import_parser.dart';
import '../main.dart';

/// 立创购物车导入页：选文件（csv/xlsx）→ 列映射（自动识别表头可调）
/// → 预览（同 C 号自动合并数量）→ 一键入库。
///
/// 与 BOM 导入不同：购物车按「C 号」匹配，已存在元件仅累加数量、
/// 恢复已删记录，不覆盖用户维护的型号/分类等字段（见 importCart）。
class CartImportScreen extends StatefulWidget {
  final AppState state;

  /// AI 批量命名注入缝（测试；null = 走设置页配置的 AI1 接口）。
  final Future<Map<String, AiModelSuggestion>> Function(
      List<({String code, String raw})> entries)? aiNameBatch;

  const CartImportScreen({super.key, required this.state, this.aiNameBatch});

  @override
  State<CartImportScreen> createState() => _CartImportScreenState();
}

class _CartImportScreenState extends State<CartImportScreen> {
  List<List<String>>? _rows; // 含表头的全部行
  CartColumnMapping _mapping = const CartColumnMapping();
  CartImportReport? _report;
  List<String>? _skipReasons;
  String _fileName = '';
  bool _busy = false;
  String? _error;

  /// 「AI 自动规范命名」开关：入库前把整表名称一次 AI 调用规范成厂商型号。
  bool _aiName = false;

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

  /// 每次 build 现算解析结果：映射调整即所见即所得（购物车行数通常很小）。
  CartParseResult? get _parsed {
    final rows = _rows;
    if (rows == null || !_mapping.isComplete) return null;
    return buildCartItems(rows, _mapping);
  }

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
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _mapping = detectCartMapping(rows.first);
        _fileName = file.name;
        _report = null;
        _skipReasons = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '解析失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final parsed = _parsed;
    if (parsed == null || parsed.isEmpty) return;
    setState(() => _busy = true);
    try {
      var items = parsed.items;
      if (_aiName) {
        // 一次 AI 调用整表规范命名；失败不阻塞入库（toast 提示后按原名继续）。
        try {
          final map = await _nameBatch([
            for (final it in items) (code: it.code, raw: it.model),
          ]);
          if (map.isNotEmpty) {
            items = [
              for (final it in items) _applyName(it, map[it.code.toUpperCase()]),
            ];
            _toast('AI 已规范 ${map.length} 项命名');
          } else {
            _toast('AI 未返回规范名，按原名入库');
          }
        } on AiException catch (e) {
          if (!mounted) return;
          _toast('AI 命名失败（${friendlyAiError(e)}），按原名入库');
        } catch (e) {
          if (!mounted) return;
          _toast('AI 命名失败：$e，按原名入库');
        }
        if (!mounted) return;
      }
      final report = await widget.state.components.importCart(items);
      if (!mounted) return;
      setState(() {
        _report = report;
        _skipReasons = parsed.skipReasons;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
            '入库完成：新增 ${report.inserted} 项，累加 ${report.merged} 项，恢复 ${report.restored} 项',
          ),
        ));
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, AiModelSuggestion>> _nameBatch(
          List<({String code, String raw})> entries) =>
      widget.aiNameBatch?.call(entries) ??
      aiNameCartItems(widget.state.settings, entries: entries);

  /// 规范名套用：型号一律换成 AI 结果；品牌仅在原行没有品牌时补。
  CartItem _applyName(CartItem it, AiModelSuggestion? sug) {
    if (sug == null) return it;
    return CartItem(
      code: it.code,
      model: sug.model.isEmpty ? it.model : sug.model,
      category: it.category,
      package: it.package,
      brand: (it.brand?.isNotEmpty ?? false) ? it.brand : sug.brand,
      note: it.note,
      qty: it.qty,
    );
  }

  void _setMapping(CartColumnMapping m) {
    setState(() {
      _mapping = m;
      _report = null; // 映射调整后旧报告作废
      _skipReasons = null;
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
      appBar: AppBar(title: const Text('立创购物车导入')),
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
            Icon(Icons.shopping_cart_outlined,
                size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              '选择立创购物车导出文件（CSV / XLSX）\n自动识别表头，同 C 号自动合并数量入库',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('选择购物车文件'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor() {
    final rows = _rows!;
    final parsed = _parsed;
    final report = _report;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(_fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
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
                _mappingDropdown('编号列（C 号）', _mapping.codeCol,
                    (v) => _setMapping(CartColumnMapping(
                          codeCol: v,
                          modelCol: _mapping.modelCol,
                          qtyCol: _mapping.qtyCol,
                          categoryCol: _mapping.categoryCol,
                          packageCol: _mapping.packageCol,
                          brandCol: _mapping.brandCol,
                          nameCol: _mapping.nameCol,
                          priceCol: _mapping.priceCol,
                        ))),
                _mappingDropdown('型号列（可空，回退名称）', _mapping.modelCol,
                    (v) => _setMapping(CartColumnMapping(
                          codeCol: _mapping.codeCol,
                          modelCol: v,
                          qtyCol: _mapping.qtyCol,
                          categoryCol: _mapping.categoryCol,
                          packageCol: _mapping.packageCol,
                          brandCol: _mapping.brandCol,
                          nameCol: _mapping.nameCol,
                          priceCol: _mapping.priceCol,
                        ))),
                _mappingDropdown('数量列', _mapping.qtyCol,
                    (v) => _setMapping(CartColumnMapping(
                          codeCol: _mapping.codeCol,
                          modelCol: _mapping.modelCol,
                          qtyCol: v,
                          categoryCol: _mapping.categoryCol,
                          packageCol: _mapping.packageCol,
                          brandCol: _mapping.brandCol,
                          nameCol: _mapping.nameCol,
                          priceCol: _mapping.priceCol,
                        ))),
                _mappingDropdown('分类列（可选）', _mapping.categoryCol,
                    (v) => _setMapping(CartColumnMapping(
                          codeCol: _mapping.codeCol,
                          modelCol: _mapping.modelCol,
                          qtyCol: _mapping.qtyCol,
                          categoryCol: v,
                          packageCol: _mapping.packageCol,
                          brandCol: _mapping.brandCol,
                          nameCol: _mapping.nameCol,
                          priceCol: _mapping.priceCol,
                        ))),
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
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              parsed == null
                  ? '请先在「列映射」中选择编号列与数量列'
                  : '有效 ${parsed.items.length} 行待入库（同 C 号已合并数量）'
                      '${parsed.skipped > 0 ? '；跳过 ${parsed.skipped} 行' : ''}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // AI 自动规范命名：入库前把整表名称一次 AI 调用规范成厂商型号（AI1）。
        SwitchListTile(
          key: const ValueKey('ai_name_switch'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _aiName,
          onChanged: (v) => setState(() => _aiName = v),
          title: const Text('AI 自动规范命名', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '把购物车名称整表交给 AI 规范成标准厂商型号并补品牌（仅全新入库行生效）',
            style: TextStyle(fontSize: 12),
          ),
        ),
        FilledButton.icon(
          onPressed: (parsed == null || parsed.isEmpty) ? null : _import,
          icon: const Icon(Icons.inventory_2_outlined),
          label: Text(parsed == null || parsed.isEmpty
              ? '导入库存'
              : '导入库存（${parsed.items.length} 项）'),
        ),
        if (report != null) ...[
          const SizedBox(height: 12),
          _buildReport(report),
        ],
        if (_skipReasons != null && _skipReasons!.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildSkipReasons(_skipReasons!),
        ],
        const SizedBox(height: 8),
        Text(
          '注：已存在的元件仅累加数量并自动恢复回收站记录，不覆盖已维护的型号与分类。',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _mappingDropdown(
      String label, int value, ValueChanged<int> onChanged) {
    final items = <DropdownMenuItem<int>>[
      const DropdownMenuItem(value: -1, child: Text('（不识别）')),
      for (var i = 0; i < _columnCount; i++)
        DropdownMenuItem(value: i, child: _columnItem(i)),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<int>(
        initialValue: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: items,
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _columnItem(int i) {
    final label = (i < _header.length && _header[i].trim().isNotEmpty)
        ? '${_header[i].trim()}（第${i + 1}列）'
        : '第${i + 1}列';
    return Text(label, overflow: TextOverflow.ellipsis);
  }

  Widget _buildPreview(List<List<String>> rows) {
    final dataRows = rows.length > 1
        ? rows.sublist(1, 1 + (rows.length - 1).clamp(0, 5))
        : <List<String>>[];
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

  Widget _buildReport(CartImportReport report) {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle_outline, color: Colors.green.shade800),
                const SizedBox(width: 8),
                Text('入库完成',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.green.shade800)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '新增 ${report.inserted} 项 · 累加 ${report.merged} 项 · 恢复 ${report.restored} 项'
              '${report.touched < report.total ? ' · 跳过 ${report.total - report.touched} 项' : ''}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text('本次请求 ${report.total} 项',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _buildSkipReasons(List<String> reasons) {
    final shown = reasons.length <= 8 ? reasons : reasons.sublist(0, 8);
    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('跳过 ${reasons.length} 行',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.orange.shade900)),
            const SizedBox(height: 4),
            for (final r in shown)
              Text(r, style: Theme.of(context).textTheme.bodySmall),
            if (reasons.length > shown.length)
              Text('… 其余 ${reasons.length - shown.length} 行略',
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
