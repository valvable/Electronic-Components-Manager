import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/services/component_repository.dart';
import '../main.dart';
import '../models/component.dart';
import '../widgets/quantity_badge.dart';
import 'add_component_dialog.dart';

/// 元件详情页：全字段展示 + 操作（编辑 / 恢复 / 彻底删除）+ AI 查询占位。
///
/// - 编辑走 [showAddComponentDialog]（复用同一表单）。
/// - 彻底删除前 [ComponentRepository.purge] 会检查 BOM 引用并抛
///   [ComponentDeletionException]（RESTRICT 双保险），此处捕获后提示。
/// - 返回 [bool]？：true 表示发生过变更，列表页应重新加载。
class DetailScreen extends StatefulWidget {
  final AppState state;
  final Component component;

  const DetailScreen({super.key, required this.state, required this.component});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late Component _c = widget.component;
  bool _busy = false;

  ComponentRepository get _repo => widget.state.components;

  /// 全字段时间格式化：YYYY-MM-DD HH:MM。
  static String _fmtFull(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${p2(dt.month)}-${p2(dt.day)} ${p2(dt.hour)}:${p2(dt.minute)}';
  }

  Future<void> _edit() async {
    final updated = await showAddComponentDialog(
      context,
      repo: _repo,
      existing: _c,
    );
    if (updated == null || !mounted) return;
    setState(() => _c = updated);
    Navigator.pop(context, true);
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      await _repo.restore(_c.id!);
      if (!mounted) return;
      final fresh = await _repo.byCid(_c.cid);
      if (!mounted) return;
      setState(() {
        _c = fresh.component ?? _c.copyWith(clearDeleted: true);
        _busy = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purge() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text(
          _c.hasLcscCid
              ? '将永久删除「${_c.model}」（CID ${_c.cid}），不可恢复。\n\n若该元件被 BOM 引用，会被拒绝并提示先解除引用。'
              : '将永久删除「${_c.model}」（无 C 号元件），不可恢复。\n\n若该元件被 BOM 引用，会被拒绝并提示先解除引用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _repo.purge(_c.id!);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已彻底删除')));
      Navigator.pop(context, true);
    } on ComponentDeletionException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyCid() async {
    await Clipboard.setData(ClipboardData(text: _c.cid));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('CID ${_c.cid} 已复制')));
  }

  /// 无 C 号元件入口：合并到真实 C 号元件 / 直接绑定已知 C 号。
  /// 合并成功（源条目进回收站）或绑定成功 → 关闭详情让列表刷新。
  Future<void> _openMerge() async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _MergeSheet(repo: _repo, source: _c),
    );
    if (!mounted || done != true) return;
    Navigator.pop(context, true);
  }

  void _aiQuery() {
    // 详情页的元件资料深度查询未接入（范围控制）；引导到已有的两处 AI 能力。
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('AI 元件资料查询暂未开放；添加元件可用 AI 分析分类、BOM 结果可用 AI 替代推荐')));
  }

  Widget _field(
    String label,
    String value, {
    IconData? icon,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          ?trailing,
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, child: content);
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final theme = Theme.of(context);
    final deleted = c.isDeleted;
    final note = c.note;

    return Scaffold(
      appBar: AppBar(
        title: const Text('元件详情'),
        actions: [
          if (deleted)
            IconButton(
              tooltip: '恢复',
              icon: const Icon(Icons.restore_outlined),
              onPressed: _busy ? null : _restore,
            )
          else
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _busy ? null : _edit,
            ),
          IconButton(
            tooltip: '彻底删除',
            icon: const Icon(Icons.delete_forever_outlined),
            onPressed: _busy ? null : _purge,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- 头部：分类首字头像 + 型号 + 状态角标 ----
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  c.categoryOrEmpty.isEmpty ? '?' : c.categoryOrEmpty[0],
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.model,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        QuantityBadge(quantity: c.quantity),
                        if (deleted)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '已删除',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 32),

          // ---- 全字段 ----
          // 无 C 号元件不显示内部编号、不给复制（isNoCidEntry：cid 存内部编号）。
          if (c.hasLcscCid)
            _field('CID', c.cid,
                icon: Icons.qr_code_2,
                onTap: _copyCid,
                trailing: Icon(Icons.copy, size: 16, color: theme.colorScheme.primary))
          else
            _field('CID', '无 C 号（内部编号）', icon: Icons.qr_code_2),
          _field('分类', c.categoryOrEmpty.isEmpty ? '未设置' : c.categoryOrEmpty,
              icon: Icons.category_outlined),
          _field('封装', (c.package == null || c.package!.isEmpty) ? '未设置' : c.package!,
              icon: Icons.straighten),
          _field('品牌', (c.brand == null || c.brand!.isEmpty) ? '未设置' : c.brand!,
              icon: Icons.factory_outlined),
          _field('位置', (c.location == null || c.location!.isEmpty) ? '未设置' : c.location!,
              icon: Icons.place_outlined),
          _field('创建时间', _fmtFull(c.createdAt), icon: Icons.schedule),
          _field('更新时间', _fmtFull(c.updatedAt), icon: Icons.update),
          if (deleted && c.deletedAt != null)
            _field('删除时间', _fmtFull(c.deletedAt!), icon: Icons.delete_outline),
          if (note != null && note.isNotEmpty)
            _field('备注', note, icon: Icons.notes),

          // ---- 无 C 号元件：合并到真实 C 号（全程人工） ----
          if (c.isNoCidEntry && !deleted) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const ValueKey('merge_to_real_btn'),
              onPressed: _busy ? null : _openMerge,
              icon: const Icon(Icons.merge),
              label: const Text('合并到真实 C 号元件'),
            ),
            const SizedBox(height: 4),
            Text(
              '散料没有 C 号时：搜索真实 C 号并入数量（本条目进回收站），'
              '或把已知 C 号绑定为本元件正式编号。',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],

          const SizedBox(height: 16),

          // ---- AI 元件资料查询（预留：见 _aiQuery 提示引导） ----
          OutlinedButton.icon(
            onPressed: _aiQuery,
            icon: const Icon(Icons.smart_toy_outlined),
            label: const Text('AI 查询'),
          ),
        ],
      ),
    );
  }
}

