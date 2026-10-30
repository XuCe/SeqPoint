import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/app_scope.dart';
import '../../settings/settings_view.dart';
import '../../shared/note_search.dart';
import '../sticky/note_editor.dart';
import 'archive_view.dart';
import 'items_view.dart';
import 'note_wall_view.dart';
import 'side_nav.dart';
import 'tags_view.dart';
import 'today_view.dart';
import 'trash_view.dart';

/// 主面板：左导航 + 内容区两栏。
///
/// 刻意不用邮件式三栏——那是重管理界面，与"轻"矛盾。
class MainPanel extends StatefulWidget {
  const MainPanel({super.key, this.hotkeys, this.tray});
  final HotkeyService? hotkeys;
  final TrayService? tray;

  @override
  State<MainPanel> createState() => _MainPanelState();
}

class _MainPanelState extends State<MainPanel> with WindowListener {
  PanelSection _section = PanelSection.today;
  int _revision = 0;
  StreamSubscription<HotkeyAction>? _hotkeySubscription;
  bool _opening = false;
  bool _backgroundReady = false;
  bool _quitting = false;
  bool get _restoring => AppScope.of(context).restoring;
  Future<void>? _hotkeyRegistration, _trayInitialization;
  final _bindings = <HotkeyAction, HotkeyBinding>{};

