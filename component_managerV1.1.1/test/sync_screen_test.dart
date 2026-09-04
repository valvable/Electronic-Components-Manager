import 'dart:io';

import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/component_repository.dart';
import 'package:component_manager/core/services/lan_discovery.dart';
import 'package:component_manager/core/services/sync_service.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/models/component.dart';
import 'package:component_manager/screens/sync_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// SyncScreen：上次主机记忆回填 + 自动发现（注入 seam）点按同步全链路。
void main() {
  Future<void> settle(WidgetTester tester,
      {int iterations = 40}) async {
    for (var i = 0; i < iterations; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  String fieldText(WidgetTester tester, String label) =>
      tester
          .widgetList<TextField>(find.byType(TextField))
          .firstWhere((t) => t.decoration?.labelText == label)
          .controller!
          .text;

  Future<void> openFfi() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  testWidgets('上次主机已记忆 → 进页自动回填 IP/端口/令牌', (tester) async {
    await openFfi();
    final db = (await tester.runAsync(
        () => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);
    final state = AppState(db);
    // 预置一次成功同步的记忆
    await tester.runAsync(() => state.settings.saveLastHost(
        ip: '192.168.1.88', port: 9001, name: '客厅主机', token: 'mem-tok'));

    await tester.pumpWidget(MaterialApp(home: SyncScreen(state: state)));
    await settle(tester);

    expect(fieldText(tester, '主机 IP'), '192.168.1.88');
    expect(fieldText(tester, '同步令牌'), 'mem-tok');
    expect(find.textContaining('客厅主机'), findsOneWidget); // helper 提示上次同步
  });

  testWidgets('无记忆主机 → IP 框为空、无上次同步提示', (tester) async {
    await openFfi();
    final db = (await tester.runAsync(
        () => AppDatabase.openAt(inMemoryDatabasePath)))!;
    addTearDown(db.close);

    await tester.pumpWidget(MaterialApp(home: SyncScreen(state: AppState(db))));
    await settle(tester);
    expect(fieldText(tester, '主机 IP'), isEmpty);
    expect(find.textContaining('上次同步'), findsNothing);
  });

  testWidgets('自动发现出主机 → 点按 → 经广播端口同步并记住主机', (tester) async {
    await openFfi();
    // flutter_test 默认把真实 HTTP 换成 400 mock——本测试要真实回环同步，清掉。
    HttpOverrides.global = null;
    // 主机库独立文件（widget 的客户端库不能与主机共用路径，否则两侧同一库判不出变化）
    final tmp =
        (await tester.runAsync(() => Directory.systemTemp.createTemp('cmp_screen')))!;
    final hostDb = (await tester.runAsync(
        () => AppDatabase.openAt(p.join(tmp.path, 'host.db'))))!;
    final clientDb = (await tester.runAsync(
        () => AppDatabase.openAt(p.join(tmp.path, 'client.db'))))!;
    addTearDown(() async {
      await hostDb.close();
      await clientDb.close();
      await tmp.delete(recursive: true);
    });

    final hostRepo = ComponentRepository(hostDb);
    await tester.runAsync(() => hostRepo.syncUpsert(Component(
          cid: 'C200',
          model: 'STM32F103C8T6',
          category: 'MCU',
          quantity: 10,
          createdAt: Component.now(),
          updatedAt: Component.now(),
        )));

    // 真实主机 HTTP 服务（port:0 → 系统分配；发现广播应指向实际端口而非默认 8321）
    final host = SyncService(state: AppState(hostDb), deviceId: 'dev-host', port: 0);
    await tester.runAsync(() => host.startHost());
    addTearDown(() => host.stopHost());
    final actualPort = host.boundPort!;

    final clientState = AppState(clientDb);
    // 注入发现源，返回真实主机的 ip:实际端口（模拟 UDP 发现结果）
    await tester.pumpWidget(MaterialApp(
      home: SyncScreen(
        state: clientState,
        discoverHosts: () async => [
          FoundHost(
              ip: '127.0.0.1',
              deviceId: 'dev-host',
              name: '测试主机',
              httpPort: actualPort),
        ],
      ),
    ));
    await settle(tester);

    // 点「自动发现主机」
    await tester.tap(find.text('自动发现主机'));
    await settle(tester, iterations: 10);
    expect(find.text('测试主机'), findsOneWidget);

    // 点按主机 → 回填 IP 并开始同步（走发现端口而非默认 8321）
    await tester.tap(find.text('测试主机'));
    await settle(tester);
    expect(fieldText(tester, '主机 IP'), '127.0.0.1');
    expect(find.textContaining('同步完成'), findsWidgets);

    // 成功才记忆主机
    final last = await tester.runAsync(() => clientState.settings.loadLastHost());
    expect(last!.ip, '127.0.0.1');

    // 主机数据已并入客户端
    final pulled = await tester.runAsync(
        () async => (await ComponentRepository(clientDb).byCid('C200')).component);
    expect(pulled!.model, 'STM32F103C8T6');
    expect(pulled.quantity, 10);
  });
}
