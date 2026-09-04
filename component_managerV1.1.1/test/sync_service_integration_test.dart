import 'dart:io';

import 'package:component_manager/core/config/constants.dart';
import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/core/services/sync_service.dart';
import 'package:component_manager/core/sync/merge_engine.dart';
import 'package:component_manager/core/sync/sync_codec.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/models/component.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 端到端：真实 HttpServer + HttpClient 跑通 主机↔客户端 全流程
/// （manifest 协商 → 全量提交 → 主机合并落库 → 结果回传 → 客户端落库 → 冲突裁决）。
void main() {
  late Database hostDb;
  late Database clientDb;
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    // 注意：不能共用 inMemoryDatabasePath——sqflite 按路径缓存连接，两个
    // ':memory:' 会拿到同一个库，导致「两侧内容已一致、判不出冲突」。
    tmp = await Directory.systemTemp.createTemp('cmp_sync_test');
    hostDb = await AppDatabase.openAt(p.join(tmp.path, 'host.db'));
    clientDb = await AppDatabase.openAt(p.join(tmp.path, 'client.db'));
  });

  tearDown(() async {
    await hostDb.close();
    await clientDb.close();
    await tmp.delete(recursive: true);
  });

  Component c({required String cid, required int qty}) => Component(
        cid: cid,
        model: 'M-$cid',
        category: '其他',
        quantity: qty,
        createdAt: Component.now(),
        updatedAt: Component.now(),
      );

  test('双向合并 + 冲突检测 + 保留两者裁决', () async {
    final hostRepo = ComponentRepository(hostDb);
    await hostRepo.syncUpsert(c(cid: 'C001', qty: 1));

    final clientRepo = ComponentRepository(clientDb);
    await clientRepo.syncUpsert(c(cid: 'C001', qty: 5)); // 与主机内容不同、时间相近
    await clientRepo.syncUpsert(c(cid: 'C002', qty: 2)); // 仅客户端有

    final host = SyncService(state: AppState(hostDb), deviceId: 'dev-host', port: 0);
    await host.startHost();
    addTearDown(() => host.stopHost());
    final port = host.boundPort!;

    final client = SyncService(
        state: AppState(clientDb), deviceId: 'dev-client', port: port);
    final result = await client.syncFrom('127.0.0.1');

    // 冲突：C001 内容互异且在 5 分钟窗口内
    expect(result.conflictsCount, 1);
    expect(result.conflicts.single.cid, 'C001');
    expect(result.conflicts.single.local.quantity, 5); // 本机（客户端）
    expect(result.conflicts.single.remote.quantity, 1); // 远端（主机）

    // 主机已采纳客户端独有 C002
    expect((await hostRepo.byCid('C002')).status, LookupStatus.active);

    // 裁决「保留两者」→ 1 + 5 = 6
    final offset = result.offset;
    final clientOwn = result.conflicts.single.local;
    final hostVer = result.conflicts.single.remote;
    final localChosen = mergeBoth(clientOwn, hostVer);
    final serverChosen = mergeBoth(
      shiftTime(clientOwn, -offset),
      shiftTime(hostVer, -offset),
    );
    await client.resolveConflicts('127.0.0.1', [
      SyncResolution(cid: 'C001', choice: 'both', component: serverChosen),
    ]);
    await clientRepo.syncUpsert(localChosen);

    expect((await hostRepo.byCid('C001')).component!.quantity, 6);
    expect((await clientRepo.byCid('C001')).component!.quantity, 6);
  });

  test('客户端配置端口 ≠ 主机实际端口时，显式 port 参数可连通（自动发现路径）',
      () async {
    final hostRepo = ComponentRepository(hostDb);
    await hostRepo.syncUpsert(c(cid: 'C100', qty: 3));

    final host = SyncService(state: AppState(hostDb), deviceId: 'dev-host', port: 0);
    await host.startHost();
    addTearDown(() => host.stopHost());
    // 自动发现/记忆会回传主机实际绑定端口（非默认 8321），客户端用 port 覆盖。
    final actualPort = host.boundPort!;
    expect(actualPort, isNot(syncPort));

    final client = SyncService(
        state: AppState(clientDb),
        deviceId: 'dev-client',
        port: syncPort // 故意保持默认，验证 port 覆盖生效
        );
    final result = await client.syncFrom('127.0.0.1', port: actualPort);
    expect(result.conflictsCount, 0);
    // 主机数据已同步进客户端
    expect((await ComponentRepository(clientDb).byCid('C100')).status,
        LookupStatus.active);

    // resolveConflicts 同样走 port 覆盖（空裁决列表直接 no-op，证明不炸即可）
    await client.resolveConflicts('127.0.0.1', const [], port: actualPort);
  });
}
