import 'package:flutter/widgets.dart';

import 'markdown_table_style.dart';

@immutable
final class MarkdownEditorThemeData {
  const MarkdownEditorThemeData({
    required this.backgroundColor,
    required this.textColor,
    required this.mutedTextColor,
    required this.accentColor,
    required this.selectionColor,
    required this.caretColor,
    required this.highlightColor,
    required this.codeBackgroundColor,
    required this.quoteBorderColor,
    required this.taskBorderColor,
    required this.taskCheckedColor,
    required this.bodyStyle,
    required this.codeStyle,
    required this.headingStyles,
    required this.contentPadding,
    required this.maxContentWidth,
    required this.taskSize,
    this.taskHitTargetSize = 32,
    this.taskHoverColor = const Color(0x147C3AED),
    this.taskFocusColor = const Color(0x247C3AED),
    this.taskPressedColor = const Color(0x337C3AED),
    this.taskDisabledColor = const Color(0x66707070),
    this.quoteBorderWidth = 2,
    this.quoteRadius = Radius.zero,
    this.quoteBackgroundColor = const Color(0x00000000),
    this.quotePadding = const EdgeInsetsDirectional.only(start: 12),
    this.quoteBlockSpacing = 0,
    this.mediaMaxWidth = 480,
    this.mediaMaxHeight = 360,
    this.mediaFit = BoxFit.contain,
    this.mediaPlaceholderColor = const Color(0x14000000),
    this.mediaErrorStyle = const TextStyle(
      color: Color(0xFF707070),
      fontSize: 14,
      fontStyle: FontStyle.italic,
    ),
    this.tableStyle = const MarkdownTableStyle(),
  }) : assert(headingStyles.length == 6),
       assert(maxContentWidth > 0),
       assert(taskSize > 0),
       assert(taskHitTargetSize >= taskSize),
       assert(quoteBorderWidth >= 0),
       assert(quoteBlockSpacing >= 0);

  factory MarkdownEditorThemeData.light() => MarkdownEditorThemeData(
    backgroundColor: const Color(0xFFFFFFFF),
    textColor: const Color(0xFF222222),
    mutedTextColor: const Color(0xFF707070),
    accentColor: const Color(0xFF7C3AED),
    selectionColor: const Color(0x337C3AED),
    caretColor: const Color(0xFF222222),
    highlightColor: const Color(0x66E0AC00),
    codeBackgroundColor: const Color(0xFFF6F6F6),
    quoteBorderColor: const Color(0xFFBDBDBD),
    taskBorderColor: const Color(0xFF707070),
    taskCheckedColor: const Color(0xFF7C3AED),
    bodyStyle: const TextStyle(
      color: Color(0xFF222222),
      fontSize: 16,
      height: 1.5,
    ),
    codeStyle: const TextStyle(
      color: Color(0xFF222222),
      fontSize: 15,
      height: 1.5,
      fontFamily: 'monospace',
    ),
    headingStyles: _headingStyles(const Color(0xFF222222)),
    contentPadding: const EdgeInsets.all(24),
    maxContentWidth: 700,
    taskSize: 18,
  );

  factory MarkdownEditorThemeData.dark() => MarkdownEditorThemeData(
    backgroundColor: const Color(0xFF1C1C1C),
    textColor: const Color(0xFFDADADA),
    mutedTextColor: const Color(0xFF999999),
    accentColor: const Color(0xFFA882FF),
    selectionColor: const Color(0x44A882FF),
    caretColor: const Color(0xFFDADADA),
    highlightColor: const Color(0x55E0DE71),
    codeBackgroundColor: const Color(0xFF282828),
    quoteBorderColor: const Color(0xFF555555),
    taskBorderColor: const Color(0xFF999999),
    taskCheckedColor: const Color(0xFFA882FF),
    bodyStyle: const TextStyle(
      color: Color(0xFFDADADA),
      fontSize: 16,
      height: 1.5,
    ),
    codeStyle: const TextStyle(
      color: Color(0xFFDADADA),
      fontSize: 15,
      height: 1.5,
      fontFamily: 'monospace',
    ),
    headingStyles: _headingStyles(const Color(0xFFDADADA)),
    contentPadding: const EdgeInsets.all(24),
    maxContentWidth: 700,
    taskSize: 18,
  );

  final Color backgroundColor;
  final Color textColor;
  final Color mutedTextColor;
  final Color accentColor;
  final Color selectionColor;
  final Color caretColor;
  final Color highlightColor;
  final Color codeBackgroundColor;
  final Color quoteBorderColor;
  final Color taskBorderColor;
  final Color taskCheckedColor;
  final TextStyle bodyStyle;
  final TextStyle codeStyle;
  final List<TextStyle> headingStyles;
  final EdgeInsets contentPadding;
  final double maxContentWidth;
  final double taskSize;
  final double taskHitTargetSize;
  final Color taskHoverColor;
  final Color taskFocusColor;
  final Color taskPressedColor;
  final Color taskDisabledColor;
  final double quoteBorderWidth;
  final Radius quoteRadius;
  final Color quoteBackgroundColor;
  final EdgeInsetsGeometry quotePadding;
  final double quoteBlockSpacing;
  final double mediaMaxWidth;
  final double mediaMaxHeight;
  final BoxFit mediaFit;
  final Color mediaPlaceholderColor;
  final TextStyle mediaErrorStyle;
  final MarkdownTableStyle tableStyle;

