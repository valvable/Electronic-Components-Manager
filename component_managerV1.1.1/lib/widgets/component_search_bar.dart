import 'package:flutter/material.dart';

/// 顶部搜索框：支持按型号 / CID 模糊搜索。
///
/// 命名说明：Material 3 自带 `SearchBar` 组件，
/// 为避免重名冲突，这里命名为 `ComponentSearchBar`。
class ComponentSearchBar extends StatelessWidget {
  final TextEditingController? controller;
  final ValueChanged<String> onChanged;
  final String hintText;

  const ComponentSearchBar({
    super.key,
    this.controller,
    required this.onChanged,
    this.hintText = '搜索型号 / CID',
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceVariant,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
