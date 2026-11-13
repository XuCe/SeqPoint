import 'package:flutter/material.dart';

import '../theme/seq_tokens.dart';

/// 设置页的统一外壳：衬线标题 + 分组卡片，内容限宽居中。
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
      appBar: AppBar(
        title: Text(title, style: TextStyle(
          fontFamily: SeqFonts.serif.first,
          fontFamilyFallback: SeqFonts.serif,
          fontWeight: FontWeight.w700,
          fontSize: 20,
          color: SeqTokens.ink,
        )),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          for (final child in [
            ...children,
            if (footnote != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Text(
                  footnote!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6),
                ),
              ),
          ])
            // 保留子项的 key，列表增删条目时有状态的子项（如展开的折叠区）不会错位重建。
            Align(
              key: child.key == null ? null : ValueKey(child.key),
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: child,
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
            padding: const EdgeInsets.fromLTRB(26, 22, 24, 8),
            child: Text(label!, style: const TextStyle(fontSize: 12.5,
                fontWeight: FontWeight.w700, letterSpacing: 0.6, color: SeqTokens.inkMuted)),
          )
        else
          const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: SeqTokens.raised,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0xFFECE6D8)),
            ),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }
}

/// 带图标标题的设置卡片：用于"同步方式""隐私档位"这类需要先说明再操作的分组。
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.title,
    this.icon,
    this.subtitle,
    this.trailing,
    this.children = const [],
    this.highlighted = false,
  });

  final String title;
  final IconData? icon;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  /// 当前生效的方式用琥珀描边强调。
  final bool highlighted;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Material(
          color: SeqTokens.raised,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: highlighted ? SeqTokens.accent : const Color(0xFFECE6D8),
              width: highlighted ? 1.5 : 1,
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 12, children.isEmpty ? 14 : 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (icon != null) ...[
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: highlighted ? SeqTokens.accentSoft : SeqTokens.chip,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 19,
                        color: highlighted ? SeqTokens.accentInk : SeqTokens.inkSoft),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontSize: 15.5,
                        fontWeight: FontWeight.w600, color: SeqTokens.ink)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!, style: const TextStyle(fontSize: 13,
                          height: 1.5, color: SeqTokens.inkMuted)),
                    ],
                  ]),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ]),
            ),
            ...children,
          ]),
        ),
      );
}

/// 分组小标题，与 [SettingsGroup] 的 label 同样式，用于卡片序列之前。
class SettingsLabel extends StatelessWidget {
  const SettingsLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(26, 22, 24, 0),
        child: Text(text, style: const TextStyle(fontSize: 12.5,
            fontWeight: FontWeight.w700, letterSpacing: 0.6, color: SeqTokens.inkMuted)),
      );
}
