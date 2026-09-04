import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database/database_helper.dart';
import 'screens/home_screen.dart';

/// 应用入口。
///
/// 关键点：sqflite 官方实现仅支持 Android/iOS，
/// Windows/Linux 桌面端必须切换为 sqflite_common_ffi（基于 SQLite FFI）实现。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端（Windows/Linux）数据库初始化
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // 预热数据库（首次启动建表），失败时打印日志并继续启动，
  // 后续数据库操作会各自抛错并给出用户提示。
  try {
    await DatabaseHelper.instance.database;
  } catch (e) {
    debugPrint('数据库初始化失败：$e');
  }

  runApp(const ComponentManagerApp());
}

/// 根组件：Material 3 + 蓝色系主色（#1565C0）+ 紧凑视觉密度。
class ComponentManagerApp extends StatelessWidget {
  const ComponentManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1565C0),
    ).copyWith(primary: const Color(0xFF1565C0));

    return MaterialApp(
      title: '元件库存管理',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        visualDensity: VisualDensity.compact,
        inputDecorationTheme: InputDecorationTheme(
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
