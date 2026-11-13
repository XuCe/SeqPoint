import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Windows 桌面引擎文字输入的仿真：照搬 Flutter 引擎
/// `shell/platform/common/text_input_model.cc` 与
/// `shell/platform/windows/text_input_plugin.cc` 的行为，
/// 加上一个拼音输入法：组字串逐键变长，选字后上屏。
///
/// 框架发给引擎的调用先排队，[deliver] 时才处理，用来模拟两边消息的先后。
class WindowsTextInputFake {
  WindowsTextInputFake(this.tester) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.textInput, _receive);
  }

  final WidgetTester tester;
  final _pending = <MethodCall>[];
  final calls = <String>[];
  _Model? _model;
  int _clientId = 0;
  bool _delta = false;

  /// 输入法自己的组字串（不受引擎状态影响）。
  String _imeComposition = '';

  String? get text => _model?.text;

  Future<Object?> _receive(MethodCall call) async {
    calls.add(call.method);
    _pending.add(call);
    return null;
  }

  /// 引擎处理框架发来的所有排队调用。
  void deliver() {
    while (_pending.isNotEmpty) {
      _handle(_pending.removeAt(0));
    }
  }

  void _handle(MethodCall call) {
    switch (call.method) {
      case 'TextInput.setClient':
        final args = call.arguments as List<Object?>;
        _clientId = args[0]! as int;
        final config = args[1]! as Map<Object?, Object?>;
        _delta = config['enableDeltaModel'] == true;
        _model = _Model();
      case 'TextInput.clearClient':
        final model = _model;
        if (model != null && model.composing) {
          model.commitComposing();
          model.endComposing();
          _sendState(model);
        }
        // view->OnResetImeComposing(): ImmNotifyIME(CPS_CANCEL)。
        _imeComposition = '';
        _model = null;
      case 'TextInput.setEditingState':
        final model = _model;
        if (model == null) return;
        final args = call.arguments as Map<Object?, Object?>;
        var base = args['selectionBase']! as int;
        var extent = args['selectionExtent']! as int;
        if (base == -1 && extent == -1) base = extent = 0;
        model.setText(args['text']! as String);
        model.setSelection(_Range(base, extent));
        final composingBase = args['composingBase']! as int;
        // 引擎原样如此：extent 也取 composingBase。
        final composingExtent = args['composingBase']! as int;
        if (composingBase == -1 && composingExtent == -1) {
          model.endComposing();
        } else {
          final start = math.min(composingBase, composingExtent);
          model.setComposingRange(_Range(composingBase, composingExtent), base - start);
        }
    }
  }

  /// 输入法收到一个拼音按键；[shown] 是此刻输入法显示的整串组字。
  void imeKey(String shown) {
    final model = _model;
    if (_imeComposition.isEmpty && model != null) {
      // WM_IME_STARTCOMPOSITION → ComposeBeginHook
      model.beginComposing();
      _sendDelta(model, _Delta.nonText(model.text));
    }
    _imeComposition = shown;
    if (model != null) _composeChange(model, shown, shown.length);
  }

  /// 选字上屏：GCS_RESULTSTR 后跟 WM_IME_ENDCOMPOSITION。
  void imeCommit(String result) {
    _imeComposition = '';
    final model = _model;
    if (model == null) return;
    _composeChange(model, result, result.length);
    model.commitComposing();
    // ComposeEndHook
    model.commitComposing();
    model.endComposing();
    _sendDelta(model, _Delta.nonText(model.text));
  }

  void _composeChange(_Model model, String text, int cursor) {
    final before = model.text;
    final start = model.composingRange.start;
    final end = model.composingRange.end;
    model.addText(text);
    model.updateComposingText(text, _Range(cursor, cursor));
    _sendDelta(model, _Delta(before, start, end, text));
  }

  void _sendDelta(_Model model, _Delta delta) {
    if (!_delta) return _sendState(model);
    _send('TextInputClient.updateEditingStateWithDeltas', [
      _clientId,
      {
        'deltas': [
          {
            'oldText': delta.oldText,
            'deltaText': delta.text,
            'deltaStart': delta.start,
            'deltaEnd': delta.end,
            ..._selectionAndComposing(model),
          },
        ],
      },
    ]);
  }

  void _sendState(_Model model) => _send('TextInputClient.updateEditingState', [
        _clientId,
        {'text': model.text, ..._selectionAndComposing(model)},
      ]);

  Map<String, Object> _selectionAndComposing(_Model model) => {
        'selectionAffinity': 'TextAffinity.downstream',
        'selectionBase': model.selection.base,
        'selectionExtent': model.selection.extent,
        'selectionIsDirectional': false,
        'composingBase': model.composing ? model.composingRange.base : -1,
        'composingExtent': model.composing ? model.composingRange.extent : -1,
      };

  void _send(String method, Object args) {
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }
}

