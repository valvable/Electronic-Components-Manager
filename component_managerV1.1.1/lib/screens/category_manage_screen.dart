import 'package:flutter/material.dart';

import '../core/config/constants.dart';
import '../core/services/component_repository.dart';
import '../core/services/settings_store.dart';
import '../main.dart';

/// 自创分类管理页（独立页，分类卡片页右上角进入）。
///
/// - 自创分类：可新建 / 改名 / 删除。改名会把在用元件（deleted_at IS NULL）
///   的活动行同步改过去（[ComponentRepository.renameCategory]，不碰软删墓碑）。
/// - 删除：仍被元件使用的自创分类 → 禁止并提示；无在用才从设置库移除。
/// - 系统分类（29，内置）：只读折叠展示 + 在用件数。
class CategoryManageScreen extends StatefulWidget {
  final AppState state;

  const CategoryManageScreen({super.key, required this.state});

  @override
  State<CategoryManageScreen> createState() => _CategoryManageScreenState();
}

class _CategoryManageScreenState extends State<CategoryManageScreen> {
  Map<String, int> _counts = const {};
  List<String> _customs = const [];
  bool _loading = true;

  ComponentRepository get _repo => widget.state.components;
  SettingsStore get _settings => widget.state.settings;

  /// 重名校验的范围：系统 29 类 + 现有自创（改名时排除自身）。
  Set<String> get _reservedNames => {...inventoryCategories, ..._customs};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final counts = await _repo.countByCategory();
      final customs = await _settings.loadCustomCategories();
      if (!mounted) return;
      setState(() {
        _counts = counts;
        _customs = customs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载失败: $e')));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- 新建 / 改名 / 删除 ----

  Future<void> _create() async {
    final name = await _promptName(title: '新建分类', reserved: _reservedNames);
    if (name == null || !mounted) return;
    if (_reservedNames.contains(name)) {
      _toast('分类「$name」已存在');
      return;
    }
    await _settings.saveCustomCategories([..._customs, name]);
    if (!mounted) return;
    _toast('已新建自创分类「$name」');
    await _load();
  }

  Future<void> _rename(String oldName) async {
    final reserved = _reservedNames..remove(oldName);
    final name = await _promptName(
      title: '重命名分类',
      initial: oldName,
      reserved: reserved,
    );
    if (name == null || name == oldName || !mounted) return;
    if (reserved.contains(name)) {
      _toast('分类「$name」已存在');
      return;
    }
    await _settings
        .saveCustomCategories([for (final n in _customs) n == oldName ? name : n]);
    await _repo.renameCategory(oldName, name); // 在用元件行同步改名
    if (!mounted) return;
    _toast('已改名为「$name」（${_counts[oldName] ?? 0} 个元件已同步）');
    await _load();
  }

  Future<void> _delete(String name) async {
    final inUse = _counts[name] ?? 0;
    if (inUse > 0) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('无法删除'),
          content: Text('仍有 $inUse 个元件使用「$name」，请先把它们改到其它分类再删除。'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('确定删除自创分类「$name」吗？（无元件使用它）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _settings
        .saveCustomCategories([for (final n in _customs) if (n != name) n]);
    if (!mounted) return;
    _toast('已删除分类「$name」');
    await _load();
  }

  /// 弹出新建/改名输入框。校验：非空、≤20 字、不与 [reserved] 重名。
  /// 取消返回 null；非法输入在当前弹窗内即时红字提示。
  Future<String?> _promptName({
    required String title,
    required Set<String> reserved,
    String initial = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => _NameDialog(
        title: title,
        initial: initial,
        reserved: reserved,
      ),
    );
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('分类管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _buildCustomSection(context),
                const SizedBox(height: 12),
                _buildSystemSection(context),
              ],
            ),
    );
  }

  Widget _buildCustomSection(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Text('自创分类', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text('${_customs.length} 个',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const Spacer(),
                TextButton.icon(
                  key: const ValueKey('create_category_btn'),
                  onPressed: _create,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建分类'),
                ),
              ],
            ),
          ),
          if (_customs.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                '还没有自创分类。散料细分（如「钽电容」「Type-C 公头」）可从添加 / 扫码的 AI 或这里新建。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          else
            for (final name in _customs)
              ListTile(
                dense: true,
                leading: const Icon(Icons.label_outline),
                title: Text(name),
                subtitle: Text('${_counts[name] ?? 0} 个元件'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '改名',
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () => _rename(name),
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      color: theme.colorScheme.error,
                      onPressed: () => _delete(name),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildSystemSection(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: const Text('系统分类（内置，只读）'),
        subtitle: Text('${inventoryCategories.length} 个基础分类，不可改名或删除',
            style: theme.textTheme.bodySmall),
        leading: const Icon(Icons.category_outlined),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final name in inventoryCategories)
                  Chip(
                    label: Text('$name ${_counts[name] ?? 0}'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 新建/改名输入弹窗：返回 trim 后的合法名，取消返回 null。
class _NameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final Set<String> reserved;

  const _NameDialog({
    required this.title,
    required this.initial,
    required this.reserved,
  });

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _ctrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入分类名');
      return;
    }
    if (name.length > 20) {
      setState(() => _error = '分类名最长 20 字');
      return;
    }
    if (widget.reserved.contains(name)) {
      setState(() => _error = '「$name」已存在（系统分类或已有自创）');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 20,
        decoration: InputDecoration(
          labelText: '分类名',
          hintText: '如 钽电容 / Type-C 公头',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}
