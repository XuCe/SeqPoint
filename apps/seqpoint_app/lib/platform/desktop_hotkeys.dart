import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

/// 桌面全局快捷键。App 在后台也生效。
///
/// 默认绑定见 [defaults]：唤起便签、新建、剪贴板成便签、选中即整理、搜索。
/// Windows 上 Alt+Space 是系统窗口菜单，故改用 Alt+Shift+Space。
class DesktopHotkeyService implements HotkeyService {
  DesktopHotkeyService({required this.isWindows});

  final bool isWindows;

  final _controller = StreamController<HotkeyAction>.broadcast();
  final _registered = <HotkeyAction, HotKey>{};

  @override
  Stream<HotkeyAction> get actions => _controller.stream;

  @override
  Map<HotkeyAction, HotkeyBinding> defaults() => {
        HotkeyAction.toggleQuickNote: HotkeyBinding(
          key: 'space',
          modifiers: isWindows ? {'alt', 'shift'} : {'alt'},
        ),
        HotkeyAction.newNote:
            const HotkeyBinding(key: 'n', modifiers: {'alt', 'shift'}),
        HotkeyAction.clipboardToNote:
            const HotkeyBinding(key: 'v', modifiers: {'alt', 'shift'}),
        HotkeyAction.organizeSelection:
            const HotkeyBinding(key: 't', modifiers: {'alt', 'shift'}),
        HotkeyAction.openSearch:
            const HotkeyBinding(key: 's', modifiers: {'alt', 'shift'}),
      };

  /// 注册全部默认快捷键。用户改过的绑定由调用方逐个 [bind]。
  Future<void> registerDefaults() async {
    await unbindAll();
    for (final entry in defaults().entries) {
      await bind(entry.key, entry.value);
    }
  }

  @override
  Future<void> bind(HotkeyAction action, HotkeyBinding binding) async {
    final key = _toHotKey(binding);
    if (key == null) return;

    final existing = _registered.remove(action);
    if (existing != null) await hotKeyManager.unregister(existing);

    await hotKeyManager.register(
      key,
      keyDownHandler: (_) => _controller.add(action),
    );
    _registered[action] = key;
  }

  @override
  Future<void> unbindAll() async {
    await hotKeyManager.unregisterAll();
    _registered.clear();
  }

  @override
  Future<List<HotkeyConflict>> detectConflicts() async {
    // 同一组合被绑到多个动作上是我们自己的冲突，可以直接查出来。
    // 与系统 / 其他应用的冲突无法可靠枚举，注册失败时才知道。
    final seen = <String, HotkeyAction>{};
    final conflicts = <HotkeyConflict>[];
    for (final entry in _registered.entries) {
      final sig = '${entry.value.modifiers?.join('+')}+${entry.value.key}';
      final owner = seen[sig];
      if (owner != null) {
        conflicts.add(HotkeyConflict(
          action: entry.key,
          reason: '与「${owner.name}」使用了相同的组合',
        ));
      } else {
        seen[sig] = entry.key;
      }
    }
    return conflicts;
  }

  Future<void> dispose() async {
    await unbindAll();
    await _controller.close();
  }

  HotKey? _toHotKey(HotkeyBinding binding) {
    final physical = _physicalKeys[binding.key.toLowerCase()];
    if (physical == null) return null;
    return HotKey(
      key: physical,
      modifiers: binding.modifiers
          .map(_modifierOf)
          .whereType<HotKeyModifier>()
          .toList(),
      scope: HotKeyScope.system,
    );
  }

  static HotKeyModifier? _modifierOf(String name) => switch (name) {
        'alt' || 'option' => HotKeyModifier.alt,
        'shift' => HotKeyModifier.shift,
        'ctrl' || 'control' => HotKeyModifier.control,
        'meta' || 'cmd' || 'command' => HotKeyModifier.meta,
        _ => null,
      };

  static const _physicalKeys = <String, PhysicalKeyboardKey>{
    'space': PhysicalKeyboardKey.space,
    'n': PhysicalKeyboardKey.keyN,
    'v': PhysicalKeyboardKey.keyV,
    't': PhysicalKeyboardKey.keyT,
    's': PhysicalKeyboardKey.keyS,
    'k': PhysicalKeyboardKey.keyK,
    'j': PhysicalKeyboardKey.keyJ,
    'd': PhysicalKeyboardKey.keyD,
  };
}
