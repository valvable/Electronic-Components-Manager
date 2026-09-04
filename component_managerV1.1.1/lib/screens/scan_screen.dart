import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/config/constants.dart';
import '../core/services/ai_client.dart';
import '../core/services/component_repository.dart';
import '../core/services/settings_store.dart';
import '../core/utils/category_options.dart';
import '../core/utils/classifier.dart';
import '../core/utils/qr_parser.dart';
import '../main.dart';
import '../models/component.dart';
import '../models/scan_result.dart';
import 'add_component_dialog.dart';

/// 扫码录入页。
///
/// - Android：`MobileScanner` 实时取景，`onDetect → parseQr` → 确认弹窗；
///   同 CID 已存在 →「是否增加数量」，已在回收站 →「是否恢复并增加数量」。
/// - Windows（无摄像头 / 启动异常）：降级为「从剪贴板粘贴二维码内容」+
///   「手动输入 CID / 型号」两个入口（反馈 #5）。
///
/// 成功保存后保留页面（可连续扫多袋料），AppBar 关闭返回主列表。
class ScanScreen extends StatefulWidget {
  final AppState state;

  /// AI 分类分析 seam（测试注入假实现）；为空时确认弹窗按设置库走真接口。
  final AiClassifyLookup? aiClassifyLookup;

  const ScanScreen({super.key, required this.state, this.aiClassifyLookup});

  @override
  ScanScreenState createState() => ScanScreenState();
}

/// 公开 State 类：便于 widget 测试直接调用 [handleScannedText] 走完整流程。
class ScanScreenState extends State<ScanScreen> {
  MobileScannerController? _camera;
  bool _cameraSupported = false;
  bool _processing = false;
  bool _cameraPaused = false;
  bool _savedAny = false;

  bool get _cameraActive => _cameraSupported && _camera != null;

  @override
  void initState() {
    super.initState();
    // 仅 Android 有摄像头；桌面不构造 controller（mobile_scanner 无 Windows 实现）。
    _cameraSupported = !kIsWeb && Platform.isAndroid;
    if (_cameraSupported) {
      _camera = MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  // ---- 扫码 / 粘贴 / 手动 入口 ----

  void _onDetect(BarcodeCapture capture) {
    final raw = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
    if (raw == null || raw.trim().isEmpty) return;
    handleScannedText(raw);
  }

  void _onCameraError(Object error, StackTrace stackTrace) {
    if (!mounted) return;
    _toast('扫码异常：$error');
  }

  Future<void> _onPaste() async {
    if (_processing) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        _toast('剪贴板中没有可粘贴的文本');
        return;
      }
      await handleScannedText(text);
    } catch (e) {
      _toast('读取剪贴板失败: $e');
    }
  }

  void _onManual() {
    if (_processing) return;
    unawaited(_openManual());
  }

  /// 手动录入（可预填型号）。
  Future<void> _openManual({String? prefillModel}) async {
    await showAddComponentDialog(context, repo: widget.state.components, prefillModel: prefillModel);
  }

  /// 核心流程：任意来源的二维码文本 → 解析 → 三态确认 → 入库/累加/恢复。
  /// 公开给 widget 测试复用（桌面/测试无摄像头，直接喂文本）。
  Future<void> handleScannedText(String raw) async {
    if (_processing) return;
    _processing = true;
    try {
      await _pauseCamera();
      final parsed = parseQr(raw);

      if (parsed.cid == null && parsed.model == null) {
        _toast('未识别到有效二维码内容，请尝试手动输入');
        return;
      }
      // 只有型号未识别出 CID：转手动录入并预填型号。
      if (parsed.cid == null) {
        await _openManual(prefillModel: parsed.model);
        return;
      }

      final lookup = await widget.state.components.byCid(parsed.cid!);
      if (!mounted) return;
      await _confirmAndSave(parsed, lookup);
    } finally {
      _processing = false;
      await _resumeCamera();
    }
  }

