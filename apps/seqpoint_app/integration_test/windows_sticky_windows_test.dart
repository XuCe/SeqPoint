import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/desktop/panel/note_wall_view.dart';
import 'package:seqpoint_app/shared/note_card.dart';
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
    PathProviderPlatform.instance = _ObserveStickyStartup(root);
    await app.main(args);
    final current = await WindowController.fromCurrentEngine();
    final checkFocus = await _readyChannel.invokeMethod<bool>('checkFocus') ?? false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!await windowManager.isVisible() || (checkFocus && !await windowManager.isFocused())) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('Sticky did not show');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final body = find.textContaining('原生开窗回归').evaluate().firstOrNull?.widget as Text?;
    final initial = await windowManager.getBounds();
    final size = await _readyChannel.invokeMethod<List>('testSize');
    debugPrint('Sticky window bounds on open: ${initial.width} x ${initial.height}');
    if (size != null) {
      await windowManager.setSize(Size(size[0] as double, size[1] as double));
      _finishNativeResize(await windowManager.getId());
    }
    await _readyChannel.invokeMethod<void>('ready', {'id': current.windowId, 'body': body?.data,
      'width': initial.width, 'height': initial.height});
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
      addTearDown(boot.dispose);
      await windowManager.ensureInitialized();
      final current = await WindowController.fromCurrentEngine();
      final mainBounds = await windowManager.getBounds();
      // Exercise setup before any taskbar interface has been initialized.
      final setup = StickyWindowSetup.prepare(
        '{"type":"sticky","noteId":"native-setup",'
        '"frame":{"x":240.0,"y":200.0,"w":360.0,"h":300.0}}',
      )!;
      await setup.placed;
      expect(setup.noteId, 'native-setup');
      await windowManager.show();
      await windowManager.focus();
      final mainHasForeground = await windowManager.isFocused();
      expect(await windowManager.isSkipTaskbar(), isTrue);
      // The setup probe resized the host to a sticky. Show the wall at its
      // original main-window size before trying to click its cards.
      await windowManager.setBounds(mainBounds);
      final windows = DesktopWindowService();
      await tester.pumpWidget(AppScope(noteService: boot.noteService, notes: boot.notes,
          items: boot.items, tags: boot.tags, search: boot.search, windows: windows,
          child: const MaterialApp(home: Scaffold(body: NoteWallView()))));
      await tester.pumpAndSettle();
      expect(find.byType(GridView), findsOneWidget);
      late Completer<String> ready;
      final visibleDuringLoad = <bool>[];
      final bodies = <String?>[];
      final sizes = <Size>[];
      const resized = [Size(684, 512), Size(568, 424)];
      late String openingNote;
      await _readyChannel.setMethodCallHandler((call) async {
        if (call.method == 'checkFocus') return mainHasForeground;
        if (call.method == 'testSize') {
          if (sizes.length >= resized.length) return null;
          return [resized[sizes.length].width, resized[sizes.length].height];
        }
        if (call.method == 'reopen') {
          expect(await windows.openSticky(openingNote), call.arguments);
        } else if (call.method == 'visibility') {
          visibleDuringLoad.add(call.arguments as bool);
        } else {
          final args = call.arguments as Map;
          sizes.add(Size(args['width'] as double, args['height'] as double));
          bodies.add(args['body'] as String?);
          ready.complete(args['id'] as String);
        }
        return null;
      });
      await windows.listenForStickyWindows();
      expect((await WindowController.getAll()).map((w) => w.windowId), [current.windowId]);
      if (mainHasForeground) expect(await windowManager.isFocused(), isTrue);
      Future<String> openFromWall(String note) async {
        openingNote = note;
        ready = Completer<String>();
        final card = find.byWidgetPredicate((w) => w is NoteCard && w.note.id == note);
        await tester.scrollUntilVisible(card, 100,
            scrollable: find.descendant(of: find.byType(GridView),
                matching: find.byType(Scrollable)));
        expect(card.hitTestable(), findsOneWidget);
        final clock = Stopwatch()..start();
        await tester.tap(card);
        await tester.tap(card);
        final id = await ready.future.timeout(const Duration(seconds: 20));
        debugPrint('BENCH sticky visible in ${clock.elapsedMilliseconds} ms');
        return id;
      }
      final first = await openFromWall(firstNote);
      expect(await windows.openSticky(firstNote), first);
      final second = await openFromWall(secondNote);
      expect(second, isNot(first));
      final ids = (await WindowController.getAll()).map((window) => window.windowId);
      expect(ids, unorderedEquals([current.windowId, first, second]));
      await _closeAndWait(windows, first);
      final reopened = await openFromWall(firstNote);
      expect(reopened, isNot(first));
      await _closeAndWait(windows, reopened);
      await _closeAndWait(windows, second);
      windows.pauseStickyOpening(true);
      expect(await windows.otherWindowIds(), isEmpty);
      windows.pauseStickyOpening(false);
      await _readyChannel.setMethodCallHandler(null);
      expect(visibleDuringLoad, List.filled(6, false),
          reason: 'A cold or reactivated sticky must stay hidden until its note is drawn');
      expect(bodies, ['原生开窗回归 A', '原生开窗回归 B', '原生开窗回归 A']);
      expect(sizes, [const Size(640, 480), const Size(640, 480), resized.first]);
      final savedB = await windows.loadFrame(secondNote);
      expect(Size(savedB!.width, savedB.height), resized[1]);
      binding.reportData = {'stickyLifecycle': true, 'opened': 3, 'closed': 3};
    });
  });
}

const _readyChannel = WindowMethodChannel('seqpoint.integration.sticky-ready',
  mode: ChannelMode.unidirectional);

// Send the same sizing messages as a released resize handle to the real HWND.
void _finishNativeResize(int hwnd) {
  final kernel = ffi.DynamicLibrary.open('kernel32.dll');
  final user = ffi.DynamicLibrary.open('user32.dll');
  final alloc = kernel.lookupFunction<ffi.IntPtr Function(ffi.Uint32, ffi.UintPtr),
      int Function(int, int)>('LocalAlloc');
  final free = kernel.lookupFunction<ffi.IntPtr Function(ffi.IntPtr), int Function(int)>('LocalFree');
  final getRect = user.lookupFunction<ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr),
      int Function(int, int)>('GetWindowRect');
  final send = user.lookupFunction<ffi.IntPtr Function(ffi.IntPtr, ffi.Uint32, ffi.UintPtr, ffi.IntPtr),
      int Function(int, int, int, int)>('SendMessageW');
  final rect = alloc(0, 4 * ffi.sizeOf<ffi.Int32>());
  if (rect == 0) throw StateError('Cannot allocate a RECT');
  try {
    if (getRect(hwnd, rect) == 0) throw StateError('Cannot read window bounds');
    send(hwnd, 0x0214, 8, rect); // WM_SIZING, WMSZ_BOTTOMRIGHT
    send(hwnd, 0x0232, 0, 0); // WM_EXITSIZEMOVE
  } finally {
    free(rect);
  }
}

class _ObserveStickyStartup extends AcceptancePaths {
  _ObserveStickyStartup(super.directory);

  @override
  Future<String?> getApplicationSupportPath() async {
    await WidgetsBinding.instance.endOfFrame;
    final current = await WindowController.fromCurrentEngine();
    await _readyChannel.invokeMethod<void>('visibility', await windowManager.isVisible());
    await _readyChannel.invokeMethod<void>('reopen', current.windowId);
    await _readyChannel.invokeMethod<void>('visibility', await windowManager.isVisible());
    return super.getApplicationSupportPath();
  }
}

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
