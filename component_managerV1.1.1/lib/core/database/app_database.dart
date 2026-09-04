import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../config/constants.dart';
import 'migration.dart';

/// 数据库入口：平台分支初始化 + 打开数据库。
///
/// - Windows 桌面：sqflite 本身仅支持 Android/iOS，必须用 sqflite_common_ffi
///   的 databaseFactoryFfi，否则丢 MissingPluginException。
/// - Android：走原生 sqflite factory。
/// - 数据库文件位置：桌面 getApplicationSupportDirectory，Android getDatabasesPath。
class AppDatabase {
  AppDatabase._();

  static Database? _db;

  /// 必须在任何仓储使用前调用一次（main 里）。可重复调用，幂等。
  static Future<void> init() async {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  static String get dbFileName => 'component_manager.db';

  /// 打开（若已打开直接返回同一实例）。
  static Future<Database> open() async {
    if (_db != null) return _db!;
    await init();

    final bool desktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    final String dir = desktop
        ? (await getApplicationSupportDirectory()).path
        : await getDatabasesPath();

    return openAt(p.join(dir, dbFileName));
  }

  /// 在指定路径打开数据库，复用与生产完全一致的建表 SQL（[onCreate]）与
  /// 外键开启（[onConfigure] PRAGMA foreign_keys=ON）——由 [open] 与测试共用，
  /// 保证测试里 RESTRICT/CASCADE 行为与真实环境一致（用户审查 #1）。
  static Future<Database> openAt(String path) async {
    await init();
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: migrationVersion,
        onCreate: onCreate,
        onUpgrade: onUpgrade,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys=ON'),
      ),
    );
  }

  /// 当前数据库实例（未打开时先打开）。
  static Future<Database> get instance async => open();

  /// 仅供测试 / 备份恢复场景：关闭后由调用方重新 open。
  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}