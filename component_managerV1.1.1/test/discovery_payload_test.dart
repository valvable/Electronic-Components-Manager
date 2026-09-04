import 'package:component_manager/core/services/discovery_payload.dart';
import 'package:flutter_test/flutter_test.dart';

/// 自动发现 UDP 报文编解码：往返 / 非法报容错 / 字段缺省容忍 / 协议版本。
void main() {
  group('encodeAnnounce', () {
    test('含 type/v/device_id/name/http_port，能编解码往返', () {
      final raw = encodeAnnounce(
        deviceId: 'dev-abc',
        name: '书房电脑',
        httpPort: 8321,
      );
      final parsed = tryDecodeAnnounce(raw);
      expect(parsed, isNotNull);
      expect(parsed!.deviceId, 'dev-abc');
      expect(parsed.name, '书房电脑');
      expect(parsed.httpPort, 8321);
    });

    test('非默认 http_port（自定义同步端口）也能往返', () {
      final parsed =
          tryDecodeAnnounce(encodeAnnounce(deviceId: 'd', name: '', httpPort: 9000));
      expect(parsed!.httpPort, 9000);
    });
  });

  group('tryDecodeAnnounce 容错', () {
    test('非 JSON → null', () {
      expect(tryDecodeAnnounce('not json'), isNull);
      expect(tryDecodeAnnounce(''), isNull);
    });

    test('JSON 但不是 Map → null', () {
      expect(tryDecodeAnnounce('[1,2,3]'), isNull);
      expect(tryDecodeAnnounce('"hi"'), isNull);
    });

    test('缺 name 容忍（取空串）', () {
      final parsed = tryDecodeAnnounce(
          '{"type":"cmp_sync","v":1,"device_id":"dev-x","http_port":8321}');
      expect(parsed, isNotNull);
      expect(parsed!.name, '');
    });

    test('type 不符 / v 不符 / 缺 device_id / 缺 http_port → null', () {
      expect(tryDecodeAnnounce('{"type":"other","v":1,"device_id":"d","http_port":1}'),
          isNull);
      expect(tryDecodeAnnounce('{"type":"cmp_sync","v":2,"device_id":"d","http_port":1}'),
          isNull);
      expect(
          tryDecodeAnnounce('{"type":"cmp_sync","v":1,"http_port":1}'), isNull);
      expect(
          tryDecodeAnnounce('{"type":"cmp_sync","v":1,"device_id":"d"}'), isNull);
      // device_id 类型错 / 空；http_port 类型错（字符串）→ 拒绝
      expect(
          tryDecodeAnnounce(
              '{"type":"cmp_sync","v":1,"device_id":7,"http_port":1}'),
          isNull);
      expect(
          tryDecodeAnnounce(
              '{"type":"cmp_sync","v":1,"device_id":"","http_port":1}'),
          isNull);
      expect(
          tryDecodeAnnounce(
              '{"type":"cmp_sync","v":1,"device_id":"d","http_port":"8321"}'),
          isNull);
    });
  });

  group('probe', () {
    test('encodeProbe 往返可被 isProbe 识别', () {
      final raw = encodeProbe();
      expect(isProbe(raw), isTrue);
    });

    test('公告 / 噪音 / 错 v 不是 probe', () {
      expect(isProbe(encodeAnnounce(deviceId: 'd', name: '', httpPort: 1)), isFalse);
      expect(isProbe('noise'), isFalse);
      expect(isProbe('{"type":"cmp_sync_probe","v":2}'), isFalse);
    });
  });
}
