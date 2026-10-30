import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/mobile/mobile_shell.dart';
import 'package:seqpoint_app/theme/seq_theme.dart';

void main() {
  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    testWidgets('$size 深色大字号下标签及恢复入口不溢出', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('这是一个很长的标签事项标题，用于验证小屏和大字号布局');
      final item = boot.noteService.lineToItem(note.id, 0);
      final tag = boot.tags.all().firstWhere((t) => t.name == '开发');
      boot.items.setTags(item.id, [tag.id]);
      await tester.pumpWidget(MaterialApp(theme: seqDarkTheme(),
        builder: (context, child) => AppScope(
          noteService: boot.noteService, notes: boot.notes, items: boot.items,
          tags: boot.tags, search: boot.search,
          child: MediaQuery(data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2), disableAnimations: true,
          ), child: child!),
        ), home: const MobileShell(),
      ));
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('标签'), 160);
      await tester.pumpAndSettle();
      await tester.tap(find.text('标签'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('开发'), 120);
      await tester.pumpAndSettle();
      await tester.tap(find.text('开发'));
      await tester.pumpAndSettle();
      expect(find.text(item.title), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack(); await tester.pumpAndSettle();
      await tester.pageBack(); await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('回收站'), 160);
      await tester.pumpAndSettle();
      await tester.tap(find.text('回收站'));
      await tester.pumpAndSettle();
      expect(find.text('回收站是空的。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
