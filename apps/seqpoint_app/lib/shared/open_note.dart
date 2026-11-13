import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../mobile/note_detail_page.dart';

typedef NoteOpener = Future<void> Function(String noteId);

/// 主面板提供的打开方式（例如在右侧面板里打开），没有时退回默认行为。
class NoteOpenerScope extends InheritedWidget {
  const NoteOpenerScope({super.key, required this.open, required super.child});

  final NoteOpener open;

  static NoteOpener? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoteOpenerScope>()?.open;

  @override
  bool updateShouldNotify(NoteOpenerScope oldWidget) => oldWidget.open != open;
}

/// 打开一张便签：主面板侧栏 → 桌面便签窗 → 整页详情，按可用性依次选择。
Future<void> openNote(BuildContext context, String noteId) async {
  final custom = NoteOpenerScope.maybeOf(context);
  if (custom != null) return custom(noteId);
  final windows = AppScope.of(context).windows;
  if (windows != null) {
    await windows.openSticky(noteId);
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: noteId)),
  );
}
