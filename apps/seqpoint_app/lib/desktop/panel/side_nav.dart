import 'package:flutter/material.dart';

import '../../theme/seq_tokens.dart';
import 'main_panel.dart';

/// 左侧导航。底部固定显示同步状态，诚实展示"仅本机 / 已同步到 N 台"。
class SideNav extends StatelessWidget {
  const SideNav({
    super.key,
    required this.current,
    required this.onSelect,
    this.todayCount = 0,
    this.onSearch,
  });

  final PanelSection current;
  final ValueChanged<PanelSection> onSelect;
  final int todayCount;
  final VoidCallback? onSearch;

  static const _entries = <(PanelSection, IconData, String)>[
    (PanelSection.today, Icons.wb_sunny_outlined, '今日'),
    (PanelSection.noteWall, Icons.sticky_note_2_outlined, '便签墙'),
    (PanelSection.items, Icons.checklist_outlined, '全部事项'),
    (PanelSection.tags, Icons.sell_outlined, '标签'),
    (PanelSection.archive, Icons.inventory_2_outlined, '已归档'),
    (PanelSection.trash, Icons.delete_outline, '回收站'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 208,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Brand(),
          if (onSearch != null)
            _NavItem(
              icon: Icons.search,
              label: '搜索',
              selected: false,
              onTap: onSearch!,
            ),
          for (final (section, icon, label) in _entries)
            _NavItem(
              icon: icon,
              label: label,
              selected: current == section,
              badge: section == PanelSection.today && todayCount > 0
                  ? '$todayCount'
                  : null,
              onTap: () => onSelect(section),
            ),
          const Spacer(),
          _NavItem(
            icon: Icons.settings_outlined,
            label: '设置',
            selected: current == PanelSection.settings,
            onTap: () => onSelect(PanelSection.settings),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 14),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: SeqTokens.inkMuted,
                  ),
                ),
                const SizedBox(width: 8),
                // 诚实语义：没有可达副本时绝不显示"已同步"。
                Text('仅本机', style: theme.textTheme.bodySmall),
              ],
            ),
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
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 16),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(SeqSpace.radiusControl),
            child: Image.asset('assets/brand/logo.png', width: 32, height: 32,
              excludeFromSemantics: true),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(
            '序点',
            maxLines: 2,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFamily: SeqFonts.serif.first,
                  fontFamilyFallback: SeqFonts.serif,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
          )),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Material(
        color: selected ? SeqTokens.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(icon,
                    size: 16,
                    color: selected
                        ? theme.colorScheme.onSurface
                        : SeqTokens.inkMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13.5,
                      color: selected
                          ? theme.colorScheme.onSurface
                          : SeqTokens.inkMuted,
                      fontWeight: selected ? FontWeight.w500 : null,
                    ),
                  ),
                ),
                if (badge != null)
                  Text(
                    badge!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: SeqTokens.accentInk,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
