import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../main.dart';
import '../../models/bom.dart';
import '../../models/component.dart';
import '../config/constants.dart';
import '../sync/merge_engine.dart';
import '../sync/sync_codec.dart';

/// 同步异常（协议/令牌/网络）。
class SyncException implements Exception {
  final String message;
  const SyncException(this.message);
  @override
  String toString() => message;
}

/// 客户端一次同步的结果。
class SyncResult {
  final int conflictsCount;
  /// 客户端时钟下的冲突（local=本机版本，remote=主机版本，供 UI 裁决）。
  final List<SyncConflict> conflicts;
  /// 客户端 = 主机 + offset（冲突裁决时把主机时钟版本换算成本机时钟）。
  final int offset;

  const SyncResult({
    required this.conflictsCount,
    required this.conflicts,
    required this.offset,
  });
}

/// 局域网同步服务：本机即服务端（HttpServer）+ 客户端（HttpClient）。
///
/// 协议：
/// - GET  /manifest → {schema, schema_version, device_id, server_ustamp}
/// - POST /sync    → {token, payload(Base64)} → {server_ustamp, merged(Base64), conflicts}
/// - POST /resolve → {token, resolutions[]} → {applied}
///
/// 数据流：客户端全量提交 → 主机 merge（LWW + 5 分钟冲突窗口 + 墓碑）→
/// 主机落库并把合并结果（主机时钟）回传 → 客户端换算到本机时钟落库。
/// 冲突裁决无状态：客户端算好最终版本（主机时钟）提交，主机直接落库。
class SyncService extends ChangeNotifier {
  final AppState state;
  String deviceId;
  String token;
  int port;

  HttpServer? _server;
  double _progress = 0; // 主机处理进度
  int _syncCount = 0; // 收到/完成的同步次数
  int _lastSyncAt = 0; // 最近一次同步时刻（本机时钟）
  bool _disposed = false;

  bool get hostRunning => _server != null;
  /// 实际绑定端口（传 port=0 时由系统分配，测试用）。
  int? get boundPort => _server?.port;
  double get progress => _progress;
  int get syncCount => _syncCount;
  int get lastSyncAt => _lastSyncAt;

  SyncService({
    required this.state,
    required this.deviceId,
    this.token = defaultSyncToken,
    this.port = syncPort,
  });

  @override
  void dispose() {
    // 屏幕退出时可能还有在途请求回调（stopHost 是异步的）——
    // dispose 后 notifyListeners 会抛 FlutterError，这里挡住。
    _disposed = true;
    super.dispose();
  }

  void _setProgress(double v) {
    _progress = v;
    if (!_disposed) notifyListeners();
  }

  // ---- 主机 ----

