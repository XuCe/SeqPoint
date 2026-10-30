import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  // 参照时刻：2026-09-05 周六 10:00
  final now = DateTime(2026, 9, 5, 10, 0);
  const time = TimeParser();
  const syntax = SyntaxParser();

  group('语法解析', () {
    test('提取标签与优先级，标题保持干净', () {
      final r = syntax.parse('回复张三报价 #项目A !P1');
      expect(r.cleanTitle, '回复张三报价');
      expect(r.tagNames, ['项目A']);
      expect(r.priorityName, 'p1');
    });

    test('多个标签按顺序去重', () {
      final r = syntax.parse('检查证书 #运维 #服务器 #运维');
      expect(r.tagNames, ['运维', '服务器']);
    });

    test('没有语法标记时原样返回', () {
      final r = syntax.parse('  就是一句话  ');
      expect(r.cleanTitle, '就是一句话');
      expect(r.tagNames, isEmpty);
      expect(r.priorityName, isNull);
    });

    test('小写 p 也认', () {
      expect(syntax.parse('事情 !p0').priorityName, 'p0');
    });

    test('时间短语留给 TimeParser，不被语法解析吃掉', () {
      final r = syntax.parse('联系客户 #项目A 明天下午三点');
      expect(r.cleanTitle, contains('明天下午三点'));
    });
  });

  group('时间解析 · 相对日', () {
    test('明天 → 次日默认 09:00', () {
      final r = time.parse('明天交周报', now)!;
      expect(r.dateTime, DateTime(2026, 9, 6, 9));
      expect(r.hasExplicitClock, isFalse);
    });

    test('后天', () {
      expect(time.parse('后天开会', now)!.dateTime.day, 7);
    });

    test('3 天后', () {
      expect(time.parse('3天后回访', now)!.dateTime.day, 8);
    });

    test('今天 + 时刻', () {
      final r = time.parse('今天下午3点开会', now)!;
      expect(r.dateTime, DateTime(2026, 9, 5, 15));
      expect(r.hasExplicitClock, isTrue);
    });
  });

  group('时间解析 · 时刻', () {
    test('明天下午三点（中文数字）', () {
      final r = time.parse('明天下午三点联系张经理', now)!;
      expect(r.dateTime, DateTime(2026, 9, 6, 15));
      expect(r.hasExplicitClock, isTrue);
    });

    test('冒号写法 10:30', () {
      expect(time.parse('明天 10:30 面试', now)!.dateTime,
          DateTime(2026, 9, 6, 10, 30));
    });

    test('晚上八点半', () {
      expect(time.parse('明天晚上八点半', now)!.dateTime,
          DateTime(2026, 9, 6, 20, 30));
    });

    test('十一点', () {
      expect(time.parse('明天十一点', now)!.dateTime, DateTime(2026, 9, 6, 11));
    });

    test('只有时刻且今天已过 → 顺延到明天', () {
      // now 是 10:00，说"8点"应指明天 8 点
      expect(time.parse('8点提醒我', now)!.dateTime, DateTime(2026, 9, 6, 8));
    });

    test('只有时刻且今天未到 → 就是今天', () {
      expect(time.parse('15点提醒我', now)!.dateTime, DateTime(2026, 9, 5, 15));
    });

    test('今晚', () {
      final r = time.parse('今晚整理资料', now)!;
      expect(r.dateTime.day, 5);
      expect(r.dateTime.hour, 20);
    });
  });

  group('时间解析 · 星期', () {
    test('周五（本周内，9-05 是周六 → 顺延到下周五 9-11）', () {
      expect(time.parse('周五前发周报', now)!.dateTime,
          DateTime(2026, 9, 11, 9));
    });

    test('下周一', () {
      // 9-05 周六的下一日历周从 9-07 周一开始。
      expect(time.parse('下周一开会', now)!.dateTime, DateTime(2026, 9, 7, 9));
    });

    test('星期日与周天等价', () {
      final a = time.parse('星期日', now)!.dateTime;
      final b = time.parse('周天', now)!.dateTime;
      expect(a, b);
    });
  });

  group('时间解析 · 绝对日期', () {
    test('9月20号', () {
      expect(time.parse('9月20号体检', now)!.dateTime, DateTime(2026, 9, 20, 9));
    });

    test('今年已过的日期算作明年', () {
      expect(time.parse('1月5号', now)!.dateTime.year, 2027);
    });
  });

  group('时间解析 · 周期', () {
    test('每周一', () {
      final r = time.parse('每周一检查备份', now)!;
      expect(r.recurrence, 'weekly:1');
      expect(r.isRecurring, isTrue);
      expect(r.dateTime, DateTime(2026, 9, 7, 9));
    });

    test('每天', () {
      expect(time.parse('每天喝水', now)!.recurrence, 'daily');
    });

    test('每月5号', () {
      final r = time.parse('每月5号交房租', now)!;
      expect(r.recurrence, 'monthly:5');
      // 本月 5 号已过（今天就是 5 号 10:00，09:00 已过）→ 顺延到下月
      expect(r.dateTime.month, 10);
    });
  });

  group('时间解析 · 拒绝模糊表达', () {
    test('没有时间词返回 null', () {
      expect(time.parse('回复张三报价', now), isNull);
    });

    test('模糊说法不猜', () {
      expect(time.parse('回头再说', now), isNull);
      expect(time.parse('过几天处理', now), isNull);
    });

    test('非法时刻不误判', () {
      expect(time.parse('第25点', now), isNull);
    });
  });

  test('命中片段可从标题中剥离', () {
    final r = time.parse('明天下午三点联系张经理', now)!;
    final title = '明天下午三点联系张经理'.replaceFirst(r.matchedText, '').trim();
    expect(title, '联系张经理');
  });
}
