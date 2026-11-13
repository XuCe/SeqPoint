import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';
import '../theme/markdown_table_style.dart';
import 'markdown_gutter.dart';
import 'markdown_projection_segment.dart';
import 'markdown_selection_interaction_policy.dart';
import 'markdown_selection_overlay.dart';
import 'markdown_text_input_client.dart';

import 'package:native_adaptive_toolbox/native_adaptive_toolbox.dart';

import 'markdown_text_projection.dart';
import 'render_markdown_editable.dart';
import 'web_editing_cursor.dart';

/// A framework-neutral editable surface with an [EditableText]-compatible
/// constructor contract and extension points for Markdown projection.
///
/// The surface is fully package-owned: it renders through
/// [RenderMarkdownEditable], drives [MarkdownTextInputClient], and never
/// instantiates Flutter's `EditableText`, `EditableTextState`, or
/// `RenderEditable`.
final class MarkdownEditableText extends StatefulWidget {
  const MarkdownEditableText({
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.cursorColor,
    required this.backgroundCursorColor,
    this.readOnly = false,
    this.obscuringCharacter = '•',
    this.obscureText = false,
    this.autocorrect = true,
    this.smartDashesType = SmartDashesType.enabled,
    this.smartQuotesType = SmartQuotesType.enabled,
    this.enableSuggestions = true,
    this.strutStyle,
    this.textAlign = TextAlign.start,
    this.textDirection,
    this.locale,
    this.textScaler,
    this.forceLine = true,
    this.textHeightBehavior,
    this.textWidthBasis = TextWidthBasis.parent,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.autofocus = false,
    this.showCursor,
    this.showSelectionHandles = false,
    this.selectionColor,
    this.selectionControls,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.onAppPrivateCommand,
    this.contentInsertionConfiguration,
    this.onChanged,
    this.onEditingComplete,
    this.onSubmitted,
    this.onSelectionChanged,
    this.scrollController,
    this.scrollPhysics,
    this.scrollPadding = const EdgeInsets.all(20),
    this.dragStartBehavior = DragStartBehavior.start,
    this.enableInteractiveSelection = true,
    this.rendererIgnoresPointer = false,
    this.mouseCursor,
    this.cursorWidth = 2,
    this.cursorHeight,
    this.cursorRadius,
    this.cursorOpacityAnimates = false,
    this.cursorOffset,
    this.paintCursorAboveText = false,
    this.clipBehavior = Clip.hardEdge,
    this.onUndo,
    this.onRedo,
    this.keyboardAppearance = Brightness.light,
    this.selectAllOnFocus = false,
    this.autofillHints = const [],
    this.enableIMEPersonalizedLearning = true,
    this.hintLocales,
    this.enableInlinePrediction,
    this.blockDecorations = const [],
    this.gutter = const MarkdownGutterConfiguration(),
    this.gutterStyle = const MarkdownGutterStyle(),
    this.foldableStarts = const [],
    this.foldedStarts = const {},
    this.onToggleFold,
    this.lineDirections = const [],
    this.projection,
    this.projectionMode = MarkdownEditorMode.raw,
    this.tableStyle = const MarkdownTableStyle(),
    this.tableCellStyles = const [],
    super.key,
  }) : assert(obscuringCharacter.length == 1),
       assert(!obscureText || maxLines == 1),
       assert(maxLines == null || maxLines > 0),
       assert(minLines == null || minLines > 0),
       assert(maxLines == null || minLines == null || maxLines >= minLines),
       assert(!expands || (maxLines == null && minLines == null)),
       assert(cursorWidth >= 0);

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final Color cursorColor;
  final Color backgroundCursorColor;
  final bool readOnly;
  final String obscuringCharacter;
  final bool obscureText;
  final bool autocorrect;
  final SmartDashesType smartDashesType;
  final SmartQuotesType smartQuotesType;
  final bool enableSuggestions;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final TextScaler? textScaler;
  final bool forceLine;
  final TextHeightBehavior? textHeightBehavior;
  final TextWidthBasis textWidthBasis;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final bool autofocus;
  final bool? showCursor;
  final bool showSelectionHandles;
  final Color? selectionColor;
  final TextSelectionControls? selectionControls;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final AppPrivateCommandCallback? onAppPrivateCommand;
  final ContentInsertionConfiguration? contentInsertionConfiguration;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;
  final ValueChanged<String>? onSubmitted;
  final SelectionChangedCallback? onSelectionChanged;
  final ScrollController? scrollController;
  final ScrollPhysics? scrollPhysics;
  final EdgeInsets scrollPadding;
  final DragStartBehavior dragStartBehavior;
  final bool enableInteractiveSelection;
  final bool rendererIgnoresPointer;
  final MouseCursor? mouseCursor;
  final double cursorWidth;
  final double? cursorHeight;
  final Radius? cursorRadius;
  final bool cursorOpacityAnimates;
  final Offset? cursorOffset;
  final bool paintCursorAboveText;
  final Clip clipBehavior;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final Brightness keyboardAppearance;
  final bool selectAllOnFocus;
  final Iterable<String> autofillHints;
  final bool enableIMEPersonalizedLearning;
  final List<Locale>? hintLocales;
  final bool? enableInlinePrediction;
  final List<MarkdownBlockDecoration> blockDecorations;

  /// Gutter feature switches (line numbers, folding); off by default.
  final MarkdownGutterConfiguration gutter;

  /// Gutter visual tokens.
  final MarkdownGutterStyle gutterStyle;

  /// Source offsets where a foldable block starts (gutter chevrons).
  final List<int> foldableStarts;

  /// Source offsets whose blocks are currently folded.
  final Set<int> foldedStarts;

  /// Called when the user activates a fold affordance in the gutter.
  final ValueChanged<int>? onToggleFold;
  final List<TextDirection> lineDirections;
  final MarkdownTextProjection? projection;
  final MarkdownEditorMode projectionMode;
  final MarkdownTableStyle tableStyle;
  final List<MarkdownTableCellStyle?> tableCellStyles;

  @override
  MarkdownEditableTextState createState() => MarkdownEditableTextState();
}

/// State operations exposed by [MarkdownEditableText].
final class MarkdownEditableTextState extends State<MarkdownEditableText> {
  static const Duration _cursorBlinkInterval = Duration(milliseconds: 500);

  final GlobalKey _renderKey = GlobalKey();
  final GlobalKey<MarkdownSelectionOverlayState> _selectionOverlayKey =
      GlobalKey<MarkdownSelectionOverlayState>();
  late MarkdownTextInputClient _inputClient;
  TextInputConnection? _textInputConnection;
  MarkdownProjectionSnapshot? _projectionSnapshot;
  TextPosition? _dragBase;
  Offset? _dragGlobalPosition;
  Object? _tableDragId;
  Object? _trackpadTableId;
  int? _tableScrollbarPointer;
  Object? _tableScrollbarDragId;
  Offset? _tableScrollbarLastGlobalPosition;
  bool _suppressTableScrollbarTap = false;
  TextSelection? _selectionAtHandleDragStart;
  bool _dragAutoScrollScheduled = false;
  StreamSubscription<int>? _toolboxActionSub;
  StreamSubscription<void>? _toolboxDismissSub;
  bool _toolbarMenuShown = false;
  Timer? _toolbarHideGraceTimer;

  /// After showing the native menu, scroll-driven dismissals are ignored for
  /// this long so IME pointer replays cannot instantly kill it.
  static const Duration _toolbarHideGrace = Duration(milliseconds: 600);
  ScrollNotificationObserverState? _scrollNotificationObserver;
  AutofillScope? _autofillScope;
  Timer? _cursorBlinkTimer;
  TextEditingValue? _lastSentEditingValue;
  TextInputStyle? _lastSentStyle;
  TextRange? _autocorrectionPromptRange;
  Size? _textPlaceholderSize;
  Offset? _secondaryTapAnchor;
  Offset? _floatingCursorOrigin;
  Offset? _floatingCursorStart;
  double? _preferredVerticalCaretX;
  PointerDeviceKind? _activePointerKind;
  bool _cursorVisible = true;
  bool _hoveringInteractiveLink = false;
  bool _touchHandlesVisible = false;
  bool _textInputUpdateScheduled = false;
  bool _fontRefreshScheduled = false;
  bool _fontRefreshCompleted = false;