  Future<void> _initTray() async {
    final tray = widget.tray;
    if (tray == null) return;
    try {
      await tray.init(
        onOpenPanel: () => unawaited(_onHotkey(null)),
        onQuickNote: () => unawaited(_onHotkey(HotkeyAction.newNote)),
        onQuit: () => unawaited(_quit()),
      );
      if (mounted) await windowManager.setPreventClose(true);
      if (!mounted) {
        await windowManager.setPreventClose(false);
        await tray.dispose();
        return;
      }
      _backgroundReady = true;
    } catch (_) {
      await tray.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('托盘未能启用，关闭窗口将退出应用。')),
        );
      }
    }
  }

  Future<void> _quit() async {
    if (_quitting || !mounted || _restoring) return;
    final scope = AppScope.of(context);
    final onQuittingChanged = scope.onQuittingChanged;
    _quitting = true;
    onQuittingChanged?.call(true);
    try {
      await scope.beforeQuit?.call();
    } catch (_) {
      _quitting = false;
      onQuittingChanged?.call(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('同步仍在关闭中，请稍后重试退出')));
      }
      return;
    }
    try {
      await _trayInitialization;
      await _hotkeyRegistration;
      await _hotkeySubscription?.cancel();
      await _releaseHotkeys();
      if (_backgroundReady) await widget.tray?.dispose();
    } finally {
      _backgroundReady = false;
      try {
        await windowManager.destroy();
      } finally {
        onQuittingChanged?.call(false);
      }
    }
  }

  Future<void> _registerHotkeys() async {
    final hotkeys = widget.hotkeys;
    if (hotkeys == null || !mounted) return;
    var failed = false;
    for (final entry in hotkeys.defaults().entries) {
      if (entry.key == HotkeyAction.organizeSelection) continue;
      try {
        await hotkeys.bind(entry.key, entry.value);
        if (mounted) setState(() => _bindings[entry.key] = entry.value);
      } catch (_) {
        failed = true;
      }
      if (!mounted) {
        await _releaseHotkeys();
        return;
      }
    }
    if (failed) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('部分全局快捷键未能启用，请在设置中查看。')));
    }
  }

  Future<void> _releaseHotkeys() async {
    try {
      await widget.hotkeys?.unbindAll();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
  }

  Future<void> _onHotkey(HotkeyAction? action) async {
    if (!mounted || _quitting || _restoring) return;
    final windows = AppScope.of(context).windows;
    if (windows == null) return;
    try {
      if (action == null) {
        await windows.showMain();
      } else if (action == HotkeyAction.toggleQuickNote) {
        final visible = await windows.isMainVisible();
        if (!mounted || _restoring) return;
        final focused = await windowManager.isFocused();
        if (!mounted || _restoring) return;
        if (visible && focused) {
          await windows.hideMain();
        } else {
          await windows.showMain();
        }
      } else if (action == HotkeyAction.newNote) {
        await windows.showMain();
        if (mounted && !_restoring) await _create();
      } else if (action == HotkeyAction.clipboardToNote) {
        await windows.showMain();
        if (!mounted || _restoring || _opening || ModalRoute.of(context)?.isCurrent != true) return;
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (!mounted || _restoring || _opening || ModalRoute.of(context)?.isCurrent != true) return;
        final text = data?.text;
        if (text == null || text.trim().isEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('剪贴板中没有可用文字。')));
          return;
        }
        await _create(initialText: text);
      } else if (action == HotkeyAction.openSearch) {
        await windows.showMain();
        await _search();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('全局快捷键执行失败，请重试。')));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _hotkeySubscription = widget.hotkeys?.actions.listen(_onHotkey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hotkeyRegistration = _registerHotkeys();
      _trayInitialization = _initTray();
    });
  }

  @override
  void dispose() {
    unawaited(_hotkeySubscription?.cancel());
    if (!_quitting) unawaited(_releaseHotkeys());
    windowManager.removeListener(this);
    if (_backgroundReady) {
      unawaited(windowManager.setPreventClose(false));
      unawaited(widget.tray?.dispose());
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (_quitting || !mounted) return;
    if (!_backgroundReady) {
      if (widget.tray != null) await _quit();
      return;
    }
    try {
      await AppScope.of(context).windows?.hideMain();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('窗口隐藏失败，请重试。')),
        );
      }
    }
  }

  @override
  void onWindowFocus() {
    // 编辑期间保留列表状态，让保存后的回调继续刷新列表。
    if (!mounted || _restoring || ModalRoute.of(context)?.isCurrent != true) return;
    setState(() => _revision++);
  }

  Future<void> _search() async {
    if (!mounted || _quitting || _restoring || _opening ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _opening = true;
    try {
      await openNoteSearch(context);
      if (mounted && !_restoring) setState(() => _revision++);
    } finally {
      _opening = false;
    }
  }

  Future<void> _create({String initialText = ''}) async {
    if (!mounted || _restoring || _opening || ModalRoute.of(context)?.isCurrent != true) return;
    _opening = true;
    try {
      final id = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => NoteEditor(initialText: initialText)),
      );
      if (id == null || !mounted || _restoring) return;
      setState(() {
        _section = PanelSection.noteWall;
        _revision++;
      });
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    if (scope.restoring) {
      return const Scaffold(key: ValueKey('restore-busy'), body: Center(child: CircularProgressIndicator(
          semanticsLabel: '正在恢复本机快照')));
    }
    final now = DateTime.now();
    final todayCount = {
      ...scope.items.dueOn(now).map((item) => item.id),
      ...scope.items.overdue(now).map((item) => item.id),
    }.length;

    return Scaffold(
      body: Row(
        children: [
          SideNav(
            current: _section,
            todayCount: todayCount,
            onSearch: _search,
            onSelect: (s) => setState(() => _section = s),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _content()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('新建便签'),
      ),
    );
  }

  Widget _content() => switch (_section) {
    PanelSection.today => TodayView(key: ValueKey(_revision), onChanged: () => setState(() {})),
    PanelSection.noteWall => NoteWallView(key: ValueKey(_revision)),
    PanelSection.items => ItemsView(key: ValueKey(_revision), onChanged: () => setState(() {})),
    PanelSection.tags => const TagsView(),
    PanelSection.archive => const ArchiveView(),
    PanelSection.trash => TrashView(onChanged: () => setState(() {})),
    PanelSection.settings => SettingsView(bindings: _bindings),
  };
}

enum PanelSection { today, noteWall, items, tags, archive, trash, settings }
