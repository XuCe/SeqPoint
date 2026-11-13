import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../features/voice/voice_input_page.dart';
import '../theme/seq_tokens.dart';
import 'me_page.dart';
import 'note_wall_page.dart';
import 'quick_capture_page.dart';
import 'today_page.dart';

/// 移动壳：底部 今日 · 便签 · 我的 三个标签页，上方常驻"记一笔"输入条与麦克风。
///
/// 去掉了居中的 ＋ 和"快速记录 / 语音速记"二选一面板：点输入条直接写，点麦克风直接说。
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

  bool get _restoring => AppScope.of(context).restoring;

  Future<void> _write({String initialText = ''}) async {
    if (_restoring) return;
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => QuickCapturePage(initialText: initialText),
        fullscreenDialog: true,
      ),
    );
    if (created == true && mounted && !_restoring) _select(1);
  }

  Future<void> _speak() async {
    if (_restoring) return;
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const VoiceInputPage(),
        fullscreenDialog: true,
      ),
    );
    if (!mounted || text == null || text.trim().isEmpty || _restoring) return;
    await _write(initialText: text);
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const Scaffold(
        key: ValueKey('restore-busy'),
        body: Center(
          child: CircularProgressIndicator(semanticsLabel: '正在恢复本机快照'),
        ),
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      body: switch (_index) {
        0 => TodayPage(key: _pageKey),
        1 => NoteWallPage(key: _pageKey),
        _ => MePage(key: _pageKey),
      },
      floatingActionButton: _index == 2
          ? null
          : SizedBox(
              width: width - 32,
              child: _CaptureBar(onWrite: _write, onSpeak: _speak),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      bottomNavigationBar: _BottomBar(current: _index, onSelect: _select),
    );
  }
}

/// 常驻输入条：左边点了就写，右边麦克风点了就说。
class _CaptureBar extends StatelessWidget {
  const _CaptureBar({required this.onWrite, required this.onSpeak});

  final VoidCallback onWrite;
  final VoidCallback onSpeak;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Tooltip(
          message: '记一笔',
          excludeFromSemantics: true,
          child: Material(
            color: SeqTokens.raised,
            elevation: 6,
            shadowColor: const Color(0x44262219),
            shape: const StadiumBorder(side: BorderSide(color: SeqTokens.line)),
            child: InkWell(
              onTap: onWrite,
              customBorder: const StadiumBorder(),
              child: Semantics(
                button: true,
                label: '记一笔',
                excludeSemantics: true,
                child: const SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      SizedBox(width: 18),
                      Icon(
                        Icons.edit_outlined,
                        size: 19,
                        color: SeqTokens.accentInk,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '记一笔…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15.5,
                            color: SeqTokens.inkMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Material(
        color: SeqTokens.accent,
        elevation: 6,
        shadowColor: const Color(0x44262219),
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: '语音速记',
          onPressed: onSpeak,
          iconSize: 24,
          constraints: const BoxConstraints.tightFor(width: 52, height: 52),
          icon: const Icon(Icons.mic_none_rounded, color: SeqTokens.noteInk),
        ),
      ),
    ],
  );
}

/// 底部导航：三个等宽标签。
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.current, required this.onSelect});

  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    const tabs = [
      (Icons.wb_sunny_outlined, '今日'),
      (Icons.sticky_note_2_outlined, '便签'),
      (Icons.person_outline, '我的'),
    ];
    // 底栏高度固定，标签字号放大到 1.3 倍为止，避免大字号下挤出底栏。
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Container(
        decoration: const BoxDecoration(
          color: SeqTokens.chrome,
          border: Border(top: BorderSide(color: SeqTokens.line)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(
              children: [
                for (var i = 0; i < tabs.length; i++)
                  Expanded(
                    child: _Tab(
                      icon: tabs[i].$1,
                      label: tabs[i].$2,
                      selected: current == i,
                      onTap: () => onSelect(i),
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
    final color = selected ? SeqTokens.ink : SeqTokens.inkMuted;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 23, color: color),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: color,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
