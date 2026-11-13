// ignore_for_file: prefer_initializing_formals

import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';
import '../model/source_range.dart';
import '../theme/markdown_editor_theme_data.dart';
import 'default_markdown_media.dart';
import 'default_task_toggle.dart';

/// Builds the widget that toggles a task checkbox for [value].
/// Return null is not supported; fall back to the default toggle by
/// returning `DefaultTaskToggle(context: value)`.
typedef MarkdownTaskToggleBuilder = Widget Function(
  BuildContext context,
  MarkdownTaskToggleContext value,
);

/// Builds a selection-handle widget for [value].
typedef MarkdownSelectionHandleBuilder = Widget Function(
  BuildContext context,
  MarkdownSelectionHandleContext value,
);

/// Builds the widget that presents a Markdown image for [value].
///
/// Hosts replace the default bounded network/asset widget with their own
/// cached-image widget; the returned widget is placed atomically in the
/// projection and must not navigate or mutate the document itself.
typedef MarkdownMediaBuilder = Widget Function(
  BuildContext context,
  MarkdownMediaContext value,
);

/// Loading state of the resolved image destination.
enum MarkdownMediaLoadState { loading, ready, failed }

/// Complete immutable configuration for one Markdown image presentation.
@immutable
final class MarkdownMediaContext {
  /// Creates a media context.
  const MarkdownMediaContext({
    required this.destination,
    required this.alt,
    required this.title,
    required this.sourceRange,
    required this.mode,
    required this.textDirection,
    required this.constraints,
    required this.loadState,
    required this.theme,
    this.linkedDestination,
  });

  /// Resolved image destination (URI-normalized, without `asset:` handling).
  final String destination;

  /// Alt text from the image's label, or null when absent.
  final String? alt;

  /// Optional title from the image's title attribute.
  final String? title;

  /// Exact source range of the whole image construct in UTF-16 offsets.
  final SourceRange sourceRange;

  /// Mode the image renders in.
  final MarkdownEditorMode mode;

  /// Direction of the line containing the image.
  final TextDirection textDirection;

  /// Bounds the presentation should stay within; null means theme defaults.
  final BoxConstraints? constraints;

  /// Current resolved-image loading state.
  final MarkdownMediaLoadState loadState;

  /// Theme tokens for default presentation.
  final MarkdownEditorThemeData theme;

  /// Destination of the enclosing link, or null when the image is standalone.
  ///
  /// A linked image never carries its own activation; the enclosing link owns
  /// the single tap action.
  final String? linkedDestination;
}

/// Which end of the selection a handle anchors.
enum MarkdownSelectionHandleKind { start, end, collapsed }

/// Complete immutable configuration for one task toggle in the editor.
@immutable
final class MarkdownTaskToggleContext {
  /// Creates a task toggle context.
  const MarkdownTaskToggleContext({
    required this.sourceRange,
    required this.checked,
    required this.enabled,
    required this.textDirection,
    required this.theme,
    required this.onToggle,
  });

  /// Exact source range of the task `[ ]` / `[x]` marker, in UTF-16 offsets.
  final SourceRange sourceRange;

  /// Whether the task currently renders as completed.
  final bool checked;

  /// Whether the task can currently be toggled (false in read-only mode).
  final bool enabled;

  /// Direction of the line containing the task.
  final TextDirection textDirection;

  /// Theme the toggle should render with.
  final MarkdownEditorThemeData theme;

  /// Atomically toggles the task in the source; safe to call any time.
  final VoidCallback onToggle;
}

/// Complete immutable configuration for one selection handle.
@immutable
final class MarkdownSelectionHandleContext {
  /// Creates a selection-handle context.
  const MarkdownSelectionHandleContext({
    required this.kind,
    required this.textDirection,
    required this.theme,
  });

  /// Which selection anchor this handle belongs to.
  final MarkdownSelectionHandleKind kind;

  /// Direction of the selection's text.
  final TextDirection textDirection;

  /// Theme the handle should render with.
  final MarkdownEditorThemeData theme;
}

/// Immutable builders for the editor's non-text controls.
///
/// Supply any subset; omitted builders fall back to the default widgets
/// ([DefaultTaskToggle] and the toolbox's foundation-only selection handles).
@immutable
final class MarkdownEditorComponentBuilders {
  /// Creates a builders set with the given overrides.
  const MarkdownEditorComponentBuilders({
    this.taskToggleBuilder,
    this.selectionHandleBuilder,
    this.mediaBuilder,
  });

  /// Builders set that uses the default widgets for every control.
  const MarkdownEditorComponentBuilders.defaults()
    : taskToggleBuilder = null,
      selectionHandleBuilder = null,
      mediaBuilder = null;

  /// Override for task checkboxes, or null for the default toggle.
  final MarkdownTaskToggleBuilder? taskToggleBuilder;

  /// Override for selection handles, or null for Flutter's platform-adaptive
  /// Material/Cupertino handle.
  ///
  /// The package retains source-aware positioning, hit targets, and dragging;
  /// this builder replaces only the visual handle.
  final MarkdownSelectionHandleBuilder? selectionHandleBuilder;

  /// Override for Markdown image presentation, or null for the default
  /// bounded network/asset widget.
  final MarkdownMediaBuilder? mediaBuilder;

  /// Builds the task widget, using [DefaultTaskToggle] when no override set.
  Widget buildTaskToggle(
    BuildContext buildContext, {
    required MarkdownTaskToggleContext context,
  }) =>
      taskToggleBuilder?.call(buildContext, context) ??
      DefaultTaskToggle(context: context);

  /// Builds the media widget, using [DefaultMarkdownMedia] when no override
  /// set.
  Widget buildMedia(
    BuildContext buildContext, {
    required MarkdownMediaContext context,
  }) =>
      mediaBuilder?.call(buildContext, context) ??
      DefaultMarkdownMedia(context: context);
}
