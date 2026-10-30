import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 便签窗内的快捷键。
///
/// ⌘/Ctrl+Enter 行转事项 ⇄ 勾选完成 · ⌘J 整理整张便签
/// ⌘⇧Enter 选中文本生成 todo · ⌘D 完成 · ⌘P 置顶
/// ⌘W 关闭归档 · ⌘K 搜索 · ⌘Z 撤销（含撤销整次整理）· Esc 收起
class StickyShortcuts extends StatelessWidget {
  const StickyShortcuts({
    super.key,
    required this.child,
    required this.actions,
  });

  final Widget child;
  final Map<StickyIntent, VoidCallback> actions;

  @override
  Widget build(BuildContext context) {
    const keys = {
      StickyIntent.toggleItem: LogicalKeyboardKey.enter,
      StickyIntent.complete: LogicalKeyboardKey.keyD,
      StickyIntent.pin: LogicalKeyboardKey.keyP,
      StickyIntent.close: LogicalKeyboardKey.keyW,
      StickyIntent.search: LogicalKeyboardKey.keyK,
      StickyIntent.undo: LogicalKeyboardKey.keyZ,
      StickyIntent.organize: LogicalKeyboardKey.keyJ,
    };
    return CallbackShortcuts(
      bindings: {
        for (final entry in keys.entries)
          if (actions[entry.key] case final action?) ...{
            SingleActivator(entry.value, control: true): action,
            SingleActivator(entry.value, meta: true): action,
          },
        if (actions[StickyIntent.organizeSelection] case final action?) ...{
          const SingleActivator(
            LogicalKeyboardKey.enter,
            control: true,
            shift: true,
          ): action,
          const SingleActivator(
            LogicalKeyboardKey.enter,
            meta: true,
            shift: true,
          ): action,
        },
        if (actions[StickyIntent.dismiss] case final action?)
          const SingleActivator(LogicalKeyboardKey.escape): action,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

enum StickyIntent {
  toggleItem,
  organize,
  organizeSelection,
  complete,
  pin,
  close,
  search,
  undo,
  dismiss,
}
