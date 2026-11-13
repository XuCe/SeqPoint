import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Package-owned bridge between a [TextEditingController] and Flutter's
/// delta-based platform text input protocol.
final class MarkdownTextInputClient with DeltaTextInputClient {
  MarkdownTextInputClient({
    required this.controller,
    List<TextInputFormatter> inputFormatters = const [],
    List<TextInputFormatter> Function()? inputFormattersOf,
    this.readOnly = false,
    this.autofillScope,
    this.onChanged,
    this.onSelectionChanged,
    this.onEditingComplete,
    this.onSubmitted,
    this.onPrivateCommand,
    this.onFloatingCursor,
    this.onAutocorrectionPrompt,
    this.onConnectionClosed,
    this.onContentInserted,
    bool Function()? onFocusReceived,
    this.onInputControlChanged,
    this.onToolbarRequested,
    this.onTextPlaceholderInserted,
    this.onTextPlaceholderRemoved,
    this.onSelector,
    this.onPlatformValue,
  }) : _inputFormattersOf = inputFormattersOf ?? (() => inputFormatters) {
    _onFocusReceived = onFocusReceived;
  }

  final TextEditingController controller;

  /// SeqPoint patch: read on every edit, so a host that rebuilds its formatter
  /// list does not have to replace this client (and reconnect the platform
  /// input, which resets an in-progress IME composition on Windows).
  List<TextInputFormatter> get inputFormatters => _inputFormattersOf();
  final List<TextInputFormatter> Function() _inputFormattersOf;
  final bool readOnly;
  final AutofillScope? autofillScope;
  final ValueChanged<String>? onChanged;
  final ValueChanged<TextSelection>? onSelectionChanged;
  final VoidCallback? onEditingComplete;
  final ValueChanged<String>? onSubmitted;
  final void Function(String action, Map<String, dynamic> data)?
  onPrivateCommand;
  final ValueChanged<RawFloatingCursorPoint>? onFloatingCursor;
  final void Function(int start, int end)? onAutocorrectionPrompt;
  final VoidCallback? onConnectionClosed;
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;
  late final bool Function()? _onFocusReceived;
  final void Function(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  )?
  onInputControlChanged;
  final VoidCallback? onToolbarRequested;
  final ValueChanged<Size>? onTextPlaceholderInserted;
  final VoidCallback? onTextPlaceholderRemoved;
  final ValueChanged<String>? onSelector;

  /// Receives every editing value the platform reports, before formatting.
  ///
  /// SeqPoint patch: the editor records it as the value the platform already
  /// holds and does not send it straight back with `setEditingState`. On
  /// Windows that echo ends an in-progress IME composition, after which each
  /// pinyin update is inserted as committed text ("wwuwu'z乌镇").
  final ValueChanged<TextEditingValue>? onPlatformValue;

  @override
  TextEditingValue get currentTextEditingValue => controller.value;

  @override
  AutofillScope? get currentAutofillScope => autofillScope;

  @override
  void updateEditingValue(TextEditingValue value) {
    onPlatformValue?.call(value);
    _commit(value);
  }

  /// Applies an edit the editor made itself (paste, cut, replace). Unlike
  /// [updateEditingValue] the platform does not hold it yet, so it is sent on.
  void applyLocalEditingValue(TextEditingValue value) => _commit(value);

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    var value = controller.value;
    if (onPlatformValue != null) {
      var platform = value;
      for (final delta in textEditingDeltas) {
        platform = delta.apply(platform);
      }
      onPlatformValue!(platform);
    }
    if (readOnly) {
      for (final delta in textEditingDeltas) {
        if (delta is TextEditingDeltaNonTextUpdate &&
            delta.oldText == value.text &&
            delta.composing == value.composing &&
            _isValidSelection(delta.selection, value.text.length)) {
          value = value.copyWith(selection: delta.selection);
        }
      }
    } else {
      for (final delta in textEditingDeltas) {
        value = delta.apply(value);
      }
    }
    _commit(value);
  }

  static bool _isValidSelection(TextSelection selection, int textLength) {
    return selection.isValid &&
        selection.start <= textLength &&
        selection.end <= textLength;
  }

  void _commit(TextEditingValue platformValue) {
    final oldValue = controller.value;
    if (readOnly) {
      if (oldValue.text != platformValue.text ||
          oldValue.composing != platformValue.composing ||
          !_isValidSelection(platformValue.selection, oldValue.text.length)) {
        return;
      }
      platformValue = oldValue.copyWith(selection: platformValue.selection);
    }
    var nextValue = platformValue;
    if (oldValue.text != platformValue.text ||
        oldValue.composing != platformValue.composing) {
      for (final formatter in inputFormatters) {
        nextValue = formatter.formatEditUpdate(oldValue, nextValue);
      }
    }
    if (nextValue == oldValue) return;

    controller.value = nextValue;
    if (oldValue.text != nextValue.text) onChanged?.call(nextValue.text);
    if (oldValue.selection != nextValue.selection) {
      onSelectionChanged?.call(nextValue.selection);
    }
  }

  @override
  void performAction(TextInputAction action) {
    onEditingComplete?.call();
    onSubmitted?.call(controller.text);
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    onPrivateCommand?.call(action, data);
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    onFloatingCursor?.call(point);
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    onAutocorrectionPrompt?.call(start, end);
  }

  @override
  void connectionClosed() {
    onConnectionClosed?.call();
  }

  @override
  void insertContent(KeyboardInsertedContent content) {
    onContentInserted?.call(content);
  }

  @override
  bool onFocusReceived() => _onFocusReceived?.call() ?? false;

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {
    onInputControlChanged?.call(oldControl, newControl);
  }

  @override
  void showToolbar() {
    onToolbarRequested?.call();
  }

  @override
  void insertTextPlaceholder(Size size) {
    onTextPlaceholderInserted?.call(size);
  }

  @override
  void removeTextPlaceholder() {
    onTextPlaceholderRemoved?.call();
  }

  @override
  void performSelector(String selectorName) {
    onSelector?.call(selectorName);
  }
}