  /// 按三态走对应确认弹窗并保存。
  Future<void> _confirmAndSave(ScannedQr parsed, ComponentLookup lookup) async {
    final repo = widget.state.components;
    final cid = parsed.cid!;
    Component? saved;

    switch (lookup.status) {
      case LookupStatus.notFound: {
        final res = await showScanEntryDialog(
          context,
          cid: cid,
          model: parsed.model,
          qty: parsed.qty,
          store: widget.state.settings,
          aiLookup: widget.aiClassifyLookup,
        );
        if (res == null || !mounted) return;
        final now = Component.now();
        final fresh = Component(
          cid: cid,
          model: res.model,
          category: res.category,
          brand: res.brand,
          quantity: res.qty,
          location: res.location,
          note: res.note,
          createdAt: now,
          updatedAt: now,
        );
        final id = await repo.insert(fresh);
        saved = fresh.copyWith(id: id);
      }
      case LookupStatus.active: {
        final res = await showScanAddDialog(
          context,
          component: lookup.component!,
          addQty: parsed.qty ?? defaultQuantity,
        );
        if (res == null || !mounted) return;
        saved = await repo.insertOrAddQty(cid, add: res.qty);
      }
      case LookupStatus.deleted: {
        final res = await showScanAddDialog(
          context,
          component: lookup.component!,
          addQty: parsed.qty ?? defaultQuantity,
          isDeleted: true,
        );
        if (res == null || !mounted) return;
        saved = await repo.insertOrAddQty(cid, add: res.qty);
      }
    }

    if (!mounted) return;
    // 分析器已证明 saved 非 null：所有不提前 return 的路径都已赋值。
    final savedComponent = saved;
    _savedAny = true;
    unawaited(HapticFeedback.lightImpact());
    _toast('已保存 ${savedComponent.model}（数量 ${savedComponent.quantity}）');
  }

  Future<void> _pauseCamera() async {
    if (_cameraActive) {
      await _camera!.pause();
      _cameraPaused = true;
    }
  }

