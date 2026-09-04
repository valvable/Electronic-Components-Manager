import 'dart:io';

import 'package:flutter/material.dart';

import '../core/config/constants.dart';
import '../core/services/device_identity.dart';
import '../core/services/lan_discovery.dart';
import '../core/services/sync_service.dart';
import '../core/sync/merge_engine.dart';
import '../core/sync/sync_codec.dart';
import '../main.dart';
import '../models/component.dart';
import '../widgets/conflict_tile.dart';

/// 局域网同步：主机模式（开 HTTP 服务等对端拉取）+ 拉取模式（连接对端合并）。
/// 冲突在拉取端弹底部面板逐条裁决（保留本地 / 保留远端 / 保留两者）。
class SyncScreen extends StatefulWidget {
  final AppState state;

  /// 测试缝：注入假发现源（默认走真实 UDP 扫描）。
  final Future<List<FoundHost>> Function()? discoverHosts;

  const SyncScreen({super.key, required this.state, this.discoverHosts});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _ipCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '$syncPort');
  final _tokenCtrl = TextEditingController(text: defaultSyncToken);

  SyncService? _sync;
  bool _busy = false; // 拉取同步进行中
  bool _hostBusy = false; // 开关主机动作中
  String _deviceId = '';
  List<String> _localIps = const [];
  String _status = '';

  // 冲突裁决会话
  List<SyncConflict>? _conflicts;
  final Set<String> _resolvingCids = {}; // 正在提交裁决的 cid（按钮禁用防重入）
  int _resolved = 0;
  int _total = 0;
  String _lastHostIp = '';
  int _sessionOffset = 0;

  // 自动发现 + 记忆
  DiscoveryAnnouncer? _announcer; // 随 HTTP 主机启停
  String _localDisplayName = ''; // 主机开启时的发现显示名（announcer 成功后回填）
  final DiscoveryScanner _scanner = DiscoveryScanner();
  List<FoundHost>? _foundHosts; // null=未扫描；空列表=扫过没找到
  bool _discovering = false;
  String _rememberedIp = '';
  String? _rememberedName;
  int? _lastSyncPort; // 最近一次实际连接/记忆的 HTTP 端口（冲突裁决回连用）
  String? _pendingHostName; // 自动发现点按的主机名（同步成功后记忆用）

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    // 主机服务随本页生命周期（避免悬空监听与端口占用）。
    _scanner.cancel();
    _announcer?.stop();
    _sync?.stopHost();
    _sync?.dispose();
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final id = await DeviceIdentity.getDeviceId(widget.state.db);
    final last = await widget.state.settings.loadLastHost();
    if (!mounted) return;
    setState(() {
      _deviceId = id;
      _sync = SyncService(
        state: widget.state,
        deviceId: id,
        token: _tokenCtrl.text.trim(),
        port: int.tryParse(_portCtrl.text) ?? syncPort,
      );
      // 回填上次成功的主机（免每次输入 IP/令牌）。
      final ip = last.ip;
      if (ip != null && ip.isNotEmpty) {
        _ipCtrl.text = ip;
        _rememberedIp = ip;
        _rememberedName = last.name;
        _lastSyncPort = last.port;
      }
      final tok = last.token;
      if (tok != null && tok.isNotEmpty) _tokenCtrl.text = tok;
    });
    _loadIps();
  }

  Future<void> _loadIps() async {
    final list = <String>[];
    try {
      final ifaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) list.add(a.address);
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _localIps = list);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  String _fmtLastSync(int epochSec) {
    if (epochSec <= 0) return '尚未同步';
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '最近 ${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  // ---- 主机 ----

  Future<void> _toggleHost() async {
    final sync = _sync;
    if (sync == null) return;
    if (sync.hostRunning) {
      await _announcer?.stop();
      _announcer = null;
      await sync.stopHost();
      if (mounted) setState(() {});
      return;
    }
    setState(() {
      _hostBusy = true;
      sync.token = _tokenCtrl.text.trim();
      sync.port = int.tryParse(_portCtrl.text) ?? syncPort;
    });
    try {
      await sync.startHost();
      try {
        _announcer = await DiscoveryAnnouncer.start(
          deviceId: sync.deviceId,
          httpPort: sync.boundPort ?? sync.port,
        );
        _localDisplayName = localDeviceName(sync.deviceId);
      } catch (e) {
        // 自动发现端口被占/网络受限：不阻断 HTTP 主机，仍可手动 IP 同步。
        if (mounted) _toast('自动发现不可用：$e（仍可手动输入 IP 同步）');
      }
      if (!mounted) return;
      setState(() => _status = '主机已开启');
      _toast('主机已开启，端口 ${sync.port}');
    } catch (e) {
      if (!mounted) return;
      _toast('开启主机失败：$e');
    } finally {
      if (mounted) setState(() => _hostBusy = false);
    }
  }

  // ---- 拉取同步 ----

  /// 自动发现：扫描局域网主机（无发现服务时回落到空，UI 提示手动输入）。
  Future<void> _discover() async {
    if (_discovering || _busy) return;
    setState(() {
      _discovering = true;
      _foundHosts = null;
    });
    final selfId = _sync?.deviceId ?? '';
    final List<FoundHost> hosts;
    try {
      hosts = widget.discoverHosts != null
          ? await widget.discoverHosts!()
          : await _scanner.discover(selfDeviceId: selfId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _discovering = false);
      _toast('自动发现失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _discovering = false;
      _foundHosts = hosts;
    });
  }

  /// 点按发现到的主机：回填 IP + 用其广播端口直接同步。
  Future<void> _useHost(FoundHost host) async {
    _ipCtrl.text = host.ip;
    _lastSyncPort = host.httpPort;
    _pendingHostName = host.name.isNotEmpty ? host.name : host.ip;
    setState(() {});
    await _syncNow();
  }

  Future<void> _syncNow() async {
    final sync = _sync;
    if (sync == null) return;
    final ip = _ipCtrl.text.trim();
    if (ip.isEmpty) {
      _toast('请填写主机 IP，或先「自动发现主机」');
      return;
    }
    // 记忆端口优先（自动发现/上次成功用过的端口），否则用本页配置端口。
    final targetPort = _lastSyncPort ?? sync.port;
    setState(() {
      _busy = true;
      _status = '连接主机 $ip …';
      _conflicts = null;
      _resolved = 0;
      sync.token = _tokenCtrl.text.trim();
    });
    final SyncResult result;
    try {
      result = await sync.syncFrom(ip, port: targetPort);
    } catch (e) {
      _pendingHostName = null; // 失败不记忆；清了避免下回成功时把旧发现名称错配到别的主机
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '同步失败';
      });
      _toast('同步失败：$e');
      return;
    }
    _lastHostIp = ip;
    _lastSyncPort = targetPort;
    _sessionOffset = result.offset;
    // 成功才记忆主机（手动与自动发现都经此唯一收口）；失败不覆盖旧记忆。
    final hostName = _pendingHostName;
    _pendingHostName = null;
    if (mounted) {
      final token = _tokenCtrl.text.trim();
      await widget.state.settings.saveLastHost(
        ip: ip,
        port: targetPort,
        name: hostName,
        token: token.isEmpty ? null : token,
      );
    }
    if (!mounted) return;
    setState(() {
      _busy = false; // 网络阶段结束；冲突裁决面板必须可交互，不能再禁用按钮
      _conflicts = result.conflicts;
      _total = result.conflictsCount;
      _status = result.conflictsCount == 0
          ? '同步完成，无冲突'
          : '同步完成，${result.conflictsCount} 个冲突待裁决';
    });
    if (result.conflicts.isNotEmpty) {
      await _showConflictSheet();
    } else {
      _toast('同步完成，无冲突');
    }
  }

  // ---- 冲突裁决 ----

  Future<void> _showConflictSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, scrollController) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$_resolved/$_total 个冲突已裁决',
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('稍后处理'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    for (final c in (_conflicts ?? const <SyncConflict>[]))
                      ConflictTile(
                        conflict: c,
                        busy: _resolvingCids.contains(c.cid),
                        onResolve: (choice) => _resolve(c, choice),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
    if (_conflicts != null && _conflicts!.isEmpty) {
      _toast('全部冲突已裁决');
    }
  }

  Future<void> _resolve(SyncConflict c, String choice) async {
    if (_resolvingCids.contains(c.cid)) return; // 防重入
    final clientOwn = c.local; // 客户端时钟
    final host = c.remote; // 已换算到客户端时钟
    final Component localChosen;
    final Component serverChosen;
    switch (choice) {
      case 'local':
        localChosen = clientOwn;
        serverChosen = shiftTime(clientOwn, -_sessionOffset);
      case 'remote':
        localChosen = host;
        serverChosen = shiftTime(host, -_sessionOffset);
      default: // both
        localChosen = mergeBoth(clientOwn, host);
        serverChosen = mergeBoth(
          shiftTime(clientOwn, -_sessionOffset),
          shiftTime(host, -_sessionOffset),
        );
    }
    setState(() => _resolvingCids.add(c.cid));
    try {
      // 先落本地（必成），再提交主机（回连用记忆/发现的端口，可能与配置端口不同）。
      await widget.state.components.syncUpsert(localChosen);
      await _sync?.resolveConflicts(_lastHostIp, [
        SyncResolution(cid: c.cid, choice: choice, component: serverChosen)
      ], port: _lastSyncPort);
      if (!mounted) return;
      setState(() {
        _resolvingCids.remove(c.cid);
        _conflicts = _conflicts!.where((x) => x.cid != c.cid).toList();
        _resolved++;
        _status = '已裁决 $_resolved/$_total 个冲突';
      });
    } catch (e) {
      if (mounted) setState(() => _resolvingCids.remove(c.cid));
      _toast('裁决失败：$e');
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final sync = _sync;
    return Scaffold(
      appBar: AppBar(title: const Text('局域网同步')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _hostCard(context, sync),
          const SizedBox(height: 12),
          _clientCard(context, sync),
          const SizedBox(height: 12),
          _infoCard(context),
        ],
      ),
    );
  }

  Widget _hostCard(BuildContext context, SyncService? sync) {
    final running = sync?.hostRunning ?? false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('主机模式（在另一台设备上拉取本机数据）',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: Text('端口')),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _portCtrl,
                    enabled: !running,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        isDense: true, border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: (_hostBusy || sync == null) ? null : _toggleHost,
              icon: Icon(running
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline),
              label: Text(running ? '停止主机' : '开启主机'),
            ),
            if (running && sync != null) ...[
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: sync,
                builder: (_, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value: sync.progress > 0 ? sync.progress : null,
                      minHeight: 4,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '已同步 ${sync.syncCount} 次 · ${_fmtLastSync(sync.lastSyncAt)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
            if (running) ...[
              const SizedBox(height: 8),
              Text('本机 IP：${_localIps.isEmpty ? '未获取' : _localIps.join('  ')}',
                  style: Theme.of(context).textTheme.bodyMedium),
              if (_announcer != null) ...[
                const SizedBox(height: 4),
                Text(
                  '发现名称：$_localDisplayName · 局域网发现端口 $syncDiscoveryPort',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 4),
              Text(
                '在另一台设备点「自动发现主机」选中本机，或在「拉取同步」中输入上方 IP 与相同令牌。首次开启请放行 Windows 防火墙（TCP $syncPort / UDP $syncDiscoveryPort）；开启期间请勿退出本页。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Text('设备 ID：$_deviceId',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _clientCard(BuildContext context, SyncService? sync) {
    final theme = Theme.of(context);
    final found = _foundHosts;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('拉取同步（连接主机，双向合并）',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            TextField(
              controller: _ipCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '主机 IP',
                hintText: '例如 192.168.1.100',
                isDense: true,
                border: const OutlineInputBorder(),
                helperText: _rememberedIp.isEmpty
                    ? null
                    : '上次同步：${_rememberedName ?? _rememberedIp} · $_rememberedIp',

              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tokenCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '同步令牌',
                hintText: '与主机一致',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // ---- 自动发现 ----
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        (_discovering || _busy || sync == null) ? null : _discover,
                    icon: _discovering
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering),
                    label: Text(_discovering ? '正在发现…' : '自动发现主机'),
                  ),
                ),
              ],
            ),
            if (found != null) ...[
              const SizedBox(height: 8),
              if (found.isEmpty)
                Text(
                  '未发现主机：请确认对方已开启主机且两台设备在同一 Wi-Fi。部分路由/热点的「AP 隔离」会阻断广播，此时请改用上方手动输入 IP。',
                  style: theme.textTheme.bodySmall,
                )
              else ...[
                for (final h in found) ...[
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.devices),
                    title: Text(h.label),
                    subtitle: Text('${h.ip} · 同步端口 ${h.httpPort}'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _useHost(h),
                  ),
                  const Divider(height: 1),
                ],
              ],
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: (_busy || sync == null) ? null : _syncNow,
              icon: const Icon(Icons.sync),
              label: Text(_busy ? '同步中…' : '开始同步'),
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 4),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status, style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('说明', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '· 双端全量合并：元件按 CID 逐条比对，更新时间较新者胜出；5 分钟内双侧都改过的条目判为冲突，可逐条裁决（保留本地 / 保留远端 / 数量合并）。\n'
              '· 软删除作为墓碑同步，两台设备删除一致。\n'
              '· BOM 单据与明细一并同步（单据按 名称+创建时间 去重）。\n'
              '· 请保持两台设备系统时间基本一致，时钟差过大可能误判。\n'
              '· 数据以 Base64 传输，令牌为弱校验，请只在可信局域网使用。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
