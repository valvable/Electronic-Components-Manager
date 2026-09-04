import 'dart:convert';

import '../../models/bom.dart';
import '../../models/component.dart';

/// 同步载荷：双端全量实体 + 发送时刻本机时间戳（供对方做时间校正）。
class SyncPayload {
  final String deviceId;
  final int clientUstamp; // 发送时刻本机 epoch 秒（时间校正基准）
  final List<Component> components;
  final List<Bom> boms;
  final List<BomItem> bomItems;

  const SyncPayload({
    required this.deviceId,
    required this.clientUstamp,
    required this.components,
    required this.boms,
    required this.bomItems,
  });

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'client_ustamp': clientUstamp,
        'components': components.map((c) => c.toJson()).toList(),
        'boms': boms.map((b) => b.toJson()).toList(),
        'bom_items': bomItems.map((i) => i.toJson()).toList(),
      };

  factory SyncPayload.fromJson(Map<String, dynamic> m) => SyncPayload(
        deviceId: (m['device_id'] as String?) ?? '',
        clientUstamp: (m['client_ustamp'] as num?)?.toInt() ?? 0,
        components: [
          for (final j in (m['components'] as List? ?? const []))
            Component.fromJson(j as Map<String, dynamic>)
        ],
        boms: [
          for (final j in (m['boms'] as List? ?? const []))
            Bom.fromJson(j as Map<String, dynamic>)
        ],
        bomItems: [
          for (final j in (m['bom_items'] as List? ?? const []))
            BomItem.fromJson(j as Map<String, dynamic>)
        ],
      );
}

/// 一条元件冲突（合并方视角：local=本机版本，remote=远端版本，均在合并方时钟下）。
class SyncConflict {
  final String cid;
  final Component local;
  final Component remote;

  const SyncConflict({
    required this.cid,
    required this.local,
    required this.remote,
  });

  Map<String, dynamic> toJson() => {
        'cid': cid,
        'local': local.toJson(),
        'remote': remote.toJson(),
      };

  factory SyncConflict.fromJson(Map<String, dynamic> m) => SyncConflict(
        cid: m['cid'] as String,
        local: Component.fromJson(m['local'] as Map<String, dynamic>),
        remote: Component.fromJson(m['remote'] as Map<String, dynamic>),
      );
}

/// BOM 明细的同步形态：以 bomKey（name@createdAt）+ componentCid 跨设备定位。
class SyncBomItem {
  final String bomKey;
  final String componentCid;
  final int quantity;

  const SyncBomItem({
    required this.bomKey,
    required this.componentCid,
    required this.quantity,
  });

  Map<String, dynamic> toJson() => {
        'bom_key': bomKey,
        'component_cid': componentCid,
        'quantity': quantity,
      };

  factory SyncBomItem.fromJson(Map<String, dynamic> m) => SyncBomItem(
        bomKey: m['bom_key'] as String,
        componentCid: m['component_cid'] as String,
        quantity: (m['quantity'] as num?)?.toInt() ?? 0,
      );
}

/// 冲突裁决：客户端在服务器时钟下算出最终版本，随 choice 一并提交（无状态，
/// 主机只按结果落库，不需要记忆冲突现场）。
class SyncResolution {
  final String cid;
  final String choice; // 'local' | 'remote' | 'both'
  final Component component; // 服务器时钟下的最终版本

  const SyncResolution({
    required this.cid,
    required this.choice,
    required this.component,
  });

  Map<String, dynamic> toJson() => {
        'cid': cid,
        'choice': choice,
        'component': component.toJson(),
      };
}

/// JSON 包进 Base64（弱混淆；真实防护靠令牌 + 仅限可信局域网）。
String encodeBase64Json(Map<String, dynamic> m) =>
    base64Encode(utf8.encode(jsonEncode(m)));

Map<String, dynamic> decodeBase64Json(String b64) =>
    jsonDecode(utf8.decode(base64Decode(b64))) as Map<String, dynamic>;
