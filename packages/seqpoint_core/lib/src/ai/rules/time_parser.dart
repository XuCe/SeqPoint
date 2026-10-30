/// 时间解析结果。
class ParsedTime {
  const ParsedTime({
    required this.dateTime,
    required this.matchedText,
    this.hasExplicitClock = false,
    this.recurrence,
  });

  /// 解析出的绝对时刻。只有日期时，时刻为当天 00:00。
  final DateTime dateTime;

  /// 命中的原文片段，供调用方从标题中剥离。
  final String matchedText;

  /// 是否含具体时刻。false 表示只有日期——提醒策略据此区分：
  /// 有时刻的提前 15 分钟提醒，只有日期的当天 09:00 提醒。
  final bool hasExplicitClock;

  /// 周期表达，如 'weekly:1' 表示每周一、'daily' 每天、'monthly:5' 每月 5 号。
  final String? recurrence;

  bool get isRecurring => recurrence != null;
}

/// 中文相对时间解析。纯本地规则，不调用模型。
///
/// 覆盖："明天下午三点""周五前""下周一""每周一""3 天后""今晚"等常见说法。
/// 解析不出来就返回 null，交给模型层兜底——宁可不解析，也不要猜错时间。
///
/// 设计取舍：只认高置信度的表达。像"回头""过几天"这种模糊说法一律不猜。
class TimeParser {
  const TimeParser();

  /// 只有日期时的默认时刻，与提醒策略中"只有日期 → 当天 09:00"一致。
  static const defaultHour = 9;

  ParsedTime? parse(String text, DateTime now) {
    // 周期表达优先：它同时给出首次发生时间。
    final recurring = _parseRecurrence(text, now);
    if (recurring != null) return recurring;

    // "今晚""明早"这类词一个词同时给出日期和时刻，单独处理，
    // 否则日期分支和时刻分支会各自命中同一片段，剥离时出现重复。
    if (_dayPeriod.hasMatch(text)) return _parseDayPeriod(text, now);

    final date = _parseDate(text, now);
    if (date == null && _weekRange.hasMatch(text)) return null;
    final dateStart = date == null ? 0 : text.indexOf(date.matched);
    final beforeDate = text.substring(0, dateStart);
    final afterDate = date == null
        ? text : text.substring(dateStart + date.matched.length);
    final clock = _parseClock(afterDate, hasDate: date != null) ??
        _parseClock(beforeDate);
    if (clock == null && [afterDate, beforeDate].any((part) =>
        _clockWithMinute.hasMatch(part) || _clockHourOnly.hasMatch(part))) {
      return null;
    }

    if (date == null && clock == null) return null;

    // 只有时刻没有日期：今天该时刻；若已过则顺延到明天。
    if (date == null) {
      final today = DateTime(
          now.year, now.month, now.day, clock!.hour, clock.minute);
      final target = today.isAfter(now) ? today : DateTime(
          now.year, now.month, now.day + 1, clock.hour, clock.minute);
      return ParsedTime(
        dateTime: target,
        matchedText: clock.matched,
        hasExplicitClock: true,
      );
    }

    // 只有日期：用默认时刻。
    if (clock == null) {
      return ParsedTime(
        dateTime: DateTime(
            date.date.year, date.date.month, date.date.day, defaultHour),
        matchedText: date.matched,
        hasExplicitClock: false,
      );
    }

    return ParsedTime(
      dateTime: DateTime(date.date.year, date.date.month, date.date.day,
          clock.hour, clock.minute),
      matchedText: '${date.matched}${clock.matched}',
      hasExplicitClock: true,
    );
  }

  // ---- 周期 ----

  static final _everyWeekday =
      RegExp(r'每(?:个)?(?:周|星期|礼拜)([一二三四五六日天1-7])');
  static final _everyMonthDay = RegExp(r'每(?:个)?月(\d{1,2})[号日]');
  static final _everyDay = RegExp(r'每天|每日');

