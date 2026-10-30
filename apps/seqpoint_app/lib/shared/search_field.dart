import 'package:flutter/material.dart';

/// 全局搜索框。⌘/Ctrl+K 聚焦。覆盖便签原文、事项标题、标签，含已归档。
class SearchField extends StatelessWidget {
  const SearchField({super.key, this.onQuery});

  final ValueChanged<String>? onQuery;

  @override
  Widget build(BuildContext context) {
    // TODO(M1)
    return const SizedBox.shrink();
  }
}
