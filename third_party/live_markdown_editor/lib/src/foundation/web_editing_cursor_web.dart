// On web, the engine overlays a transparent DOM editing element (`textarea`
// with the `flt-text-editing` class) that is sized to the entire editable
// surface while the field is focused. Browsers give that element the I-beam
// cursor, which overrides every framework [MouseRegion] under the pointer —
// so interactive parts (task toggles, links) inside the editor would show the
// writing cursor instead of the click cursor.
//
// This helper keeps the editing element's CSS cursor in sync with the
// framework's resolved hover cursor. Off web it is a no-op.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/rendering.dart' show MouseCursor, SystemMouseCursors;

/// Applies [cursor] to the engine's web editing element, if one exists.
///
/// The framework reports the cursor it resolved for the current pointer
/// position; the DOM element then matches it, so the browser shows the same
/// cursor the framework intends (click over interactive parts, I-beam over
/// text). Safe to call from any platform; does nothing when not on web.
void applyWebEditingCursor(MouseCursor cursor) {
  if (!kIsWeb) return;
  final element = _editingElement();
  if (element == null) return;
  final style = element.getProperty<JSAny?>('style'.toJS) as JSObject?;
  if (style == null) return;
  final cursorName = cursor == SystemMouseCursors.click ? 'pointer' : 'text';
  style.callMethod<JSAny?>('setProperty'.toJS, 'cursor'.toJS, cursorName.toJS);
}

/// Finds the engine's active text editing element.
///
/// The engine creates the element lazily on focus and removes it on blur.
/// Autofill groups may hold extra hidden zero-sized copies off screen, so the
/// active element is the one with non-zero layout size.
JSObject? _editingElement() {
  final document =
      globalContext.getProperty<JSAny?>('document'.toJS) as JSObject?;
  if (document == null) return null;
  final elements = document.callMethod<JSAny?>(
    'querySelectorAll'.toJS,
    '.flt-text-editing'.toJS,
  ) as JSObject?;
  if (elements == null) return null;
  final length =
      (elements.getProperty<JSAny?>('length'.toJS) as JSNumber?)?.toDartInt ??
      0;
  for (var index = 0; index < length; index++) {
    final element =
        elements.callMethod<JSAny?>('item'.toJS, index.toJS) as JSObject?;
    if (element == null) continue;
    final width =
        (element.getProperty<JSAny?>(
          'offsetWidth'.toJS,
        ) as JSNumber?)?.toDartInt ??
        0;
    final height =
        (element.getProperty<JSAny?>(
          'offsetHeight'.toJS,
        ) as JSNumber?)?.toDartInt ??
        0;
    if (width > 0 && height > 0) {
      return element;
    }
  }
  return null;
}
