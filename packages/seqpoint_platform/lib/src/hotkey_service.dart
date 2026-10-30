/// 全局快捷键动作。四个核心动作各一个，全部可自定义。
enum HotkeyAction {
  /// 唤起 / 收起快速便签。默认 ⌥Space / Alt+Space。
  toggleQuickNote,

  /// 新建空白便签。默认 ⌥⇧N / Alt+Shift+N。
  newNote,

  /// 剪贴板内容成便签。默认 ⌥⇧V / Alt+Shift+V。
  clipboardToNote,

  /// 选中即整理：抓取当前应用选中文字 → 确认卡 → 生成 todo。
  /// 默认 ⌥⇧T / Alt+Shift+T。
  organizeSelection,

  /// 打开主面板并聚焦搜索。默认 ⌥⇧S / Alt+Shift+S。
  openSearch,
}

/// 快捷键组合的平台无关表示。
class HotkeyBinding {
  const HotkeyBinding({required this.key, required this.modifiers});
  final String key;
  final Set<String> modifiers;
}

class HotkeyConflict {
  const HotkeyConflict({required this.action, required this.reason});
  final HotkeyAction action;
  final String reason;
}

/// 全局快捷键。桌面端实现，移动端为空实现。
///
/// 性能要求：从按键到可输入 ≤ 300ms。
abstract interface class HotkeyService {
  Future<void> bind(HotkeyAction action, HotkeyBinding binding);
  Future<void> unbindAll();

  /// 触发流。UI 层订阅它执行对应动作。
  Stream<HotkeyAction> get actions;

  /// 与系统或其他应用的冲突检测，设置页展示。
  Future<List<HotkeyConflict>> detectConflicts();

  /// 该平台的默认绑定。
  Map<HotkeyAction, HotkeyBinding> defaults();
}
