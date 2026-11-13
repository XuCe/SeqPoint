import 'package:flutter/painting.dart';

/// Feature switches for the editor gutter.
///
/// Both features are off by default so existing hosts are unaffected. Line
/// numbers and folding are Raw/Live features; the Read surface accepts the
/// configuration for sharing but never draws a gutter.
final class MarkdownGutterConfiguration {
  const MarkdownGutterConfiguration({
    this.lineNumbers = false,
    this.folding = false,
  });

  /// Reserve a number column with source-stable line numbers.
  final bool lineNumbers;

  /// Paint fold affordances and let the gutter toggle folds.
  final bool folding;

  /// Whether the gutter reserves any width.
  bool get isEnabled => lineNumbers || folding;

  MarkdownGutterConfiguration copyWith({bool? lineNumbers, bool? folding}) =>
      MarkdownGutterConfiguration(
        lineNumbers: lineNumbers ?? this.lineNumbers,
        folding: folding ?? this.folding,
      );

  @override
  bool operator ==(Object other) =>
      other is MarkdownGutterConfiguration &&
      other.lineNumbers == lineNumbers &&
      other.folding == folding;

  @override
  int get hashCode => Object.hash(lineNumbers, folding);

  @override
  String toString() =>
      'MarkdownGutterConfiguration(lineNumbers: $lineNumbers, '
      'folding: $folding)';
}

/// Visual tokens for the gutter, composed by the widget layer from the theme.
final class MarkdownGutterStyle {
  const MarkdownGutterStyle({
    this.numberStyle = const TextStyle(fontSize: 12, height: 1.4),
    this.color = const Color(0x8A000000),
    this.foldedColor = const Color(0xCC000000),
    this.chevronColor = const Color(0x8A000000),
    this.chevronSize = 12,
    this.padding = 8,
    this.gap = 6,
  });

  /// Typography for the number column.
  final TextStyle numberStyle;

  /// Number colour.
  final Color color;

  /// Number colour for folded first lines.
  final Color foldedColor;

  /// Chevron stroke colour.
  final Color chevronColor;

  /// Side of the chevron hit target.
  final double chevronSize;

  /// Horizontal padding on the gutter's outer edges.
  final double padding;

  /// Gap between the number column and the chevron slot.
  final double gap;

  MarkdownGutterStyle copyWith({
    TextStyle? numberStyle,
    Color? color,
    Color? foldedColor,
    Color? chevronColor,
    double? chevronSize,
    double? padding,
    double? gap,
  }) => MarkdownGutterStyle(
    numberStyle: numberStyle ?? this.numberStyle,
    color: color ?? this.color,
    foldedColor: foldedColor ?? this.foldedColor,
    chevronColor: chevronColor ?? this.chevronColor,
    chevronSize: chevronSize ?? this.chevronSize,
    padding: padding ?? this.padding,
    gap: gap ?? this.gap,
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownGutterStyle &&
      other.numberStyle == numberStyle &&
      other.color == color &&
      other.foldedColor == foldedColor &&
      other.chevronColor == chevronColor &&
      other.chevronSize == chevronSize &&
      other.padding == padding &&
      other.gap == gap;

  @override
  int get hashCode => Object.hash(
    numberStyle,
    color,
    foldedColor,
    chevronColor,
    chevronSize,
    padding,
    gap,
  );
}

/// Width the gutter reserves: padding, the widest number, and the chevron slot.
double markdownGutterWidth({
  required MarkdownGutterConfiguration configuration,
  required MarkdownGutterStyle style,
  required TextScaler textScaler,
  required String widestNumber,
}) {
  if (!configuration.isEnabled) return 0;
  var width = style.padding * 2;
  if (configuration.lineNumbers) {
    final painter = TextPainter(
      text: TextSpan(text: widestNumber, style: style.numberStyle),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    width += painter.width;
    painter.dispose();
  }
  if (configuration.lineNumbers && configuration.folding) {
    width += style.gap;
  }
  if (configuration.folding) width += style.chevronSize;
  return width;
}
