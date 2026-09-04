import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/config/constants.dart';
import '../core/services/ai_client.dart';
import '../core/services/component_repository.dart';
import '../core/services/lcsc_lookup.dart';
import '../core/services/settings_store.dart';
import '../core/utils/category_options.dart';
import '../core/utils/classifier.dart';
import '../models/component.dart';

/// 弹出全屏底部弹窗，添加 / 编辑元件。
/// 返回保存后的 [Component]；取消返回 null。
/// [prefillModel]：扫码只识别到型号、未识别 CID 时，预填型号输入框。
/// [lcscLookup]：C 号查料实现（默认真网络；测试注入假实现）。
/// [aiClassifyLookup]：AI 分类分析实现（默认从设置读配置走真接口；测试注入假实现）。
/// [aiNameLookup]：AI 自动命名实现（规范型号；测试注入假实现）。
Future<Component?> showAddComponentDialog(
  BuildContext context, {
  required ComponentRepository repo,
  Component? existing,
  String? prefillModel,
  Future<LcscPartInfo?> Function(String code)? lcscLookup,
  AiClassifyLookup? aiClassifyLookup,
  AiNameLookup? aiNameLookup,
}) async {
  final result = await showModalBottomSheet<Component>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => AddComponentDialog(
      repo: repo,
      existing: existing,
      prefillModel: prefillModel,
      lcscLookup: lcscLookup,
      aiClassifyLookup: aiClassifyLookup,
      aiNameLookup: aiNameLookup,
    ),
  );
  return result;
}

/// 手动添加 / 编辑元件表单。
/// - 型号必填；CID 可空（新增模式留空 = 无 C 号元件，系统生成内部隐藏编号，
///   界面不显示该编号）。非空才按 C+数字 校验并在输入时防抖查重，内联提示
///   「已存在 / 已在回收站 / 可用」。编辑无 C 号元件时不渲染 CID 框，避免暴露编号。
/// - 型号变更且用户未手动改过分类时，自动按 [classify] 预选分类。
/// - 新增模式输入合法 C 号（C+数字）后，出现「从立创查料自动填充」按钮：
///   查国际站自动填型号/分类/封装/备注；失败提示且不动已有输入。
/// - 型号非空时出现「AI 查询」按钮（新增与编辑都有）：用 AI 修正分类，
///   封装/备注空槽才填；不回填模型/CID。AI 给出的分类不在 系统29+自创 清单时，
///   弹窗确认后创建为自创分类并采用（取消则按型号兜底，不污染分类表）。
/// - 分类下拉选项 = 系统 29 类 + 自创分类（[loadCategoryOptions]）。
/// - 数量：滑块（1~1000）+ 数字输入双路联动（默认 1）。保存成功轻震一下。
class AddComponentDialog extends StatefulWidget {
  final ComponentRepository repo;
  final Component? existing;
  final String? prefillModel;
  final Future<LcscPartInfo?> Function(String code)? lcscLookup;
  final AiClassifyLookup? aiClassifyLookup;
  final AiNameLookup? aiNameLookup;

  const AddComponentDialog({
    super.key,
    required this.repo,
    this.existing,
    this.prefillModel,
    this.lcscLookup,
    this.aiClassifyLookup,
    this.aiNameLookup,
  });

  @override
  State<AddComponentDialog> createState() => _AddComponentDialogState();
}

