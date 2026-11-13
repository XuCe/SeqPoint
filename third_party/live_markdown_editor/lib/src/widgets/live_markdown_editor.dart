import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';
import '../direction/markdown_direction.dart';
import '../editing/markdown_editing_behavior.dart';
import '../extensions/markdown_syntax_configuration.dart';
import '../rendering/editable_markdown.dart';
import '../theme/markdown_editor_theme_data.dart';
import '../foundation/markdown_gutter.dart';
import 'markdown_component_builders.dart';
import 'markdown_editor_overlay.dart';
import 'markdown_read_view.dart';

/// A source-preserving Markdown editor with Raw, Live, and Read modes.
///
/// [LiveMarkdownEditor] renders [controller]'s Markdown source in the mode
/// selected through `controller.mode` and drives every edit back through the
/// controller, so `controller.text` remains the single source of truth and
/// round-trips unchanged between modes. Its editable engine depends only on
/// Flutter's widgets, services, and rendering layers; the default context menu
/// uses Flutter's public adaptive Material/Cupertino presentation. No
/// filesystem, network, or URL-launcher integration is required.
///
/// Non-text UI is replaceable through [componentBuilders]; links and change
/// notifications are delegated to the host through [onLinkTap], [onChanged],
/// and [onModeChanged]. The host owns the controller and must dispose it.
final class LiveMarkdownEditor extends StatefulWidget {
  /// Creates a Markdown editor bound to [controller].
  ///
  /// The editor does not persist Markdown or open links itself; supply
  /// [onChanged] and [onLinkTap] to integrate with the host application.
  const LiveMarkdownEditor({
    required this.controller,
    this.focusNode,
    this.scrollController,
    this.theme,
    this.behavior = const MarkdownEditingBehavior(),
    this.syntax = const MarkdownSyntaxConfiguration.editorDefaults(),
    this.componentBuilders = const MarkdownEditorComponentBuilders.defaults(),
    this.directionMode = MarkdownDirectionMode.aware,
    this.fallbackDirection = TextDirection.ltr,
    this.gutter = const MarkdownGutterConfiguration(),
    this.gutterStyle = const MarkdownGutterStyle(),
    this.onChanged,
    this.onSelectionChanged,
    this.onModeChanged,
    this.onLinkTap,
    super.key,
  });

  /// The source of truth for the edited Markdown and the selected mode.
  ///
  /// Owned by the host; the editor listens to it and never disposes it.
  final MarkdownEditorController controller;

  /// Optional focus node shared with the host; created internally when null.
  final FocusNode? focusNode;

  /// Optional scroll controller shared with the host; created internally
  /// when null. The same controller is retained across Raw, Live, and Read
  /// mode transitions.
  final ScrollController? scrollController;

  /// Theme for the editor surface; defaults to the light [MarkdownEditorThemeData].
  final MarkdownEditorThemeData? theme;

  /// Configures delimiter pairing, selection wrapping, list continuation,
  /// fenced-code completion, and list indentation.
  final MarkdownEditingBehavior behavior;

  /// Selects built-in, additive, and explicit-override Markdown syntax.
  final MarkdownSyntaxConfiguration syntax;

  /// Immutable builders for tasks, selection handles, and the context menu.
  final MarkdownEditorComponentBuilders componentBuilders;

  /// Gutter features (source-stable line numbers and fold affordances).
  ///
  /// Off by default. Raw and Live draw the gutter; Read renders everything.
  final MarkdownGutterConfiguration gutter;

  /// Visual tokens for the gutter; defaults match the light theme.
  final MarkdownGutterStyle gutterStyle;

  /// Per-line direction resolution for the edited surface.
  ///
  /// Defaults to [MarkdownDirectionMode.aware], which shapes every hard
  /// source line with its own first-strong bidi base.
  final MarkdownDirectionMode directionMode;

  /// Direction used for neutral lines when [directionMode] cannot infer one
  /// from the document text.
  final TextDirection fallbackDirection;