  MarkdownEditorThemeData copyWith({
    Color? backgroundColor,
    Color? textColor,
    Color? mutedTextColor,
    Color? accentColor,
    Color? selectionColor,
    Color? caretColor,
    Color? highlightColor,
    Color? codeBackgroundColor,
    Color? quoteBorderColor,
    Color? taskBorderColor,
    Color? taskCheckedColor,
    TextStyle? bodyStyle,
    TextStyle? codeStyle,
    List<TextStyle>? headingStyles,
    EdgeInsets? contentPadding,
    double? maxContentWidth,
    double? taskSize,
    double? taskHitTargetSize,
    Color? taskHoverColor,
    Color? taskFocusColor,
    Color? taskPressedColor,
    Color? taskDisabledColor,
    double? quoteBorderWidth,
    Radius? quoteRadius,
    Color? quoteBackgroundColor,
    EdgeInsetsGeometry? quotePadding,
    double? quoteBlockSpacing,
    double? mediaMaxWidth,
    double? mediaMaxHeight,
    BoxFit? mediaFit,
    Color? mediaPlaceholderColor,
    TextStyle? mediaErrorStyle,
    MarkdownTableStyle? tableStyle,
  }) => MarkdownEditorThemeData(
    backgroundColor: backgroundColor ?? this.backgroundColor,
    textColor: textColor ?? this.textColor,
    mutedTextColor: mutedTextColor ?? this.mutedTextColor,
    accentColor: accentColor ?? this.accentColor,
    selectionColor: selectionColor ?? this.selectionColor,
    caretColor: caretColor ?? this.caretColor,
    highlightColor: highlightColor ?? this.highlightColor,
    codeBackgroundColor: codeBackgroundColor ?? this.codeBackgroundColor,
    quoteBorderColor: quoteBorderColor ?? this.quoteBorderColor,
    taskBorderColor: taskBorderColor ?? this.taskBorderColor,
    taskCheckedColor: taskCheckedColor ?? this.taskCheckedColor,
    bodyStyle: bodyStyle ?? this.bodyStyle,
    codeStyle: codeStyle ?? this.codeStyle,
    headingStyles: headingStyles ?? this.headingStyles,
    contentPadding: contentPadding ?? this.contentPadding,
    maxContentWidth: maxContentWidth ?? this.maxContentWidth,
    taskSize: taskSize ?? this.taskSize,
    taskHitTargetSize: taskHitTargetSize ?? this.taskHitTargetSize,
    taskHoverColor: taskHoverColor ?? this.taskHoverColor,
    taskFocusColor: taskFocusColor ?? this.taskFocusColor,
    taskPressedColor: taskPressedColor ?? this.taskPressedColor,
    taskDisabledColor: taskDisabledColor ?? this.taskDisabledColor,
    quoteBorderWidth: quoteBorderWidth ?? this.quoteBorderWidth,
    quoteRadius: quoteRadius ?? this.quoteRadius,
    quoteBackgroundColor: quoteBackgroundColor ?? this.quoteBackgroundColor,
    quotePadding: quotePadding ?? this.quotePadding,
    quoteBlockSpacing: quoteBlockSpacing ?? this.quoteBlockSpacing,
    mediaMaxWidth: mediaMaxWidth ?? this.mediaMaxWidth,
    mediaMaxHeight: mediaMaxHeight ?? this.mediaMaxHeight,
    mediaFit: mediaFit ?? this.mediaFit,
    mediaPlaceholderColor: mediaPlaceholderColor ?? this.mediaPlaceholderColor,
    mediaErrorStyle: mediaErrorStyle ?? this.mediaErrorStyle,
    tableStyle: tableStyle ?? this.tableStyle,
  );

  static List<TextStyle> _headingStyles(Color color) => List.unmodifiable([
    TextStyle(
      color: color,
      fontSize: 32,
      height: 1.25,
      fontWeight: FontWeight.w700,
    ),
    TextStyle(
      color: color,
      fontSize: 26,
      height: 1.3,
      fontWeight: FontWeight.w700,
    ),
    TextStyle(
      color: color,
      fontSize: 22,
      height: 1.35,
      fontWeight: FontWeight.w600,
    ),
    TextStyle(
      color: color,
      fontSize: 19,
      height: 1.4,
      fontWeight: FontWeight.w600,
    ),
    TextStyle(
      color: color,
      fontSize: 17,
      height: 1.45,
      fontWeight: FontWeight.w600,
    ),
    TextStyle(
      color: color,
      fontSize: 16,
      height: 1.5,
      fontWeight: FontWeight.w600,
    ),
  ]);
}
