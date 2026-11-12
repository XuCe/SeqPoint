import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

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
  DesktopWindowService({this.childWindow = false});
  final bool childWindow;

  static const _framePrefix = 'sticky.frame.';

  /// noteId → 已打开的窗口 id。避免同一便签开出多个窗口。
  static final _openWindows = <String, WindowController>{};
  static const _host = WindowMethodChannel('seqpoint.sticky.host', mode: ChannelMode.unidirectional);
  static Future<void>? _frameWrites;
  static bool _hostsChildren = false;

  Future<void> listenForStickyWindows() async {
    await _host.setMethodCallHandler((call) async {
      final args = call.arguments as Map;
      final noteId = args['noteId'] as String;
      final frame = WindowFrame.fromJson((args['frame'] as Map?)?.cast<String, Object?>());
      switch (call.method) {
        case 'open':
          return openSticky(noteId, frame: frame);
        case 'saveFrame':
          await saveFrame(noteId, frame!);
          return null;
        default:
          throw UnsupportedError(call.method);
      }
    });
    _hostsChildren = true;
  }

  static bool _openingPaused = false;
  static final _pendingOpenings = <String, Future<String>>{};

  @override
  void pauseStickyOpening(bool paused) {
    _openingPaused = paused;
  }

  @override
  Future<List<String>> otherWindowIds() async {
    if (!_openingPaused) throw StateError('须先暂停开窗再检查恢复条件');
    await Future.wait(List.of(_pendingOpenings.values)).timeout(const Duration(seconds: 5));
    final current = await WindowController.fromCurrentEngine();
    final all = await WindowController.getAll();
    return all.where((w) => w.windowId != current.windowId)
        .map((w) => w.windowId).toList();
  }

  @override
  Future<String> openSticky(String noteId, {WindowFrame? frame}) {
    if (_openingPaused) return Future.error(StateError('正在恢复，暂不能打开便签窗'));
    if (childWindow) {
      return _host.invokeMethod<String>('open',
          {'noteId': noteId, 'frame': frame?.toJson()}).then((id) => id!);
    }
    return _pendingOpenings.putIfAbsent(noteId, () =>
        _openSticky(noteId, frame: frame).whenComplete(() { _pendingOpenings.remove(noteId); }));
  }

  Future<String> _openSticky(String noteId, {WindowFrame? frame}) async {
    final live = await WindowController.getAll();
    if (_openingPaused) throw StateError('正在恢复，开窗已中止');
    _openWindows.removeWhere((_, window) => !live.any((w) => w.windowId == window.windowId));
    var existing = _openWindows[noteId];
    if (existing == null || !live.any((w) => w.windowId == existing!.windowId)) {
      existing = live.where((w) {
        if (w.arguments.isEmpty) return false;
        final data = jsonDecode(w.arguments) as Map<String, dynamic>;
        return data['type'] == 'sticky' && data['noteId'] == noteId;
      }).firstOrNull;
    }
    if (existing != null) {
      try {
        await existing.invokeMethod<void>('activate');
      } on WindowChannelException catch (error) {
        // A new engine registers its handler before showing itself.
        if (error.code != 'CHANNEL_UNREGISTERED' && error.code != 'CHANNEL_NOT_FOUND') rethrow;
      }
      return existing.windowId;
    }

    final target = frame ?? await loadFrame(noteId) ?? _defaultFrame();
    if (_openingPaused) throw StateError('正在恢复，开窗已中止');
    final arguments = jsonEncode({'type': 'sticky', 'noteId': noteId, 'frame': target.toJson(),
      if (_hostsChildren) 'hosted': true});
    final controller = await WindowController.create(
        WindowConfiguration(arguments: arguments, hiddenAtLaunch: true));
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
    if (childWindow) {
      return _host.invokeMethod<void>('saveFrame', {'noteId': noteId, 'frame': frame.toJson()});
    }
    final previous = _frameWrites;
    final done = Completer<void>();
    _frameWrites = done.future;
    try {
      if (previous != null) await previous;
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString('$_framePrefix$noteId', jsonEncode(frame.toJson()))) {
        throw StateError('无法保存便签窗口大小');
      }
    } finally {
      if (identical(_frameWrites, done.future)) _frameWrites = null;
      done.complete();
    }
  }

  @override
  Future<WindowFrame?> loadFrame(String noteId) async {
    final pending = _frameWrites;
    if (pending != null) await pending;
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

  WindowFrame _defaultFrame() =>
      const WindowFrame(x: 100, y: 64, width: 640, height: 480);
}

/// 便签子窗口在自己的进程内调用：摆好位置、设好标题、准备好关闭通道。
///
/// 子窗口有独立的 Flutter 引擎，window_manager 在那里作用于它自己。
class StickyWindowSetup {
  const StickyWindowSetup();

  /// [arguments] 是主窗口传来的 JSON 字符串。
  static ({String noteId, bool hosted, Future<void> placed})? prepare(String arguments) {
    if (arguments.isEmpty) return null;
    final json = jsonDecode(arguments) as Map<String, Object?>;
    if (json['type'] != 'sticky' || json['noteId'] is! String) return null;
    final frame = WindowFrame.fromJson((json['frame'] as Map?)?.cast<String, Object?>());
    return (noteId: json['noteId'] as String, hosted: json['hosted'] == true, placed: _place(frame));
  }

  static Future<void> _place(WindowFrame? frame) async {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow();
    if (Platform.isWindows) await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    if (frame != null) {
      await windowManager.setBounds(
        Rect.fromLTWH(frame.x, frame.y, frame.width, frame.height),
      );
    }
    await windowManager.setTitle('便签');
    await windowManager.setSkipTaskbar(true);
  }
}
