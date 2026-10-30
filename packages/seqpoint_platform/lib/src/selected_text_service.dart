/// 读取当前前台应用的选中文字，供"选中即整理"使用。
///
/// 实现路径：
/// - macOS：辅助功能权限 + 模拟 ⌘C，读完立即还原剪贴板；
/// - Windows：SendInput 模拟 Ctrl+C，同样还原剪贴板。
///
/// 失败时的退化方案是"剪贴板成便签"。
abstract interface class SelectedTextService {
  /// 返回选中文字，无选中或无权限返回 null。
  Future<String?> getSelectedText();

  /// 是否已获得所需系统权限（macOS 辅助功能）。
  Future<bool> hasPermission();

  /// 引导用户授权。
  Future<void> requestPermission();
}
