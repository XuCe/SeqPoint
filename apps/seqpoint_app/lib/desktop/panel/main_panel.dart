import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/app_scope.dart';
import '../../mobile/note_detail_page.dart';
import '../../updates/full_update_installer.dart';
import '../../settings/settings_view.dart';
import '../../shared/item_editor_page.dart';
import '../../shared/open_note.dart';
import '../../theme/seq_tokens.dart';
import '../sticky/note_editor.dart';
import 'closed_view.dart';
import 'command_palette.dart';
import 'items_view.dart';
import 'note_wall_view.dart';
import 'side_nav.dart';
import 'today_view.dart';

/// 主面板：左导航 + 内容区；打开便签时右侧滑出便签面板。
///
/// 平时只有两栏，便签面板按需出现、随手关掉，不做常驻的邮件式三栏。
class MainPanel extends StatefulWidget {
  const MainPanel({super.key, this.hotkeys, this.tray});
  final HotkeyService? hotkeys;
  final TrayService? tray;

  @override
  State<MainPanel> createState() => _MainPanelState();
}

class _MainPanelState extends State<MainPanel> with WindowListener, WidgetsBindingObserver {
  PanelSection _section = PanelSection.today;
  int _revision = 0;
  String? _tagId;
  String? _panelNoteId;
  StreamSubscription<HotkeyAction>? _hotkeySubscription;
  bool _opening = false;
  bool _backgroundReady = false;
  bool _quitting = false;
  bool _readyToTerminate = false;
  Future<AppExitResponse>? _exitRequest;
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

  Future<void> _prepareFullUpdate() async {
    if (!mounted || _quitting || _restoring) {
      throw StateError('应用正在关闭或恢复');
    }
    final windows = AppScope.of(context).windows;
    if (windows == null) return;
    windows.pauseStickyOpening(true);
    try {
      if ((await windows.otherWindowIds()).isNotEmpty) {
        throw StateError('请先保存并关闭所有便签窗口');
      }
    } finally {
      windows.pauseStickyOpening(false);
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() => _exitRequest ??=
      _prepareNativeExit().whenComplete(() => _exitRequest = null);

  Future<AppExitResponse> _prepareNativeExit() async {
    if (_readyToTerminate) return AppExitResponse.exit;
    if (!mounted || _quitting || _restoring) return AppExitResponse.cancel;
    final scope = AppScope.of(context);
    try {
      await _prepareFullUpdate();
      _quitting = true;
      scope.onQuittingChanged?.call(true);
      await scope.beforeQuit?.call();
      _readyToTerminate = true;
      return AppExitResponse.exit;
    } catch (_) {
      _quitting = false;
      scope.onQuittingChanged?.call(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('暂时无法安全退出，请保存并关闭便签或稍后重试')));
      }
      return AppExitResponse.cancel;
    }
  }

