/// 序点 SeqPoint 平台能力抽象。
///
/// 这里只有接口，实现按端注入。核心层与 UI 层都只依赖这些接口，
/// 便于在测试中替换，也便于让某端"没有这个能力"（如移动端没有全局快捷键）。
library;

export 'src/hotkey_service.dart';
export 'src/notification_service.dart';
export 'src/secret_store.dart';
export 'src/selected_text_service.dart';
export 'src/sync_engine_host.dart';
export 'src/tray_service.dart';
export 'src/widget_service.dart';
export 'src/window_service.dart';
