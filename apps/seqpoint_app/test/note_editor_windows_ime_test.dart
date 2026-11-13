import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/sticky/note_editor.dart';

import 'note_editor_test_support.dart';
import 'support/windows_text_input_fake.dart';

/// 用 Windows 引擎文字输入的仿真打拼音：组字过程中的拼音不能留在正文里。
void main() {
  const words = [
    (['w', 'wu', "wu'z"], '乌镇'),
    (['s', 'sh', 'shi', "shi'p"], '视频'),
    (['j', 'ji', 'jie', "jie'r"], '接入'),
  ];

  for (final timing in ['逐键刷新', '快速连按', '引擎先收到下一键']) {
    testWidgets('Windows 便签编辑器打拼音（$timing）只留下选定的汉字', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('经营平台 app端 打包', title: '当前工作任务');
      final engine = WindowsTextInputFake(tester);
      await tester.pumpWidget(AppScope(
        noteService: boot.noteService, notes: boot.notes, items: boot.items,
        tags: boot.tags, search: boot.search,
        child: MaterialApp(home: NoteEditor(noteId: note.id)),
      ));
      await tester.pumpAndSettle();
      engine.deliver();
      expect(engine.text, '经营平台 app端 打包');

      for (final (keys, result) in words) {
        for (final key in keys) {
          engine.imeKey(key);
          switch (timing) {
            case '逐键刷新':
              await tester.pump();
              engine.deliver();
            case '快速连按':
              break;
            default:
              // 上一帧框架发出的调用，在这一键之后才到引擎。
              engine.deliver();
              await tester.pump();
          }
        }
        engine.imeCommit(result);
        await tester.pump();
        engine.deliver();
      }
      await tester.pumpAndSettle();
      engine.deliver();

      expect(noteEditor(tester).controller.text, '经营平台 app端 打包乌镇视频接入');
      expect(engine.text, '经营平台 app端 打包乌镇视频接入');
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
}