  /// Called with the full Markdown source after every user edit.
  final ValueChanged<String>? onChanged;

  /// Called with the updated selection after caret or selection changes.
  final ValueChanged<TextSelection>? onSelectionChanged;

  /// Called with the new mode after [MarkdownEditorController.mode] changes.
  final ValueChanged<MarkdownEditorMode>? onModeChanged;

  /// Called when the user activates a Markdown link in Read or Live mode;
  /// the host decides whether and how to open it.
  final ValueChanged<String>? onLinkTap;

  @override
  State<LiveMarkdownEditor> createState() => _LiveMarkdownEditorState();
}

final class _LiveMarkdownEditorState extends State<LiveMarkdownEditor> {
  late FocusNode _focusNode;
  late ScrollController _scrollController;
  late final MarkdownEditorThemeData _defaultTheme;
  late MarkdownEditorMode _lastMode;
  late String _lastText;

  bool get _ownsFocusNode => widget.focusNode == null;
  bool get _ownsScrollController => widget.scrollController == null;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _scrollController = widget.scrollController ?? ScrollController();
    _defaultTheme = MarkdownEditorThemeData.light();
    _lastMode = widget.controller.mode;
    _lastText = widget.controller.text;
    widget.controller.addListener(_handleControllerChange);
  }

  @override
  void didUpdateWidget(LiveMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChange);
      widget.controller.addListener(_handleControllerChange);
      _lastMode = widget.controller.mode;
      _lastText = widget.controller.text;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      if (oldWidget.focusNode == null) _focusNode.dispose();
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      if (oldWidget.scrollController == null) _scrollController.dispose();
      _scrollController = widget.scrollController ?? ScrollController();
    }
  }

  void _handleControllerChange() {
    if (_lastText != widget.controller.text) {
      _lastText = widget.controller.text;
      widget.onChanged?.call(_lastText);
    }
    double? modeScrollOffset;
    if (_lastMode != widget.controller.mode) {
      if (_scrollController.hasClients) {
        modeScrollOffset = _scrollController.positions.last.pixels;
      }
      _lastMode = widget.controller.mode;
      widget.onModeChanged?.call(_lastMode);
    }
    if (!mounted) return;
    setState(() {});
    if (modeScrollOffset != null) {
      _restoreScrollAfterModeChange(modeScrollOffset);
    }
  }

  void _restoreScrollAfterModeChange(double offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.positions.last;
      position.jumpTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChange);
    if (_ownsFocusNode) _focusNode.dispose();
    if (_ownsScrollController) _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme ?? _defaultTheme;
    return ColoredBox(
      color: theme.backgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = math.max(
            0.0,
            constraints.maxWidth - theme.contentPadding.horizontal,
          );
          final width = math.min(theme.maxContentWidth, availableWidth);
          return Padding(
            padding: theme.contentPadding,
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                key: const Key('markdown-content'),
                width: width,
                child: MarkdownEditorOverlay(
                  child: widget.controller.mode == MarkdownEditorMode.read
                      ? MarkdownReadView(
                          controller: widget.controller,
                          scrollController: _scrollController,
                          theme: theme,
                          componentBuilders: widget.componentBuilders,
                          syntax: widget.syntax,
                          directionMode: widget.directionMode,
                          fallbackDirection: widget.fallbackDirection,
                          onLinkTap: widget.onLinkTap,
                          onSelectionChanged: widget.onSelectionChanged,
                        )
                      : EditableMarkdown(
                          controller: widget.controller,
                          focusNode: _focusNode,
                          scrollController: _scrollController,
                          theme: theme,
                          directionMode: widget.directionMode,
                          fallbackDirection: widget.fallbackDirection,
                          behavior: widget.behavior,
                          componentBuilders: widget.componentBuilders,
                          syntax: widget.syntax,
                          onChanged: null,
                          onSelectionChanged: widget.onSelectionChanged,
                          onLinkTap: widget.onLinkTap,
                          gutter: widget.gutter,
                          gutterStyle: widget.gutterStyle,
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