class _Delta {
  _Delta(this.oldText, this.start, this.end, this.text);
  _Delta.nonText(this.oldText) : start = -1, end = -1, text = '';
  final String oldText;
  final int start;
  final int end;
  final String text;
}

class _Range {
  _Range(this.base, this.extent);
  _Range.at(int position) : base = position, extent = position;
  int base;
  int extent;
  int get start => math.min(base, extent);
  int get end => math.max(base, extent);
  int get length => end - start;
  bool get collapsed => base == extent;
  bool contains(_Range other) => other.start >= start && other.end <= end;
  void setEnd(int position) {
    if (base <= extent) {
      extent = position;
    } else {
      base = position;
    }
  }
}

/// `TextInputModel` 的逐行移植（UTF-16，与 Dart 字符串一致）。
class _Model {
  String text = '';
  _Range selection = _Range.at(0);
  _Range composingRange = _Range.at(0);
  bool composing = false;

  _Range get textRange => _Range(0, text.length);
  _Range get editableRange => composing ? composingRange : textRange;

  bool setText(String value) {
    text = value;
    selection = _Range.at(0);
    composingRange = _Range.at(0);
    composing = false;
    return true;
  }

  bool setSelection(_Range range) {
    if (composing && !range.collapsed) return false;
    if (!editableRange.contains(range)) return false;
    selection = range;
    return true;
  }

  bool setComposingRange(_Range range, int cursorOffset) {
    if (!composing || !textRange.contains(range)) return false;
    composingRange = range;
    selection = _Range.at(range.start + cursorOffset);
    return true;
  }

  void beginComposing() {
    composing = true;
    composingRange = _Range.at(selection.start);
  }

  void updateComposingText(String value, _Range cursor) {
    if (value.isEmpty && composingRange.collapsed) return;
    final remove = composingRange.collapsed ? selection : composingRange;
    text = text.replaceRange(remove.start, remove.end, value);
    composingRange.setEnd(composingRange.start + value.length);
    selection = _Range(cursor.start + composingRange.start,
        cursor.extent + composingRange.start);
  }

  void commitComposing() {
    if (composingRange.collapsed) return;
    composingRange = _Range.at(composingRange.end);
    selection = _Range.at(composingRange.start);
  }

  void endComposing() {
    composing = false;
    composingRange = _Range.at(0);
  }

  bool deleteSelected() {
    if (selection.collapsed) return false;
    final start = selection.start;
    text = text.replaceRange(start, selection.end, '');
    selection = _Range.at(start);
    if (composing) composingRange = _Range.at(start);
    return true;
  }

  void addText(String value) {
    deleteSelected();
    if (composing) {
      text = text.replaceRange(composingRange.start, composingRange.end, '');
      selection = _Range.at(composingRange.start);
      composingRange.setEnd(composingRange.start + value.length);
    }
    final position = selection.start;
    text = text.replaceRange(position, position, value);
    selection = _Range.at(position + value.length);
  }
}
