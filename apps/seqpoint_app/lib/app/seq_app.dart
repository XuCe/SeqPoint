import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

import '../desktop/desktop_shell.dart';
import '../desktop/sticky/sticky_window.dart';
import '../desktop/sticky/note_editor.dart';
import '../main.dart' show isDesktop;
import '../mobile/mobile_shell.dart';
import '../mobile/note_detail_page.dart';
import '../mobile/quick_capture_page.dart';
import '../mobile/today_page.dart';
import '../shared/item_editor_page.dart';
import '../theme/seq_theme.dart';
import '../platform/secure_secret_store.dart';
import '../platform/syncthing_engine_host.dart';
import '../sync/app_sync_service.dart';
import '../sync/sync_reconciliation.dart';
import '../sync/sync_pairing_page.dart';
import 'app_scope.dart';
import 'bootstrap.dart';
import 'reminder_coordinator.dart';

typedef AppSyncServiceFactory = AppSyncService Function(
    SeqDatabase db, Directory root, Future<void> Function() onCommittedChange);

/// 应用根组件。启动时先装配核心层，再按端分流到桌面壳或移动壳。
class SeqApp extends StatefulWidget {
  const SeqApp({super.key, this.windows, this.hotkeys, this.tray,
    this.notifications, this.notificationError, this.notificationCapacity, this.syncFactory,
    this.title = '序点'})
    : _stickyNoteId = null,
      onClose = null;

  /// 桌面便签子窗口。
  const SeqApp.sticky({
    super.key,
    required String noteId,
    this.title = '序点',
    this.windows,
    this.onClose,
  }) : _stickyNoteId = noteId,
       hotkeys = null,
       notifications = null,
       notificationError = null,
       notificationCapacity = null,
       syncFactory = null,
       tray = null;

  final String title;
  final String? _stickyNoteId;
  final WindowService? windows;
  final HotkeyService? hotkeys;
  final TrayService? tray;
  final NotificationService? notifications;
  final String? notificationError;
  final int? notificationCapacity;
  final VoidCallback? onClose;
  final AppSyncServiceFactory? syncFactory;

  @override
  State<SeqApp> createState() => _SeqAppState();
}

