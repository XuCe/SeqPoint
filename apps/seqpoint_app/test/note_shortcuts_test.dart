import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/shared/note_shortcuts.dart';

void main() {
  test('选区清单保留已勾项、缩进与选区末尾下一行', () {
    const text = '  买菜\n- [x] 牛奶\n\n3. 茶\n下一行';
    final result = asNoteChecklist(
      TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: text.indexOf('下一行'), extentOffset: 0),
      ),
    );
    expect(result.text, '  - [ ] 买菜\n- [x] 牛奶\n\n- [ ] 茶\n下一行');
    expect(result.selection.baseOffset, greaterThan(result.selection.extentOffset));
  });
  TextEditingValue atEnd(String text, {TextRange composing = TextRange.empty}) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
    composing: composing,
  );

  test('在选区贴网址生成链接，直接粘贴或粘贴普通文字保留原文', () {
    const selected = TextEditingValue(
      text: '看报价单',
      selection: TextSelection(baseOffset: 1, extentOffset: 4),
    );
    expect(
      noteShortcut(selected, atEnd('看https://example.org/'))?.text,
      '看[报价单](https://example.org/)',
    );
    expect(noteShortcut(atEnd(''), atEnd('https://example.org/')), isNull);
    expect(noteShortcut(selected, atEnd('看普通文本')), isNull);
  });

  test('行首编号、顿号和勾选简写，保留正文和光标', () {
    for (final (before, after, expected) in [
      ('1.', '1.买', '1. 买'),
      ('前文\n12', '前文\n12、', '前文\n12. '),
      ('[]', '[] ', '- [ ] '),
      ('1.', '1.5', '1.5'),
      ('价格1.', '价格1.买', '价格1.买'),
      ('', '1.买菜', '1.买菜'),
    ]) {
      final result = noteShortcut(atEnd(before), atEnd(after));
      expect(result ?? atEnd(after), atEnd(expected));
    }
  });

  test('中文输入法选字提交后才处理，撤销转换保留原文', () {
    final composing = atEnd('1.mai', composing: const TextRange(start: 2, end: 5));
    expect(noteShortcut(atEnd('1.'), composing), isNull);
    expect(noteShortcut(composing, atEnd('1.买菜')), atEnd('1. 买菜'));
    expect(
      noteShortcut(atEnd('1.买菜', composing: const TextRange(start: 2, end: 4)), atEnd('1.买菜')),
      atEnd('1. 买菜'),
    );
    expect(noteShortcut(atEnd('前文\n1.'), atEnd('前文\n1.\n')), atEnd('前文\n'));
    expect(noteShortcut(atEnd('1. 买菜'), atEnd('1.买菜')), isNull);
  });
}
