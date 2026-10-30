import 'dart:async';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class TestTray implements TrayService {
  void Function()? open, quick, quit;
  Completer<void>? gate;
  bool failInit = false;
  int disposals = 0;

  @override
  Future<void> init({
    required void Function() onOpenPanel,
    required void Function() onQuickNote,
    required void Function() onQuit,
  }) async {
    open = onOpenPanel;
    quick = onQuickNote;
    quit = onQuit;
    await gate?.future;
    if (failInit) throw StateError('tray init failed');
  }

  @override
  Future<void> setBadge(int count) async {}

  @override
  Future<void> dispose() async { disposals++; }
}