extension on Component {
  /// 展示用：分类为空时返回空串（区别于默认「其他」）。
  String get categoryOrEmpty => category;
}

/// 详情页「合并到真实 C 号元件」底部弹窗。
///
/// - 顶部搜索框：搜 C 号 / 型号，候选 = 活动 + 真实 C 号 + 非自身；
///   随输入防抖刷新。
/// - 点候选 → 确认后 [ComponentRepository.mergeToReal]：目标数量相加、
///   本条目软删进回收站（墓碑随局域网同步传播）。
/// - 搜索无结果且输入恰为合法 C 号时，提供「绑定该 C 号」备选
///   （[ComponentRepository.attachRealCid]，库存尚无该料时的认领路径）。
class _MergeSheet extends StatefulWidget {
  final ComponentRepository repo;
  final Component source;

  const _MergeSheet({required this.repo, required this.source});

  @override
  State<_MergeSheet> createState() => _MergeSheetState();
}

class _MergeSheetState extends State<_MergeSheet> {
  final TextEditingController _ctrl = TextEditingController();
  Timer? _debounce;
  List<Component> _candidates = const [];
  bool _busy = false;

  Component get _src => widget.source;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _search);
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) {
      setState(() => _candidates = const []);
      return;
    }
    final list = await widget.repo.search(q);
    if (!mounted) return;
    setState(() {
      _candidates = list
          .where((c) => c.hasLcscCid && !c.isDeleted && c.cid != _src.cid)
          .toList();
    });
  }

  bool get _validCode => RegExp(r'^C\d{5,}$').hasMatch(_ctrl.text.trim());

  bool get _queried => _ctrl.text.trim().isNotEmpty;

  bool get _hasResults => _candidates.isNotEmpty;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _merge(Component target) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('并入真实 C 号'),
        content: Text(
          '把「${_src.model}」的数量 ${_src.quantity} '
          '并入「${target.model}」（CID ${target.cid}）？\n\n'
          '并入后目标数量 ${target.quantity + _src.quantity}，'
          '本条目移入回收站（可恢复）。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            key: const ValueKey('merge_confirm_btn'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('并入'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.repo.mergeToReal(
        sourceCid: _src.cid,
        targetCid: target.cid,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context, true);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text(
            '已将「${_src.model}」${_src.quantity} 并入「${target.model}」，源条目进回收站'),
      ));
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.message);
    }
  }

  Future<void> _attach(String code) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('绑定 C 号'),
        content: Text(
          '库存中还没有 $code 这条料。\n\n'
          '把「${_src.model}」的正式编号设为 $code ？\n'
          '（数量不变，仍是一条记录）',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            key: const ValueKey('attach_cid_btn'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('绑定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.repo.attachRealCid(_src.cid, code);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context, true);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
          SnackBar(content: Text('已将「${_src.model}」绑定为 $code')));
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: SizedBox(
        height: mq.size.height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Text('并入真实 C 号', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _ctrl,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        labelText: '搜索真实 C 号 / 型号',
                        hintText: '如 C25704 或电阻型号',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '正在把「${_src.model}」（数量 ${_src.quantity}）并入库存里已有真实 C 号的元件；'
                      '并入后本条目移入回收站。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (!_queried)
                      Text(
                        '输入 C 号或型号搜索已有元件。',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      )
                    else if (_hasResults)
                      for (final target in _candidates)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.memory, size: 20),
                          title: Text(
                            target.model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('CID ${target.cid} · 数量 ${target.quantity}'),
                          trailing: Text(target.categoryOrOther,
                              style: theme.textTheme.labelSmall),
                          onTap: _busy ? null : () => _merge(target),
                        )
                    else if (_validCode)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.badge_outlined, size: 20),
                        title: Text('把 C 号 $_query 绑定为正式编号',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: const Text('库存尚无该料时使用（认领本件）'),
                        trailing: Icon(Icons.chevron_right,
                            color: theme.colorScheme.primary),
                        onTap: _busy ? null : () => _attach(_query),
                      )
                    else
                      Text(
                        '没有搜到匹配的元件。确认 C 号无误后，'
                        '可把真实 C 号直接绑定为本元件正式编号。',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _query => _ctrl.text.trim();
}