  RenderMarkdownEditable? get renderEditable =>
      _renderKey.currentContext?.findRenderObject() as RenderMarkdownEditable?;

  /// The immutable projection used for the current layout.
  MarkdownProjectionSnapshot get projectionSnapshot => _projectionSnapshot!;

  @visibleForTesting
  bool get debugCursorVisible => _cursorVisible;

  /// Whether the last hover resolved over an interactive part (link or
  /// inline control). On web this drives the engine editing-element cursor.
  @visibleForTesting
  bool get debugHoveringInteractive => _hoveringInteractiveLink;

  @visibleForTesting
  bool get debugCursorBlinkTimerActive => _cursorBlinkTimer?.isActive ?? false;

  @visibleForTesting
  Duration get cursorBlinkInterval => _cursorBlinkInterval;

  @visibleForTesting
  bool get cursorCurrentlyVisible => _cursorVisible;

  @visibleForTesting
  bool get debugHasInputConnection => _textInputConnection?.attached ?? false;

  @visibleForTesting
  Size? get debugTextPlaceholderSize => _textPlaceholderSize;

  @visibleForTesting
  Rect? get debugAutocorrectionPromptRect {
    final range = _autocorrectionPromptRange;
    return range == null ? null : _rectForSourceRange(range);
  }

  @visibleForTesting
  bool get debugToolbarIsShown => _toolbarMenuShown;

  bool get _shouldHaveInputConnection =>
      widget.focusNode.hasFocus && (!widget.readOnly || kIsWeb);

  bool get _shouldBlinkCursor {
    final selection = widget.controller.selection;
    return widget.focusNode.hasFocus &&
        (widget.showCursor ?? !widget.readOnly) &&
        selection.isValid &&
        selection.isCollapsed;
  }

  Axis get _scrollAxis =>
      widget.maxLines == 1 ? Axis.horizontal : Axis.vertical;

