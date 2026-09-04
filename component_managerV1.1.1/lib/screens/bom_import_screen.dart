import 'package:flutter/material.dart';

/// BOM 导入与库存对比页面（第二阶段实现，当前为占位页）。
///
/// 第二阶段规划：
/// 1. 导入 Excel(.xlsx) / CSV 格式 BOM 表（列名可配置：型号、数量）；
/// 2. 与本地库存按型号/CID 对比：库存充足 / 缺货 X 个 / 待采购；
/// 3. 对比结果表格展示 + 一键导出报告。
///
/// 数据库 `boms` / `bom_items` 表已在第一阶段建好，模型见 `models/bom.dart`。
class BOMImportScreen extends StatelessWidget {
  const BOMImportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BOM 库存对比')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.table_chart_outlined,
                  size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              const Text(
                'BOM 导入与库存对比',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '第二阶段功能：\n'
                '· 导入 Excel(.xlsx) / CSV 格式 BOM 表\n'
                '· 自动对比库存：库存充足 / 缺货 X 个 / 待采购\n'
                '· 对比结果表格展示，支持一键导出报告',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.8),
              ),
              const SizedBox(height: 16),
              const Chip(
                avatar: Icon(Icons.schedule, size: 16),
                label: Text('第二阶段开发中'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
