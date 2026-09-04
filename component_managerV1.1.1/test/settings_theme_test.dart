import 'dart:io';

import 'package:component_manager/core/config/constants.dart';
import 'package:component_manager/core/database/app_database.dart';
import 'package:component_manager/core/services/settings_store.dart';
import 'package:component_manager/main.dart';
import 'package:component_manager/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 黑夜模式 + settings 表：存取/迁移/切换持久化/启动应用。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 让出真实事件循环 + 推进帧（DB 读写走 runAsync）。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  group('SettingsStore', () {
    test('新库含 settings 表；get 缺省 null，set/get/replace 生效', () async {
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final store = SettingsStore(db);

      expect(await store.get('any'), isNull);
      expect(await store.loadThemeMode(), 'light'); // 缺省亮色

      await store.saveThemeMode('dark');
      expect(await store.loadThemeMode(), 'dark');
      await store.saveThemeMode('light'); // replace 覆盖
      expect(await store.loadThemeMode(), 'light');
    });

    test('lastHost：缺省全 null', () async {
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final store = SettingsStore(db);
      final last = await store.loadLastHost();
      expect(last.ip, isNull);
      expect(last.port, isNull);
      expect(last.name, isNull);
      expect(last.token, isNull);
    });

    test('lastHost：save/load 往返（含名称令牌）', () async {
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final store = SettingsStore(db);

      await store.saveLastHost(ip: '192.168.1.50', port: 9000, name: '书房主机', token: 'tok-1');
      final last = await store.loadLastHost();
      expect(last.ip, '192.168.1.50');
      expect(last.port, 9000);
      expect(last.name, '书房主机');
      expect(last.token, 'tok-1');

      // 再次保存覆盖（端口非默认 → 记忆端口优先于配置 8321）
      await store.saveLastHost(ip: '192.168.1.51', port: 8321);
      final last2 = await store.loadLastHost();
      expect(last2.ip, '192.168.1.51');
      expect(last2.port, 8321);
      expect(last2.name, '书房主机'); // 未更新则保留旧名
    });

    test('lastHost：token/name 为空不写、不清旧值', () async {
      final db = await AppDatabase.openAt(inMemoryDatabasePath);
      addTearDown(db.close);
      final store = SettingsStore(db);

      await store.saveLastHost(ip: '192.168.1.60', port: 8321, name: '主机', token: 'tok-9');
      await store.saveLastHost(ip: '192.168.1.61', port: 8321); // 不给 name/token
      final last = await store.loadLastHost();
      expect(last.ip, '192.168.1.61');
      expect(last.name, '主机');
      expect(last.token, 'tok-9');
    });

    test('v2 旧库（无 settings）升级到当前版本：补建 settings 表且数据保留', () async {
      final dir = await Directory.systemTemp.createTemp('cmp_sett_mig');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'v2.db');

      // 手工构建 v2 库：有 deleted_at、无 settings 表
      final raw = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE components(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                cid TEXT UNIQUE NOT NULL,
                model TEXT NOT NULL,
                category TEXT NOT NULL,
                package TEXT,
                quantity INTEGER NOT NULL DEFAULT 0,
                location TEXT,
                note TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                deleted_at INTEGER
              )
            ''');
          },
        ),
      );
      await raw.insert('components', {
        'cid': 'C999',
        'model': 'M',
        'category': '其他',
        'quantity': 1,
        'created_at': 1,
        'updated_at': 1,
      });
      await raw.close();

      final db = await AppDatabase.openAt(path);
      addTearDown(db.close);
      expect(await db.getVersion(), migrationVersion);
      // settings 表已建，可存取
      final store = SettingsStore(db);
      await store.saveThemeMode('dark');
      expect(await store.loadThemeMode(), 'dark');
      // 原数据保留
      final rows = await db.query('components');
      expect(rows.single['cid'], 'C999');
    });
  });

  group('黑夜模式', () {
    testWidgets('右上角开关切换主题并持久化；重启后恢复', (tester) async {
      final db =
          (await tester.runAsync(() => AppDatabase.openAt(inMemoryDatabasePath)))!;
      addTearDown(db.close);
      final state = AppState(db);

      await tester.pumpWidget(ComponentManagerApp(state));
      await settle(tester);

      Brightness brightness() => Theme.of(
              tester.element(find.byType(HomeScreen).first))
          .brightness;
      expect(brightness(), Brightness.light);

      // 右上角切换到黑夜
      await tester.tap(find.byTooltip('切换到黑夜模式'));
      await settle(tester);
      expect(brightness(), Brightness.dark);
      expect(find.byTooltip('切换到亮色'), findsOneWidget);
      // 已持久化
      final saved = await tester.runAsync(() => state.settings.loadThemeMode());
      expect(saved, 'dark');

      // 模拟重启：新 AppState 载入持久化主题
      final state2 = AppState(db);
      await tester.runAsync(() => state2.loadPersistedTheme());
      expect(state2.themeMode.value, ThemeMode.dark);

      // 切回亮色并持久化
      await tester.tap(find.byTooltip('切换到亮色'));
      await settle(tester);
      expect(brightness(), Brightness.light);
      final saved2 = await tester.runAsync(() => state.settings.loadThemeMode());
      expect(saved2, 'light');
    });
  });
}