  Future<void> startHost() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handleRequest);
  }

  Future<void> stopHost() async {
    await _server?.close(force: true);
    _server = null;
    _setProgress(0);
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/manifest') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'schema': syncSchemaName,
          'schema_version': syncProtocolVersion,
          'device_id': deviceId,
          'server_ustamp': Component.now(),
        }));
        await res.close();
        return;
      }
      if (req.method == 'POST' && (path == '/sync' || path == '/resolve')) {
        final body = await _readJson(req);
        if (body['token'] != token) {
          res.statusCode = HttpStatus.forbidden;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'error': 'invalid_token'}));
          await res.close();
          return;
        }
        _setProgress(0.2);
        if (path == '/sync') {
          await _handleSync(res, body);
        } else {
          await _handleResolve(res, body);
        }
        return;
      }
      res.statusCode = HttpStatus.notFound;
      await res.close();
    } catch (e) {
      res.statusCode = HttpStatus.internalServerError;
      try {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'error': e.toString()}));
      } catch (_) {}
      await res.close();
    } finally {
      _setProgress(0);
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _handleSync(HttpResponse res, Map<String, dynamic> body) async {
    final payload =
        SyncPayload.fromJson(decodeBase64Json(body['payload'] as String));
    final serverNow = Component.now();
    final offset = serverNow - payload.clientUstamp; // 客户端时钟 → 主机时钟

    final localComponents = await state.components.all(includeDeleted: true);
    final localBoms = await state.boms.listBoms();
    final localBomItems = <BomItem>[];
    for (final b in localBoms) {
      localBomItems.addAll(await state.boms.itemsForBom(b.id!));
    }

    final outcome = merge(
      localComponents: localComponents,
      remoteComponents: payload.components,
      remoteOffsetToLocal: offset,
      localBoms: localBoms,
      remoteBoms: payload.boms,
      localBomItems: localBomItems,
      remoteBomItems: payload.bomItems,
    );

    await _applyOutcome(outcome);

    _syncCount++;
    _lastSyncAt = serverNow;
    _setProgress(0.9);

    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({
      'schema_version': syncProtocolVersion,
      'server_ustamp': serverNow,
      'merged': encodeBase64Json(outcome.toJson()),
      'conflicts': outcome.conflicts.map((c) => c.toJson()).toList(),
    }));
    await res.close();
  }

  Future<void> _handleResolve(HttpResponse res, Map<String, dynamic> body) async {
    final resolutions = [
      for (final j in (body['resolutions'] as List? ?? const []))
        _resolutionFromJson(j as Map<String, dynamic>)
    ];
    for (final r in resolutions) {
      await state.components.syncUpsert(r.component);
    }
    _syncCount++;
    _lastSyncAt = Component.now();
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'applied': resolutions.length}));
    await res.close();
  }

  /// 合并结果落库：元件 syncUpsert（保时间戳）；BOM 按 name@createdAt 定位去重；
  /// 明细行经 cid → 本机 id 映射去重插入。
  Future<void> _applyOutcome(MergeOutcome outcome) async {
    for (final c in outcome.mergedComponents) {
      await state.components.syncUpsert(c);
    }
    final keyToId = <String, int>{};
    for (final b in outcome.mergedBoms) {
      var id = await state.boms.findBomByKey(b.name, b.createdAt);
      id ??= await state.boms.insertBom(b.name, b.createdAt);
      keyToId[bomKey(b)] = id;
    }
    for (final it in outcome.mergedBomItems) {
      final bomId = keyToId[it.bomKey];
      final lookup = await state.components.byCid(it.componentCid);
      final compId = lookup.component?.id;
      if (bomId == null || compId == null) continue;
      await state.boms.insertBomItemIfAbsent(bomId, compId, it.quantity);
    }
  }

  // ---- 客户端 ----

  /// [port] 覆盖默认端口（自动发现/记忆的主机端口可能 ≠ 配置的 [port]）。
  Future<SyncResult> syncFrom(String hostIp, {int? port}) async {
    final client = HttpClient();
    try {
      final base = Uri.parse('http://$hostIp:${port ?? this.port}');

      // 1. manifest 协商：schema 与协议版本一致才继续。
      final manifest = await _getJson(client, base.resolve('/manifest'));
      if (manifest['schema'] != syncSchemaName) {
        throw const SyncException('对方不是元件库存同步服务（schema 不匹配）');
      }
      final remoteVer = (manifest['schema_version'] as num?)?.toInt() ?? 0;
      if (remoteVer != syncProtocolVersion) {
        throw SyncException(
            '同步协议版本不一致：本机 v$syncProtocolVersion，主机 v$remoteVer，请升级应用');
      }

      // 2. 构造本机全量载荷并提交。
      final payload = await _buildPayload();
      final resp = await _postJson(client, base.resolve('/sync'), {
        'token': token,
        'payload': encodeBase64Json(payload.toJson()),
      });
      final serverUstamp = (resp['server_ustamp'] as num).toInt();
      final offset = Component.now() - serverUstamp; // 主机时钟 → 本机时钟
      final outcome =
          MergeOutcome.fromJson(decodeBase64Json(resp['merged'] as String));

      // 3. 合并结果换算到本机时钟并落库。
      await _applyOutcome(shiftOutcome(outcome, offset));

      // 4. 冲突（主机时钟）→ 换算到本机时钟，local=本机版本（payload 里保留的
      //    原始快照），remote=主机版本。
      final conflicts = <SyncConflict>[];
      for (final j in (resp['conflicts'] as List? ?? const [])) {
        final sc = SyncConflict.fromJson(j as Map<String, dynamic>);
        conflicts.add(SyncConflict(
          cid: sc.cid,
          local: _ownVersion(payload, sc.cid),
          remote: shiftTime(sc.local, offset),
        ));
      }

      return SyncResult(
        conflictsCount: conflicts.length,
        conflicts: conflicts,
        offset: offset,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 提交冲突裁决。resolutions 中 component 为主机时钟下的最终版本。
  /// [port] 覆盖默认端口（与 [syncFrom] 保持一致）。
  Future<void> resolveConflicts(
      String hostIp, List<SyncResolution> resolutions,
      {int? port}) async {
    if (resolutions.isEmpty) return;
    final client = HttpClient();
    try {
      final base = Uri.parse('http://$hostIp:${port ?? this.port}');
      final resp = await _postJson(client, base.resolve('/resolve'), {
        'token': token,
        'resolutions': resolutions.map((r) => r.toJson()).toList(),
      });
      if ((resp['applied'] as num?)?.toInt() != resolutions.length) {
        throw const SyncException('冲突裁决未全部生效');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<SyncPayload> _buildPayload() async {
    final components = await state.components.all(includeDeleted: true);
    final boms = await state.boms.listBoms();
    final bomItems = <BomItem>[];
    for (final b in boms) {
      bomItems.addAll(await state.boms.itemsForBom(b.id!));
    }
    return SyncPayload(
      deviceId: deviceId,
      clientUstamp: Component.now(),
      components: components,
      boms: boms,
      bomItems: bomItems,
    );
  }

  /// 冲突的「本机版本」取自己提交时的原始快照（不能读合并后的库）。
  Component _ownVersion(SyncPayload p, String cid) {
    for (final c in p.components) {
      if (c.cid == cid) return c;
    }
    return Component(
        cid: cid, model: '(未知)', category: '其他', createdAt: 0, updatedAt: 0);
  }

  // ---- HTTP 小工具 ----

  Future<Map<String, dynamic>> _getJson(HttpClient client, Uri uri) async {
    final req = await client.getUrl(uri);
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    if (res.statusCode != HttpStatus.ok) {
      throw SyncException('HTTP ${res.statusCode}');
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(
      HttpClient client, Uri uri, Map<String, dynamic> body) async {
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    if (res.statusCode != HttpStatus.ok) {
      throw SyncException(_friendlyError(res.statusCode, text));
    }
    if (text.isEmpty) return const {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  String _friendlyError(int status, String text) {
    if (status == HttpStatus.forbidden) return '同步令牌不匹配';
    if (status == HttpStatus.notFound) return '主机没有同步服务（404）';
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      final err = j['error'] as String?;
      if (err != null && err.isNotEmpty) return err;
    } catch (_) {}
    return 'HTTP $status';
  }
}

/// 服务器端反序列化裁决（不公开 in toJson 之外，收包用）。
SyncResolution _resolutionFromJson(Map<String, dynamic> m) => SyncResolution(
      cid: m['cid'] as String,
      choice: m['choice'] as String,
      component: Component.fromJson(m['component'] as Map<String, dynamic>),
    );