  ParsedTime? _parseRecurrence(String text, DateTime now) {
    final wm = _everyWeekday.firstMatch(text);
    if (wm != null) {
      final weekday = _weekdayValue(wm.group(1)!);
      if (weekday != null) {
        final next = _nextWeekday(now, weekday, allowToday: true);
        return ParsedTime(
          dateTime: _atDefaultHour(next),
          matchedText: wm.group(0)!,
          recurrence: 'weekly:$weekday',
        );
      }
    }

    final mm = _everyMonthDay.firstMatch(text);
    if (mm != null) {
      final day = int.parse(mm.group(1)!);
      if (day >= 1 && day <= 31) {
        var target = DateTime(now.year, now.month, day, defaultHour);
        if (target.isBefore(now)) {
          target = DateTime(now.year, now.month + 1, day, defaultHour);
        }
        return ParsedTime(
          dateTime: target,
          matchedText: mm.group(0)!,
          recurrence: 'monthly:$day',
        );
      }
    }

    final dm = _everyDay.firstMatch(text);
    if (dm != null) {
      return ParsedTime(
        dateTime: _atDefaultHour(DateTime(now.year, now.month, now.day + 1)),
        matchedText: dm.group(0)!,
        recurrence: 'daily',
      );
    }

    return null;
  }

  // ---- 日期 ----

  static final _absoluteDate = RegExp(r'(\d{1,2})\s*月\s*(\d{1,2})\s*[号日]');
  static final _relativeDay =
      RegExp(r'(前天|昨天|今天|今日|明天|明日|后天|大后天)');
  static final _daysLater = RegExp(r'(\d{1,3})\s*天(?:之)?后');
  static final _weekRef =
      RegExp(r'(这|本|下|下下|上)?(?:个)?(?:周|星期|礼拜)([一二三四五六日天]|[1-7](?![\d:：点]))');
  static final _weekRange =
      RegExp(r'(?:这|本|下下|下|上)(?:个)?(?:周|星期|礼拜)');

  _DateMatch? _parseDate(String text, DateTime now) {
    final am = _absoluteDate.firstMatch(text);
    if (am != null) {
      final month = int.parse(am.group(1)!);
      final day = int.parse(am.group(2)!);
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        var target = DateTime(now.year, month, day);
        // 今年已过的日期视作明年。
        if (target.isBefore(DateTime(now.year, now.month, now.day))) {
          target = DateTime(now.year + 1, month, day);
        }
        return _DateMatch(target, am.group(0)!);
      }
    }

    final rm = _relativeDay.firstMatch(text);
    if (rm != null) {
      final offset = switch (rm.group(1)!) {
        '前天' => -2,
        '昨天' => -1,
        '今天' || '今日' => 0,
        '明天' || '明日' => 1,
        '后天' => 2,
        '大后天' => 3,
        _ => 0,
      };
      final base = DateTime(now.year, now.month, now.day);
      return _DateMatch(DateTime(base.year, base.month, base.day + offset), rm.group(0)!);
    }

    final dm = _daysLater.firstMatch(text);
    if (dm != null) {
      final days = int.parse(dm.group(1)!);
      final base = DateTime(now.year, now.month, now.day);
      return _DateMatch(DateTime(base.year, base.month, base.day + days), dm.group(0)!);
    }

    final wm = _weekRef.firstMatch(text);
    if (wm != null) {
      final weekday = _weekdayValue(wm.group(2)!);
      if (weekday != null) {
        final prefix = wm.group(1);
        final target = switch (prefix) {
          '下' => _nextWeekday(now, weekday, allowToday: false, weekOffset: 1),
          '下下' => _nextWeekday(now, weekday, allowToday: false, weekOffset: 2),
          '上' => _nextWeekday(now, weekday, allowToday: false, weekOffset: -1),
          // 「这周五」「周五」都指本周内的那天；已过则顺延到下周。
          _ => _nextWeekday(now, weekday, allowToday: true),
        };
        return _DateMatch(target, wm.group(0)!);
      }
    }

