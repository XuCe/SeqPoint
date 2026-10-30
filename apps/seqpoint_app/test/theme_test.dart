import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/theme/seq_theme.dart';
import 'package:seqpoint_app/theme/seq_tokens.dart';

void main() {
  test('浅色主题使用暖纸白底与琥珀重点色', () {
    final t = seqLightTheme();
    expect(t.scaffoldBackgroundColor, SeqTokens.paper);
    expect(t.colorScheme.primary, SeqTokens.accentInk);
  });

  test('深色主题使用暖黑底，不是纯黑', () {
    final t = seqDarkTheme();
    expect(t.scaffoldBackgroundColor, SeqTokens.darkBg);
    expect(t.colorScheme.primary, SeqTokens.darkAccent);
  });

  test('便签纸在明暗主题下是同一张纸', () {
    expect(SeqTokens.noteYellow, const Color(0xFFF6DC85));
    expect(SeqTokens.noteInk, const Color(0xFF3A3012));
  });

  test('按钮最小高度满足移动端 44px 触达标准', () {
    final t = seqLightTheme();
    final filled = t.filledButtonTheme.style!.minimumSize!
        .resolve({}) as Size;
    expect(filled.height, greaterThanOrEqualTo(SeqSpace.minTapTarget));
  });
}
