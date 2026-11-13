import 'package:flutter/rendering.dart' show MouseCursor;

/// Off web the editor surface is fully framework-rendered, so framework
/// [MouseRegion] cursors apply directly and no DOM sync is needed.
void applyWebEditingCursor(MouseCursor cursor) {}
