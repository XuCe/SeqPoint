import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  const parser = TimeParser();
  for (final (now, phrase, expected) in [
    (DateTime(2026, 9, 5, 10), '下周一', DateTime(2026, 9, 7, 9)),
    (DateTime(2026, 9, 5, 10), '下周五', DateTime(2026, 9, 11, 9)),
    (DateTime(2026, 9, 7, 10), '下周一', DateTime(2026, 9, 14, 9)),
    (DateTime(2026, 9, 6, 10), '下周一', DateTime(2026, 9, 7, 9)),
    (DateTime(2026, 9, 6, 10), '下下周一', DateTime(2026, 9, 14, 9)),
    (DateTime(2026, 9, 6, 10), '上周五', DateTime(2026, 8, 28, 9)),
    (DateTime(2026, 9, 4, 10), '下周五', DateTime(2026, 9, 11, 9)),
    (DateTime(2026, 9, 5, 10), '下个星期日', DateTime(2026, 9, 13, 9)),
    (DateTime(2026, 9, 5, 10), '下礼拜六', DateTime(2026, 9, 12, 9)),
    (DateTime(2026, 12, 31, 10), '下周一', DateTime(2027, 1, 4, 9)),
    (DateTime(2026, 3, 1, 10), '下周一', DateTime(2026, 3, 2, 9)),
    (DateTime(2026, 9, 9, 10), '上周五', DateTime(2026, 9, 4, 9)),
  ]) {
    test('日历周 $phrase / $now', () {
      final result = parser.parse('$phrase开会', now)!;
      expect(result.dateTime, expected);
      expect(result.matchedText, phrase);
      expect(result.hasExplicitClock, isFalse);
      expect('$phrase开会'.replaceFirst(result.matchedText, '').trim(), '开会');
    });
  }

  for (final (now, phrase, expected) in [
    (DateTime(2026, 9, 5, 10), '今晚八点', DateTime(2026, 9, 5, 20)),
    (DateTime(2026, 9, 5, 10), '今晚8点', DateTime(2026, 9, 5, 20)),
    (DateTime(2026, 9, 5, 10), '今晚八点半', DateTime(2026, 9, 5, 20, 30)),
    (DateTime(2026, 9, 5, 10), '今晚 9:15', DateTime(2026, 9, 5, 21, 15)),
    (DateTime(2026, 9, 5, 10), '今晚上十一点', DateTime(2026, 9, 5, 23)),
    (DateTime(2026, 9, 5, 10), '今晚21:45', DateTime(2026, 9, 5, 21, 45)),
    (DateTime(2026, 9, 5, 10), '今晚二十一点', DateTime(2026, 9, 5, 21)),
    (DateTime(2026, 9, 5, 10), '今晚十二点', DateTime(2026, 9, 6)),
    (DateTime(2026, 9, 5, 10), '今晚00:30', DateTime(2026, 9, 6, 0, 30)),
    (DateTime(2026, 9, 5, 10), '今晚零点', DateTime(2026, 9, 6)),
    (DateTime(2026, 9, 5, 10), '今晚零点半', DateTime(2026, 9, 6, 0, 30)),
    (DateTime(2026, 9, 5, 10), '明天凌晨零点', DateTime(2026, 9, 6)),
    (DateTime(2026, 9, 5, 10), '明天晚上十二点', DateTime(2026, 9, 7)),
    (DateTime(2026, 9, 5, 10), '明早八点', DateTime(2026, 9, 6, 8)),
    (DateTime(2026, 9, 5, 10), '明下午三点', DateTime(2026, 9, 6, 15)),
    (DateTime(2026, 9, 5, 10), '明天下午两点', DateTime(2026, 9, 6, 14)),
    (DateTime(2026, 9, 5, 10), '明天上午十二点', DateTime(2026, 9, 6, 12)),
    (DateTime(2026, 9, 5, 10), '明早十二点', DateTime(2026, 9, 6, 12)),
    (DateTime(2026, 9, 5, 10), '明天中午十二点', DateTime(2026, 9, 6, 12)),
    (DateTime(2026, 9, 5, 10), '明天凌晨十二点', DateTime(2026, 9, 6)),
    (DateTime(2026, 9, 5, 10), '后晚七点', DateTime(2026, 9, 7, 19)),
    (DateTime(2026, 9, 5, 22), '今晚八点', DateTime(2026, 9, 5, 20)),
    (DateTime(2026, 9, 5, 22), '今晚', DateTime(2026, 9, 5, 20)),
    (DateTime(2026, 9, 5, 10), '下周1 15:00', DateTime(2026, 9, 7, 15)),
    (DateTime(2026, 9, 5, 10), '下周7晚上八点', DateTime(2026, 9, 13, 20)),
    (DateTime(2026, 9, 5, 10), '下周一晚八点', DateTime(2026, 9, 7, 20)),
  ]) {
    test('时段 $phrase / $now', () {
      final result = parser.parse('$phrase提交', now)!;
      expect(result.dateTime, expected);
      expect(result.matchedText, phrase);
      expect(result.hasExplicitClock, isTrue);
      expect('$phrase提交'.replaceFirst(result.matchedText, '').trim(), '提交');
    });
  }
  test('独立的晚表示当天晚间', () {
    final result = parser.parse('下周一晚', DateTime(2026, 9, 5, 10))!;
    expect(result.dateTime, DateTime(2026, 9, 7, 20));
    expect(result.matchedText, '下周一晚');
    expect(result.hasExplicitClock, isTrue);
  });
  for (final title in ['晚些提交', '晚点提交', '晚会排练']) {
    test('短晚不会消费正文：$title', () {
      final result = parser.parse('下周一$title', DateTime(2026, 9, 5, 10))!;
      expect(result.dateTime, DateTime(2026, 9, 7, 9));
      expect(result.matchedText, '下周一');
      expect(result.hasExplicitClock, isFalse);
      expect('下周一$title'.replaceFirst(result.matchedText, ''), title);
    });
  }
  for (final (now, phrase, expected) in [
    (DateTime(2026, 11, 1, 0, 30), '明天', DateTime(2026, 11, 2, 9)),
    (DateTime(2026, 10, 31, 23, 30), '后天', DateTime(2026, 11, 2, 9)),
    (DateTime(2026, 11, 1, 0, 30), '明晚八点', DateTime(2026, 11, 2, 20)),
    (DateTime(2026, 11, 1, 0, 30), '3天后', DateTime(2026, 11, 4, 9)),
    (DateTime(2026, 11, 1, 0, 30), '每天', DateTime(2026, 11, 2, 9)),
    (DateTime(2026, 3, 7, 23, 30), '每天', DateTime(2026, 3, 8, 9)),
    (DateTime(2026, 3, 7, 23), '8点', DateTime(2026, 3, 8, 8)),
    (DateTime(2026, 10, 31, 23), '8点', DateTime(2026, 11, 1, 8)),
    (DateTime(2026, 3, 8, 0, 30), '明早八点', DateTime(2026, 3, 9, 8)),
    (DateTime(2026, 11, 1, 0, 30), '下周一', DateTime(2026, 11, 2, 9)),
    (DateTime(2026, 3, 8, 0, 30), '下周一', DateTime(2026, 3, 9, 9)),
    (DateTime(2026, 12, 31, 23, 30), '明天', DateTime(2027, 1, 1, 9)),
    (DateTime(2028, 2, 28, 22), '后天', DateTime(2028, 3, 1, 9)),
    (DateTime(2026, 3, 9, 12), '昨天', DateTime(2026, 3, 8, 9)),
  ]) {
    test('日历日期 $phrase / $now', () {
      final result = parser.parse('$phrase提交', now)!;
      expect(result.dateTime, expected);
      expect(result.matchedText, phrase);
    });
  }

  for (final phrase in ['下周交报告', '下周下午3点交报告', '下个星期晚上8点交报告',
    '下下周10:30交报告', '下周12点交报告']) {
    test('未指定星期保留待确认：$phrase', () {
      expect(parser.parse(phrase, DateTime(2026, 9, 5, 10)), isNull);
    });
  }
  for (final phrase in ['今晚25点提交', '今晚上25:90提交', '明天25点提交',
    '明天上午8:99提交', '下周一二十五点提交', '明天下午二十四点提交',
    '今晚23:60提交', '今晚二十五点提交']) {
    test('非法时刻不猜默认期限：$phrase', () {
      expect(parser.parse(phrase, DateTime(2026, 9, 5, 10)), isNull);
    });
  }
  for (final phrase in ['今晚1点提交', '今晚五点提交', '明天晚上一点提交',
    '今晚凌晨1点提交', '明晚凌晨一点提交']) {
    test('晚间歧义不猜期限：$phrase', () {
      expect(parser.parse(phrase, DateTime(2026, 9, 5, 10)), isNull);
    });
  }
  for (final phrase in ['今晚123点提交', '今晚8:590提交', '今晚八点100分提交',
    '今晚八点 100分提交', '今晚一百二十三点提交', '今晚十零点提交', '今晚十十点提交']) {
    test('非法数字时刻不可截断：$phrase', () {
      expect(parser.parse(phrase, DateTime(2026, 9, 5, 10)), isNull);
    });
  }
  for (final (text, expected, matched, title) in [
    ('8:59 0号会议室', DateTime(2026, 9, 6, 8, 59), '8:59', '0号会议室'),
    ('今晚八点半100分题目', DateTime(2026, 9, 5, 20, 30), '今晚八点半', '100分题目'),
  ]) {
    test('任务正文的数字不会被错误消费：$text', () {
      final result = parser.parse(text, DateTime(2026, 9, 5, 10))!;
      expect(result.dateTime, expected);
      expect(result.matchedText, matched);
      expect(text.replaceFirst(result.matchedText, '').trim(), title);
    });
  }
  test('星期里的数字不会误当成几点，也不会损坏任务标题', () {
    final result = parser.parse('下周三点名', DateTime(2026, 9, 5, 10))!;
    expect(result.dateTime, DateTime(2026, 9, 9, 9));
    expect(result.hasExplicitClock, isFalse);
    expect(result.matchedText, '下周三');
    expect('下周三点名'.replaceFirst(result.matchedText, ''), '点名');
  });
}
