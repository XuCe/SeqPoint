import 'package:flutter_test/flutter_test.dart';
import 'package:live_markdown_editor/live_markdown_editor.dart';

Finder get noteField => find.byType(LiveMarkdownEditor);

LiveMarkdownEditor noteEditor(WidgetTester tester) => tester.widget<LiveMarkdownEditor>(noteField);

Future<void> typeNote(WidgetTester tester, String text) async {
  await tester.tap(noteField);
  tester.testTextInput.enterText(text);
  await tester.pump();
}
