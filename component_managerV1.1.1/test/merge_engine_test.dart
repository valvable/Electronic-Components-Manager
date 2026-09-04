import 'dart:convert';

import 'package:component_manager/core/sync/merge_engine.dart';
import 'package:component_manager/core/sync/sync_codec.dart';
import 'package:component_manager/models/bom.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';

Component c({
  required String cid,
  String model = 'M',
  int qty = 0,
  required int updatedAt,
  int? deletedAt,
  int? id = 1,
}) =>
    Component(
      id: id,
      cid: cid,
      model: model,
      category: '其他',
      quantity: qty,
      createdAt: updatedAt - 100,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    );

MergeOutcome run({
  required List<Component> local,
  required List<Component> remote,
  int offset = 0,
  List<Bom>? localBoms,
  List<Bom>? remoteBoms,
  List<BomItem>? localItems,
  List<BomItem>? remoteItems,
}) =>
    merge(
      localComponents: local,
      remoteComponents: remote,
      remoteOffsetToLocal: offset,
      localBoms: localBoms ?? const [],
      remoteBoms: remoteBoms ?? const [],
      localBomItems: localItems ?? const [],
      remoteBomItems: remoteItems ?? const [],
    );

void main() {
  group('LWW 单侧', () {
    test('远端独有：采纳并校正时间戳', () {
      final out = run(local: [], remote: [c(cid: 'A', qty: 3, updatedAt: 100)],
          offset: 50);
      final a = out.mergedComponents.single;
      expect(a.cid, 'A');
      expect(a.quantity, 3);
      expect(a.updatedAt, 150); // 100 + 50 偏移校正
      expect(out.conflicts, isEmpty);
    });

    test('本机独有：原样保留', () {
      final out = run(local: [c(cid: 'A', qty: 3, updatedAt: 100)], remote: []);
      expect(out.mergedComponents.single.quantity, 3);
      expect(out.mergedComponents.single.id, 1);
      expect(out.conflicts, isEmpty);
    });
  });

  group('LWW 双侧', () {
    test('远端 updated_at 更晚（窗口外）→ 远端胜出', () {
      final out = run(
        local: [c(cid: 'A', qty: 1, updatedAt: 10)],
        remote: [c(cid: 'A', qty: 9, updatedAt: 2000)],
      );
      expect(out.mergedComponents.single.quantity, 9);
      expect(out.conflicts, isEmpty);
    });

    test('本机 updated_at 更晚（窗口外）→ 本机胜出', () {
      final out = run(
        local: [c(cid: 'A', qty: 1, updatedAt: 2000)],
        remote: [c(cid: 'A', qty: 9, updatedAt: 10)],
      );
      expect(out.mergedComponents.single.quantity, 1);
    });

    test('时钟偏移校正后远端胜出', () {
      // 远端时钟比本机慢 50 秒：远端 updatedAt=100 → 校正 150 > 本机 120
      final out = run(
        local: [c(cid: 'A', qty: 1, updatedAt: 120)],
        remote: [c(cid: 'A', qty: 9, updatedAt: 100)],
        offset: 50,
      );
      expect(out.mergedComponents.single.quantity, 9);
    });
  });

  group('冲突', () {
    test('5 分钟内双侧修改且内容不同 → 冲突，merged 默认落 LWW 胜者', () {
      final out = run(
        local: [c(cid: 'A', qty: 1, updatedAt: 100)],
        remote: [c(cid: 'A', qty: 9, updatedAt: 160)],
      );
      expect(out.conflicts, hasLength(1));
      final cf = out.conflicts.single;
      expect(cf.cid, 'A');
      expect(cf.local.quantity, 1); // 本机版本
      expect(cf.remote.quantity, 9); // 远端版本（已校正）
      expect(out.mergedComponents.single.quantity, 9); // LWW 兜底
    });

    test('内容一致不判冲突', () {
      final out = run(
        local: [c(cid: 'A', qty: 5, updatedAt: 100)],
        remote: [c(cid: 'A', qty: 5, updatedAt: 120)],
      );
      expect(out.conflicts, isEmpty);
      expect(out.mergedComponents.single.quantity, 5);
    });

    test('mergeBoth：数量相加、时间取新、任一侧未删则恢复', () {
      final m = mergeBoth(
        c(cid: 'A', qty: 1, updatedAt: 100, deletedAt: 100),
        c(cid: 'A', qty: 4, updatedAt: 500),
      );
      expect(m.quantity, 5);
      expect(m.updatedAt, 500);
      expect(m.isDeleted, isFalse);
      expect(m.createdAt, 0); // min(0, 400)
      expect(m.id, isNull);
    });

    test('两侧都软删 → 保留较晚墓碑', () {
      final m = mergeBoth(
        c(cid: 'A', qty: 1, updatedAt: 100, deletedAt: 100),
        c(cid: 'A', qty: 2, updatedAt: 300, deletedAt: 300),
      );
      expect(m.isDeleted, isTrue);
      expect(m.deletedAt, 300);
    });
  });

  group('墓碑传播', () {
    test('远端软删传播到本机', () {
      final out = run(
        local: [c(cid: 'A', qty: 1, updatedAt: 100)],
        remote: [c(cid: 'A', qty: 1, updatedAt: 400, deletedAt: 400)],
      );
      expect(out.mergedComponents.single.isDeleted, isTrue);
    });

    test('远端独有已删条目也被采纳', () {
      final out = run(local: [], remote: [
        c(cid: 'A', qty: 1, updatedAt: 100, deletedAt: 100)
      ]);
      expect(out.mergedComponents.single.isDeleted, isTrue);
    });
  });

  group('BOM 并集', () {
    test('单据按 name@createdAt 去重，明细按行去重取最大数量', () {
      final out = run(
        local: [c(cid: 'A', qty: 5, updatedAt: 100)],
        remote: [c(cid: 'A', qty: 5, updatedAt: 100)],
        localBoms: [const Bom(id: 1, name: 'B', createdAt: 100)],
        remoteBoms: [
          const Bom(id: 9, name: 'B', createdAt: 100),
          const Bom(id: 10, name: 'C', createdAt: 200),
        ],
        localItems: [
          const BomItem(id: 1, bomId: 1, componentId: 1, quantity: 5)
        ],
        remoteItems: [
          const BomItem(id: 2, bomId: 9, componentId: 1, quantity: 5),
          const BomItem(id: 3, bomId: 10, componentId: 1, quantity: 8),
        ],
      );
      expect(out.mergedBoms.length, 2); // B 去重，C 采用
      expect(out.mergedBoms.any((b) => b.name == 'C'), isTrue);
      expect(out.mergedBomItems.length, 2);
      final bItems =
          out.mergedBomItems.where((i) => i.bomKey == 'B@100').toList();
      expect(bItems, hasLength(1)); // 双侧同一行合并为一条
      expect(bItems.single.quantity, 5);
    });

    test('同一行数量不同 → 取最大', () {
      final out = run(
        local: [c(cid: 'A', qty: 5, updatedAt: 100)],
        remote: [c(cid: 'A', qty: 5, updatedAt: 100)],
        localBoms: [const Bom(id: 1, name: 'B', createdAt: 100)],
        remoteBoms: [const Bom(id: 2, name: 'B', createdAt: 100)],
        localItems: [
          const BomItem(id: 1, bomId: 1, componentId: 1, quantity: 5)
        ],
        remoteItems: [
          const BomItem(id: 2, bomId: 2, componentId: 1, quantity: 8)
        ],
      );
      final item = out.mergedBomItems.single;
      expect(item.componentCid, 'A');
      expect(item.quantity, 8);
    });

    test('远端独有 BOM 时间戳校正到本机', () {
      final out = run(
        local: [],
        remote: [],
        remoteBoms: [const Bom(id: 5, name: 'D', createdAt: 200)],
        offset: 30,
      );
      final d = out.mergedBoms.single;
      expect(d.name, 'D');
      expect(d.createdAt, 230);
    });
  });

  group('时间换算与序列化', () {
    test('toLocalTime 偏移换算', () {
      // 远端在 T=1000 发送，本机此刻 1100 → 偏移 +100
      expect(toLocalTime(1200, remoteUstamp: 1000, localNow: 1100), 1300);
    });

    test('shiftOutcome 整体平移（客户端把主机结果换算到本机时钟）', () {
      final o = MergeOutcome(
        mergedComponents: [c(cid: 'A', qty: 2, updatedAt: 100)],
        mergedBoms: const [Bom(id: 1, name: 'B', createdAt: 100)],
        mergedBomItems: const [],
      );
      final shifted = shiftOutcome(o, 50);
      expect(shifted.mergedComponents.single.updatedAt, 150);
      expect(shifted.mergedBoms.single.createdAt, 150);
    });

    test('MergeOutcome JSON 往返（走 Base64 通道）', () {
      final o = MergeOutcome(
        mergedComponents: [c(cid: 'A', qty: 2, updatedAt: 100)],
        mergedBoms: const [Bom(id: 1, name: 'B', createdAt: 100)],
        mergedBomItems: const [
          SyncBomItem(bomKey: 'B@100', componentCid: 'A', quantity: 2)
        ],
      );
      final json = jsonDecode(utf8.decode(
              base64Decode(encodeBase64Json(o.toJson()))))
          as Map<String, dynamic>;
      final back = MergeOutcome.fromJson(json);
      expect(back.mergedComponents.single.cid, 'A');
      expect(back.mergedBoms.single.name, 'B');
      expect(back.mergedBomItems.single.quantity, 2);
    });

    test('SyncPayload JSON 往返', () {
      final p = SyncPayload(
        deviceId: 'dev-x',
        clientUstamp: 123,
        components: [c(cid: 'A', qty: 2, updatedAt: 100)],
        boms: const [Bom(id: 1, name: 'B', createdAt: 50)],
        bomItems: const [
          BomItem(id: 1, bomId: 1, componentId: 1, quantity: 3)
        ],
      );
      final back = SyncPayload.fromJson(
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.deviceId, 'dev-x');
      expect(back.clientUstamp, 123);
      expect(back.components.single.cid, 'A');
      expect(back.bomItems.single.quantity, 3);
    });
  });
}