    return null;
  }

  /// "今晚""明早"这类日期与时段合一的词。
  ///
  /// 单独处理的原因：若让日期分支和时刻分支各自匹配同一个词，
  /// 拼出的 matchedText 会重复（"今晚今晚"），调用方剥离标题时会出错。
  static final _dayPeriod = RegExp(
      r'(今|明|后)(晚上|晚|早上|早|上午|下午|中午)');

  ParsedTime? _parseDayPeriod(String text, DateTime now) {
    final m = _dayPeriod.firstMatch(text);
    if (m == null) return null;

    final dayOffset = switch (m.group(1)!) {
      '今' => 0,
      '明' => 1,
      '后' => 2,
      _ => 0,
    };
    final hour = switch (m.group(2)!) {
      '早上' || '早' => 8,
      '上午' => 9,
      '中午' => 12,
      '下午' => 15,
      '晚上' || '晚' => 20,
      _ => defaultHour,
    };

    final base = DateTime(now.year, now.month, now.day);
    final day = DateTime(base.year, base.month, base.day + dayOffset);

    // 词后若还跟着具体时刻（"今晚八点"），以具体时刻为准。
    final tail = text.substring(m.end);
    final clock = _parseClock(tail, inheritedPeriod: m.group(2));
    if (clock == null &&
        (_clockWithMinute.hasMatch(tail) || _clockHourOnly.hasMatch(tail))) {
      return null;
    }
    if (clock != null) {
      if ((m.group(2) == '晚' || m.group(2) == '晚上') &&
          clock.matched.trimLeft().startsWith('凌晨')) {
        return null;
      }
      return ParsedTime(
        dateTime:
            DateTime(day.year, day.month, day.day, clock.hour, clock.minute),
        matchedText: '${m.group(0)!}${clock.matched}',
        hasExplicitClock: true,
      );
    }

    return ParsedTime(
      dateTime: DateTime(day.year, day.month, day.day, hour),
      matchedText: m.group(0)!,
      hasExplicitClock: true,
    );
  }

  // ---- 时刻 ----

  static final _clockWithMinute =
      RegExp(r'(上午|下午|晚上|晚|中午|早上|凌晨)?\s*(\d{1,2})\s*[:：]\s*(\d{2})');
  static final _clockHourOnly = RegExp(
      r'(上午|下午|晚上|晚|中午|早上|凌晨)?\s*([0-9]{1,2}|[零一二两三四五六七八九十]{1,3})\s*点(?:\s*(半|[0-9]{1,2}\s*分))?');
  static final _periodOnly = RegExp(r'(上午|下午|晚上|中午|早上|凌晨|^晚(?=\s*$))');
  static final _numberCharacter = RegExp(r'[0-9零一二两三四五六七八九十百千万亿]');
  static final _trailingMinutes = RegExp(r'^\s*[0-9]+\s*分');

  _ClockMatch? _parseClock(String text,
      {String? inheritedPeriod, bool hasDate = false}) {
    final wm = _clockWithMinute.firstMatch(text);
    if (wm != null) {
      final start = wm.start + wm.group(0)!.indexOf(wm.group(2)!);
      if ((start > 0 && _numberCharacter.hasMatch(text[start - 1])) ||
          (wm.end < text.length && _numberCharacter.hasMatch(text[wm.end]))) {
        return null;
      }
      final period = wm.group(1) ?? inheritedPeriod;
      var hour = int.parse(wm.group(2)!);
      final minute = int.parse(wm.group(3)!);
      if (hour <= 23 && minute <= 59) {
        if ((period == '晚' || period == '晚上') && hour >= 1 && hour <= 5) {
          return null;
        }
        hour = _applyPeriod(hour, period);
        return _ClockMatch(hour, minute, wm.group(0)!);
      }
      return null;
    }

    final hm = _clockHourOnly.firstMatch(text);
    if (hm != null) {
      final start = hm.start + hm.group(0)!.indexOf(hm.group(2)!);
      final tail = text.substring(hm.end);
      if ((start > 0 && _numberCharacter.hasMatch(text[start - 1])) ||
          (hm.group(3) == null &&
              ((tail.isNotEmpty && _numberCharacter.hasMatch(tail[0])) ||
                  _trailingMinutes.hasMatch(tail)))) {
        return null;
      }
      final period = hm.group(1) ?? inheritedPeriod;
      final hour = _hourValue(hm.group(2)!);
      if (hour != null && hour <= 23) {
        if ((period == '晚' || period == '晚上') && hour >= 1 && hour <= 5) {
          return null;
        }
        var minute = 0;
        final minutePart = hm.group(3);
        if (minutePart != null) {
          minute = minutePart.contains('半')
              ? 30
              : int.tryParse(minutePart.replaceAll(RegExp(r'[^\d]'), '')) ?? 0;
        }
        if (minute <= 59) {
          return _ClockMatch(_applyPeriod(hour, period), minute, hm.group(0)!);
        }
      }
      return null;
    }

    // 只有"今晚""下午"这类时段词：给个代表时刻。
    final pm = _periodOnly.firstMatch(text);
    if (pm != null) {
      if (pm.group(1) == '晚' && !hasDate) return null;
      final hour = switch (pm.group(1)!) {
        '凌晨' => 6,
        '早上' || '上午' => 9,
        '中午' => 12,
        '下午' => 15,
        '晚上' || '晚' => 20,
        _ => defaultHour,
      };
      return _ClockMatch(hour, 0, pm.group(0)!);
    }

    return null;
  }

  /// 把 12 小时制的说法折算为 24 小时制。
  static int _applyPeriod(int hour, String? period) {
    if (period == null) return hour;
    return switch (period) {
      '下午' => hour < 12 ? hour + 12 : hour,
      '晚上' || '晚' => hour == 0 || hour == 12 ? 24 : (hour < 12 ? hour + 12 : hour),
      '中午' => hour == 12 ? 12 : (hour < 12 ? hour + 12 : hour),
      '凌晨' => hour == 12 ? 0 : hour,
      '早上' || '早' || '上午' => hour,
      _ => hour,
    };
  }

  // ---- 工具 ----

  static const _cnDigits = {
    '零': 0,
    '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5,
    '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
  };

  /// 支持 "3"、"三"、"十"、"十一"、"十二" 等写法。
  static int? _hourValue(String raw) {
    final direct = int.tryParse(raw);
    if (direct != null) return direct;

    if (raw == '十') return 10;
    if (raw == '二十') return 20;
    if (raw.startsWith('二十') && raw.length == 3) {
      final unit = _cnDigits[raw[2]];
      return unit == null || unit < 1 || unit > 9 ? null : 20 + unit;
    }
    if (raw.startsWith('十') && raw.length == 2) {
      final unit = _cnDigits[raw[1]];
      return unit == null || unit < 1 || unit > 9 ? null : 10 + unit;
    }
    if (raw.length == 1) return _cnDigits[raw];
    return null;
  }

  /// 周一=1 … 周日=7，与 DateTime.weekday 一致。
  static int? _weekdayValue(String raw) {
    if (raw == '日' || raw == '天' || raw == '7') return 7;
    final n = int.tryParse(raw);
    if (n != null && n >= 1 && n <= 7) return n;
    return _cnDigits[raw];
  }

  /// 找到下一个指定星期几。
  ///
  /// [allowToday] 为 true 且今天正是那天时返回今天；
  /// [weekOffset] 非零时以本周为基准定位指定日历周。
  static DateTime _nextWeekday(
    DateTime now,
    int weekday, {
    required bool allowToday,
    int weekOffset = 0,
  }) {
    final base = DateTime(now.year, now.month, now.day);
    var delta = weekday - base.weekday;
    if (weekOffset == 0 && (delta < 0 || (delta == 0 && !allowToday))) delta += 7;
    return DateTime(base.year, base.month, base.day + delta + weekOffset * 7);
  }

  static DateTime _atDefaultHour(DateTime d) =>
      DateTime(d.year, d.month, d.day, defaultHour);
}

class _DateMatch {
  const _DateMatch(this.date, this.matched);
  final DateTime date;
  final String matched;
}

class _ClockMatch {
  const _ClockMatch(this.hour, this.minute, this.matched);
  final int hour;
  final int minute;
  final String matched;
}
