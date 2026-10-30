import 'package:flutter/material.dart';

import '../theme/seq_tokens.dart';

/// 设置页的统一外壳：标题栏 + 分组列表。
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    this.footnote,
  });

  final String title;
  final List<Widget> children;

  /// 页面底部的说明文字，用来讲清楚"数据去哪了"这类事。
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ...children,
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Text(
                footnote!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// 设置分组卡片。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children, this.label});

  final String? label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 6),
            child: Text(label!, style: Theme.of(context).textTheme.labelSmall),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: SeqTokens.line),
            ),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }
}
