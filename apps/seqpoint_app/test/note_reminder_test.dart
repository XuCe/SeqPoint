import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/shared/note_reminder.dart';

void main() {
  final now = DateTime(2026, 11, 11, 10);
  NoteReminder? read(String text, {int? caret}) {
    final line = noteLineAtCaret(TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret ?? text.length),
    ));
    return line == null ? null : NoteReminder.fromLine(line, now);
  }
  test('只识别光标所在行，普通日期保留原文', () {
    const text = '明天下午三点回电话\n买牛奶';
    expect(read(text), isNull);
    final draft = read(text, caret: 4)!;
    expect(draft.index, 0);
    expect(draft.due, DateTime(2026, 11, 12, 15));
    expect(draft.contentWithTitle(text, draft.title), text);
  });
  test('空行斜杠入口和带标题的提醒命令只替换所在行', () {
    expect(read('首页\n/')!.title, '');
    final draft = read('上一行\n/提醒 买牛奶\n下一行', caret: 9)!;
    expect(draft.title, '买牛奶');
    expect(draft.contentWithTitle('上一行\n/提醒 买牛奶\n下一行', '买酸奶'), '上一行\n买酸奶\n下一行');
    expect(read('https://example.com/提醒'), isNull);
  });
}