  Future<void> _resumeCamera() async {
    if (_cameraPaused && mounted) {
      _cameraPaused = false;
      try {
        await _camera!.start();
      } catch (_) {
        // 摄像头不可用由 errorBuilder 呈现降级界面，不抛到 UI 流程。
      }
    }
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
      appBar: AppBar(
        title: const Text('扫码入库'),
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, _savedAny),
        ),
      ),
      body: _cameraActive ? _buildCameraView() : _buildFallback(),
    );
  }

  Widget _buildCameraView() {
    return Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: _camera,
            fit: BoxFit.cover,
            onDetect: _onDetect,
            onDetectError: _onCameraError,
            errorBuilder: (context, error) => _buildFallback(
              errorMessage: '摄像头启动失败：${error.errorCode}',
            ),
            overlayBuilder: (context, _) => const _ScanHint(),
          ),
        ),
        _buildActionBar(),
      ],
    );
  }

  Widget _buildActionBar() {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _onPaste,
                  icon: const Icon(Icons.content_paste_go),
                  label: const Text('粘贴二维码'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _onManual,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('手动输入'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 桌面 / 摄像头异常降级面板：粘贴 + 手动输入。
  Widget _buildFallback({String? errorMessage}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.qr_code_scanner, size: 72, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              errorMessage ?? '当前平台无摄像头\n可从立创料袋复制二维码文本后粘贴录入',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _onPaste,
              icon: const Icon(Icons.content_paste_go),
              label: const Text('从剪贴板粘贴二维码内容'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _onManual,
              icon: const Icon(Icons.edit_note),
              label: const Text('手动输入 CID / 型号'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 取景框上的提示条。
class _ScanHint extends StatelessWidget {
  const _ScanHint();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.center_focus_strong, color: Colors.white, size: 18),
              SizedBox(width: 6),
              Text('对准元件袋上的二维码', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 新元件确认入库弹窗的返回值。
class ScanEntryResult {
  final String model;
  final String category;
  final int qty;
  final String? brand;
  final String? location;
  final String? note;

  const ScanEntryResult({
    required this.model,
    required this.category,
    required this.qty,
    this.brand,
    this.location,
    this.note,
  });
}

/// 新元件（CID 不存在）确认弹窗：型号可编辑、分类自动识别、数量预填自
/// 二维码 qty（缺省 1），可选位置/备注。
///
/// AI 分类：分类行旁的「AI 查询」手动触发；当本地 [classify] 判为默认
/// 「其他」时**自动触发一次**（确定性高就不打扰）。AI 给新分类 → 弹窗确认
/// 创建为自创分类并采用。未配置时只提示一次去设置页。
Future<ScanEntryResult?> showScanEntryDialog(
  BuildContext context, {
  required String cid,
  String? model,
  int? qty,
  SettingsStore? store,
  AiClassifyLookup? aiLookup,
  AiNameLookup? aiNameLookup,
}) {
  return showModalBottomSheet<ScanEntryResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => _ScanEntryDialog(
      cid: cid,
      model: model,
      qty: qty,
      store: store,
      aiLookup: aiLookup,
      aiNameLookup: aiNameLookup,
    ),
  );
}

class _ScanEntryDialog extends StatefulWidget {
  final String cid;
  final String? model;
  final int? qty;
  final SettingsStore? store;
  final AiClassifyLookup? aiLookup;
  final AiNameLookup? aiNameLookup;

  const _ScanEntryDialog({
    required this.cid,
    this.model,
    this.qty,
    this.store,
    this.aiLookup,
    this.aiNameLookup,
  });

  @override
  State<_ScanEntryDialog> createState() => _ScanEntryDialogState();
}

class _ScanEntryDialogState extends State<_ScanEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _modelCtrl;
  late final TextEditingController _brandCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _noteCtrl;

  late String _category;
  late int _qty;
  bool _categoryTouched = false;

  /// 分类下拉选项：系统 29 + 自创（store 非空时异步加载）。
  List<String> _categoryOptions = inventoryCategories;
  bool _categoryOptionsLoaded = false;

  bool _aiBusy = false;
  bool _namingBusy = false;
  bool _autoAiDone = false; // 本次弹窗只自动触发一次

  @override
  void initState() {
    super.initState();
    final model = widget.model;
    _modelCtrl = TextEditingController(text: model ?? widget.cid);
    _brandCtrl = TextEditingController();
    _locationCtrl = TextEditingController();
    _noteCtrl = TextEditingController();
    _category = classify(model ?? widget.cid);
    _qty = (widget.qty ?? defaultQuantity).clamp(1, 1 << 30);
    _modelCtrl.addListener(_onModelChanged);
    _initCategories();
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _brandCtrl.dispose();
    _locationCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _initCategories() async {
    final store = widget.store;
    if (store == null) {
      _categoryOptionsLoaded = true;
      return;
    }
    try {
      final options = await loadCategoryOptions(store);
      if (!mounted) return;
      setState(() {
        _categoryOptions = options;
        _categoryOptionsLoaded = true;
      });
      _maybeAutoAi();
    } catch (_) {
      if (!mounted) return;
      _categoryOptionsLoaded = true;
      _maybeAutoAi();
    }
  }

  /// 首次本地分类判为默认「其他」且用户没手动改过 → 自动跑一次 AI。
  void _maybeAutoAi() {
    if (_autoAiDone || !_categoryOptionsLoaded || _categoryTouched) return;
    _autoAiDone = true;
    final m = _modelCtrl.text.trim();
    if (m.isEmpty) return;
    if (classify(m) != defaultCategory) return; // 确定性高 → 不自动打扰
    unawaited(_runAi(automatic: true));
  }

  void _onModelChanged() {
    if (_categoryTouched) return;
    final m = _modelCtrl.text.trim();
    if (m.isEmpty) return;
    final auto = classify(m);
    if (auto != _category) setState(() => _category = auto);
    _maybeAutoAi();
  }

  // ---- AI 分类（按钮手动 + 判「其他」自动一次）----

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<AiClassifySuggestion?> _callAi(String model, String? cid) {
    final seam = widget.aiLookup;
    if (seam != null) return seam(model, cid);
    final store = widget.store;
    if (store == null) return Future.value(null);
    return aiClassifyFromSettings(
      store,
      model: model,
      cid: cid,
      categories: _categoryOptions,
    );
  }

  /// 跑一次 AI 分类并落地。[automatic] 为自动触发（未配置等失败只提示一次）。
  Future<void> _runAi({bool automatic = false}) async {
    final model = _modelCtrl.text.trim();
    final cidText = widget.cid; // 扫码到的一定是立创 C 号
    final categorySnapshot = _category;
    setState(() => _aiBusy = true);
    AiClassifySuggestion? sug;
    try {
      sug = await _callAi(
        model.isNotEmpty ? model : cidText,
        model.isNotEmpty && cidText.isNotEmpty ? cidText : null,
      );
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() => _aiBusy = false);
      _toast(automatic
          ? friendlyAiError(e) // 自动触发失败只提示一次，不打断入库
          : 'AI 查询失败：${friendlyAiError(e)}');
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
      if (!automatic) _toast('AI 没给出有效分类，请手动选择');
      return;
    }
    final s = sug;
    final suggested = s.category.trim();
    final inOptions = _categoryOptions.contains(suggested);
    final untouched = _category == categorySnapshot;

    String? adopt;
    String? adoptedNote;
    if (inOptions) {
      adopt = suggested;
    } else if (untouched) {
      // 确认创建新自创分类并采用；无 store（无持久化渠道）按取消兜底。
      final store = widget.store;
      final canCreate = store != null;
      final ok = canCreate
          ? await _confirmCreateCategory(suggested)
          : false;
      if (!mounted) return;
      if (ok == true) {
        await addCustomCategory(store!, suggested);
        if (!mounted) return;
        setState(() {
          _categoryOptions = optionsIncluding(_categoryOptions, suggested);
        });
        adopt = suggested;
        adoptedNote = 'AI 分类「$suggested」已创建为自创分类并采用';
      } else {
        adopt = classify(model.isNotEmpty ? model : suggested);
        adoptedNote = canCreate
            ? '未创建自创分类「$suggested」，已按型号归入「$adopt」'
            : null;
      }
    }
    final willApply = untouched && adopt != null;
    setState(() {
      // 竞态门：用户在途改过分类则不覆盖
      if (_category == categorySnapshot && adopt != null) {
        _category = adopt;
        _categoryTouched = true; // AI 结果为准，锁定防型号监听覆盖
      }
      if (_brandCtrl.text.trim().isEmpty && s.brand != null) {
        _brandCtrl.text = s.brand!;
      }
      if (_noteCtrl.text.trim().isEmpty) {
        // 扫码弹窗无「封装」输入框：AI 封装并入备注提示。
        final noteText = s.note ?? s.package;
        if (noteText != null && noteText.isNotEmpty) {
          _noteCtrl.text = noteText;
        }
      }
    });
    if (willApply && adoptedNote != null) {
      _toast(adoptedNote);
    } else {
      _toast('AI：${adopt ?? _category}');
    }
  }

  /// 「AI 命名」：把当前型号/描述规范成厂商标准型号（AI1 接口，空槽才填品牌）。
  Future<void> _aiRename() async {
    if (_namingBusy) return;
    final raw = _modelCtrl.text.trim();
    if (raw.isEmpty) return;
    setState(() => _namingBusy = true);
    AiModelSuggestion? sug;
    try {
      sug = await (widget.aiNameLookup?.call(raw, widget.cid) ??
          (widget.store == null
              ? Future<AiModelSuggestion?>.value(null)
              : aiNameFromSettings(widget.store!, rawModel: raw, cid: widget.cid)));
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
    if (_brandCtrl.text.trim().isEmpty && s.brand != null) {
      _brandCtrl.text = s.brand!;
    }
    if (s.model == raw) {
      _toast('AI：「$raw」已是规范型号');
    } else {
      setState(() => _modelCtrl.text = s.model);
      _toast('已按 AI 规范命名：${s.model}');
    }
  }

  /// 展示「把 AI 给的新分类创建为自创分类」确认框。
  Future<bool> _confirmCreateCategory(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('使用新分类？'),
        content: Text(
          'AI 给出的分类「$name」不在现有分类里。\n\n把它创建为自创分类并采用？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('不创建'),
          ),
          FilledButton(
            key: const ValueKey('scan_ai_create_category_ok'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建并使用'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final model = _modelCtrl.text.trim();
    Navigator.pop(
      context,
      ScanEntryResult(
        model: model,
        category: _category,
        qty: _qty,
        brand: _brandCtrl.text.trim().isEmpty ? null : _brandCtrl.text.trim(),
        location: _locationCtrl.text.trim().isEmpty ? null : _locationCtrl.text.trim(),
        note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: FractionallySizedBox(
        heightFactor: 0.72,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Text('确认入库', style: Theme.of(context).textTheme.titleLarge),
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
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '型号 *',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.memory),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? '请输入型号' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: widget.cid,
                        enabled: false,
                        decoration: const InputDecoration(
                          labelText: 'CID',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.qr_code_2),
                        ),
                      ),
                      // AI 按钮行：本地分类=其他时「查询分类」自动触发一次；
                      // 「AI 命名」把型号规范成厂商 MPN（两者独立、都走 AI1）。
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 4,
                          children: [
                            TextButton.icon(
                              key: const ValueKey('scan_ai_name_btn'),
                              onPressed: (_namingBusy ||
                                      (widget.store == null &&
                                          widget.aiNameLookup == null))
                                  ? null
                                  : _aiRename,
                              icon: _namingBusy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.edit_note, size: 18),
                              label: Text(_namingBusy ? '命名中…' : 'AI 命名'),
                            ),
                            TextButton.icon(
                              key: const ValueKey('scan_ai_query_btn'),
                              onPressed: _aiBusy ? null : () => _runAi(),
                              icon: _aiBusy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.auto_awesome, size: 18),
                              label: Text(_aiBusy ? 'AI 分析中…' : 'AI 查询分类'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<String>(
                        initialValue: _category,
                        decoration: const InputDecoration(
                          labelText: '分类',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.category_outlined),
                        ),
                        // 选项恒包含当前值（自创 / 跨设备同步来的陌生分类），防断言崩。
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
                        key: const ValueKey('scan_brand_field'),
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
                      Row(
                        children: [
                          const Text('数量'),
                          const SizedBox(width: 12),
                          IconButton.filledTonal(
                            onPressed:
                                _qty > 1 ? () => setState(() => _qty--) : null,
                            icon: const Icon(Icons.remove),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text('$_qty',
                                style: Theme.of(context).textTheme.titleMedium),
                          ),
                          IconButton.filledTonal(
                            onPressed: () => setState(() => _qty++),
                            icon: const Icon(Icons.add),
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
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('保存'),
                        ),
                      ),
                    ],
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

/// 已有元件加量 / 回收站恢复弹窗的返回值。
class ScanAddResult {
  final int qty;
  const ScanAddResult(this.qty);
}

/// 同 CID 已存在（或已在回收站）：确认增加数量（数量可调）。
Future<ScanAddResult?> showScanAddDialog(
  BuildContext context, {
  required Component component,
  required int addQty,
  bool isDeleted = false,
}) {
  return showDialog<ScanAddResult>(
    context: context,
    builder: (_) => _ScanAddDialog(
      component: component,
      addQty: addQty,
      isDeleted: isDeleted,
    ),
  );
}

class _ScanAddDialog extends StatefulWidget {
  final Component component;
  final int addQty;
  final bool isDeleted;

  const _ScanAddDialog({
    required this.component,
    required this.addQty,
    required this.isDeleted,
  });

  @override
  State<_ScanAddDialog> createState() => _ScanAddDialogState();
}

class _ScanAddDialogState extends State<_ScanAddDialog> {
  late int _qty;

  @override
  void initState() {
    super.initState();
    _qty = widget.addQty.clamp(1, 1 << 30);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.component;
    return AlertDialog(
      title: Text(widget.isDeleted ? '该元件已在回收站' : '该元件已存在'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('「${c.model}」'),
          Text('当前数量：${c.quantity}'),
          if (widget.isDeleted) const SizedBox(height: 4),
          if (widget.isDeleted)
            Text('恢复后将自动从回收站移出。',
                style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('增加数量'),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                icon: const Icon(Icons.remove),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('$_qty',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton.filledTonal(
                onPressed: () => setState(() => _qty++),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ScanAddResult(_qty)),
          child: const Text('确认增加'),
        ),
      ],
    );
  }
}
