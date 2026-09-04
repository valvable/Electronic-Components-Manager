import 'dart:io';

import 'package:component_manager/core/services/lan_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

/// UDP 自动发现 loopback 集成：Announcer + Scanner 同一台机真实走一遍
/// probe→单播应答。socket 必须 try/finally 关（挂起头号来源）。
void main() {
  test('Scanner 能发现同机 Announcer（含显示名与 http 端口）', () async {
    final announcer = await DiscoveryAnnouncer.start(
      deviceId: 'dev-host-abc',
      httpPort: 9123, // 非默认端口：证明广播端口贯通
      listenPort: 0, // 系统分配，避免撞默认 8322
      bindAddress: '127.0.0.1',
      name: '测试主机',
      // 本测试只依赖 probe→单播应答，周期广播用极长时间避免向真实局域网发包。
      interval: const Duration(days: 1),
    );
    try {
      final hosts = await DiscoveryScanner().discover(
        window: const Duration(milliseconds: 800),
        probeCount: 3,
        probeGap: const Duration(milliseconds: 80),
        sendTarget: InternetAddress('127.0.0.1'),
        sendTargetPort: announcer.boundPort!,
      );
      expect(hosts, hasLength(1));
      final host = hosts.single;
      expect(host.ip, '127.0.0.1');
      expect(host.deviceId, 'dev-host-abc');
      expect(host.name, '测试主机');
      expect(host.httpPort, 9123);
      expect(host.label, '测试主机'); // name 优先
    } finally {
      await announcer.stop();
    }
  });

  test('selfDeviceId 与主机一致 → 自己不进列表', () async {
    final announcer = await DiscoveryAnnouncer.start(
      deviceId: 'dev-self',
      httpPort: 8321,
      listenPort: 0,
      bindAddress: '127.0.0.1',
      name: '自己',
      interval: const Duration(days: 1),
    );
    try {
      final hosts = await DiscoveryScanner().discover(
        selfDeviceId: 'dev-self',
        window: const Duration(milliseconds: 800),
        probeCount: 3,
        probeGap: const Duration(milliseconds: 80),
        sendTarget: InternetAddress('127.0.0.1'),
        sendTargetPort: announcer.boundPort!,
      );
      expect(hosts, isEmpty);
    } finally {
      await announcer.stop();
    }
  });

  test('无 announcer 时发现超时为空列表，socket 不泄漏', () async {
    final hosts = await DiscoveryScanner().discover(
      window: const Duration(milliseconds: 300),
      probeCount: 1,
      sendTarget: InternetAddress('127.0.0.1'),
      sendTargetPort: 1, // 无人监听 → 无应答
    );
    expect(hosts, isEmpty);
  });
}
