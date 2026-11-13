// Barrel that routes the web editing-cursor sync to the platform
// implementation. On web the engine's transparent editing element overrides
// framework cursors, so the real implementation patches its CSS cursor; on
// every other platform the editor renders itself and this is a no-op.
library;

export 'web_editing_cursor_io.dart'
    if (dart.library.js_interop) 'web_editing_cursor_web.dart';
