import 'package:flutter/material.dart';

/// 设计令牌。数值来自定稿的效果图。
///
/// 暖纸白底 + 琥珀重点 + 便签纸黄。便签纸在明暗主题下保持同色——纸就是纸。
abstract final class SeqTokens {
  // 浅色
  static const paper = Color(0xFFFAF8F3);
  static const raised = Color(0xFFFFFFFF);
  static const ink = Color(0xFF262219);
  static const inkMuted = Color(0xFF6E675A);
  static const line = Color(0xFFE7E1D2);
  static const lineSoft = Color(0xFFF0EBDE);
  static const accent = Color(0xFFF1C232);
  static const accentSoft = Color(0xFFFBF0CC);
  static const accentInk = Color(0xFF8A6B14);

  // 语义色
  static const goodInk = Color(0xFF3E7A4E);
  static const goodBg = Color(0xFFE4F0E5);
  static const dangerInk = Color(0xFFA0453E);
  static const dangerBg = Color(0xFFF5E2DF);

  // 便签纸（明暗一致）
  static const noteYellow = Color(0xFFF6DC85);
  static const noteInk = Color(0xFF3A3012);

  // 深色
  static const darkBg = Color(0xFF1B1915);
  static const darkRaised = Color(0xFF242019);
  static const darkInk = Color(0xFFECE7DB);
  static const darkInkMuted = Color(0xFFA39B89);
  static const darkLine = Color(0xFF3B362A);
  static const darkAccent = Color(0xFFE5BE44);
  static const darkAccentSoft = Color(0xFF3B3319);

  /// 便签可选底色。
  static const noteColors = <String, Color>{
    'yellow': noteYellow,
    'blue': Color(0xFFCFE0EC),
    'green': Color(0xFFD3E5D0),
    'pink': Color(0xFFF0D6D9),
    'gray': Color(0xFFE4E0D6),
  };
}

/// 字体。标题衬线、正文无衬线。
abstract final class SeqFonts {
  static const serif = ['Noto Serif SC', 'Songti SC', 'serif'];
  static const sans = [
    'Noto Sans SC',
    'PingFang SC',
    'Microsoft YaHei',
    'sans-serif'
  ];
}

/// 间距与圆角。
abstract final class SeqSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const radiusCard = 14.0;
  static const radiusControl = 10.0;

  /// 移动端最小可点击高度。
  static const minTapTarget = 44.0;
}
