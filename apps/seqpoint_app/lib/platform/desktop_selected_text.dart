import 'package:flutter/services.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

/// 读取当前前台应用的选中文字，供"选中即整理"使用。
///
/// 原生侧实现（M0 任务 9 已写好方案）：
/// - macOS：辅助功能权限 + 模拟 ⌘C，读完立即还原剪贴板；
/// - Windows：SendInput 模拟 Ctrl+C，同样还原剪贴板。
///
/// 原生通道尚未接线时 [getSelectedText] 返回 null，
/// 调用方退化为"剪贴板成便签"。
class DesktopSelectedTextService implements SelectedTextService {
  const DesktopSelectedTextService();

  static const _channel = MethodChannel('seqpoint/selected_text');

  @override
  Future<String?> getSelectedText() async {
    try {
      return await _channel.invokeMethod<String>('getSelectedText');
    } on MissingPluginException {
      return null; // 原生侧未接线
    } on PlatformException {
      return null; // 无权限或取词失败，交由调用方退化
    }
  }

  @override
  Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } on MissingPluginException {
      // 原生侧未接线，静默忽略
    }
  }
}