class _AddComponentDialogState extends State<AddComponentDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _modelCtrl;
  late final TextEditingController _cidCtrl;
  late final TextEditingController _packageCtrl;
  late final TextEditingController _brandCtrl; // 品牌（v4，可空）
  late final TextEditingController _locationCtrl;
  late final TextEditingController _noteCtrl;
  late final TextEditingController _qtyCtrl; // 数量直接输入

  late String _category;
  late int _quantity;
  bool _categoryTouched = false;
  bool _saving = false;

  /// 分类下拉选项：系统 29 类 + 用户自创（initState 异步加载，见 [_loadCategoryOptions]）。
  List<String> _categoryOptions = inventoryCategories;
  late final SettingsStore _store = SettingsStore(widget.repo.db);

  /// 数量滑块上限（>1000 用右侧输入框精确填）。
  static const int _qtyMax = 1000;

  // CID 三态提示
  String? _cidHint;
  bool _cidBusy = false;

  // 立创 C 号查料
  bool _lookupBusy = false;

  // AI 分类分析
  bool _aiBusy = false;
  // AI 自动命名（规范型号）
  bool _namingBusy = false;

  Component? get _existing => widget.existing;
  bool get _isEdit => _existing != null;

  Future<LcscPartInfo?> _lookup(String code) =>
      widget.lcscLookup?.call(code) ?? lookupLcsc(code);

  /// AI 自动命名：注入实现优先，否则走 AI1（基础接口——命名不属于替换任务）。
  Future<AiModelSuggestion?> _aiName(String raw, String? cid) =>
      widget.aiNameLookup?.call(raw, cid) ??
      aiNameFromSettings(_store, rawModel: raw, cid: cid);

  /// 「AI 命名」按钮：把当前型号/名称规范成厂商标准型号（空槽才填品牌）。
  Future<void> _aiRename() async {
    final raw = _modelCtrl.text.trim();
    final rawCid = _cidCtrl.text.trim();
    final cid = (!_isEdit && RegExp(r'^C\d{5,}$').hasMatch(rawCid)) ? rawCid : null;
    if (raw.isEmpty && cid == null) return;
    setState(() => _namingBusy = true);
    AiModelSuggestion? sug;
    try {
      sug = await _aiName(raw.isNotEmpty ? raw : cid!, cid);
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() => _namingBusy = false);
      _toast('AI 命名失败：${friendlyAiError(e)}');
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _namingBusy = false);
      _toast('AI 命名失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _namingBusy = false);
    final s = sug;
    if (s == null) {
      _toast('AI 没给出规范型号');
      return;
    }
    if (s.model == raw) {
      _toast('AI：「$raw」已是规范型号');
    } else {
      setState(() => _modelCtrl.text = s.model);
    }
    if (_brandCtrl.text.trim().isEmpty && s.brand != null) {
      _brandCtrl.text = s.brand!;
    }
    if (s.model != raw) _toast('已按 AI 规范命名：${s.model}');
  }

  /// AI 分类分析：注入实现优先；否则现场从设置取配置走真接口
  /// （repo 的 db 是公开字段，dialog 不持有 AppState 也能构造 SettingsStore）。
  /// allowed 清单用「系统 29 + 自创」而非写死 29 类。
  Future<AiClassifySuggestion?> _aiLookup(String model, String? cid) =>
      widget.aiClassifyLookup?.call(model, cid) ??
      aiClassifyFromSettings(
        _store,
        model: model,
        cid: cid,
        categories: _categoryOptions,
      );

  @override
  void initState() {
    super.initState();
    final e = _existing;
    _modelCtrl =
        TextEditingController(text: e?.model ?? widget.prefillModel ?? '');
    _cidCtrl = TextEditingController(text: e?.cid ?? '');
    _packageCtrl = TextEditingController(text: e?.package ?? '');
    _brandCtrl = TextEditingController(text: e?.brand ?? '');
    _locationCtrl = TextEditingController(text: e?.location ?? '');
    _noteCtrl = TextEditingController(text: e?.note ?? '');
    _category = e?.categoryOrOther ?? defaultCategory;
    _quantity = (e?.quantity ?? defaultQuantity).clamp(1, 1 << 30);
    _qtyCtrl = TextEditingController(text: '$_quantity');

    _cidCtrl.addListener(_onCidChanged);
    _modelCtrl.addListener(_onModelChanged);
    _loadCategoryOptions();
  }

  /// 加载「系统 29 + 自创」到下拉与 AI 清单（异步入，失败回退系统 29 类）。
  Future<void> _loadCategoryOptions() async {
    try {
      final options = await loadCategoryOptions(_store);
      if (!mounted) return;
      setState(() => _categoryOptions = options);
    } catch (_) {
      // 设置表读失败不回退界面，仅保留系统 29 类。
    }
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _cidCtrl.dispose();
    _packageCtrl.dispose();
    _brandCtrl.dispose();
    _locationCtrl.dispose();
    _noteCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  // 编辑时 CID 不可改（唯一键），无需重复检查。
  void _onCidChanged() {
    if (_isEdit) return;
    final cid = _cidCtrl.text.trim();
    if (cid.isEmpty) {
      setState(() => _cidHint = null);
      return;
    }
    widget.repo.byCid(cid).then((lookup) {
      if (!mounted) return;
      setState(() {
        _cidBusy = false;
        _cidHint = switch (lookup.status) {
          LookupStatus.active => '已存在（数量 ${lookup.component!.quantity}），保存将提示重复',
          LookupStatus.deleted => '该 CID 已在回收站，保存将恢复',
          LookupStatus.notFound => '可用',
        };
      });
    });
  }

  void _onModelChanged() {
    if (_categoryTouched) return;
    final model = _modelCtrl.text.trim();
    if (model.isEmpty) return;
    final auto = classify(model);
    setState(() => _category = auto);
  }

  /// 数量统一入口：夹到 ≥1 并同步输入框文本（滑块/输入两路共用）。
  void _setQuantity(int v) {
    final clamped = v < 1 ? 1 : v;
    setState(() {
      _quantity = clamped;
      _qtyCtrl.text = '$clamped';
    });
  }

  /// 输入框实时解析：输入中途留空/非法不打断，提交时兜底回填当前值。
  void _onQtyTyped(String text) {
    final n = int.tryParse(text);
    if (n == null || n < 1) return;
    if (_quantity == n) return;
    setState(() => _quantity = n);
  }

  /// 保存成功统一收尾：轻震一下（入库成功反馈）后带结果关闭弹窗。
  void _popSaved(Component c) {
    unawaited(HapticFeedback.lightImpact());
    Navigator.pop(context, c);
  }

  /// 收集当前表单为「新元件」字段集（不含 id/时间戳）。
  Component _buildFresh({required String cid}) {
    return Component(
      cid: cid,
      model: _modelCtrl.text.trim(),
      category: _category,
      package: _packageCtrl.text.trim().isEmpty ? null : _packageCtrl.text.trim(),
      brand: _brandCtrl.text.trim().isEmpty ? null : _brandCtrl.text.trim(),
      quantity: _quantity,
      location: _locationCtrl.text.trim().isEmpty ? null : _locationCtrl.text.trim(),
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      createdAt: Component.now(),
      updatedAt: Component.now(),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final model = _modelCtrl.text.trim();
    final cid = _cidCtrl.text.trim();
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        final e = _existing!;
        final brandText = _brandCtrl.text.trim();
        final updated = e.copyWith(
          model: model,
          category: _category,
          package: _packageCtrl.text.trim().isEmpty
              ? null
              : _packageCtrl.text.trim(),
          brand: brandText.isEmpty ? null : brandText,
          clearBrand: brandText.isEmpty,
          quantity: _quantity,
          location: _locationCtrl.text.trim().isEmpty
              ? null
              : _locationCtrl.text.trim(),
          note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
          updatedAt: Component.now(),
        );
        await widget.repo.update(updated);
        if (!mounted) return;
        _popSaved(updated);
        return;
      }

      if (cid.isEmpty) {
        // 无 C 号手录：生成内部隐藏编号落库（界面不显示编号）。
        final freshCid = newInternalCid();
        final fresh = _buildFresh(cid: freshCid);
        await widget.repo.insert(fresh);
        if (!mounted) return;
        _popSaved(fresh);
        return;
      }

      // 新增（有 C 号）：先按 cid 查三态，区分「存在则累加提示 / 已删则恢复提示 / 可插入」
      final lookup = await widget.repo.byCid(cid);
      if (!mounted) return;
      if (lookup.status == LookupStatus.active) {
        setState(() => _saving = false);
        final add = await _confirmExisting(lookup.component!, isDeleted: false);
        if (add == true && mounted) {
          final c = await widget.repo.insertOrAddQty(cid, add: _quantity);
          if (!mounted) return;
          _popSaved(c);
        }
        return;
      }
      if (lookup.status == LookupStatus.deleted) {
        setState(() => _saving = false);
        final add = await _confirmExisting(lookup.component!, isDeleted: true);
        if (add == true && mounted) {
          final c = await widget.repo.insertOrAddQty(cid, add: _quantity);
          if (!mounted) return;
          _popSaved(c);
        }
        return;
      }

      // 不存在 → 直接插入（auto-classify 已在输入时预填分类）
      final fresh = _buildFresh(cid: cid);
      await widget.repo.insert(fresh);
      if (!mounted) return;
      _popSaved(fresh);
    } on ComponentDeletionException {
      // 不应出现；插入不涉及。
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  /// 已有同 CID 元件：询问是否增加数量（编辑弹窗内调用）。
  Future<bool?> _confirmExisting(Component c, {required bool isDeleted}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDeleted ? '该元件已在回收站' : '该元件已存在'),
        content: Text(
          isDeleted
              ? '「${c.model}」已软删除（数量 ${c.quantity}）。\n是否恢复并增加 $_quantity 个？'
              : '「${c.model}」当前数量 ${c.quantity}。\n是否增加 $_quantity 个？',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('增加数量'),
          ),
        ],
      ),
    );
  }

  /// 输入 C 号（如 C25704）→ 从立创国际站查料，自动填充型号/分类/封装/备注。
  /// 仅新增模式可用（编辑时 CID 锁定）。查询失败保持手动输入，不覆盖任何字段。
  Future<void> _autoFillFromLcsc() async {
    final code = normalizeLcscCode(_cidCtrl.text);
    if (!isLcscCode(code)) return;
    setState(() => _lookupBusy = true);
    LcscPartInfo? info;
    try {
      info = await _lookup(code);
    } catch (_) {
      info = null; // 注入实现可能抛异常，一律按查不到处理
    } finally {
      if (mounted) setState(() => _lookupBusy = false);
    }
    if (!mounted) return;
    if (info == null ||
        (info.productModel == null &&
            info.package == null &&
            info.description == null)) {
      _toast('没查到「$code」的数据（网络或页面变动），保持手动填写');
      return;
    }
    final part = info; // setState 闭包内无法类型提升，拷贝为确定非空
    setState(() {
      _categoryTouched = true; // 分类以查料结果为准，阻止型号监听覆盖
      if (part.productModel != null && part.productModel!.isNotEmpty) {
        _modelCtrl.text = part.productModel!;
      }
      _category = categoryFromLcsc(
        part.catalogName,
        hint: '${part.productModel ?? ''} ${part.description ?? ''}',
      );
      if (_packageCtrl.text.trim().isEmpty && part.package != null) {
        _packageCtrl.text = part.package!;
      }
      if (_brandCtrl.text.trim().isEmpty &&
          part.brandName != null &&
          part.brandName!.isNotEmpty) {
        _brandCtrl.text = part.brandName!;
      }
      if (_noteCtrl.text.trim().isEmpty && part.description != null) {
        _noteCtrl.text = part.description!;
      }
    });
    _toast('已填充 $code：${part.productModel ?? part.description}');
  }

  /// AI 分析型号 → 修正分类，封装/备注空槽才填。
  /// 竞态门：请求在途时用户改了分类下拉，则不覆盖用户的主动选择。
  ///
  /// 新分类处理（系统29+自创之外）：
  /// - 弹窗确认「创建为自创分类并使用」→ 写入设置 + 追加进下拉选项 + 采用；
  /// - 取消 → 不写库，按型号 classify 兜底（不污染分类表）。
  Future<void> _aiClassifyFill() async {
    final model = _modelCtrl.text.trim();
    final rawCid = _cidCtrl.text.trim();
    // 无 C 号元件的 cid 是内部隐藏编号，绝不发给 AI；仅传形如 C+数字 的真实料号。
    final cid = (rawCid.isEmpty ||
            (_isEdit && _existing!.isNoCidEntry) ||
            !RegExp(r'^C\d{5,}$').hasMatch(rawCid))
        ? null
        : rawCid;
    if (model.isEmpty && cid == null) return;
    final categorySnapshot = _category;
    setState(() => _aiBusy = true);
    AiClassifySuggestion? sug;
    try {
      sug = await _aiLookup(
        model.isNotEmpty ? model : cid!,
        cid,
      );
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() => _aiBusy = false);
      _toast('AI 查询失败：${friendlyAiError(e)}');
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _aiBusy = false);
      _toast('AI 查询失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _aiBusy = false);
    if (sug == null) {
      _toast('AI 没给出有效分类，请手动选择');
      return;
    }
    final s = sug;
    final suggested = s.category.trim();
    final inOptions = _categoryOptions.contains(suggested);
    final untouched = _category == categorySnapshot;

    String? adopt; // 建议最终采用分类；null = 不写（保持用户已在途的选择）
    String? adoptedNote; // 写了分类时附带的说明（写进备注空槽 + toast）
    if (inOptions) {
      adopt = suggested;
    } else if (untouched) {
      // AI 给出清单外新分类且用户在途没改过 → 确认后创建为自创分类。
      final ok = await _confirmCreateCategory(suggested);
      if (!mounted) return;
      if (ok == true) {
        await addCustomCategory(_store, suggested); // 重名脏数据不重复写
        if (!mounted) return;
        setState(() {
          _categoryOptions = optionsIncluding(_categoryOptions, suggested);
        });
        adopt = suggested;
        adoptedNote = 'AI 给出新分类「$suggested」，已创建为自创分类并采用';
      } else {
        adopt = classify(model.isNotEmpty ? model : suggested);
        adoptedNote =
            'AI 曾建议「$suggested」（未创建），已按型号归入「$adopt」';
      }
    }
    // !inOptions && !untouched：用户在途改过分类 → 不创建、不采用，只填空槽。

    final confidenceNote = s.confidence != null
        ? '（置信度 ${(s.confidence! * 100).round()}%）'
        : '';
    final willApply = untouched && adopt != null;
    setState(() {
      // 竞态门：仅在请求在途用户没改过分类时覆盖（含初始未手动改过）
      if (_category == categorySnapshot && adopt != null) {
        _category = adopt;
        _categoryTouched = true; // 锁定，防后续型号输入监听覆盖 AI 结果
      }
      if (_packageCtrl.text.trim().isEmpty && s.package != null) {
        _packageCtrl.text = s.package!;
      }
      if (_brandCtrl.text.trim().isEmpty && s.brand != null) {
        _brandCtrl.text = s.brand!;
      }
      if (_noteCtrl.text.trim().isEmpty) {
        final fill = adoptedNote ?? s.note;
        if (fill != null && fill.isNotEmpty) {
          _noteCtrl.text = fill;
        }
      }
    });
    if (willApply && adoptedNote != null) {
      _toast(adoptedNote);
    } else {
      _toast('AI：${adopt ?? _category}$confidenceNote');
    }
  }

  /// 展示「把 AI 给出的新分类创建为自创分类」确认框。
  Future<bool> _confirmCreateCategory(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('使用新分类？'),
        content: Text(
          'AI 给出的分类「$name」不在现有分类里。\n\n'
          '把它创建为自创分类并采用？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('不创建'),
          ),
          FilledButton(
            key: const ValueKey('ai_create_category_ok'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建并使用'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      // 键盘弹出时不遮挡（viewInsets 补偿）
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: FractionallySizedBox(
        heightFactor: 0.92,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Text(_isEdit ? '编辑元件' : '添加元件',
                        style: Theme.of(context).textTheme.titleLarge),
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
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _modelCtrl,
                        autofocus: !_isEdit,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '型号 *',
                          hintText: '如 XL-1608UPC-06',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.memory),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? '请输入型号' : null,
                      ),
                      const SizedBox(height: 12),
                      if (_isEdit && _existing!.isNoCidEntry)
                        // 编辑无 C 号元件：不渲染 CID 输入框，避免暴露内部编号。
                        Container(
                          key: const ValueKey('no_cid_banner'),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            border: Border.all(
                              color:
                                  Theme.of(context).colorScheme.outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 18,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  '无 C 号元件（内部编号由系统保管，不显示）。'
                                  '可在详情页把它合并到真实 C 号元件。',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        TextFormField(
                          controller: _cidCtrl,
                          enabled: !_isEdit,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: 'CID（立创编号，可空）',
                            hintText: '如 C2977076；留空 = 无 C 号散料',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.qr_code_2),
                            suffixIcon: _cidBusy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: Center(
                                      child: SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2)),
                                    ),
                                  )
                                : null,
                            helperText: _isEdit
                                ? _cidHint
                                : (_cidCtrl.text.trim().isEmpty
                                    ? '留空将按无 C 号元件入库，可稍后在详情页补 C 号 / 合并'
                                    : _cidHint),
                            helperStyle: TextStyle(
                              color: _cidHint == '可用'
                                  ? Colors.green
                                  : (_cidHint != null
                                      ? Colors.orange
                                      : null),
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return null; // CID 可空
                            if (_isEdit) return null;
                            if (!RegExp(r'^C\d{5,}$').hasMatch(v.trim())) {
                              return 'CID 形如 C 后跟至少 5 位数字';
                            }
                            return null;
                          },
                          onFieldSubmitted: (_) => _save(),
                        ),
                      // AI 查询 + C 号查料自动填充（型号或 C 号非空时出现；保存中禁用）。
                      // AI：新增与编辑都显示（目标是分类修正）；立创查料仅新增 + 合法 C 号。
                      if (!_saving &&
                          (_modelCtrl.text.trim().isNotEmpty ||
                              _cidCtrl.text.trim().isNotEmpty)) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            if (!_isEdit && isLcscCode(_cidCtrl.text))
                              TextButton.icon(
                                onPressed: (_lookupBusy || _aiBusy || _namingBusy)
                                    ? null
                                    : _autoFillFromLcsc,
                                icon: _lookupBusy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : const Icon(Icons.auto_fix_high,
                                        size: 18),
                                label: Text(_lookupBusy ? '查询中…' : '从立创查料自动填充'),
                              ),
                            if (_modelCtrl.text.trim().isNotEmpty)
                              TextButton.icon(
                                key: const ValueKey('ai_name_btn'),
                                onPressed: (_aiBusy || _lookupBusy || _namingBusy)
                                    ? null
                                    : _aiRename,
                                icon: _namingBusy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : const Icon(Icons.edit_note, size: 18),
                                label: Text(_namingBusy ? '命名中…' : 'AI 命名'),
                              ),
                            TextButton.icon(
                              key: const ValueKey('ai_query_btn'),
                              onPressed: (_aiBusy || _lookupBusy)
                                  ? null
                                  : _aiClassifyFill,
                              icon: _aiBusy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.auto_awesome, size: 18),
                              label: Text(_aiBusy ? 'AI 分析中…' : 'AI 查询'),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 4),
                      DropdownButtonFormField<String>(
                        initialValue: _category,
                        decoration: const InputDecoration(
                          labelText: '分类',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.category_outlined),
                        ),
                        // 选项恒包含当前值（自创分类 / 跨设备同步来的陌生分类 / 回收站行），防断言崩。
                        items: [
                          for (final c in optionsIncluding(_categoryOptions, _category))
                            DropdownMenuItem(value: c, child: Text(c)),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _category = v;
                            _categoryTouched = true;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _packageCtrl,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '封装',
                          hintText: '如 0805 / SOP-16（可选）',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.straighten),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 品牌：同型号不同品牌各自入库一行，外层列表聚合显示总数量。
                      TextFormField(
                        key: const ValueKey('brand_field'),
                        controller: _brandCtrl,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '品牌（可选）',
                          hintText: '如 国巨 / 三星 / TI',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.factory_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 数量：滑块 + 直接输入双路（数字键盘，联动 _quantity）。
                      Row(
                        children: [
                          const Text('数量'),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Slider(
                              key: const ValueKey('qty_slider'),
                              value: _quantity.clamp(1, _qtyMax).toDouble(),
                              min: 1,
                              max: _qtyMax.toDouble(),
                              label: '$_quantity',
                              onChanged: (v) => _setQuantity(v.round()),
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            child: TextField(
                              key: const ValueKey('qty_input'),
                              controller: _qtyCtrl,
                              keyboardType: TextInputType.number,
                              textInputAction: TextInputAction.done,
                              textAlign: TextAlign.end,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                isDense: true,
                                suffixText: '个',
                                border: OutlineInputBorder(),
                              ),
                              onChanged: _onQtyTyped,
                              onSubmitted: (v) {
                                final n = int.tryParse(v);
                                _setQuantity(
                                    (n == null || n < 1) ? _quantity : n);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _locationCtrl,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '位置',
                          hintText: '如 A1-3 抽屉（可选）',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.place_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _noteCtrl,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: '备注',
                          hintText: '可选',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.notes),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_isEdit ? '保存修改' : '保存'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
