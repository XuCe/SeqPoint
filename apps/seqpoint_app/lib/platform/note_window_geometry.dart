import 'package:flutter/foundation.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:window_manager/window_manager.dart';

/// Records the final bounds after a native move or resize gesture.
class NoteWindowGeometry with WindowListener {
  NoteWindowGeometry(this.windows, {this.noteId});
  final WindowService windows;
  final String? noteId;
  bool draftResized = false;
  Future<void> _pending = Future.value();

  @override
  void onWindowResized() {
    if (noteId == null) draftResized = true;
    onWindowMoved();
  }

  @override
  void onWindowMoved() {
    final id = noteId;
    if (id != null) _pending = saveCurrentFrame(id);
  }

  Future<void> saveCurrentFrame(String id) async {
    try {
      final bounds = await windowManager.getBounds();
      if (bounds.isEmpty || !bounds.isFinite) return;
      await windows.saveFrame(id, WindowFrame(x: bounds.left, y: bounds.top,
          width: bounds.width, height: bounds.height));
    } catch (error, stack) {
      FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack,
          context: ErrorDescription('保存便签窗口大小时')));
    }
  }

  Future<void> close() async {
    await _pending;
    await windowManager.close();
  }
}
