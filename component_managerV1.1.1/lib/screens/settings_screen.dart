import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/services/ai_client.dart';
import '../core/services/export_service.dart';
import '../core/services/import_parser.dart';
import '../main.dart';

/// 设置：数据备份/恢复 + AI 接口配置 + 关于与安全边界说明。
class SettingsScreen extends StatefulWidget {
  final AppState state;

  const SettingsScreen({super.key, required this.state});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  // ---- AI 配置表单 ----
  final _baseUrlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  // AI2（增强）：元件替换专用；留空回退 AI1。
  final _baseUrl2Ctrl = TextEditingController();
  final _apiKey2Ctrl = TextEditingController();
  final _model2Ctrl = TextEditingController();
  bool _keyVisible = false;
  bool _key2Visible = false;
  bool _aiBusy = false; // 测试连接中
  bool _ai2Busy = false;

  @override
  void initState() {
    super.initState();
    _loadAiConfig();
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _baseUrl2Ctrl.dispose();
    _apiKey2Ctrl.dispose();
    _model2Ctrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  // ---- AI 配置 ----

  Future<void> _loadAiConfig() async {
    final results = await Future.wait([
      widget.state.settings.loadAiConfig(),
      widget.state.settings.loadAi2Config(),
    ]);
    if (!mounted) return;
    final cfg = results[0];
    final cfg2 = results[1];
    _baseUrlCtrl.text = cfg.baseUrl ?? '';
    _apiKeyCtrl.text = cfg.apiKey ?? '';
    _modelCtrl.text = cfg.model ?? '';
    _baseUrl2Ctrl.text = cfg2.baseUrl ?? '';
    _apiKey2Ctrl.text = cfg2.apiKey ?? '';
    _model2Ctrl.text = cfg2.model ?? '';
  }

  Future<void> _saveAi() async {
    final store = widget.state.settings;
    await store.saveAiConfig(
      baseUrl: _baseUrlCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
    );
    await store.saveAi2Config(
      baseUrl: _baseUrl2Ctrl.text.trim(),
      apiKey: _apiKey2Ctrl.text.trim(),
      model: _model2Ctrl.text.trim(),
    );
    if (!mounted) return;
    final ai1Empty =
        _baseUrlCtrl.text.trim().isEmpty && _modelCtrl.text.trim().isEmpty;
    final ai2Empty =
        _baseUrl2Ctrl.text.trim().isEmpty && _model2Ctrl.text.trim().isEmpty;
    _toast(ai1Empty && ai2Empty ? '已清除 AI 配置' : 'AI 配置已保存');
  }

  /// 用给定表单内容真实请求一次（消息「回复 OK」）；成功/失败均 toast。
  Future<void> _testAiSlot({
    required TextEditingController baseUrl,
    required TextEditingController apiKey,
    required TextEditingController model,
    required void Function(bool) setBusy,
  }) async {
    setBusy(true);
    try {
      await aiChat(
        AiConfig(
          baseUrl: baseUrl.text.trim(),
          apiKey: apiKey.text.trim(),
          model: model.text.trim(),
        ),
        messages: const [
          {'role': 'user', 'content': '回复 OK'},
        ],
      );
      if (!mounted) return;
      _toast('连接成功');
    } on AiException catch (e) {
      if (!mounted) return;
      _toast(friendlyAiError(e));
    } catch (e) {
      if (!mounted) return;
      _toast('连接失败：$e');
    } finally {
      if (mounted) setBusy(false);
    }
  }

  // ---- 备份 ----

  Future<void> _exportBackup() async {
    setState(() => _busy = true);
    try {
      final json = await buildBackupJson(
        components: widget.state.components,
        boms: widget.state.boms,
      );
      final stamp = DateTime.now().toString().substring(0, 10).replaceAll('-', '');
      final path = await saveTextFile(
        '元件库存备份_$stamp.json',
        json,
        extension: 'json',
      );
      if (path == null) {
        _toast('已取消保存');
      } else {
        _toast('备份已保存：$path');
      }
    } catch (e) {
      _toast('备份失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- 恢复 ----

  Future<void> _importBackup() async {
    final file = await pickImportFile(['json']);
    if (file == null) return; // 用户取消选择
    final String text;
    try {
      text = utf8.decode(await file.readAsBytes());
    } catch (e) {
      _toast('读取备份文件失败：$e');
      return;
    }
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复数据'),
        content: const Text('将清空并覆盖当前全部元件与 BOM 数据，此操作不可撤销。确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final n = await restoreBackupJson(
        jsonText: text,
        components: widget.state.components,
        boms: widget.state.boms,
      );
      _toast('恢复成功，共 $n 个元件');
    } catch (e) {
      _toast('恢复失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text('数据备份与恢复',
                            style: Theme.of(context).textTheme.titleSmall),
                      ),
                      ListTile(
                        leading: const Icon(Icons.backup_outlined),
                        title: const Text('导出备份'),
                        subtitle: const Text('全量数据（含已删除元件、BOM）保存为 JSON 文件'),
                        onTap: _exportBackup,
                      ),
                      ListTile(
                        leading: const Icon(Icons.restore),
                        title: const Text('恢复备份'),
                        subtitle: const Text('从 JSON 备份重建全部数据（会覆盖当前内容）'),
                        onTap: _importBackup,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _buildAiCard(context),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text('关于', style: Theme.of(context).textTheme.titleSmall),
                      ),
                      const ListTile(
                        leading: Icon(Icons.inventory_2_outlined),
                        title: Text('电子元件管家'),
                        subtitle: Text('版本 1.1.1（正式版）'),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Text(
                          '局域网同步：数据经 Base64 传输 + 共享同步令牌弱校验，请只在可信局域网内使用。',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildAiCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AI 查询', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'AI 1（基础）：元件分类、AI 命名。配置 OpenAI 兼容接口后即可用。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            _aiFields(
              baseUrl: _baseUrlCtrl,
              apiKey: _apiKeyCtrl,
              model: _modelCtrl,
              visible: _keyVisible,
              onToggleVisible: () => setState(() => _keyVisible = !_keyVisible),
              testLabel: '测试连接',
              testing: _aiBusy,
              onTest: () => _testAiSlot(
                baseUrl: _baseUrlCtrl,
                apiKey: _apiKeyCtrl,
                model: _modelCtrl,
                setBusy: (v) => setState(() => _aiBusy = v),
              ),
            ),
            const Divider(height: 28),
            Text('AI 2（增强，元件替换专用）', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'BOM 缺料的库存替代 / 网络替代走这里的强模型；留空则回退 AI 1。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            _aiFields(
              baseUrl: _baseUrl2Ctrl,
              apiKey: _apiKey2Ctrl,
              model: _model2Ctrl,
              visible: _key2Visible,
              onToggleVisible: () => setState(() => _key2Visible = !_key2Visible),
              testLabel: '测试 AI 2',
              testing: _ai2Busy,
              labelSuffix: '（AI 2）',
              onTest: () => _testAiSlot(
                baseUrl: _baseUrl2Ctrl,
                apiKey: _apiKey2Ctrl,
                model: _model2Ctrl,
                setBusy: (v) => setState(() => _ai2Busy = v),
              ),
              modelHint: '如 deepseek-reasoner / gpt-4o（建议用推理更强的）',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _aiBusy || _ai2Busy ? null : _saveAi,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Key 明文保存在本机数据库（与同步令牌同级），仅在调用时传给接口。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// 一组 Base URL / API Key / 模型 输入 + 独立测试按钮（AI1、AI2 共用）。
  /// [labelSuffix]（如 '（AI 2）'）避免两组 labelText 撞名。
  Widget _aiFields({
    required TextEditingController baseUrl,
    required TextEditingController apiKey,
    required TextEditingController model,
    required bool visible,
    required VoidCallback onToggleVisible,
    required String testLabel,
    required bool testing,
    required VoidCallback onTest,
    String modelHint = '如 gpt-4o-mini / deepseek-chat',
    String labelSuffix = '',
  }) {
    final obscured = !visible;
    return Column(
      children: [
        TextField(
          controller: baseUrl,
          decoration: InputDecoration(
            labelText: 'Base URL$labelSuffix',
            hintText: '如 https://api.openai.com/v1',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: apiKey,
          obscureText: obscured,
          decoration: InputDecoration(
            labelText: 'API Key$labelSuffix',
            hintText: '本地无 Key 服务（Ollama 等）可留空',
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(
                visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
              ),
              onPressed: onToggleVisible,
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: model,
          decoration: InputDecoration(
            labelText: '模型$labelSuffix',
            hintText: modelHint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: testing ? null : onTest,
            icon: testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering, size: 18),
            label: Text(testing ? '测试中…' : testLabel),
          ),
        ),
      ],
    );
  }
}
