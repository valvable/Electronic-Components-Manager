import 'dart:convert';

/// 局域网自动发现的 UDP 报文编解码（纯逻辑可单测，不碰 socket）。
///
/// 两种报文（UTF-8 JSON，单包 < 1400B）：
/// - 主机广播 / 应答：`{"type":"cmp_sync","v":1,"device_id":…,"name":…,"http_port":8321}`
/// - 客户端探测：    `{"type":"cmp_sync_probe","v":1}`
///
/// 主机收到 probe 只单播回 announcer（防同机两个 announcer 回声死循环），
/// 同时自身周期广播 announcer，供「被动收听」的客户端免探测即可发现。

const String discoveryAnnounceType = 'cmp_sync';
const String discoveryProbeType = 'cmp_sync_probe';
const int discoveryVersion = 1;

/// 一条主机公告的解析结果。[name] 允许为空串（部分设备取不到主机名）。
class DiscoveryAnnounce {
  final String deviceId;
  final String name;
  final int httpPort; // 主机实际 HTTP 同步端口（可能 ≠ 默认 8321）

  const DiscoveryAnnounce({
    required this.deviceId,
    required this.name,
    required this.httpPort,
  });
}

/// 主机公告 → JSON 字符串。
String encodeAnnounce({
  required String deviceId,
  required String name,
  required int httpPort,
}) {
  return jsonEncode({
    'type': discoveryAnnounceType,
    'v': discoveryVersion,
    'device_id': deviceId,
    'name': name,
    'http_port': httpPort,
  });
}

/// 客户端探测报文。
String encodeProbe() =>
    jsonEncode({'type': discoveryProbeType, 'v': discoveryVersion});

/// 解析主机公告；非本协议报文 / 字段缺失返回 null（忽略局域网其它噪音）。
DiscoveryAnnounce? tryDecodeAnnounce(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  if (decoded['type'] != discoveryAnnounceType) return null;
  if (decoded['v'] != discoveryVersion) return null;
  final deviceId = decoded['device_id'];
  final httpPort = decoded['http_port'];
  if (deviceId is! String || deviceId.isEmpty) return null;
  if (httpPort is! int) return null;
  return DiscoveryAnnounce(
    deviceId: deviceId,
    name: (decoded['name'] as String?) ?? '',
    httpPort: httpPort,
  );
}

/// 是否客户端探测报文。
bool isProbe(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return false;
  }
  return decoded is Map<String, dynamic> &&
      decoded['type'] == discoveryProbeType &&
      decoded['v'] == discoveryVersion;
}
