import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final current = await WindowController.fromCurrentEngine();
  final noteId = await StickyWindowSetup.apply(current.arguments);
  if (noteId != null) {
    runApp(MaterialApp(home: Scaffold(body: Text(noteId))));
    return;
  }
  testWidgets('real Windows engines open two stickies without terminating', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.runAsync(() async {
      final windows = DesktopWindowService();
      // Creation returns after the native runner has registered child plugins.
      final first = await windows.openSticky('native-note-a');
      expect(await windows.openSticky('native-note-a'), first);
      final second = await windows.openSticky('native-note-b');
      expect(second, isNot(first));
      final ids = (await WindowController.getAll()).map((window) => window.windowId);
      expect(ids, containsAll([current.windowId, first, second]));
    });
  });
}
