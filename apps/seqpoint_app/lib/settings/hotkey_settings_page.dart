import 'package:flutter/material.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

import '../theme/seq_tokens.dart';
import 'settings_scaffold.dart';

/// 当前便签内快捷键与全局绑定说明。
class HotkeySettingsPage extends StatelessWidget {
  const HotkeySettingsPage({super.key, this.bindings});

  /// 当前生效的绑定。为空时展示默认值。
  final Map<HotkeyAction, HotkeyBinding>? bindings;

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: '快捷键',
      footnote:
          '便签内快捷键在便签窗口获得焦点时生效。'
          '当前行可通过点击或 Tab 键选择。'
          '全局快捷键在序点运行时生效；未设置的组合尚未启用。',
      children: [
        SettingsGroup(
          label: '全局',
          children: [
            for (final action in HotkeyAction.values)
              ListTile(
                title: Text(_labelOf(action)),
                subtitle: Text(_descOf(action)),
                trailing: _Keys(_format(
                  bindings?[action],
                  mac: Theme.of(context).platform == TargetPlatform.macOS,
                ), muted: bindings?[action] == null),
              ),
          ],
        ),
        SettingsGroup(
          label: '主窗口',
          children: [
            for (final (key, label) in const [
              ('⌘/Ctrl + K', '搜索或跳转'),
              ('⌘/Ctrl + N', '记一笔'),
              ('⌘/Ctrl + Enter', '今日输入框里记下'),
            ])
              ListTile(title: Text(label), trailing: _Keys(key)),
          ],
        ),
        SettingsGroup(
          label: '便签内',
          children: [
            for (final (key, label) in const [
              ('⌘/Ctrl + Enter', '当前行转为事项 / 切换完成'),
              ('⌘/Ctrl + D', '完成当前事项'),
              ('⌘/Ctrl + P', '置顶 / 取消置顶'),
              ('⌘/Ctrl + W', '揭走并关闭便签'),
              ('⌘/Ctrl + K', '搜索便签和事项'),
              ('Esc', '收起便签窗口'),
            ])
              ListTile(title: Text(label), trailing: _Keys(key)),
          ],
        ),
      ],
    );
  }

  static String _format(HotkeyBinding? b, {required bool mac}) {
    if (b == null) return '未设置';
    final key = b.key == 'space' ? 'Space' : b.key.toUpperCase();
    if (!mac) {
      const names = {
        'alt': 'Alt',
        'shift': 'Shift',
        'ctrl': 'Ctrl',
        'meta': 'Win',
      };
      return [...b.modifiers.map((m) => names[m] ?? m), key].join('+');
    }
    const symbols = {'alt': '⌥', 'shift': '⇧', 'ctrl': '⌃', 'meta': '⌘'};
    final mods = b.modifiers.map((m) => symbols[m] ?? m).join();
    return '$mods$key';
  }

  static String _labelOf(HotkeyAction a) => switch (a) {
    HotkeyAction.toggleQuickNote => '唤起 / 收起主窗口',
    HotkeyAction.newNote => '新建便签',
    HotkeyAction.clipboardToNote => '剪贴板成便签',
    HotkeyAction.organizeSelection => '选中即整理',
    HotkeyAction.openSearch => '搜索',
  };

  static String _descOf(HotkeyAction a) => switch (a) {
    HotkeyAction.toggleQuickNote => '后台时唤起，前台时收起；保留当前页面',
    HotkeyAction.newNote => '开一张空白便签',
    HotkeyAction.clipboardToNote => '把复制的文字直接变成便签',
    HotkeyAction.organizeSelection => '抓取任意应用中选中的文字并生成待办',
    HotkeyAction.openSearch => '打开主面板并聚焦搜索框',
  };
}

/// 快捷键组合，做成键帽样式。
class _Keys extends StatelessWidget {
  const _Keys(this.text, {this.muted = false});
  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: muted ? Colors.transparent : SeqTokens.chip,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: SeqTokens.line),
        ),
        child: Text(text, style: TextStyle(fontSize: 12.5,
            color: muted ? SeqTokens.inkFaint : SeqTokens.inkSoft, fontWeight: FontWeight.w600)),
      );
}
