import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/constants.dart';
import 'discovery_payload.dart';

/// 局域网自动发现（UDP，dart:io，无第三方依赖）。
///
/// 角色分离，均不进 SyncService（保持既有同步代码与测试不动）：
/// - [DiscoveryAnnouncer]：主机侧——HTTP 主机运行期间每 [interval] 向
///   `255.255.255.255:8322` 广播一条公告；收到客户端 probe 只**单播回**公告
///   （避免两个 announcer 对公告回声死循环）。
/// - [DiscoveryScanner]：客户端侧——绑临时端口发几次 probe 并收听广播，
///   在 [window] 内收集去重后返回。
///
/// 备注：纯 UDP 广播依赖同一网段（家用路由默认不隔离；部分热点开「AP 隔离」
/// 会收不到 → UI 保留手动输入 IP 兜底）。明文公告仅含设备标识与端口，无数据。

/// 客户端发现到的一台主机。
class FoundHost {
  final String ip;
  final String deviceId;
  final String name; // 可为空串（取不到主机名时）
  final int httpPort; // 主机实际 HTTP 同步端口（可能 ≠ 默认 8321）

  const FoundHost({
    required this.ip,
    required this.deviceId,
    required this.name,
    required this.httpPort,
  });

  String get label => name.isNotEmpty ? name : ip;
}

String? _cachedLocalName;

/// 本机显示名（缓存一次，勿在周期广播里反复查——Android 上 hostname 查询
/// 可能慢/抛异常）。取不到时回退 deviceId 尾部短号。
String localDeviceName(String deviceId) {
  if (_cachedLocalName != null && _cachedLocalName!.isNotEmpty) {
    return _cachedLocalName!;
  }
  String name = '';
  try {
    name = Platform.localHostname;
  } catch (_) {}
  if (name.isEmpty) {
    final idx = deviceId.lastIndexOf('-');
    name = deviceId.substring(idx < 0 ? 0 : idx + 1);
  }
  _cachedLocalName = name;
  return name;
}

/// 主机侧公告器：绑定发现端口、周期广播、应答 probe。随 HTTP 主机启停。
class DiscoveryAnnouncer {
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  Timer? _timer;
  final List<int> _announceBytes;
  int? _port;

  bool get running => _socket != null;

  /// 实际绑定的发现端口（listenPort:0 时系统分配，测试用）。
  int? get boundPort => _port;

  DiscoveryAnnouncer._(this._announceBytes);

  /// 绑定发现端口并开始周期广播。
  ///
  /// - [listenPort] 默认 [syncDiscoveryPort]（8322）；0 → 临时端口（测试）。
  /// - [bindAddress] 默认 `0.0.0.0`；loopback 测试传 `127.0.0.1`。
  /// - [name] 提供则用之，否则 [localDeviceName]（测试可传避免 hostname 查询）。
  static Future<DiscoveryAnnouncer> start({
    required String deviceId,
    required int httpPort,
    int listenPort = syncDiscoveryPort,
    String bindAddress = '0.0.0.0',
    String? name,
    Duration interval = const Duration(seconds: 2),
  }) async {
    final label = name ?? localDeviceName(deviceId);
    final bytes = utf8.encode(encodeAnnounce(
      deviceId: deviceId,
      name: label,
      httpPort: httpPort,
    ));
    final socket =
        await RawDatagramSocket.bind(InternetAddress(bindAddress), listenPort);
    socket.broadcastEnabled = true;
    final announcer = DiscoveryAnnouncer._(bytes);
    announcer._socket = socket;
    announcer._port = socket.port;
    announcer._sub = socket.listen(announcer._onEvent);
    announcer._timer = Timer.periodic(interval, (_) => announcer._broadcast());
    return announcer;
  }

  /// 事件循环：读事件排空 receive()，只对 probe 单播回公告。
  void _onEvent(RawSocketEvent event) {
    final socket = _socket;
    if (socket == null || event != RawSocketEvent.read) return;
    while (true) {
      final d = socket.receive();
      if (d == null) break;
      if (!isProbe(utf8.decode(d.data, allowMalformed: true))) continue;
      try {
        socket.send(_announceBytes, d.address, d.port);
      } catch (_) {
        // 回包失败忽略（对端已离线等）
      }
    }
  }

  void _broadcast() {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(_announceBytes,
          InternetAddress(syncDiscoveryBroadcast), syncDiscoveryPort);
    } catch (_) {
      // 广播失败（如绑在 loopback/隔离网络）忽略，不影响 HTTP 主机。
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final socket = _socket;
    final sub = _sub;
    _socket = null;
    _sub = null;
    await sub?.cancel();
    socket?.close(); // RawDatagramSocket.close() 为同步 void
  }
}

/// 客户端扫描器：一次性探测 + 收听，返回局域网内主机列表。
class DiscoveryScanner {
  RawDatagramSocket? _socket;

  /// 取消当前扫描（关闭 socket；等待中的 Future 会走完 window 再返回，调用方
  /// 用 mounted 守卫丢弃过期结果即可）。
  void cancel() {
    _socket?.close();
    _socket = null;
  }

  /// 一次发现会话：发 [probeCount] 次探测 + 收听 [window]。
  ///
  /// [sendTarget] 缺省向广播地址发（真实局域网）；loopback 测试传具体地址。
  Future<List<FoundHost>> discover({
    String selfDeviceId = '', // 过滤自己（本机同时当主机时）
    Duration window = const Duration(milliseconds: 1800),
    InternetAddress? sendTarget,
    int? sendTargetPort,
    int probeCount = 3,
    Duration probeGap = const Duration(milliseconds: 200),
  }) async {
    final socket =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket = socket;
    socket.broadcastEnabled = true;

    final found = <String, FoundHost>{};
    final probeBytes = utf8.encode(encodeProbe());
    final target = sendTarget ?? InternetAddress(syncDiscoveryBroadcast);
    final targetPort = sendTargetPort ?? syncDiscoveryPort;

    void onData(Datagram d) {
      final ann = tryDecodeAnnounce(
          utf8.decode(d.data, allowMalformed: true));
      if (ann == null) return;
      if (selfDeviceId.isNotEmpty && ann.deviceId == selfDeviceId) return;
      found['${d.address.address}|${ann.deviceId}|${ann.httpPort}'] = FoundHost(
        ip: d.address.address,
        deviceId: ann.deviceId,
        name: ann.name,
        httpPort: ann.httpPort,
      );
    }

    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final d = socket.receive();
        if (d == null) break;
        onData(d);
      }
    });

    try {
      // 先发探测引导主机即时应答（广播可能丢，多发几次）。
      for (var i = 0; i < probeCount; i++) {
        try {
          socket.send(probeBytes, target, targetPort);
        } catch (_) {}
        if (i < probeCount - 1) {
          await Future<void>.delayed(probeGap);
        }
      }
      // 剩余窗口收听广播与应答。
      final remain = window -
          probeGap * ((probeCount - 1).clamp(0, probeCount - 1));
      if (remain > Duration.zero) {
        await Future<void>.delayed(remain);
      }
    } finally {
      _socket = null;
      await sub.cancel();
      socket.close(); // RawDatagramSocket.close() 为同步 void
    }
    return found.values.toList();
  }
}