class _SeqAppState extends State<SeqApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<({String itemId, NotificationAction action})>? _responses;
  ReminderCoordinator? _reminders;
  AppSyncService? _sync;
  SyncReconciliation? _syncReconciliation;
  Future<void>? _lifecycleDrain;
  int _syncRevision = 0;
  Bootstrap? _currentBoot;
  bool _restoring = false;
  bool _quitting = false;
  Object? _fatalDatabaseError;
  late final Future<Bootstrap> _boot = getApplicationSupportDirectory().then((
    directory,
  ) async {
    await directory.create(recursive: true);
    final boot = await Bootstrap.run(
      dbPath: '${directory.path}${Platform.pathSeparator}seqpoint.db',
    );
    if (!mounted) {
      boot.dispose();
      return boot;
    }
    _currentBoot = boot;
    final notifications = widget.notifications;
    if (mounted && widget._stickyNoteId == null && notifications != null) {
      _restartReminders(boot);
      _responses = notifications.responses.listen((event) {
        unawaited(_openNotification(event.itemId));
      });
      unawaited(_readLaunchNotification(notifications));
    }
    if (widget._stickyNoteId == null) _mountSync(boot, directory);
    return boot;
  });

  Future<void> _readLaunchNotification(NotificationService service) async {
    try {
      final id = await service.takeLaunchItem();
      if (id != null && id.isNotEmpty) await _openNotification(id);
    } catch (e) {
      _notice('读取通知点击失败：$e');
    }
  }

  void _restartReminders(Bootstrap boot) {
    _reminders?.dispose();
    final notifications = widget.notifications;
    _reminders = notifications == null ? null : ReminderCoordinator(
        db: boot.db, notifications: notifications, capacity: widget.notificationCapacity);
    final reminders = _reminders;
    if (reminders != null) unawaited(reminders.start());
  }

  void _mountSync(Bootstrap boot, Directory directory) {
    _lifecycleDrain = null;
    final reconciliation = SyncReconciliation(reminders: _reminders, onChanged: () {
      if (mounted && !_restoring && !_quitting && identical(boot, _currentBoot)) {
        setState(() => _syncRevision++);
      }
    });
    _syncReconciliation = reconciliation;
    final root = Directory('${directory.path}/sync-vault');
    _sync = widget.syncFactory?.call(boot.db, root, reconciliation.afterRemoteChange) ??
        AppSyncService(db: boot.db, root: root, secrets: const SecureSecretStore(),
            engineHost: SyncthingEngineHost(home: Directory('${directory.path}/syncthing-engine'),
                secrets: const SecureSecretStore()),
            onCommittedChange: reconciliation.afterRemoteChange);
    unawaited(_sync!.startAutomatic());
  }

  Future<void> _drainSync() {
    final pending = _lifecycleDrain;
    if (pending != null) return pending;
    final completion = Completer<void>();
    _lifecycleDrain = completion.future;
    final sync = _sync, reconciliation = _syncReconciliation, reminders = _reminders;
    () async {
      await sync?.stop();
      await reconciliation?.pause();
      await reminders?.pause();
      if (identical(sync, _sync)) { _sync = null; sync?.dispose(); }
      if (identical(reconciliation, _syncReconciliation)) _syncReconciliation = null;
    }().then(completion.complete, onError: (Object error, StackTrace stack) {
      if (identical(_lifecycleDrain, completion.future)) _lifecycleDrain = null;
      completion.completeError(error, stack);
    });
    return completion.future;
  }

  Future<void> _restoreSnapshot(File source) async {
    if (!mounted || _restoring || _quitting || _currentBoot == null || widget._stickyNoteId != null) {
      throw StateError('应用忙碌或正在退出，无法开始恢复');
    }
    SnapshotService.validate(source);
    final target = _currentBoot!.db.raw.select('PRAGMA database_list').first['file'] as String;
    if (FileSystemEntity.identicalSync(source.path, target)) {
      throw StateError('请选择独立快照，不能使用当前数据库作为恢复源');
    }
    if (_hasEditingPage()) throw StateError('请先保存并关闭编辑页面，再恢复本机快照');
    setState(() => _restoring = true);
    widget.windows?.pauseStickyOpening(true);
    try {
      final otherWindows = await widget.windows?.otherWindowIds()
          .timeout(const Duration(seconds: 5)) ?? const <String>[];
      if (otherWindows.isNotEmpty) throw StateError('请先保存并关闭所有便签窗口，再恢复');
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) throw StateError('应用已关闭，恢复已中止');
      final protection = await _replaceDatabase(source);
      if (mounted) {
        _navigator.currentState?.popUntil((route) => route.isFirst);
        WidgetsBinding.instance.addPostFrameCallback((_) =>
            _notice('已恢复本机快照；原数据保护副本：${protection.path}'));
      }
    } catch (error) {
      if (_currentBoot == null) _fatalDatabaseError = error;
      rethrow;
    } finally {
      widget.windows?.pauseStickyOpening(false);
      if (!mounted) {
        await _drainSync();
        _currentBoot?.dispose(); _currentBoot = null;
      }
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<File> _replaceDatabase(File source) async {
    final old = _currentBoot!;
    final path = old.db.raw.select('PRAGMA database_list').first['file'] as String;
    RestoreSession? session;
    Bootstrap? candidate;
    var closed = false;
    try {
      await _drainSync();
      await _reminders?.pause();
      final protection = await SnapshotService(old.db).createManual(
          Directory('${File(path).parent.path}/snapshots'));
      final ids = old.db.raw.select('SELECT notification_id FROM notification_plans');
      final notifications = widget.notifications;
      if (ids.isNotEmpty && notifications == null) throw StateError('无法撤销旧提醒，请先恢复通知功能');
      for (final row in ids) { await notifications!.cancel(row['notification_id'] as int); }
      if (!mounted) throw StateError('应用已关闭，恢复已中止');
      old.dispose(); closed = true; _currentBoot = null;
      session = await RestoreSession.prepare(source, targetPath: path);
      if (!mounted) throw StateError('应用已关闭，恢复已中止');
      await session.apply();
      candidate = await Bootstrap.run(dbPath: path, recoverPendingRestore: false);
      for (final row in candidate.db.raw.select('SELECT id FROM notes')) {
        candidate.notes.byId(row['id'] as String);
      }
      final reminders = ReminderRepository(candidate.db);
      for (final row in candidate.db.raw.select('SELECT id FROM items')) {
        final id = row['id'] as String;
        candidate.items.byId(id); reminders.forItem(id);
      }
      candidate.tags.all(); ActivityRepository(candidate.db).recent(limit: -1);
      NotificationPlanRepository(candidate.db).active();
      if (!mounted) throw StateError('应用已关闭，恢复已中止');
      await session.commit();
      _currentBoot = candidate; candidate = null;
      return protection.file;
    } catch (_) {
      candidate?.dispose();
      if (closed) {
        await session?.rollback();
        if (mounted) _currentBoot = await Bootstrap.run(dbPath: path);
      }
      rethrow;
    } finally {
      if (!mounted) {
        _currentBoot?.dispose(); _currentBoot = null;
        _reminders?.dispose(); _reminders = null;
      } else if (closed) {
        final current = _currentBoot;
        if (current != null) {
          _restartReminders(current);
          _mountSync(current, Directory(File(path).parent.path));
        }
        else { _reminders?.dispose(); _reminders = null; }
      } else {
        final reminders = _reminders;
        if (reminders != null) unawaited(reminders.start());
        if (_sync == null && _currentBoot != null) {
          _mountSync(_currentBoot!, Directory(File(path).parent.path));
        }
      }
    }
  }

  bool _hasEditingPage() {
    var found = false;
    void inspect(Element element) {
      if (element.widget is NoteEditor || element.widget is QuickCapturePage ||
          element.widget is ItemEditorPage || element.widget is SyncPairingPage) {
        found = true;
        return;
      }
      if (!found) element.visitChildElements(inspect);
    }
    final root = _navigator.currentContext;
    if (root is Element) inspect(root);
    return found;
  }

  void _notice(String text) {
    if (!mounted) return;
    _messenger.currentState?.hideCurrentSnackBar();
    _messenger.currentState?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openNotification(String id) async {
    try {
      final boot = _currentBoot ?? await _boot;
      if (!mounted || _restoring || id.isEmpty || !identical(boot, _currentBoot)) return;
      final navigator = _navigator.currentState;
      if (navigator == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_openNotification(id));
        });
        return;
      }
      await widget.windows?.showMain();
      if (!mounted || _restoring || !identical(boot, _currentBoot)) return;
      if (navigator.canPop()) {
        _notice('请先保存或关闭当前页面，再打开提醒');
        return;
      }
      if (id == '@today') {
        unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) =>
          Scaffold(appBar: AppBar(title: const Text('今日')),
            body: const TodayPage()))));
        return;
      }
      final item = boot.items.byId(id);
      final note = item?.noteId == null ? null : boot.notes.byId(item!.noteId!);
      if (item == null || !item.isOpen ||
          (item.noteId != null && (note == null || note.deletedAt != null))) {
        _notice('事项已完成或删除');
        return;
      }
      if (note != null) {
        unawaited(navigator.push<void>(MaterialPageRoute(
          builder: (_) => NoteDetailPage(noteId: note.id))));
      }
      unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => ItemEditorPage(itemId: item.id))));
    } catch (e) {
      _notice('打开提醒失败：$e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_restoring) {
      unawaited(_sync?.resumeAutomatic()??Future<void>.value());
      final reminders = _reminders;
      if (reminders != null) unawaited(reminders.reconcile());
    }
    if((Platform.isAndroid || Platform.isIOS) &&
        (state==AppLifecycleState.paused || state==AppLifecycleState.hidden)) {
      _sync?.suspendAutomatic();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final boot = _currentBoot, restoring = _restoring;
    final draining = _drainSync();
    _reminders?.dispose();
    _reminders = null;
    unawaited(_responses?.cancel());
    if (!restoring) _currentBoot = null;
    unawaited(draining.then((_) {
      if (!restoring) boot?.dispose();
    }, onError: (Object _, StackTrace stack) {
      FlutterError.reportError(FlutterErrorDetails(
          exception: StateError('同步尚未排空，保留数据库连接'), stack: stack));
    }));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      scaffoldMessengerKey: _messenger,
      title: widget.title,
      debugShowCheckedModeBanner: false,
      theme: seqLightTheme(),
      darkTheme: seqDarkTheme(),
      home: _home(),
      builder: (context, child) => FutureBuilder<Bootstrap>(
        future: _boot,
        builder: (context, snapshot) {
          if (_fatalDatabaseError != null) {
            return _StartupError(error: _fatalDatabaseError!);
          }
          if (snapshot.hasError) {
            return _StartupError(error: snapshot.error!);
          }
          final boot = _currentBoot ?? snapshot.data;
          if (boot == null) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return AppScope(
            database: boot.db,
            sync: widget._stickyNoteId == null ? _sync : null,
            syncRevision: _syncRevision,
            beforeQuit: widget._stickyNoteId == null ? _drainSync : null,
            restoring: _restoring,
            restoreSnapshot: widget._stickyNoteId == null ? _restoreSnapshot : null,
            onQuittingChanged: (value) => _quitting = value,
            noteService: boot.noteService,
            notes: boot.notes,
            items: boot.items,
            tags: boot.tags,
            search: boot.search,
            windows: widget.windows,
            reminders: _reminders,
            notificationError: widget.notificationError,
            child: AbsorbPointer(absorbing: _restoring,
                child: ExcludeFocus(excluding: _restoring, child: child!)),
          );
        },
      ),
    );
  }

  Widget _home() {
    final stickyId = widget._stickyNoteId;
    if (stickyId != null) {
      return StickyWindow(noteId: stickyId, onClose: widget.onClose);
    }
    return isDesktop
        ? DesktopShell(hotkeys: widget.hotkeys, tray: widget.tray)
        : const MobileShell();
  }
}

/// 启动失败时如实说明，不静默退化。
class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('序点没能启动', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('$error', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
