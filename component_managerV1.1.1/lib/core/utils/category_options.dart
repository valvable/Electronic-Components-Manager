/// 分类选项统一数据源：系统 29 类 + 用户自创分类。
///
/// 所有分类下拉 / AI 分类 allowed 清单 / 分类卡片页都用这里，保证口径一致：
/// - [loadCategoryOptions]：设置库 → 自创列表，合并进系统 29 类（自创去重去空，
///   且剔除与系统 29 类重名的脏数据）。
/// - [optionsIncluding]：下拉的 items 始终包含当前值（跨设备同步来的陌生分类名、
///   已删自创分类的回收站行等）——防止 DropdownButton 值不在 items 里触发断言。
library;

import '../config/constants.dart';
import '../services/settings_store.dart';

/// 系统 29 类 + 自创分类（自创里与系统重名/空名的会被滤掉）。
Future<List<String>> loadCategoryOptions(SettingsStore store) async {
  final customs = await store.loadCustomCategories();
  final reserved = <String>{...inventoryCategories};
  final extra = <String>[];
  for (final name in customs) {
    final t = name.trim();
    if (t.isEmpty || reserved.contains(t)) continue;
    reserved.add(t);
    extra.add(t);
  }
  return [...inventoryCategories, ...extra];
}

/// 返回 [options] 的副本，保证包含 [value]（不存在则追加到末尾）。
/// 用于 Dropdown 的 items 构造，防止当前值不在列表时触发断言崩溃。
List<String> optionsIncluding(List<String> options, String value) =>
    options.contains(value) ? options : [...options, value];

/// 追加一个新自创分类到设置库（trim 后）。
/// 与系统 29 类或已有自创重名/空名 → 返回 false 且不写库。成功返回 true。
Future<bool> addCustomCategory(SettingsStore store, String name) async {
  final t = name.trim();
  if (t.isEmpty) return false;
  final customs = await store.loadCustomCategories();
  if (inventoryCategories.contains(t) || customs.contains(t)) return false;
  await store.saveCustomCategories([...customs, t]);
  return true;
}
