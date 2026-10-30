import 'dart:async';
import 'package:flutter/material.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/platform/desktop_hotkeys.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';

class TestHotkeys implements HotkeyService {
  final events = StreamController<HotkeyAction>.broadcast();
  final bound = <HotkeyAction, HotkeyBinding>{};
  HotkeyAction? failOn;
  Completer<void>? gate;
  int releases = 0;
  @override
  Stream<HotkeyAction> get actions => events.stream;
  @override
  Map<HotkeyAction, HotkeyBinding> defaults() => DesktopHotkeyService(isWindows: false).defaults();
  @override
  Future<void> bind(HotkeyAction action, HotkeyBinding binding) async {
    await gate?.future;
    if (action == failOn) throw StateError('register failed');
    bound[action] = binding;
  }
  @override
  Future<void> unbindAll() async { releases++; bound.clear(); }
  @override
  Future<List<HotkeyConflict>> detectConflicts() async => [];
}

Widget hotkeyApp(Bootstrap boot, HotkeyService hotkeys, {TrayService? tray}) => AppScope(
  noteService: boot.noteService, notes: boot.notes, items: boot.items,
  tags: boot.tags, search: boot.search, windows: DesktopWindowService(),
  child: MaterialApp(home: MainPanel(hotkeys: hotkeys, tray: tray)),
);
