import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

import 'reminder_coordinator.dart';
import '../sync/app_sync_service.dart';

/// 依赖注入容器。把核心层的服务提供给界面树。
///
/// 暂用 InheritedWidget，规模变大后再考虑换状态管理方案。
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.noteService,
    required this.notes,
    required this.items,
    required this.tags,
    required this.search,
    this.windows,
    this.reminders,
    this.notificationError,
    this.database,
    this.restoring = false,
    this.onQuittingChanged,
    this.restoreSnapshot,
    this.sync,
    this.beforeQuit,
    this.syncRevision = 0,
    required super.child,
  });

  final NoteService noteService;
  final NoteRepository notes;
  final ItemRepository items;
  final TagRepository tags;
  final SearchService search;
  final WindowService? windows;
  final ReminderCoordinator? reminders;
  final String? notificationError;
  final SeqDatabase? database;
  final bool restoring;
  final ValueChanged<bool>? onQuittingChanged;
  final Future<void> Function(File)? restoreSnapshot;
  final AppSyncService? sync;
  final Future<void> Function()? beforeQuit;
  final int syncRevision;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未在界面树中提供');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      oldWidget.restoring != restoring ||
      oldWidget.database != database ||
      oldWidget.reminders != reminders ||
      oldWidget.sync != sync ||
      oldWidget.syncRevision != syncRevision ||
      oldWidget.notificationError != notificationError;
}
