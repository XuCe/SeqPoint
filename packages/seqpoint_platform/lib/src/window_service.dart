/// 便签窗的矩形位置，避免核心层依赖 Flutter 的 Rect。
class WindowFrame {
  const WindowFrame({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x, y, width, height;

  Map<String, Object?> toJson() =>
      {'x': x, 'y': y, 'w': width, 'h': height};

  static WindowFrame? fromJson(Map<String, Object?>? j) => j == null
      ? null
      : WindowFrame(
          x: (j['x'] as num).toDouble(),
          y: (j['y'] as num).toDouble(),
          width: (j['w'] as num).toDouble(),
          height: (j['h'] as num).toDouble(),
        );
}

/// 桌面窗口管理：主窗口显隐 + 独立便签窗。
///
/// 便签窗是真正的系统窗口，不是应用内浮层——这样才能"贴在屏幕上"、
/// 跨应用置顶、被单独拖到第二块屏幕。
///
/// 窗口 id 是字符串：底层多窗口插件用字符串标识窗口。
abstract interface class WindowService {
  /// 打开一个便签窗，返回窗口 id。同一便签重复调用只会聚焦已有窗口。
  Future<String> openSticky(String noteId, {WindowFrame? frame});

  Future<void> closeSticky(String windowId);

  /// 主引擎恢复期间阻止所有服务实例创建新的便签引擎。
  void pauseStickyOpening(bool paused);

  /// 等待在途开窗后枚举，返回除当前引擎之外的所有窗口ID。
  Future<List<String>> otherWindowIds();

  /// 置顶当前窗口。便签子窗口在自己的进程内调用。
  Future<void> setAlwaysOnTop(bool value);

  /// 记住位置与大小，下次打开还原。
  Future<void> saveFrame(String noteId, WindowFrame frame);

  Future<WindowFrame?> loadFrame(String noteId);

  /// 主窗口显隐，供全局快捷键调用。
  Future<void> showMain();
  Future<void> hideMain();
  Future<bool> isMainVisible();
}
