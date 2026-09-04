import 'dart:math';

import 'package:sqflite/sqflite.dart';

/// 设备标识：首次运行生成并持久化到 DB 的 sync_meta 表。
/// 表用 CREATE TABLE IF NOT EXISTS 惰性建立，不触碰 schema 版本号。
class DeviceIdentity {
  static const _table = 'sync_meta';

  static Future<String> getDeviceId(Database db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS $_table (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    final rows = await db.query(
      _table,
      where: 'key = ?',
      whereArgs: ['device_id'],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first['value'] as String;
    final id = _generate();
    await db.insert(_table, {'key': 'device_id', 'value': id});
    return id;
  }

  static String _generate() {
    final rnd = Random();
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final suffix = rnd.nextInt(0x1fffff).toRadixString(16);
    return 'dev-$stamp-$suffix';
  }
}
