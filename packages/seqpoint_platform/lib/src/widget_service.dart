/// 移动端桌面 / 锁屏小组件。
abstract interface class WidgetService {
  /// 更新今日剩余数量。
  Future<void> updateTodayCount(int count);

  /// 小组件是否已被用户添加。
  Future<bool> isAdded();
}

/// 系统分享接入："发送到序点"。
abstract interface class ShareIntake {
  /// 分享进来的文本流。冷启动的首条也从这里给出。
  Stream<String> get texts;

  /// 分享进来的图片路径流。
  Stream<List<String>> get imagePaths;
}

/// 长按 App 图标的快捷动作。
enum QuickActionType { quickNote, voiceNote }

abstract interface class QuickActionsService {
  Future<void> register();
  Stream<QuickActionType> get selections;
}