  @override
  void initState() {
    super.initState();
    _inputClient = _createInputClient();
    widget.controller.addListener(_handleControllerChange);
    widget.focusNode.addListener(_handleFocusChange);
    widget.scrollController?.addListener(_handleScroll);
    _toolboxActionSub = NativeToolboxMenu.onAction.listen(_handleToolboxAction);
    _toolboxDismissSub = NativeToolboxMenu.onDismiss.listen((_) {
      _toolbarMenuShown = false;
      if (mounted) setState(() {});
    });
    _restartCursorBlink();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.focusNode.requestFocus();
      });
    } else if (widget.focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleFocusChange();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextAutofillScope = AutofillGroup.maybeOf(context);
    if (nextAutofillScope != _autofillScope) {
      _autofillScope = nextAutofillScope;
      _replaceInputClient();
    }
    final nextObserver = ScrollNotificationObserver.maybeOf(context);
    if (nextObserver != _scrollNotificationObserver) {
      _scrollNotificationObserver?.removeListener(_handleObservedScroll);
      _scrollNotificationObserver = nextObserver
        ?..addListener(_handleObservedScroll);
    }
    _scheduleTextInputUpdate();
  }

  @override
  void didUpdateWidget(MarkdownEditableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // SeqPoint patch: the input client reads formatters and callbacks from the
    // current widget, so only a new controller or read-only state needs a new
    // client. Hosts rebuild formatter lists and closures on every frame, and
    // each replacement reconnected the platform input, which resets an
    // in-progress IME composition on Windows.
    final replaceInputClient =
        oldWidget.controller != widget.controller ||
        oldWidget.readOnly != widget.readOnly;

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChange);
      widget.controller.addListener(_handleControllerChange);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChange);
      widget.focusNode.addListener(_handleFocusChange);
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController?.removeListener(_handleScroll);
      widget.scrollController?.addListener(_handleScroll);
    }
    if (replaceInputClient) _replaceInputClient();

    if (oldWidget.readOnly != widget.readOnly ||
        oldWidget.focusNode != widget.focusNode) {
      if (_shouldHaveInputConnection) {
        _openInputConnection();
      } else {
        _closeInputConnection();
      }
    } else if (_textInputConnection?.attached ?? false) {
      _textInputConnection!.updateConfig(_textInputConfiguration());
    }
    if (oldWidget.showCursor != widget.showCursor ||
        oldWidget.readOnly != widget.readOnly ||
        oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode) {
      _restartCursorBlink();
    }
    _scheduleTextInputUpdate();
  }

  MarkdownTextInputClient _createInputClient() => MarkdownTextInputClient(
    controller: widget.controller,
    inputFormattersOf: () => widget.inputFormatters ?? const [],
    readOnly: widget.readOnly,
    autofillScope: _autofillScope,
    onChanged: (text) => widget.onChanged?.call(text),
    onSelectionChanged: (selection) => widget.onSelectionChanged?.call(
      selection,
      SelectionChangedCause.keyboard,
    ),
    onEditingComplete: () => widget.onEditingComplete?.call(),
    onSubmitted: (text) => widget.onSubmitted?.call(text),
    onPrivateCommand: _handlePrivateCommand,
    onFloatingCursor: _handleFloatingCursor,
    onAutocorrectionPrompt: _handleAutocorrectionPrompt,
    onConnectionClosed: _handleConnectionClosed,
    onContentInserted: _handleContentInserted,
    onFocusReceived: _handlePlatformFocusReceived,
    onInputControlChanged: _handleInputControlChanged,
    onToolbarRequested: showToolbar,
    onTextPlaceholderInserted: _handleTextPlaceholderInserted,
    onTextPlaceholderRemoved: _handleTextPlaceholderRemoved,
    onSelector: _handleSelector,
    // SeqPoint patch: the platform already holds what it just reported.
    onPlatformValue: (value) => _lastSentEditingValue = value,
  );

  void _replaceInputClient() {
    final reconnect = _textInputConnection?.attached ?? false;
    if (reconnect) _closeInputConnection();
    _inputClient = _createInputClient();
    if (reconnect && _shouldHaveInputConnection) _openInputConnection();
  }

  TextInputConfiguration _textInputConfiguration() {
    final hints = widget.autofillHints.toList(growable: false);
    final insertionConfiguration = widget.contentInsertionConfiguration;
    return TextInputConfiguration(
      viewId: View.of(context).viewId,
      inputType: widget.keyboardType ?? TextInputType.text,
      inputAction:
          widget.textInputAction ??
          (widget.maxLines == 1
              ? TextInputAction.done
              : TextInputAction.newline),
      textCapitalization: widget.textCapitalization,
      readOnly: widget.readOnly,
      obscureText: widget.obscureText,
      autocorrect: widget.autocorrect,
      smartDashesType: widget.smartDashesType,
      smartQuotesType: widget.smartQuotesType,
      enableSuggestions: widget.enableSuggestions,
      enableInteractiveSelection: widget.enableInteractiveSelection,
      enableDeltaModel: true,
      keyboardAppearance: widget.keyboardAppearance,
      autofillConfiguration: hints.isEmpty
          ? AutofillConfiguration.disabled
          : AutofillConfiguration(
              uniqueIdentifier: 'MarkdownEditableText-$hashCode',
              autofillHints: hints,
              currentEditingValue: widget.controller.value,
            ),
      enableIMEPersonalizedLearning: widget.enableIMEPersonalizedLearning,
      allowedMimeTypes:
          insertionConfiguration?.allowedMimeTypes ?? const <String>[],
      hintLocales: widget.hintLocales,
      enableInlinePrediction: widget.enableInlinePrediction,
    );
  }

  void _handleControllerChange() {
    _secondaryTapAnchor = null;
    _restartCursorBlink();
    _scheduleTextInputUpdate();
    if (mounted) setState(() {});
  }

  void _handleFocusChange() {
    hideToolbar();
    if (widget.focusNode.hasFocus) {
      if (widget.selectAllOnFocus) {
        selectAll(SelectionChangedCause.keyboard);
      } else if (!widget.controller.selection.isValid) {
        widget.controller.selection = TextSelection.collapsed(
          offset: widget.controller.text.length,
        );
      }
      if (_shouldHaveInputConnection) {
        _openInputConnection();
      }
    } else {
      _touchHandlesVisible = false;
      _closeInputConnection();
    }
    _restartCursorBlink();
    if (mounted) setState(() {});
  }

  void _openInputConnection() {
    if (!_shouldHaveInputConnection ||
        (_textInputConnection?.attached ?? false)) {
      return;
    }
    applyWebEditingCursor(
      _hoveringInteractiveLink
          ? SystemMouseCursors.click
          : SystemMouseCursors.text,
    );
    _textInputConnection = TextInput.attach(
      _inputClient,
      _textInputConfiguration(),
    );
    _lastSentEditingValue = null;
    _lastSentStyle = null;
    _scheduleTextInputUpdate();
    _textInputConnection!.show();
  }

  void _closeInputConnection() {
    _textInputConnection?.close();
    _textInputConnection = null;
    _lastSentEditingValue = null;
    _lastSentStyle = null;
  }

  void _handleConnectionClosed() {
    _textInputConnection = null;
    _lastSentEditingValue = null;
    _lastSentStyle = null;
    if (mounted) setState(() {});
  }

  bool _handlePlatformFocusReceived() {
    if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
    return widget.focusNode.hasFocus;
  }

  void _handleInputControlChanged(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {
    if (newControl != null && (_textInputConnection?.attached ?? false)) {
      _textInputConnection!.show();
    }
    _scheduleTextInputUpdate();
  }

  void _scheduleTextInputUpdate() {
    if (_textInputUpdateScheduled) return;
    _textInputUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _textInputUpdateScheduled = false;
      if (!mounted) return;
      _flushTextInputUpdate();
    });
  }

  void _flushTextInputUpdate() {
    final connection = _textInputConnection;
    if (connection == null || !connection.attached) return;

    final value = widget.controller.value;
    if (_lastSentEditingValue != value) {
      connection.setEditingState(value);
      _lastSentEditingValue = value;
    }
    final direction = widget.textDirection ?? Directionality.of(context);
    final style = TextInputStyle(
      fontFamily: widget.style.fontFamily,
      fontSize: widget.style.fontSize,
      fontWeight: widget.style.fontWeight,
      textDirection: direction,
      textAlign: widget.textAlign,
      letterSpacing: widget.style.letterSpacing,
      wordSpacing: widget.style.wordSpacing,
      lineHeight: widget.style.fontSize == null || widget.style.height == null
          ? null
          : widget.style.fontSize! * widget.style.height!,
    );
    if (_lastSentStyle != style) {
      connection.updateStyle(style);
      _lastSentStyle = style;
    }

    final render = renderEditable;
    if (render == null ||
        !render.attached ||
        !render.hasSize ||
        !value.selection.isValid) {
      return;
    }
    connection.setEditableSizeAndTransform(
      render.size,
      render.getTransformTo(null),
    );
    connection.setCaretRect(
      render.caretRectForSourceOffset(
        value.selection.start,
        affinity: value.selection.affinity,
      ),
    );
    final composing = value.composing;
    connection.setComposingRect(
      composing.isValid
          ? _rectForSourceRange(composing) ??
                render.caretRectForSourceOffset(composing.start)
          : render.caretRectForSourceOffset(value.selection.extentOffset),
    );
    connection.setSelectionRects(_selectionRects(value.selection));
    _selectionOverlayKey.currentState?.updateGeometry();
  }

  List<SelectionRect> _selectionRects(TextSelection selection) {
    final render = renderEditable;
    if (render == null || selection.isCollapsed) return const [];
    final boxes = render.selectionBoxesForSourceRange(selection);
    return [
      for (final box in boxes)
        SelectionRect(
          position: selection.start,
          bounds: box.toRect(),
          direction: box.direction,
        ),
    ];
  }

  Rect? _rectForSourceRange(TextRange range) {
    final render = renderEditable;
    if (render == null ||
        !render.attached ||
        !render.hasSize ||
        !range.isValid ||
        range.end > widget.controller.text.length) {
      return null;
    }
    if (range.isCollapsed) {
      return render.caretRectForSourceOffset(range.start);
    }
    final boxes = render.selectionBoxesForSourceRange(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
    );
    if (boxes.isEmpty) return render.caretRectForSourceOffset(range.start);
    var rect = boxes.first.toRect();
    for (final box in boxes.skip(1)) {
      rect = rect.expandToInclude(box.toRect());
    }
    return rect;
  }

  void _handleComposition(Layer layer) {
    final render = renderEditable;
    if (render == null || !render.attached) return;
    _scheduleTextInputUpdate();
    _selectionOverlayKey.currentState?.updateGeometry();
  }

  void _handleScroll() {
    renderEditable?.refreshGutterHover();
    if (_toolbarHideGraceTimer == null) {
      _reanchorOrDismissMenu();
    }
    _scheduleTextInputUpdate();
    _selectionOverlayKey.currentState?.updateGeometry();
  }

  void _handleObservedScroll(ScrollNotification notification) {
    // Dismiss only when content actually moves; a drag that merely starts
    // (e.g. pointer replay while the IME opens) must not kill a fresh menu.
    if (_toolbarHideGraceTimer == null &&
        notification is ScrollUpdateNotification &&
        notification.scrollDelta != 0) {
      _reanchorOrDismissMenu();
    }
    _scheduleTextInputUpdate();
    _selectionOverlayKey.currentState?.updateGeometry();
  }

  @override
  void dispose() {
    hideToolbar();
    _toolbarHideGraceTimer?.cancel();
    _toolboxActionSub?.cancel();
    _toolboxDismissSub?.cancel();
    _cursorBlinkTimer?.cancel();
    _scrollNotificationObserver?.removeListener(_handleObservedScroll);
    _closeInputConnection();
    widget.controller.removeListener(_handleControllerChange);
    widget.focusNode.removeListener(_handleFocusChange);
    widget.scrollController?.removeListener(_handleScroll);
    super.dispose();
  }

  void _restartCursorBlink() {
    _cursorBlinkTimer?.cancel();
    _cursorBlinkTimer = null;
    if (!_shouldBlinkCursor) {
      _cursorVisible = false;
      return;
    }
    _cursorVisible = true;
    _cursorBlinkTimer = Timer.periodic(_cursorBlinkInterval, (_) {
      if (!mounted || !_shouldBlinkCursor) {
        _restartCursorBlink();
        return;
      }
      setState(() => _cursorVisible = !_cursorVisible);
    });
  }

  TextSelectionToolbarAnchors get contextMenuAnchors {
    final clickAnchor = _secondaryTapAnchor;
    if (clickAnchor != null) {
      return TextSelectionToolbarAnchors(primaryAnchor: clickAnchor);
    }
    final render = renderEditable;
    if (render == null || !widget.controller.selection.isValid) {
      return const TextSelectionToolbarAnchors(primaryAnchor: Offset.zero);
    }
    final selection = widget.controller.selection;
    final primary = render.localToGlobal(
      render.caretRectForSourceOffset(selection.extentOffset).bottomCenter,
    );
    final secondary = selection.isCollapsed
        ? null
        : render.localToGlobal(
            render.caretRectForSourceOffset(selection.baseOffset).bottomCenter,
          );
    return TextSelectionToolbarAnchors(
      primaryAnchor: primary,
      secondaryAnchor: secondary,
    );
  }

  List<ContextMenuButtonItem> get contextMenuButtonItems {
    final selection = widget.controller.selection;
    return [
      if (!widget.obscureText && selection.isValid && !selection.isCollapsed)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            hideToolbar();
            unawaited(copySelection(SelectionChangedCause.toolbar));
          },
        ),
      if (!widget.readOnly &&
          !widget.obscureText &&
          selection.isValid &&
          !selection.isCollapsed)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.cut,
          onPressed: () {
            hideToolbar();
            unawaited(cutSelection(SelectionChangedCause.toolbar));
          },
        ),
      if (!widget.readOnly)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () {
            hideToolbar();
            unawaited(pasteText(SelectionChangedCause.toolbar));
          },
        ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        onPressed: () {
          hideToolbar();
          selectAll(SelectionChangedCause.toolbar);
        },
      ),
    ];
  }

  Future<void> copySelection(SelectionChangedCause cause) async {
    if (cause == SelectionChangedCause.toolbar) hideToolbar();
    final selection = widget.controller.selection;
    if (widget.obscureText || !selection.isValid || selection.isCollapsed) {
      return;
    }
    await Clipboard.setData(
      ClipboardData(
        text: widget.controller.text.substring(selection.start, selection.end),
      ),
    );
    bringIntoView(TextPosition(offset: selection.extentOffset));
  }

  Future<void> cutSelection(SelectionChangedCause cause) async {
    if (cause == SelectionChangedCause.toolbar) hideToolbar();
    if (widget.readOnly || widget.obscureText) return;
    final selection = widget.controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    await copySelection(cause);
    if (!mounted) return;
    _replaceSelectionWith('', selection);
  }

  Future<void> pasteText(SelectionChangedCause cause) async {
    if (cause == SelectionChangedCause.toolbar) hideToolbar();
    if (widget.readOnly) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final pasted = data?.text;
    if (pasted == null || !mounted) return;
    final selection = widget.controller.selection.isValid
        ? widget.controller.selection
        : TextSelection.collapsed(offset: widget.controller.text.length);
    _replaceSelectionWith(pasted, selection);
  }

  void selectAll(SelectionChangedCause cause) {
    if (cause == SelectionChangedCause.toolbar) hideToolbar();
    _updateSelection(
      TextSelection(baseOffset: 0, extentOffset: widget.controller.text.length),
      cause,
    );
  }

  void _replaceSelectionWith(String replacement, TextSelection selection) {
    if (widget.readOnly) return;
    final source = widget.controller.text;
    final text = source.replaceRange(
      selection.start,
      selection.end,
      replacement,
    );
    final caret = selection.start + replacement.length;
    _inputClient.applyLocalEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret),
      ),
    );
  }

  void requestKeyboard() {
    widget.focusNode.requestFocus();
    if (_shouldHaveInputConnection) _openInputConnection();
  }

  bool showToolbar() {
    if (kIsWeb || _toolbarMenuShown || !widget.controller.selection.isValid) {
      return false;
    }
    final render = renderEditable;
    if (render == null || !render.attached || !render.hasSize) return false;

    final visibleBounds = _visibleMenuBounds(render);
    final secondaryTap = _secondaryTapAnchor;
    final Rect anchor;
    final bool topRight;
    if (secondaryTap != null) {
      _secondaryTapAnchor = null;
      final (point, flips) = NativeToolboxPositioner.resolvePointAnchor(
        secondaryTap,
        visibleBounds,
        rtl: Directionality.of(context) == TextDirection.rtl,
      );
      anchor = Rect.fromPoints(point, point);
      topRight = flips;
    } else {
      final selectionBounds = _selectionGlobalBounds(render);
      if (selectionBounds == null) return false;
      anchor = NativeToolboxPositioner.resolveAnchor(
        selectionBounds,
        visibleBounds,
      );
      topRight = false;
    }
    final actions = contextMenuButtonItems;
    unawaited(
      NativeToolboxMenu.showMenu(
        anchorRect: anchor,
        actions: [
          for (final item in actions)
            NativeToolboxAction(
              id: item.type.name,
              label:
                  item.label ??
                  switch (item.type) {
                    ContextMenuButtonType.cut => 'Cut',
                    ContextMenuButtonType.copy => 'Copy',
                    ContextMenuButtonType.paste => 'Paste',
                    ContextMenuButtonType.selectAll => 'Select all',
                    _ => 'Action',
                  },
            ),
        ],
        selectionMode: !widget.readOnly,
        topRight: topRight,
      ).then((shown) {
        if (!shown) return;
        _toolbarMenuShown = true;
        _toolbarHideGraceTimer?.cancel();
        _toolbarHideGraceTimer = Timer(_toolbarHideGrace, () {
          _toolbarHideGraceTimer = null;
        });
        if (mounted) setState(() {});
      }),
    );
    return true;
  }

  void hideToolbar() {
    _toolbarMenuShown = false;
    if (!kIsWeb) {
      unawaited(NativeToolboxMenu.dismissMenu());
    }
  }

  /// Follows a scrolled selection: keep the native menu pinned at the
  /// editor's border instead of leaving it at a stale anchor; dismiss it once
  /// the user has dismissed it themselves.
  void _reanchorOrDismissMenu() {
    if (!_toolbarMenuShown) {
      hideToolbar();
      return;
    }
    showToolbar();
  }

  /// The selection in FlutterView-global logical coordinates.
  Rect? _selectionGlobalBounds(RenderMarkdownEditable render) {
    final selection = widget.controller.selection;
    final boxes = render.selectionBoxesForSourceRange(selection);
    if (boxes.isEmpty) return null;
    return boxes
        .map((box) {
          final rect = box.toRect();
          return Rect.fromPoints(
            render.localToGlobal(rect.topLeft),
            render.localToGlobal(rect.bottomRight),
          );
        })
        .reduce((a, b) => a.expandToInclude(b));
  }

  /// The editor's on-screen box minus the IME: the menu must stay inside the
  /// text box (floating above it, never clipped) and never under the keyboard.
  Rect _visibleMenuBounds(RenderMarkdownEditable render) {
    final media = MediaQuery.of(context);
    final editor = Rect.fromPoints(
      render.localToGlobal(Offset.zero),
      render.localToGlobal(render.size.bottomRight(Offset.zero)),
    );
    final screen = Rect.fromLTWH(
      0,
      0,
      media.size.width,
      media.size.height - media.viewInsets.bottom,
    );
    return editor.intersect(screen);
  }

  void _handleToolboxAction(int index) {
    final items = contextMenuButtonItems;
    if (index < 0 || index >= items.length) return;
    _toolbarMenuShown = false;
    items[index].onPressed?.call();
  }

  void bringIntoView(TextPosition position) {
    final controller = widget.scrollController;
    final render = renderEditable;
    if (controller == null || !controller.hasClients || render == null) return;
    final caret = render.caretRectForSourceOffset(
      position.offset,
      affinity: position.affinity,
    );
    final table = render.tableIdForOffset(caret.center);
    if (table != null) {
      render.revealTable(table, caret.left);
      render.revealTable(table, caret.right);
    }
    final metrics = controller.position;
    final visibleStart = metrics.pixels;
    final visibleEnd = visibleStart + metrics.viewportDimension;
    final caretStart = _scrollAxis == Axis.vertical ? caret.top : caret.left;
    final caretEnd = _scrollAxis == Axis.vertical ? caret.bottom : caret.right;
    final leadingPadding = _scrollAxis == Axis.vertical
        ? widget.scrollPadding.top
        : widget.scrollPadding.left;
    final trailingPadding = _scrollAxis == Axis.vertical
        ? widget.scrollPadding.bottom
        : widget.scrollPadding.right;
    var target = visibleStart;
    if (caretStart < visibleStart + leadingPadding) {
      target = caretStart - leadingPadding;
    } else if (caretEnd > visibleEnd - trailingPadding) {
      target = caretEnd + trailingPadding - metrics.viewportDimension;
    }
    controller.jumpTo(
      target.clamp(metrics.minScrollExtent, metrics.maxScrollExtent).toDouble(),
    );
  }

  TextPosition _positionForGlobalOffset(Offset globalOffset) {
    final render = renderEditable!;
    return render.sourcePositionForOffset(render.globalToLocal(globalOffset));
  }

  void _updateSelection(TextSelection selection, SelectionChangedCause cause) {
    final safeSelection = TextSelection(
      baseOffset: selection.baseOffset
          .clamp(0, widget.controller.text.length)
          .toInt(),
      extentOffset: selection.extentOffset
          .clamp(0, widget.controller.text.length)
          .toInt(),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
    final current = widget.controller.value;
    final next = current.copyWith(
      selection: safeSelection,
      composing: TextRange.empty,
    );
    if (next == current) return;
    final selectionChanged = current.selection != safeSelection;
    widget.controller.value = next;
    if (selectionChanged) {
      widget.onSelectionChanged?.call(safeSelection, cause);
    }
    bringIntoView(
      TextPosition(
        offset: safeSelection.extentOffset,
        affinity: safeSelection.affinity,
      ),
    );
  }

  MarkdownSelectionInteractionPolicy _interactionPolicy(
    PointerDeviceKind? pointerKind,
  ) => MarkdownSelectionInteractionPolicy.resolve(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    pointerKind: pointerKind,
    interactiveSelectionEnabled: widget.enableInteractiveSelection,
  );

  void _selectCaret(Offset globalOffset, {bool preserveTouchHandles = false}) {
    hideToolbar();
    _secondaryTapAnchor = null;
    if (!preserveTouchHandles) _touchHandlesVisible = false;
    requestKeyboard();
    final position = _positionForGlobalOffset(globalOffset);
    final current = widget.controller.selection;
    final extend =
        HardwareKeyboard.instance.isShiftPressed &&
        current.isValid &&
        widget.enableInteractiveSelection;
    _updateSelection(
      extend
          ? current.copyWith(
              extentOffset: position.offset,
              affinity: position.affinity,
            )
          : TextSelection.collapsed(
              offset: position.offset,
              affinity: position.affinity,
            ),
      SelectionChangedCause.tap,
    );
  }

  void _handleTapUp(TapDragUpDetails details) {
    if (_suppressTableScrollbarTap) {
      _suppressTableScrollbarTap = false;
      _activePointerKind = null;
      return;
    }
    final pointerKind = details.kind;
    final policy = _interactionPolicy(pointerKind);
    final render = renderEditable;
    final foldStart = render == null || !widget.gutter.folding
        ? null
        : render.foldStartForGutterOffset(
            render.globalToLocal(details.globalPosition),
          );
    if (foldStart != null) {
      widget.onToggleFold?.call(foldStart);
      _activePointerKind = null;
      return;
    }
    final position = _positionForGlobalOffset(details.globalPosition);
    final selection = widget.controller.selection;
    final extend =
        HardwareKeyboard.instance.isShiftPressed &&
        selection.isValid &&
        widget.enableInteractiveSelection;
    if (!extend &&
        policy.usesPackageTouchUi &&
        policy.isStrictlyInsideSelection(selection, position)) {
      requestKeyboard();
      _touchHandlesVisible = true;
      if (_toolbarMenuShown) {
        hideToolbar();
      } else {
        showToolbar();
      }
      _activePointerKind = null;
      if (mounted) setState(() {});
      return;
    }
    // A normal tap places a caret only. Handles belong to word selection
    // (double-tap/long-press) or an active handle drag, not a collapsed caret.
    _selectCaret(details.globalPosition);
    _activePointerKind = null;
  }

  void _handleDoubleTapDown(TapDragDownDetails details) {
    if (_isDraggingTableScrollbar) return;
    final policy = _interactionPolicy(details.kind ?? _activePointerKind);
    _touchHandlesVisible = policy.showsTouchHandles && !kIsWeb;
    _selectWord(details.globalPosition);
    _activePointerKind = null;
    if (policy.usesPackageTouchUi) showToolbar();
  }

  void _handleLongPressEnd() {
    final policy = _interactionPolicy(_activePointerKind);
    _endDrag();
    _activePointerKind = null;
    if (policy.usesPackageTouchUi) showToolbar();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowUp &&
        event.logicalKey != LogicalKeyboardKey.arrowDown) {
      _preferredVerticalCaretX = null;
    }
    final keyboard = HardwareKeyboard.instance;
    final primary = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      final shown = _toolbarMenuShown;
      hideToolbar();
      return shown ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (primary && event.logicalKey == LogicalKeyboardKey.keyA) {
      selectAll(SelectionChangedCause.keyboard);
      return KeyEventResult.handled;
    }
    if (primary && event.logicalKey == LogicalKeyboardKey.keyC && !kIsWeb) {
      unawaited(copySelection(SelectionChangedCause.keyboard));
      return KeyEventResult.handled;
    }
    if (primary &&
        event.logicalKey == LogicalKeyboardKey.keyX &&
        !widget.readOnly &&
        !kIsWeb) {
      unawaited(cutSelection(SelectionChangedCause.keyboard));
      return KeyEventResult.handled;
    }
    if (primary &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        !widget.readOnly &&
        !kIsWeb) {
      unawaited(pasteText(SelectionChangedCause.keyboard));
      return KeyEventResult.handled;
    }
    if (primary && event.logicalKey == LogicalKeyboardKey.keyZ) {
      widget.onUndo?.call();
      return widget.onUndo == null
          ? KeyEventResult.ignored
          : KeyEventResult.handled;
    }
    if (primary && event.logicalKey == LogicalKeyboardKey.keyY) {
      widget.onRedo?.call();
      return widget.onRedo == null
          ? KeyEventResult.ignored
          : KeyEventResult.handled;
    }
    if (!widget.readOnly && event.logicalKey == LogicalKeyboardKey.backspace) {
      _deleteCharacter(forward: false);
      return KeyEventResult.handled;
    }
    if (!widget.readOnly && event.logicalKey == LogicalKeyboardKey.delete) {
      _deleteCharacter(forward: true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && !primary) {
      if (widget.readOnly) return KeyEventResult.ignored;
      if (widget.maxLines == 1) {
        widget.onEditingComplete?.call();
        widget.onSubmitted?.call(widget.controller.text);
      } else {
        _insertText('\n');
      }
      return KeyEventResult.handled;
    }

    final moveRight = event.logicalKey == LogicalKeyboardKey.arrowRight;
    final moveLeft = event.logicalKey == LogicalKeyboardKey.arrowLeft;
    if (moveRight || moveLeft) {
      _moveHorizontal(moveRight: moveRight, extend: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    final moveUp = event.logicalKey == LogicalKeyboardKey.arrowUp;
    final moveDown = event.logicalKey == LogicalKeyboardKey.arrowDown;
    if (moveUp || moveDown) {
      _moveVertical(moveDown: moveDown, extend: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _insertText(String text) {
    if (widget.readOnly) return;
    final current = widget.controller.selection;
    final selection = current.isValid
        ? current
        : TextSelection.collapsed(offset: widget.controller.text.length);
    _replaceSelectionWith(text, selection);
  }

  void _deleteCharacter({required bool forward}) {
    if (widget.readOnly) return;
    final selection = widget.controller.selection;
    if (!selection.isValid) return;
    if (!selection.isCollapsed) {
      _replaceSelectionWith('', selection);
      return;
    }
    final boundary = CharacterBoundary(widget.controller.text);
    final offset = selection.extentOffset;
    final start = forward
        ? offset
        : boundary.getLeadingTextBoundaryAt(offset - 1) ?? 0;
    final end = forward
        ? boundary.getTrailingTextBoundaryAt(offset) ??
              widget.controller.text.length
        : offset;
    if (start != end) {
      _replaceSelectionWith(
        '',
        TextSelection(baseOffset: start, extentOffset: end),
      );
    }
  }

  void _moveHorizontal({required bool moveRight, required bool extend}) {
    final selection = widget.controller.selection;
    if (!selection.isValid) return;
    if (!extend && !selection.isCollapsed) {
      _updateSelection(
        TextSelection.collapsed(
          offset: moveRight ? selection.end : selection.start,
        ),
        SelectionChangedCause.keyboard,
      );
      return;
    }
    final direction = _lineDirectionAt(selection.extentOffset);
    final forward = direction == TextDirection.rtl ? !moveRight : moveRight;
    final boundary = CharacterBoundary(widget.controller.text);
    final current = selection.extentOffset;
    final target = forward
        ? boundary.getTrailingTextBoundaryAt(current) ??
              widget.controller.text.length
        : boundary.getLeadingTextBoundaryAt(current - 1) ?? 0;
    _updateSelection(
      extend
          ? selection.copyWith(extentOffset: target)
          : TextSelection.collapsed(offset: target),
      SelectionChangedCause.keyboard,
    );
  }

  TextDirection _lineDirectionAt(int offset) {
    if (widget.lineDirections.isEmpty) {
      return widget.textDirection ?? TextDirection.ltr;
    }
    final safeOffset = offset.clamp(0, widget.controller.text.length).toInt();
    final line = '\n'
        .allMatches(widget.controller.text.substring(0, safeOffset))
        .length;
    return line < widget.lineDirections.length
        ? widget.lineDirections[line]
        : widget.lineDirections.last;
  }

  void _moveVertical({required bool moveDown, required bool extend}) {
    final selection = widget.controller.selection;
    final render = renderEditable;
    if (!selection.isValid || render == null) return;
    final caret = render.caretRectForSourceOffset(
      selection.extentOffset,
      affinity: selection.affinity,
    );
    final visualX = _preferredVerticalCaretX ?? caret.left;
    _preferredVerticalCaretX = visualX;
    final target = render.sourcePositionForOffset(
      Offset(
        visualX,
        caret.center.dy +
            (moveDown
                ? render.preferredLineHeight
                : -render.preferredLineHeight),
      ),
    );
    _updateSelection(
      extend
          ? selection.copyWith(
              extentOffset: target.offset,
              affinity: target.affinity,
            )
          : TextSelection.collapsed(
              offset: target.offset,
              affinity: target.affinity,
            ),
      SelectionChangedCause.keyboard,
    );
  }

  void _selectWord(Offset globalOffset) {
    if (!widget.enableInteractiveSelection) return;
    hideToolbar();
    requestKeyboard();
    final position = _positionForGlobalOffset(globalOffset);
    final range = renderEditable!.wordBoundaryForSourcePosition(position);
    _updateSelection(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
      SelectionChangedCause.doubleTap,
    );
  }

  void _selectLine(Offset globalOffset) {
    if (!widget.enableInteractiveSelection) return;
    hideToolbar();
    requestKeyboard();
    final position = _positionForGlobalOffset(globalOffset);
    final range = renderEditable!.lineBoundaryForSourcePosition(position);
    var end = range.end;
    if (end < widget.controller.text.length &&
        widget.controller.text.codeUnitAt(end) == 0x0A) {
      end += 1;
    }
    _updateSelection(
      TextSelection(baseOffset: range.start, extentOffset: end),
      SelectionChangedCause.tap,
    );
  }

  void _startDrag(Offset globalOffset, {PointerDeviceKind? pointerKind}) {
    if (!widget.enableInteractiveSelection) return;
    hideToolbar();
    requestKeyboard();
    final render = renderEditable;
    final resolvedKind = pointerKind ?? _activePointerKind;
    _tableDragId = resolvedKind == PointerDeviceKind.touch && render != null
        ? render.tableIdForOffset(render.globalToLocal(globalOffset))
        : null;
    final position = _positionForGlobalOffset(globalOffset);
    final mapper = _projectionSnapshot!.mapper;
    final visualOffset = mapper.sourceToVisual(
      position.offset,
      affinity: TextAffinity.upstream,
    );
    var baseOffset = mapper.visualToSource(
      visualOffset,
      affinity: TextAffinity.upstream,
    );
    for (final segment in _projectionSnapshot!.segments) {
      if (segment.kind == MarkdownProjectionSegmentKind.widget &&
          position.offset == segment.sourceRange.end) {
        baseOffset = segment.sourceRange.start;
        break;
      }
    }
    _dragBase = TextPosition(
      offset: baseOffset,
      affinity: TextAffinity.upstream,
    );
    _dragGlobalPosition = globalOffset;
    if (_tableDragId != null) return;
    _updateSelection(
      TextSelection.collapsed(offset: _dragBase!.offset),
      SelectionChangedCause.drag,
    );
  }

  void _updateDrag(Offset globalOffset) {
    if (_dragBase == null || !widget.enableInteractiveSelection) return;
    final render = renderEditable;
    if (_tableDragId != null && render != null) {
      final last = _dragGlobalPosition;
      if (last != null) {
        final delta = globalOffset.dx - last.dx;
        render.setTableScroll(
          _tableDragId!,
          render.tableScroll(_tableDragId!) - delta,
        );
      }
      _dragGlobalPosition = globalOffset;
      return;
    }
    _dragGlobalPosition = globalOffset;
    _updateDragExtent(globalOffset);
    _scheduleDragAutoScroll();
  }

  void _updateDragExtent(Offset globalOffset) {
    final extent = _positionForGlobalOffset(globalOffset);
    _updateSelection(
      TextSelection(baseOffset: _dragBase!.offset, extentOffset: extent.offset),
      SelectionChangedCause.drag,
    );
  }

  void _scheduleDragAutoScroll() {
    if (_dragAutoScrollScheduled || _dragBase == null) return;
    _dragAutoScrollScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _dragAutoScrollScheduled = false;
      final globalPosition = _dragGlobalPosition;
      if (!mounted || _dragBase == null || globalPosition == null) return;
      if (_autoScrollForDrag(globalPosition)) {
        _updateDragExtent(globalPosition);
        _scheduleDragAutoScroll();
      }
    });
  }

  bool _autoScrollForDrag(Offset globalOffset) {
    final controller = widget.scrollController;
    final render = renderEditable;
    if (controller == null || !controller.hasClients || render == null) {
      return false;
    }
    final local = render.globalToLocal(globalOffset);
    final coordinate = _scrollAxis == Axis.vertical ? local.dy : local.dx;
    final viewport = controller.position.viewportDimension;
    const edge = 24.0;
    final delta = coordinate < controller.offset + edge
        ? -edge
        : coordinate > controller.offset + viewport - edge
        ? edge
        : 0.0;
    if (delta == 0) return false;
    final position = controller.position;
    final target = (controller.offset + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if (target == controller.offset) return false;
    controller.jumpTo(target);
    return true;
  }

  void _endDrag() {
    _dragBase = null;
    _dragGlobalPosition = null;
    _tableDragId = null;
    _selectionAtHandleDragStart = null;
  }

  void _startSelectionHandleDrag(MarkdownSelectionEndpoint endpoint) {
    hideToolbar();
    _selectionAtHandleDragStart = widget.controller.selection;
  }

  void _handleSelectionHandleChanged(
    MarkdownSelectionEndpoint endpoint,
    TextPosition position,
  ) {
    if (!widget.enableInteractiveSelection) return;
    final current = _selectionAtHandleDragStart ?? widget.controller.selection;
    if (!current.isValid) return;
    final length = widget.controller.text.length;
    final offset = position.offset.clamp(0, length).toInt();
    final next = switch (endpoint) {
      MarkdownSelectionEndpoint.collapsed => TextSelection.collapsed(
        offset: offset,
        affinity: position.affinity,
      ),
      MarkdownSelectionEndpoint.start => TextSelection(
        baseOffset: offset.clamp(0, current.end).toInt(),
        extentOffset: current.end,
      ),
      MarkdownSelectionEndpoint.end => TextSelection(
        baseOffset: current.start,
        extentOffset: offset.clamp(current.start, length).toInt(),
        affinity: position.affinity,
      ),
    };
    _updateSelection(next, SelectionChangedCause.drag);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final render = renderEditable;
    if (render == null || event.scrollDelta.dx == 0) return;
    final id = render.tableIdForOffset(render.globalToLocal(event.position));
    if (id == null) return;
    render.setTableScroll(id, render.tableScroll(id) + event.scrollDelta.dx);
  }

  bool get _isDraggingTableScrollbar => _tableScrollbarPointer != null;

  bool _startTableScrollbarDrag(PointerDownEvent event) {
    final render = renderEditable;
    if (render == null) return false;
    final id = render.tableScrollbarIdForOffset(
      render.globalToLocal(event.position),
    );
    if (id == null) return false;
    _tableScrollbarPointer = event.pointer;
    _tableScrollbarDragId = id;
    _tableScrollbarLastGlobalPosition = event.position;
    _suppressTableScrollbarTap = true;
    return true;
  }

  void _updateTableScrollbarDrag(PointerMoveEvent event) {
    if (event.pointer != _tableScrollbarPointer) return;
    final render = renderEditable;
    final id = _tableScrollbarDragId;
    final last = _tableScrollbarLastGlobalPosition;
    if (render != null && id != null && last != null) {
      render.dragTableScrollbar(id, event.position.dx - last.dx);
    }
    _tableScrollbarLastGlobalPosition = event.position;
  }

  void _endTableScrollbarDrag(PointerEvent event, {bool cancelled = false}) {
    if (event.pointer != _tableScrollbarPointer) return;
    _tableScrollbarPointer = null;
    _tableScrollbarDragId = null;
    _tableScrollbarLastGlobalPosition = null;
    if (cancelled) _suppressTableScrollbarTap = false;
  }

  void _handlePointerPanZoomStart(PointerPanZoomStartEvent event) {
    final render = renderEditable;
    _trackpadTableId = render?.tableIdForOffset(
      render.globalToLocal(event.position),
    );
  }

  void _handlePointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final render = renderEditable;
    final id = _trackpadTableId;
    if (render == null || id == null || event.panDelta.dx == 0) return;
    render.setTableScroll(id, render.tableScroll(id) - event.panDelta.dx);
  }

  void _handlePointerPanZoomEnd(PointerPanZoomEndEvent event) {
    _trackpadTableId = null;
  }

  void _handlePrivateCommand(String action, Map<String, dynamic> data) {
    widget.onAppPrivateCommand?.call(action, data);
  }

  void _handleSelector(String selectorName) {
    final selectorIntent = intentForMacOSSelector(selectorName);
    final focusContext = widget.focusNode.context ?? primaryFocus?.context;
    if (selectorIntent != null &&
        focusContext != null &&
        Actions.maybeFind<Intent>(focusContext, intent: selectorIntent) !=
            null) {
      Actions.invoke<Intent>(focusContext, selectorIntent);
      return;
    }
    switch (selectorName) {
      case 'selectAll:':
        selectAll(SelectionChangedCause.keyboard);
      case 'copy:':
        unawaited(copySelection(SelectionChangedCause.keyboard));
      case 'cut:':
        unawaited(cutSelection(SelectionChangedCause.keyboard));
      case 'paste:':
        unawaited(pasteText(SelectionChangedCause.keyboard));
      case 'deleteBackward:':
        _deleteCharacter(forward: false);
      case 'deleteForward:':
        _deleteCharacter(forward: true);
      case 'insertNewline:':
        _insertText('\n');
      case 'insertTab:':
        _insertText('\t');
      case 'moveLeft:':
        _moveHorizontal(moveRight: false, extend: false);
      case 'moveRight:':
        _moveHorizontal(moveRight: true, extend: false);
      case 'moveLeftAndModifySelection:':
        _moveHorizontal(moveRight: false, extend: true);
      case 'moveRightAndModifySelection:':
        _moveHorizontal(moveRight: true, extend: true);
      case 'cancelOperation:':
        hideToolbar();
    }
  }

  void _handleFloatingCursor(RawFloatingCursorPoint point) {
    final render = renderEditable;
    if (render == null || !widget.controller.selection.isValid) return;
    switch (point.state) {
      case FloatingCursorDragState.Start:
        final startLocation = point.startLocation;
        _floatingCursorOrigin = point.offset ?? Offset.zero;
        _floatingCursorStart =
            startLocation?.$1 ??
            render
                .caretRectForSourceOffset(
                  widget.controller.selection.extentOffset,
                )
                .center;
        if (startLocation != null) {
          _updateSelection(
            TextSelection.collapsed(
              offset: startLocation.$2.offset,
              affinity: startLocation.$2.affinity,
            ),
            SelectionChangedCause.drag,
          );
        }
      case FloatingCursorDragState.Update:
        final origin = _floatingCursorOrigin;
        final start = _floatingCursorStart;
        final offset = point.offset;
        if (origin == null || start == null || offset == null) return;
        final position = render.sourcePositionForOffset(
          start + offset - origin,
        );
        _updateSelection(
          TextSelection.collapsed(
            offset: position.offset,
            affinity: position.affinity,
          ),
          SelectionChangedCause.drag,
        );
      case FloatingCursorDragState.End:
        _floatingCursorOrigin = null;
        _floatingCursorStart = null;
        _restartCursorBlink();
    }
  }

  void _handleAutocorrectionPrompt(int start, int end) {
    final range = TextRange(start: start, end: end);
    _autocorrectionPromptRange =
        range.isValid && end <= widget.controller.text.length ? range : null;
    _scheduleTextInputUpdate();
    if (mounted) setState(() {});
  }

  void _handleContentInserted(KeyboardInsertedContent content) {
    final configuration = widget.contentInsertionConfiguration;
    final allowed = configuration?.allowedMimeTypes;
    if (allowed != null &&
        allowed.isNotEmpty &&
        !allowed.contains(content.mimeType)) {
      return;
    }
    final insertedText = _textFromInsertedContent(content);
    if (insertedText != null && !widget.readOnly) {
      final selection = widget.controller.selection.isValid
          ? widget.controller.selection
          : TextSelection.collapsed(offset: widget.controller.text.length);
      _replaceSelectionWith(insertedText, selection);
    }
    configuration?.onContentInserted(content);
  }

  String? _textFromInsertedContent(KeyboardInsertedContent content) {
    if (!content.mimeType.toLowerCase().startsWith('text/')) return null;
    final data = content.data;
    if (data != null && data.isNotEmpty) {
      return utf8.decode(data, allowMalformed: true);
    }
    try {
      return Uri.tryParse(content.uri)?.data?.contentAsString();
    } on FormatException {
      return null;
    }
  }

  void _handleTextPlaceholderInserted(Size size) {
    if (!size.isFinite || size.width < 0 || size.height < 0) return;
    setState(() => _textPlaceholderSize = size);
    _scheduleTextInputUpdate();
  }

  void _handleTextPlaceholderRemoved() {
    if (_textPlaceholderSize == null) return;
    setState(() => _textPlaceholderSize = null);
    _scheduleTextInputUpdate();
  }

  @override
  Widget build(BuildContext context) {
    if (!_fontRefreshScheduled && !_fontRefreshCompleted) {
      _fontRefreshScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _fontRefreshScheduled = false;
        _fontRefreshCompleted = true;
        setState(() {});
      });
    }
    _scheduleTextInputUpdate();
    return LayoutBuilder(
      builder: (context, constraints) {
        final direction = widget.textDirection ?? Directionality.of(context);
        final textScaler =
            widget.textScaler ?? MediaQuery.textScalerOf(context);
        _projectionSnapshot =
            (widget.projection ?? const IdentityMarkdownTextProjection())
                .project(
                  MarkdownProjectionContext(
                    value: widget.controller.value,
                    mode: widget.projectionMode,
                    constraints: constraints,
                    style: widget.style,
                    fallbackDirection: direction,
                  ),
                );
        final text = widget.obscureText
            ? TextSpan(
                text: List.filled(
                  widget.controller.text.length,
                  widget.obscuringCharacter,
                ).join(),
                style: widget.style,
              )
            : _projectionSnapshot!.visualText ??
                  widget.controller.buildTextSpan(
                    context: context,
                    style: widget.style,
                    withComposing: !widget.readOnly,
                  );
        final inlineChildren = _extractInlineChildren(text);
        Widget renderSurface = MouseRegion(
          cursor: _hoveringInteractiveLink
              ? SystemMouseCursors.click
              : widget.mouseCursor ?? SystemMouseCursors.text,
          onExit: (_) => renderEditable?.clearTableHover(),
          child: IgnorePointer(
            ignoring: widget.rendererIgnoresPointer,
            child: MarkdownEditableRenderWidget(
              key: _renderKey,
              text: text,
              inlineChildren: inlineChildren,
              mapper: _projectionSnapshot!.mapper,
              textDirection: direction,
              textAlign: widget.textAlign,
              textScaler: textScaler,
              strutStyle: widget.strutStyle,
              locale: widget.locale,
              textHeightBehavior: widget.textHeightBehavior,
              textWidthBasis: widget.textWidthBasis,
              maxLines: widget.maxLines,
              blockDecorations: widget.blockDecorations,
              gutter: widget.gutter,
              gutterStyle: widget.gutterStyle,
              foldableStarts: widget.foldableStarts,
              foldedStarts: widget.foldedStarts,
              onToggleFold: widget.onToggleFold,
              lineDirections: widget.lineDirections,
              tables: _projectionSnapshot?.tables ?? const [],
              tableStyle: widget.tableStyle,
              tableCellStyles: widget.tableCellStyles,
              mode: widget.projectionMode,
              selection: widget.controller.selection,
              cursorColor: widget.cursorColor,
              selectionColor: widget.selectionColor ?? const Color(0x663366ff),
              showCursor:
                  (widget.showCursor ?? !widget.readOnly) &&
                  widget.focusNode.hasFocus &&
                  _cursorVisible,
              cursorWidth: widget.cursorWidth,
              sourceText: widget.controller.text,
              readOnly: widget.readOnly,
              focused: widget.focusNode.hasFocus,
              onTap: requestKeyboard,
              onSelectionChanged: (selection) =>
                  _updateSelection(selection, SelectionChangedCause.keyboard),
              onCopy: () => copySelection(SelectionChangedCause.toolbar),
              onCut: () => cutSelection(SelectionChangedCause.toolbar),
              onPaste: () => pasteText(SelectionChangedCause.toolbar),
              onHoverInteractiveChanged: (interactive) {
                if (interactive != _hoveringInteractiveLink) {
                  setState(() => _hoveringInteractiveLink = interactive);
                  applyWebEditingCursor(
                    interactive
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.text,
                  );
                }
              },
            ),
          ),
        );
        final placeholderSize = _textPlaceholderSize;
        if (placeholderSize != null) {
          renderSurface = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              renderSurface,
              SizedBox(
                key: const ValueKey<String>(
                  'markdown-platform-text-placeholder',
                ),
                width: placeholderSize.width,
                height: placeholderSize.height,
              ),
            ],
          );
        }

        final fontSize = widget.style.fontSize ?? 14;
        final lineHeight =
            textScaler.scale(fontSize) * (widget.style.height ?? 1);
        final minimumLines = widget.forceLine
            ? (widget.minLines ?? 1)
            : (widget.minLines ?? 0);
        final minHeight = widget.expands && constraints.hasBoundedHeight
            ? constraints.maxHeight
            : lineHeight * minimumLines;
        final minWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 0.0;
        final scrollChild = ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth, minHeight: minHeight),
          child: renderSurface,
        );
        final scrollView = NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            _handleObservedScroll(notification);
            return false;
          },
          child: SingleChildScrollView(
            controller: widget.scrollController,
            physics: widget.scrollPhysics,
            scrollDirection: _scrollAxis,
            clipBehavior: widget.clipBehavior,
            child: scrollChild,
          ),
        );

        final gestures = Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            _activePointerKind = event.kind;
            if (_startTableScrollbarDrag(event)) return;
            requestKeyboard();
          },
          onPointerMove: _updateTableScrollbarDrag,
          onPointerUp: _endTableScrollbarDrag,
          onPointerCancel: (event) {
            _endTableScrollbarDrag(event, cancelled: true);
            _activePointerKind = null;
          },
          onPointerSignal: _handlePointerSignal,
          onPointerPanZoomStart: _handlePointerPanZoomStart,
          onPointerPanZoomUpdate: _handlePointerPanZoomUpdate,
          onPointerPanZoomEnd: _handlePointerPanZoomEnd,
          child: TextSelectionGestureDetector(
            behavior: HitTestBehavior.translucent,
            onSingleTapUp: _handleTapUp,
            onSingleTapCancel: () {
              _suppressTableScrollbarTap = false;
              _activePointerKind = null;
            },
            onDoubleTapDown: widget.enableInteractiveSelection
                ? _handleDoubleTapDown
                : null,
            onTripleTapDown: widget.enableInteractiveSelection
                ? (details) => _selectLine(details.globalPosition)
                : null,
            onSecondaryTapDown: (details) {
              _secondaryTapAnchor = details.globalPosition;
              final position = _positionForGlobalOffset(details.globalPosition);
              final selection = widget.controller.selection;
              if (!selection.isValid ||
                  selection.isCollapsed ||
                  position.offset < selection.start ||
                  position.offset > selection.end) {
                _updateSelection(
                  TextSelection.collapsed(offset: position.offset),
                  SelectionChangedCause.tap,
                );
                _secondaryTapAnchor = details.globalPosition;
              }
            },
            onSecondaryTap: showToolbar,
            onSingleLongTapStart: widget.enableInteractiveSelection
                ? (details) {
                    if (_isDraggingTableScrollbar) return;
                    final policy = _interactionPolicy(_activePointerKind);
                    _touchHandlesVisible = policy.showsTouchHandles && !kIsWeb;
                    _selectWord(details.globalPosition);
                    _dragBase = TextPosition(
                      offset: widget.controller.selection.baseOffset,
                    );
                  }
                : null,
            onSingleLongTapMoveUpdate: widget.enableInteractiveSelection
                ? (details) {
                    if (!_isDraggingTableScrollbar) {
                      _updateDrag(details.globalPosition);
                    }
                  }
                : null,
            onSingleLongTapEnd: widget.enableInteractiveSelection
                ? (_) => _handleLongPressEnd()
                : null,
            onSingleLongTapCancel: () {
              _endDrag();
              _activePointerKind = null;
            },
            onDragSelectionStart: widget.enableInteractiveSelection
                ? (details) {
                    if (!_isDraggingTableScrollbar) {
                      _startDrag(
                        details.globalPosition,
                        pointerKind: details.kind,
                      );
                    }
                  }
                : null,
            onDragSelectionUpdate: widget.enableInteractiveSelection
                ? (details) {
                    if (!_isDraggingTableScrollbar) {
                      _updateDrag(details.globalPosition);
                    }
                  }
                : null,
            onDragSelectionEnd: widget.enableInteractiveSelection
                ? (_) => _endDrag()
                : null,
            child: scrollView,
          ),
        );

        Widget selectionSurface = gestures;
        final selectionControls = widget.selectionControls;
        if (selectionControls != null) {
          selectionSurface = MarkdownSelectionOverlay(
            key: _selectionOverlayKey,
            renderKey: _renderKey,
            selection: widget.controller.selection,
            selectionControls: selectionControls,
            textDirectionForOffset: _lineDirectionAt,
            positionForGlobalOffset: _positionForGlobalOffset,
            onSelectionHandleChanged: _handleSelectionHandleChanged,
            visible:
                (widget.showSelectionHandles || _touchHandlesVisible) &&
                widget.focusNode.hasFocus,
            interactive: widget.enableInteractiveSelection,
            dragStartBehavior: widget.dragStartBehavior,
            onHandleTap: hideToolbar,
            onHandleDragStart: _startSelectionHandleDrag,
            onHandleDragEnd: _endDrag,
            child: gestures,
          );
        }

        return Focus(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          onKeyEvent: _handleKeyEvent,
          child: _MarkdownCompositionCallback(
            enabled: _textInputConnection?.attached ?? false,
            onComposite: _handleComposition,
            child: TapRegion(
              onTapOutside: (_) => hideToolbar(),
              child: selectionSurface,
            ),
          ),
        );
      },
    );
  }

  List<Widget> _extractInlineChildren(InlineSpan span) {
    final result = <Widget>[];
    void visit(InlineSpan current) {
      if (current case WidgetSpan(:final child)) result.add(child);
      if (current case TextSpan(:final children?)) {
        for (final child in children) {
          visit(child);
        }
      }
    }

    visit(span);
    return result;
  }
}

