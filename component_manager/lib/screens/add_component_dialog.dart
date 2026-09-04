import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database/database_helper.dart';
import '../models/component.dart';
import '../utils/category_recognizer.dart';

/// 手动添加 / 编辑元件的对话框。
///
/// - 新增模式：型号自动识别分类（用户可手动覆盖）；保存时若 CID 已存在，
///   弹窗询问「合并数量 / 新增记录 / 取消」。
/// - 编辑模式：字段预填，不再自动改分类，保存后更新 updated_at。
class AddComponentDialog extends StatefulWidget {
  final Component? initial; // 非空表示编辑模式

  const AddComponentDialog({super.key, this.initial});

  /// 便捷调用：返回 true 表示已成功写入数据库（调用方据此刷新列表）。
  static Future<bool?> show(BuildContext context, {Component? initial}) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AddComponentDialog(initial: initial),
    );
  }

  @override
  State<AddComponentDialog> createState() => _AddComponentDialogState();
}

class _AddComponentDialogState extends State<AddComponentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _modelCtrl = TextEditingController();
  final _cidCtrl = TextEditingController();
  final _packageCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  String _category = AppCategories.other;
  bool _categoryManuallySet = false; // 用户手动选过分类后，不再自动识别覆盖
  bool _saving = false;

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      // 编辑模式：预填全部字段
      _modelCtrl.text = initial.model;
      _cidCtrl.text = initial.cid;
      _packageCtrl.text = initial.package ?? '';
      _qtyCtrl.text = '${initial.quantity}';
      _locationCtrl.text = initial.location ?? '';
      _noteCtrl.text = initial.note ?? '';
      _category = initial.category;
      _categoryManuallySet = true;
    } else {
      _qtyCtrl.text = '1'; // 数量默认 1
    }
  }

  @override
  void dispose() {
    for (final c in [
      _modelCtrl,
      _cidCtrl,
      _packageCtrl,
      _qtyCtrl,
      _locationCtrl,
      _noteCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 根据型号实时自动识别分类（用户未手动选择时生效）。
  void _onModelChanged(String value) {
    if (_categoryManuallySet) return;
    final recognized = CategoryRecognizer.recognize(value);
    // 识别结果为「其他」时不覆盖当前选择，避免输入过程中闪烁
    if (recognized != AppCategories.other && recognized != _category) {
      setState(() => _category = recognized);
    }
  }

  // ================ 保存逻辑 ================

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // 在异步操作前捕获 navigator/messenger，避免跨异步使用 context
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final model = _modelCtrl.text.trim();
    final cid = _cidCtrl.text.trim().toUpperCase();
    final quantity = int.tryParse(_qtyCtrl.text.trim()) ?? 1;
    final now = DateTime.now().toIso8601String();

    setState(() => _saving = true);

    try {
      final existing = await DatabaseHelper.instance.findByCid(cid);

      // 新增模式下 CID 已存在：询问 合并 / 新增 / 取消
      if (!_isEdit && existing != null) {
        final choice = await _askDuplicateAction(existing, quantity);
        if (choice == 'merge') {
          await DatabaseHelper.instance
              .increaseQuantity(existing.id!, quantity);
          messenger.showSnackBar(SnackBar(
            content: Text(
                '已合并：${existing.model} 库存 ${existing.quantity} → ${existing.quantity + quantity}'),
            behavior: SnackBarBehavior.floating,
          ));
          navigator.pop(true);
          return;
        }
        if (choice != 'new') {
          // 用户取消
          if (mounted) setState(() => _saving = false);
          return;
        }
        // choice == 'new'：继续往下走普通新增逻辑
      }

      if (_isEdit) {
        final updated = widget.initial!.copyWith(
          cid: cid,
          model: model,
          category: _category,
          package: _packageCtrl.text.trim(),
          quantity: quantity,
          location: _locationCtrl.text.trim(),
          note: _noteCtrl.text.trim(),
          updatedAt: now,
        );
        await DatabaseHelper.instance.updateComponent(updated);
      } else {
        final component = Component(
          cid: cid,
          model: model,
          category: _category,
          package: _packageCtrl.text.trim(),
          quantity: quantity,
          location: _locationCtrl.text.trim(),
          note: _noteCtrl.text.trim(),
          createdAt: now,
          updatedAt: now,
        );
        await DatabaseHelper.instance.insertComponent(component);
      }

      messenger.showSnackBar(SnackBar(
        content: Text(_isEdit ? '已保存修改' : '已添加：$model ×$quantity'),
        behavior: SnackBarBehavior.floating,
      ));
      navigator.pop(true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('保存失败：$e'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFFD32F2F),
      ));
      if (mounted) setState(() => _saving = false);
    }
  }

  /// CID 重复时的选择弹窗：合并数量 / 新增记录 / 取消。
  Future<String?> _askDuplicateAction(Component existing, int addQuantity) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('该 CID 已存在'),
        content: Text(
          '库存中已有「${existing.model}」\n'
          '（CID: ${existing.cid}，当前数量 ${existing.quantity}）\n\n'
          '· 合并：数量累加（+ $addQuantity）\n'
          '· 新增：另存为一条新记录（可放不同位置）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'new'),
            child: const Text('新增记录'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'merge'),
            child: const Text('合并数量'),
          ),
        ],
      ),
    );
  }

  DateTime _parseDate(String iso) {
    return DateTime.tryParse(iso) ?? DateTime.now();
  }

  // ================ UI ================

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '编辑元件' : '手动添加元件'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _modelCtrl,
                  onChanged: _onModelChanged,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: '型号 *',
                    hintText: '如 STM32F103C8T6 / 0805电阻',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请输入型号' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _cidCtrl,
                  decoration: const InputDecoration(
                    labelText: 'CID（立创料号）*',
                    hintText: '如 C25704',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请输入 CID' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _category,
                  decoration: const InputDecoration(
                    labelText: '分类',
                    helperText: '可根据型号自动识别，也可手动修改',
                  ),
                  items: AppCategories.all
                      .map((c) =>
                          DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _category = v;
                      _categoryManuallySet = true;
                    });
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _packageCtrl,
                        decoration: const InputDecoration(
                          labelText: '封装',
                          hintText: '如 0805 / SOP-8',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _qtyCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '数量'),
                        validator: (v) {
                          final n = int.tryParse(v?.trim() ?? '');
                          if (n == null || n < 0) return '无效数量';
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _locationCtrl,
                  decoration: const InputDecoration(
                    labelText: '位置',
                    hintText: '如 元件柜 A-3',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _noteCtrl,
                  decoration: const InputDecoration(labelText: '备注'),
                  minLines: 2,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                ),
                if (_isEdit && widget.initial!.createdAt.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '录入时间：${DateFormat('yyyy-MM-dd HH:mm').format(_parseDate(widget.initial!.createdAt))}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined, size: 18),
          label: Text(_saving ? '保存中...' : '保存'),
        ),
      ],
    );
  }
}
