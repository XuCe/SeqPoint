import 'dart:async';
import 'dart:io';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/main.dart' as app;
import 'package:seqpoint_app/platform/desktop_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'native_sync_support.dart';

// Use flutter drive: flutter test's wrapper never starts the child Dart entry.
Future<void> main([List<String> args = const []]) async {
  final root = Directory(const String.fromEnvironment('SEQPOINT_STICKY_SMOKE_ROOT'));
  if (root.path.isEmpty) throw ArgumentError('Set SEQPOINT_STICKY_SMOKE_ROOT');
  if (args.firstOrNull == 'multi_window') {
    WidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = AcceptancePaths(root);
    await app.main(args);
    final current = await WindowController.fromCurrentEngine();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!await windowManager.isVisible() || !await windowManager.isFocused()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('Sticky did not show');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await _readyChannel.invokeMethod<void>('ready', current.windowId);
    return;
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  PathProviderPlatform.instance = AcceptancePaths(root);
  testWidgets('real Windows engines open two stickies without terminating', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.runAsync(() async {
      await root.create(recursive: true);
      final boot = await Bootstrap.run(dbPath: '${root.path}/seqpoint.db');
      final firstNote = boot.noteService.capture('原生开窗回归 A').id;
      final secondNote = boot.noteService.capture('原生开窗回归 B').id;
      boot.dispose();
      await windowManager.ensureInitialized();
      final current = await WindowController.fromCurrentEngine();
      // Exercise setup before any taskbar interface has been initialized.
      expect(await StickyWindowSetup.apply(
        '{"type":"sticky","noteId":"native-setup",'
        '"frame":{"x":240.0,"y":200.0,"w":360.0,"h":300.0}}',
      ), 'native-setup');
      await windowManager.show();
      await windowManager.focus();
      expect(await windowManager.isSkipTaskbar(), isTrue);
      final windows = DesktopWindowService();
      final ready = <String, Completer<void>>{};
      await _readyChannel.setMethodCallHandler((call) async {
        ready.putIfAbsent(call.arguments as String, Completer<void>.new).complete();
      });
      // Creation returns after the native runner has registered child plugins.
      final first = await windows.openSticky(firstNote);
      await ready.putIfAbsent(first, Completer<void>.new).future.timeout(const Duration(seconds: 20));
      expect(await windows.openSticky(firstNote), first);
      final second = await windows.openSticky(secondNote);
      await ready.putIfAbsent(second, Completer<void>.new).future.timeout(const Duration(seconds: 20));
      expect(second, isNot(first));
      final ids = (await WindowController.getAll()).map((window) => window.windowId);
      expect(ids, containsAll([current.windowId, first, second]));
      await _closeAndWait(windows, first);
      final reopened = await windows.openSticky(firstNote);
      await ready.putIfAbsent(reopened, Completer<void>.new).future.timeout(const Duration(seconds: 20));
      expect(reopened, isNot(first));
      await _closeAndWait(windows, reopened);
      await _closeAndWait(windows, second);
      expect((await WindowController.getAll()).map((window) => window.windowId), [current.windowId]);
      await _readyChannel.setMethodCallHandler(null);
      binding.reportData = {'stickyLifecycle': true, 'opened': 3, 'closed': 3};
    });
  });
}

const _readyChannel = WindowMethodChannel('seqpoint.integration.sticky-ready',
  mode: ChannelMode.unidirectional);

Future<void> _closeAndWait(DesktopWindowService windows, String id) async {
  // Closing an engine can dispose its reply channel before the close is acknowledged.
  try {
    await windows.closeSticky(id).timeout(const Duration(seconds: 5));
  } on WindowChannelException catch (_) {
  } on TimeoutException catch (_) {}
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while ((await WindowController.getAll()).any((window) => window.windowId == id)) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('Sticky did not close');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