final class _MarkdownCompositionCallback extends SingleChildRenderObjectWidget {
  const _MarkdownCompositionCallback({
    required this.enabled,
    required this.onComposite,
    required super.child,
  });

  final bool enabled;
  final CompositionCallback onComposite;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMarkdownCompositionCallback(enabled, onComposite);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMarkdownCompositionCallback renderObject,
  ) {
    renderObject
      ..onComposite = onComposite
      ..enabled = enabled;
  }
}

final class _RenderMarkdownCompositionCallback extends RenderProxyBox {
  _RenderMarkdownCompositionCallback(this._enabled, this._onComposite);

  bool _enabled;
  CompositionCallback _onComposite;
  VoidCallback? _cancelCompositionCallback;

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) {
      _cancelCompositionCallback?.call();
      _cancelCompositionCallback = null;
    } else {
      markNeedsPaint();
    }
  }

  set onComposite(CompositionCallback value) {
    if (value == _onComposite) return;
    _onComposite = value;
    _cancelCompositionCallback?.call();
    _cancelCompositionCallback = null;
    if (_enabled) markNeedsPaint();
  }

  void _dispatchComposition(Layer layer) => _onComposite(layer);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_enabled) {
      _cancelCompositionCallback ??= context.addCompositionCallback(
        _dispatchComposition,
      );
    }
    super.paint(context, offset);
  }

  @override
  void detach() {
    _cancelCompositionCallback?.call();
    _cancelCompositionCallback = null;
    super.detach();
  }
}
