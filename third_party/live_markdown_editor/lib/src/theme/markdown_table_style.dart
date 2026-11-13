import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';

/// Selects whether neighboring table cells share a border or own separate
/// bordered boxes.
enum MarkdownTableBorderModel { collapsed, separated }

/// The visual pattern used for one table-border side.
enum MarkdownTableBorderPattern { none, solid, dashed, dotted }

/// A logical border side for a Markdown table or table cell.
@immutable
final class MarkdownTableBorderSide {
  const MarkdownTableBorderSide({
    required this.color,
    this.width = 1,
    this.pattern = MarkdownTableBorderPattern.solid,
  }) : assert(width >= 0);

  const MarkdownTableBorderSide.none()
    : color = const Color(0x00000000),
      width = 0,
      pattern = MarkdownTableBorderPattern.none;

  final Color color;
  final double width;
  final MarkdownTableBorderPattern pattern;

  bool get isVisible =>
      width > 0 && color.a > 0 && pattern != MarkdownTableBorderPattern.none;

  MarkdownTableBorderSide copyWith({
    Color? color,
    double? width,
    MarkdownTableBorderPattern? pattern,
  }) => MarkdownTableBorderSide(
    color: color ?? this.color,
    width: width ?? this.width,
    pattern: pattern ?? this.pattern,
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownTableBorderSide &&
      color == other.color &&
      width == other.width &&
      pattern == other.pattern;

  @override
  int get hashCode => Object.hash(color, width, pattern);
}

/// A border expressed in logical table edges.
@immutable
final class MarkdownTableBorder {
  const MarkdownTableBorder({
    this.start = const MarkdownTableBorderSide.none(),
    this.top = const MarkdownTableBorderSide.none(),
    this.end = const MarkdownTableBorderSide.none(),
    this.bottom = const MarkdownTableBorderSide.none(),
  });

  const MarkdownTableBorder.all(MarkdownTableBorderSide side)
    : start = side,
      top = side,
      end = side,
      bottom = side;

  final MarkdownTableBorderSide start;
  final MarkdownTableBorderSide top;
  final MarkdownTableBorderSide end;
  final MarkdownTableBorderSide bottom;

  MarkdownResolvedTableBorder resolve(TextDirection direction) =>
      direction == TextDirection.ltr
      ? MarkdownResolvedTableBorder(
          left: start,
          top: top,
          right: end,
          bottom: bottom,
        )
      : MarkdownResolvedTableBorder(
          left: end,
          top: top,
          right: start,
          bottom: bottom,
        );