  Future<void> _quitForUpdate() async {
    await _prepareFullUpdate();
    await _quit();
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
        _readyToTerminate = true;
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
    WidgetsBinding.instance.addObserver(this);
    fullUpdateInstaller.onPrepare = _prepareFullUpdate;
    fullUpdateInstaller.onQuit = _quitForUpdate;
    _hotkeySubscription = widget.hotkeys?.actions.listen(_onHotkey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hotkeyRegistration = _registerHotkeys();
      _trayInitialization = _initTray();
    });
  }

  @override
  void dispose() {
    fullUpdateInstaller.onPrepare = null;
    fullUpdateInstaller.onQuit = null;
    unawaited(_hotkeySubscription?.cancel());
    if (!_quitting) unawaited(_releaseHotkeys());
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
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
    PaletteChoice? choice;
    try {
      choice = await showCommandPalette(context, commands: [
        const PaletteCommand('new', '记一笔', Icons.edit_outlined, hint: '新建便签'),
        const PaletteCommand('today', '去今日', Icons.wb_sunny_outlined),
        const PaletteCommand('notes', '去便签', Icons.sticky_note_2_outlined),
        const PaletteCommand('items', '去事项', Icons.checklist_rounded),
        const PaletteCommand('closed', '去已关闭', Icons.inventory_2_outlined),
        const PaletteCommand('settings', '打开设置', Icons.settings_outlined),
      ]);
    } finally {
      _opening = false;
    }
    if (choice == null || !mounted || _restoring) return;
    switch (choice) {
      case PaletteCommand(id: 'new'):
        await _create();
      case PaletteCommand(:final id):
        _select(switch (id) {
          'notes' => PanelSection.notes,
          'items' => PanelSection.items,
          'closed' => PanelSection.closed,
          'settings' => PanelSection.settings,
          _ => PanelSection.today,
        });
      case PaletteHit(:final hit):
        try {
          if (hit.isNote) {
            await openNote(context, hit.objectId);
          } else {
            await ItemEditorPage.open(context, hit.objectId);
          }
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('打开搜索结果失败，请重试。')));
          }
        }
        if (mounted && !_restoring) setState(() => _revision++);
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
        _section = PanelSection.notes;
        _revision++;
      });
    } finally {
      _opening = false;
    }
  }

  void _select(PanelSection section) => setState(() {
        _section = section;
        if (section != PanelSection.items) _tagId = null;
      });

  /// 没有独立便签窗的桌面（如 Linux）在主面板右侧打开便签。
  Future<void> _openInPanel(String noteId) async {
    setState(() => _panelNoteId = noteId);
  }

  void _panelChanged() {
    if (mounted) setState(() => _revision++);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    if (scope.restoring) {
      return const Scaffold(key: ValueKey('restore-busy'), body: Center(child: CircularProgressIndicator(
          semanticsLabel: '正在恢复本机快照')));
    }
    final todayCount = scope.items.dueThroughTodayCount(DateTime.now());
    final tags = [
      for (final tag in [...scope.tags.all(kind: TagKind.project), ...scope.tags.all(kind: TagKind.custom),
          ...scope.tags.all(kind: TagKind.type)])
        (tag, scope.tags.usageCount(tag.id)),
    ].where((entry) => entry.$2 > 0 || entry.$1.kind == TagKind.project).take(12).toList();
    final peers = scope.sync?.verifiedPeers.length ?? 0;
    final panelNoteId = _panelNoteId;
    final panelNote = panelNoteId == null ? null : scope.notes.byId(panelNoteId);
    final showPanel = panelNote != null && !panelNote.isDeleted && !panelNote.isClosed;

    final panel = showPanel
        ? NoteDetailPage(
            key: ValueKey(panelNoteId),
            noteId: panelNoteId!,
            onDismiss: () => setState(() => _panelNoteId = null),
            onChanged: _panelChanged,
          )
        : null;
    final body = LayoutBuilder(builder: (context, constraints) {
      // 窗口较窄时便签面板浮在内容上，避免把内容区挤到放不下卡片。
      final panelWidth = constraints.maxWidth < 980 ? 360.0 : 420.0;
      final docked = constraints.maxWidth - 233 - panelWidth >= 560;
      return Row(
        children: [
          SideNav(
            current: _section,
            todayCount: todayCount,
            noteCount: scope.notes.active().length,
            onSearch: _search,
            onCreate: _create,
            createHint: widget.hotkeys == null ? null
                : defaultTargetPlatform == TargetPlatform.macOS ? '⌥⇧N' : 'Alt+Shift+N',
            tags: tags,
            selectedTagId: _tagId,
            onTag: (tag) => setState(() {
              _section = PanelSection.items;
              _tagId = _tagId == tag.id ? null : tag.id;
            }),
            syncLabel: peers == 0 ? '仅本机' : '已和 $peers 台设备配对',
            synced: peers > 0,
            onSelect: _select,
          ),
          const VerticalDivider(width: 1, color: SeqTokens.line),
          Expanded(
            child: panel == null || docked
                ? _content()
                : Stack(children: [
                    Positioned.fill(child: _content()),
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: panelWidth,
                      child: Material(elevation: 12, child: panel),
                    ),
                  ]),
          ),
          if (panel != null && docked) ...[
            const VerticalDivider(width: 1, color: SeqTokens.line),
            SizedBox(width: panelWidth, child: panel),
          ],
        ],
      );
    });

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _search,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _create,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _create,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: scope.windows == null
              ? NoteOpenerScope(open: _openInPanel, child: body)
              : body,
        ),
      ),
    );
  }

  Widget _content() => switch (_section) {
    PanelSection.today => TodayView(revision: _revision, onChanged: () => setState(() {})),
    PanelSection.notes => NoteWallView(revision: _revision, onChanged: () => setState(() {})),
    PanelSection.items => ItemsView(
        key: ValueKey('items-$_tagId'),
        tagId: _tagId,
        revision: _revision,
        onClearTag: () => setState(() => _tagId = null),
        onChanged: () => setState(() {})),
    PanelSection.closed => ClosedView(revision: _revision, onChanged: () => setState(() {})),
    PanelSection.settings => SettingsView(bindings: _bindings),
  };
}

enum PanelSection { today, notes, items, closed, settings }
