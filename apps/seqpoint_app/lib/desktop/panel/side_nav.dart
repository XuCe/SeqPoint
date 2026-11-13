import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../shared/seq_widgets.dart';
import '../../theme/seq_tokens.dart';
import 'main_panel.dart';

/// 左侧导航：品牌 → 记一笔 → 搜索或跳转 → 四个去处 → 标签筛选 → 同步状态。
///
/// 同步状态块同时是设置入口，诚实展示"仅本机 / 已同步"。
class SideNav extends StatelessWidget {
  const SideNav({
    super.key,
    required this.current,
    required this.onSelect,
    this.todayCount = 0,
    this.noteCount = 0,
    this.closedCount = 0,
    this.onSearch,
    this.onCreate,
    this.createHint,
    this.tags = const [],
    this.selectedTagId,
    this.onTag,
    this.syncLabel = '仅本机',
    this.synced = false,
  });

  final PanelSection current;
  final ValueChanged<PanelSection> onSelect;
  final int todayCount;
  final int noteCount;
  final int closedCount;
  final VoidCallback? onSearch;
  final VoidCallback? onCreate;

  /// "记一笔"全局快捷键的提示，未注册全局快捷键时为空。
  final String? createHint;
  final List<(Tag, int)> tags;
  final String? selectedTagId;
  final ValueChanged<Tag>? onTag;
  final String syncLabel;
  final bool synced;

  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    final entries = <(PanelSection, IconData, String, int)>[
      (PanelSection.today, Icons.wb_sunny_outlined, '今日', todayCount),
      (PanelSection.notes, Icons.sticky_note_2_outlined, '便签', noteCount),
      (PanelSection.items, Icons.checklist_rounded, '事项', 0),
      (PanelSection.closed, Icons.inventory_2_outlined, '已关闭', 0),
    ];
    return Container(
      width: 232,
      color: SeqTokens.chrome,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Brand(),
          if (onCreate != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: FilledButton(
                onPressed: onCreate,
                style: FilledButton.styleFrom(
                  backgroundColor: SeqTokens.accent,
                  foregroundColor: SeqTokens.noteInk,
                  minimumSize: const Size(0, 42),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                ),
                child: Row(children: [
                  const Icon(Icons.edit_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('记一笔')),
                  if (createHint != null) KbdHint(createHint!, dark: true),
                ]),
              ),
            ),
          if (onSearch != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Material(
                color: SeqTokens.raised,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: onSearch,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: SeqTokens.line),
                    ),
                    child: Row(children: [
                      const Icon(Icons.search, size: 17, color: SeqTokens.inkMuted),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('搜索', style: TextStyle(
                          fontSize: 13.5, color: SeqTokens.inkMuted))),
                      KbdHint(_mac ? '⌘K' : 'Ctrl+K'),
                    ]),
                  ),
                ),
              ),
            ),
          for (final (section, icon, label, count) in entries)
            _NavItem(
              icon: icon,
              label: label,
              selected: current == section,
              badge: count > 0 ? '$count' : null,
              accentBadge: section == PanelSection.today,
              onTap: () => onSelect(section),
            ),
          if (tags.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(26, 22, 20, 6),
              child: Text('标签', style: TextStyle(fontSize: 11.5, letterSpacing: 1.2,
                  fontWeight: FontWeight.w600, color: SeqTokens.inkFaint)),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final (tag, count) in tags)
                    _NavItem(
                      icon: Icons.tag,
                      label: tag.name,
                      selected: current == PanelSection.items && selectedTagId == tag.id,
                      badge: count > 0 ? '$count' : null,
                      dense: true,
                      onTap: () => onTag?.call(tag),
                    ),
                ],
              ),
            ),
          ] else
            const Spacer(),
          _SyncBlock(
            label: syncLabel,
            synced: synced,
            selected: current == PanelSection.settings,
            onTap: () => onSelect(PanelSection.settings),
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 14, 16),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Image.asset('assets/brand/logo.png', width: 30, height: 30,
              excludeFromSemantics: true),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(
            '序点',
            maxLines: 1,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFamily: SeqFonts.serif.first,
                  fontFamilyFallback: SeqFonts.serif,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  letterSpacing: 1.5,
                ),
          )),
        ],
      ),
    );
  }
}

class _SyncBlock extends StatelessWidget {
  const _SyncBlock({
    required this.label,
    required this.synced,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool synced;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
        child: Material(
          color: selected ? SeqTokens.raised : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: synced ? SeqTokens.syncDot : SeqTokens.inkFaint,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // 诚实语义：没有可达副本时绝不显示"已同步"。
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: SeqTokens.inkSoft)),
                    const Text('设置', style: TextStyle(fontSize: 13.5,
                        fontWeight: FontWeight.w600, color: SeqTokens.ink)),
                  ]),
                ),
                const Icon(Icons.settings_outlined, size: 17, color: SeqTokens.inkMuted),
              ]),
            ),
          ),
        ),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
    this.accentBadge = false,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;
  final bool accentBadge;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? SeqTokens.ink : SeqTokens.inkSoft;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: selected ? SeqTokens.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 6 : 9),
            decoration: selected
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: SeqTokens.line),
                  )
                : null,
            child: Row(
              children: [
                Icon(icon, size: dense ? 15 : 18, color: selected ? SeqTokens.ink : SeqTokens.inkMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: dense ? 13 : 14,
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (badge != null)
                  accentBadge
                      ? Container(
                          key: const ValueKey('today-badge'),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                          decoration: BoxDecoration(
                            color: SeqTokens.accent,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(badge!, style: const TextStyle(fontSize: 11.5,
                              fontWeight: FontWeight.w700, color: SeqTokens.noteInk)),
                        )
                      : Text(badge!, style: const TextStyle(fontSize: 12, color: SeqTokens.inkFaint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
