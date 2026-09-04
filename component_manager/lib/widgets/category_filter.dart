import 'package:flutter/material.dart';

import '../utils/category_recognizer.dart';

/// 分类筛选下拉菜单（顶部工具栏用，紧凑样式）。
///
/// 选项来自 [AppCategories.filterOptions]：
/// 全部 / 电阻 / 电容 / IC / 二极管 / 三极管 / 连接器 / 晶振 / 其他。
class CategoryFilter extends StatelessWidget {
  final String value; // 当前选中的分类（含「全部」）
  final ValueChanged<String> onChanged;

  const CategoryFilter({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          borderRadius: BorderRadius.circular(8),
          padding: const EdgeInsets.symmetric(vertical: 10),
          items: AppCategories.filterOptions
              .map((c) => DropdownMenuItem(
                    value: c,
                    child: Text(c, style: const TextStyle(fontSize: 13)),
                  ))
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