  MarkdownTableBorder copyWith({
    MarkdownTableBorderSide? start,
    MarkdownTableBorderSide? top,
    MarkdownTableBorderSide? end,
    MarkdownTableBorderSide? bottom,
  }) => MarkdownTableBorder(
    start: start ?? this.start,
    top: top ?? this.top,
    end: end ?? this.end,
    bottom: bottom ?? this.bottom,
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownTableBorder &&
      start == other.start &&
      top == other.top &&
      end == other.end &&
      bottom == other.bottom;

  @override
  int get hashCode => Object.hash(start, top, end, bottom);
}

/// A border whose sides have been resolved to physical edges.
@immutable
final class MarkdownResolvedTableBorder {
  const MarkdownResolvedTableBorder({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final MarkdownTableBorderSide left;
  final MarkdownTableBorderSide top;
  final MarkdownTableBorderSide right;
  final MarkdownTableBorderSide bottom;
}

/// Immutable information passed to a table-cell style resolver.
@immutable
final class MarkdownTableCellStyleContext {
  const MarkdownTableCellStyleContext({
    required this.mode,
    required this.row,
    required this.column,
    required this.isHeader,
    required this.isOddBodyRow,
    required this.tableDirection,
    required this.cellDirection,
  }) : assert(row >= 0),
       assert(column >= 0);

  final MarkdownEditorMode mode;
  final int row;
  final int column;
  final bool isHeader;
  final bool isOddBodyRow;
  final TextDirection tableDirection;
  final TextDirection cellDirection;
}

/// Presentation-only override for an individual table cell.
@immutable
final class MarkdownTableCellStyle {
  const MarkdownTableCellStyle({
    this.border,
    this.radius,
    this.padding,
    this.backgroundColor,
    this.textStyle,
  });

  final MarkdownTableBorder? border;
  final BorderRadiusGeometry? radius;
  final EdgeInsetsGeometry? padding;
  final Color? backgroundColor;
  final TextStyle? textStyle;

  static MarkdownTableCellStyle merge(
    MarkdownTableCellStyle base,
    MarkdownTableCellStyle? override,
  ) => override == null
      ? base
      : MarkdownTableCellStyle(
          border: override.border ?? base.border,
          radius: override.radius ?? base.radius,
          padding: override.padding ?? base.padding,
          backgroundColor: override.backgroundColor ?? base.backgroundColor,
          textStyle: override.textStyle ?? base.textStyle,
        );

  MarkdownTableCellStyle copyWith({
    MarkdownTableBorder? border,
    BorderRadiusGeometry? radius,
    EdgeInsetsGeometry? padding,
    Color? backgroundColor,
    TextStyle? textStyle,
  }) => MarkdownTableCellStyle(
    border: border ?? this.border,
    radius: radius ?? this.radius,
    padding: padding ?? this.padding,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    textStyle: textStyle ?? this.textStyle,
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownTableCellStyle &&
      border == other.border &&
      radius == other.radius &&
      padding == other.padding &&
      backgroundColor == other.backgroundColor &&
      textStyle == other.textStyle;

  @override
  int get hashCode =>
      Object.hash(border, radius, padding, backgroundColor, textStyle);
}

/// Resolves presentation-only overrides for an individual table cell.
typedef MarkdownTableCellStyleResolver = MarkdownTableCellStyle? Function(
  MarkdownTableCellStyleContext context,
);

/// Theme tokens governing table layout and decoration.
@immutable
final class MarkdownTableStyle {
  const MarkdownTableStyle({
    this.borderModel = MarkdownTableBorderModel.collapsed,
    this.outerBorder = const MarkdownTableBorder(),
    this.cellBorder = const MarkdownTableBorder(),
    this.outerRadius = BorderRadius.zero,
    this.cellRadius = BorderRadius.zero,
    this.cellPadding = EdgeInsetsDirectional.zero,
    this.columnSpacing = 0,
    this.rowSpacing = 0,
    this.backgroundColor = const Color(0x00000000),
    this.headerBackgroundColor = const Color(0x00000000),
    this.bodyBackgroundColor = const Color(0x00000000),
    this.oddRowBackgroundColor = const Color(0x00000000),
    this.evenRowBackgroundColor = const Color(0x00000000),
    this.headerTextStyle,
    this.bodyTextStyle,
    this.cellStyleResolver,
  }) : assert(columnSpacing >= 0),
       assert(rowSpacing >= 0);

  final MarkdownTableBorderModel borderModel;
  final MarkdownTableBorder outerBorder;
  final MarkdownTableBorder cellBorder;
  final BorderRadiusGeometry outerRadius;
  final BorderRadiusGeometry cellRadius;
  final EdgeInsetsGeometry cellPadding;
  final double columnSpacing;
  final double rowSpacing;
  final Color backgroundColor;
  final Color headerBackgroundColor;
  final Color bodyBackgroundColor;
  final Color oddRowBackgroundColor;
  final Color evenRowBackgroundColor;
  final TextStyle? headerTextStyle;
  final TextStyle? bodyTextStyle;
  final MarkdownTableCellStyleResolver? cellStyleResolver;

  MarkdownTableStyle copyWith({
    MarkdownTableBorderModel? borderModel,
    MarkdownTableBorder? outerBorder,
    MarkdownTableBorder? cellBorder,
    BorderRadiusGeometry? outerRadius,
    BorderRadiusGeometry? cellRadius,
    EdgeInsetsGeometry? cellPadding,
    double? columnSpacing,
    double? rowSpacing,
    Color? backgroundColor,
    Color? headerBackgroundColor,
    Color? bodyBackgroundColor,
    Color? oddRowBackgroundColor,
    Color? evenRowBackgroundColor,
    TextStyle? headerTextStyle,
    TextStyle? bodyTextStyle,
    MarkdownTableCellStyleResolver? cellStyleResolver,
  }) => MarkdownTableStyle(
    borderModel: borderModel ?? this.borderModel,
    outerBorder: outerBorder ?? this.outerBorder,
    cellBorder: cellBorder ?? this.cellBorder,
    outerRadius: outerRadius ?? this.outerRadius,
    cellRadius: cellRadius ?? this.cellRadius,
    cellPadding: cellPadding ?? this.cellPadding,
    columnSpacing: columnSpacing ?? this.columnSpacing,
    rowSpacing: rowSpacing ?? this.rowSpacing,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    headerBackgroundColor: headerBackgroundColor ?? this.headerBackgroundColor,
    bodyBackgroundColor: bodyBackgroundColor ?? this.bodyBackgroundColor,
    oddRowBackgroundColor: oddRowBackgroundColor ?? this.oddRowBackgroundColor,
    evenRowBackgroundColor:
        evenRowBackgroundColor ?? this.evenRowBackgroundColor,
    headerTextStyle: headerTextStyle ?? this.headerTextStyle,
    bodyTextStyle: bodyTextStyle ?? this.bodyTextStyle,
    cellStyleResolver: cellStyleResolver ?? this.cellStyleResolver,
  );

  @override
  bool operator ==(Object other) =>
      other is MarkdownTableStyle &&
      borderModel == other.borderModel &&
      outerBorder == other.outerBorder &&
      cellBorder == other.cellBorder &&
      outerRadius == other.outerRadius &&
      cellRadius == other.cellRadius &&
      cellPadding == other.cellPadding &&
      columnSpacing == other.columnSpacing &&
      rowSpacing == other.rowSpacing &&
      backgroundColor == other.backgroundColor &&
      headerBackgroundColor == other.headerBackgroundColor &&
      bodyBackgroundColor == other.bodyBackgroundColor &&
      oddRowBackgroundColor == other.oddRowBackgroundColor &&
      evenRowBackgroundColor == other.evenRowBackgroundColor &&
      headerTextStyle == other.headerTextStyle &&
      bodyTextStyle == other.bodyTextStyle &&
      cellStyleResolver == other.cellStyleResolver;

  @override
  int get hashCode => Object.hashAll([
    borderModel,
    outerBorder,
    cellBorder,
    outerRadius,
    cellRadius,
    cellPadding,
    columnSpacing,
    rowSpacing,
    backgroundColor,
    headerBackgroundColor,
    bodyBackgroundColor,
    oddRowBackgroundColor,
    evenRowBackgroundColor,
    headerTextStyle,
    bodyTextStyle,
    cellStyleResolver,
  ]);
}
