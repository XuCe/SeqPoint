import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../theme/seq_tokens.dart';
import 'capture_sheet.dart';
import 'me_page.dart';
import 'note_wall_page.dart';
import 'today_page.dart';

/// 移动壳：底部 今日 · 便签 · ＋ · 我的，＋ 为居中凸起主按钮。
///
/// 砍掉了旧版 5 Tab 中的"事项"与"节点"：事项并入便签 Tab 的切换视图，
/// 节点能力整体推迟。
class MobileShell extends StatefulWidget {
  const MobileShell({super.key});

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  int _index = 0;

  /// 用 key 强制重建，让页面在返回时重新读库。
  Key _pageKey = UniqueKey();

  void _select(int index) => setState(() {
        _index = index;
        _pageKey = UniqueKey();
      });

  Future<void> _openCapture() async {
    if (AppScope.of(context).restoring) return;
    final created = await CaptureSheet.show(context);
    if (created == true && mounted && !AppScope.of(context).restoring) _select(1);
  }

  @override
  Widget build(BuildContext context) {
    if (AppScope.of(context).restoring) {
      return const Scaffold(key: ValueKey('restore-busy'), body: Center(child: CircularProgressIndicator(
          semanticsLabel: '正在恢复本机快照')));
    }
    return Scaffold(
      body: switch (_index) {
        0 => TodayPage(key: _pageKey),
        1 => NoteWallPage(key: _pageKey),
        _ => MePage(key: _pageKey),
      },
      floatingActionButton: SizedBox(
        width: 56,
        height: 56,
        child: FloatingActionButton(
          onPressed: _openCapture,
          backgroundColor: SeqTokens.accent,
          foregroundColor: SeqTokens.noteInk,
          elevation: 4,
          shape: const CircleBorder(),
          tooltip: '记一笔',
          child: const Icon(Icons.add, size: 26),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: _BottomBar(current: _index, onSelect: _select),
    );
  }
}

/// 底部导航。中间给 FAB 留出位置，所以是 2 + 空位 + 1 的布局。
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.current, required this.onSelect});

  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      height: 64,
      padding: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: [
          Expanded(
            child: _Tab(
              icon: Icons.wb_sunny_outlined,
              label: '今日',
              selected: current == 0,
              onTap: () => onSelect(0),
            ),
          ),
          Expanded(
            child: _Tab(
              icon: Icons.sticky_note_2_outlined,
              label: '便签',
              selected: current == 1,
              onTap: () => onSelect(1),
            ),
          ),
          // FAB 占位
          const SizedBox(width: 72),
          Expanded(
            child: _Tab(
              icon: Icons.person_outline,
              label: '我的',
              selected: current == 2,
              onTap: () => onSelect(2),
            ),
          ),
          const Expanded(child: SizedBox.shrink()),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? SeqTokens.accentInk : SeqTokens.inkMuted;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: selected ? FontWeight.w500 : null,
            ),
          ),
        ],
      ),
    );
  }
}
