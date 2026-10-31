import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面窗口管理。
///
/// desktop_multi_window 只负责"开一个新引擎窗口"并传递参数字符串；
/// 尺寸、标题、置顶都由子窗口在自己的进程里用 window_manager 设置。
/// 因此本类的职责是：创建窗口 + 记忆位置，以及主窗口显隐。
class DesktopWindowService implements WindowService {
  DesktopWindowService();

  static const _framePrefix = 'sticky.frame.';

  /// noteId → 已打开的窗口 id。避免同一便签开出多个窗口。
  final _openWindows = <String, WindowController>{};
  static bool _openingPaused = false;
  static final _pendingOpenings = <Future<String>>{};

  @override
  void pauseStickyOpening(bool paused) => _openingPaused = paused;

  @override
  Future<List<String>> otherWindowIds() async {
    if (!_openingPaused) throw StateError('须先暂停开窗再检查恢复条件');
    await Future.wait(List.of(_pendingOpenings)).timeout(const Duration(seconds: 5));
    final current = await WindowController.fromCurrentEngine();
    final all = await WindowController.getAll();
    return all.where((w) => w.windowId != current.windowId).map((w) => w.windowId).toList();
  }

  @override
  Future<String> openSticky(String noteId, {WindowFrame? frame}) {
    if (_openingPaused) return Future.error(StateError('正在恢复，暂不能打开便签窗'));
    final operation = _openSticky(noteId, frame: frame);
    _pendingOpenings.add(operation);
    unawaited(operation.then<void>((_) { _pendingOpenings.remove(operation); },
        onError: (Object error, StackTrace stack) { _pendingOpenings.remove(operation); }));
    return operation;
  }

  Future<String> _openSticky(String noteId, {WindowFrame? frame}) async {
    final live = await WindowController.getAll();
    if (_openingPaused) throw StateError('正在恢复，开窗已中止');
    var existing = _openWindows[noteId];
    if (existing == null || !live.any((w) => w.windowId == existing!.windowId)) {
      existing = live.where((w) {
        if (w.arguments.isEmpty) return false;
        final data = jsonDecode(w.arguments) as Map<String, dynamic>;
        return data['type'] == 'sticky' && data['noteId'] == noteId;
      }).firstOrNull;
    }
    if (existing != null) {
      await existing.show();
      return existing.windowId;
    }

    final target = frame ?? await loadFrame(noteId) ?? _defaultFrame();
    if (_openingPaused) throw StateError('正在恢复，开窗已中止');
    final controller = await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({
          'type': 'sticky',
          'noteId': noteId,
          'frame': target.toJson(),
        }),
        // 先隐藏，等子窗口自己摆好位置再显示，避免闪一下默认位置。
        hiddenAtLaunch: true,
      ),
    );
    _openWindows[noteId] = controller;
    return controller.windowId;
  }

  @override
  Future<void> closeSticky(String windowId) async {
    _openWindows.removeWhere((_, c) => c.windowId == windowId);
    // 关闭由子窗口自己执行：主窗口这边只发个信号。
    await WindowController.fromWindowId(windowId)
        .invokeMethod<void>('close_self');
  }

  @override
  Future<void> setAlwaysOnTop(bool value) =>
      windowManager.setAlwaysOnTop(value);

  @override
  Future<void> saveFrame(String noteId, WindowFrame frame) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_framePrefix$noteId', jsonEncode(frame.toJson()));
  }

  @override
  Future<WindowFrame?> loadFrame(String noteId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_framePrefix$noteId');
    if (raw == null) return null;
    return WindowFrame.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<void> showMain() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> hideMain() => windowManager.hide();

  @override
  Future<bool> isMainVisible() => windowManager.isVisible();

  /// 新便签窗的默认位置：偏右下，像随手贴在角落。
  WindowFrame _defaultFrame() =>
      const WindowFrame(x: 240, y: 200, width: 360, height: 300);
}

/// 便签子窗口在自己的进程内调用：摆好位置、设好标题、准备好关闭通道。
///
/// 子窗口有独立的 Flutter 引擎，window_manager 在那里作用于它自己。
class StickyWindowSetup {
  const StickyWindowSetup();

  /// [arguments] 是主窗口传来的 JSON 字符串。
  static Future<String?> apply(String arguments) async {
    if (arguments.isEmpty) return null;
    final json = jsonDecode(arguments) as Map<String, Object?>;
    if (json['type'] != 'sticky') return null;

    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow();
    final frame = WindowFrame.fromJson(
      (json['frame'] as Map?)?.cast<String, Object?>(),
    );
    if (frame != null) {
      await windowManager.setBounds(
        Rect.fromLTWH(frame.x, frame.y, frame.width, frame.height),
      );
    }
    await windowManager.setTitle('便签');
    await windowManager.setSkipTaskbar(true);
    return json['noteId'] as String?;
  }
}
