import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';
import '../model/source_range.dart';
import '../theme/markdown_editor_theme_data.dart';
import 'markdown_syntax_extension.dart';

/// One ordered, source-backed part of an extension presentation.
///
/// Parts are immutable. [sourceRange] must lie inside the owning node's range;
/// the core validates ordering, overlap, coverage, and visible-text length
/// before converting parts into projection segments.
sealed class MarkdownExtensionPresentationPart {
  const MarkdownExtensionPresentationPart({required this.sourceRange});

  /// Exact UTF-16 source range this part owns.
  final SourceRange sourceRange;
}

/// Styled source-backed text. [text] must preserve the source UTF-16 length
/// of [sourceRange]; decoded values use a visible prefix plus hidden
/// remainder, exactly like core projections.
final class MarkdownExtensionTextPart
    extends MarkdownExtensionPresentationPart {
  const MarkdownExtensionTextPart({
    required super.sourceRange,
    required this.text,
    this.style,
  });

  final String text;
  final TextStyle? style;
}

/// A hidden delimiter or marker range that collapses to one visual boundary.
final class MarkdownExtensionHiddenPart
    extends MarkdownExtensionPresentationPart {
  const MarkdownExtensionHiddenPart({required super.sourceRange});
}

/// An atomic widget occupying exactly one visual placeholder for the whole
/// [sourceRange].
///
/// [id] must be unique within one projection. [builder] runs inside the
/// editor's guarded extension boundary and receives the presentation context.
final class MarkdownExtensionWidgetPart
    extends MarkdownExtensionPresentationPart {
  const MarkdownExtensionWidgetPart({
    required super.sourceRange,
    required this.id,
    required this.builder,
  });

  /// Stable widget identifier; must be unique within one projection.
  final String id;

  /// Builds the widget for the part.
  final Widget Function(
    BuildContext context,
    MarkdownExtensionPresentationContext value,
  )
  builder;
}

/// A block-level decoration (border, background) for the owning node.
final class MarkdownExtensionBlockDecoration {
  const MarkdownExtensionBlockDecoration({
    required this.kind,
    this.nestingLevel = 1,
  });

  /// Stable decoration kind, e.g. `note` or `quote`.
  final String kind;

  /// Nesting depth for stacked decorations.
  final int nestingLevel;
}

/// A validated presentation returned by an extension for one node.
///
/// [parts] must be ordered, non-overlapping, inside the node range, and may
/// cover only part of it (gaps render as literal source). Widget part IDs
/// must be unique across one projection.
final class MarkdownExtensionPresentation {
  const MarkdownExtensionPresentation({
    this.parts = const [],
    this.decoration,
    this.semanticsLabel,
    this.onActivate,
  });

  final List<MarkdownExtensionPresentationPart> parts;

  /// Optional block decoration for the owning block node.
  final MarkdownExtensionBlockDecoration? decoration;

  /// Optional semantics label for the owning construct.
  final String? semanticsLabel;

  /// Optional activation callback; the editor wraps it in one tap action.
  final VoidCallback? onActivate;
}

/// Context passed to an extension presentation hook.
final class MarkdownExtensionPresentationContext {
  const MarkdownExtensionPresentationContext({
    required this.source,
    required this.nodeRange,
    required this.mode,
    required this.activeRange,
    required this.theme,
    required this.textDirection,
    required this.session,
  });

  /// The exact document source. Never mutate it.
  final String source;

  /// Range of the node being presented.
  final SourceRange nodeRange;

  /// Mode the projection renders in.
  final MarkdownEditorMode mode;

  /// Active edit range (caret/selection/composing), or null when inactive.
  final SourceRange? activeRange;

  /// Theme tokens for the presentation.
  final MarkdownEditorThemeData theme;

  /// Direction of the line containing the node.
  final TextDirection textDirection;

  /// Per-editor session created by the extension, or null when the extension
  /// declares no session factory.
  final MarkdownSyntaxSession? session;
}
