/// 通知上的动作按钮。
enum NotificationAction { done, snooze, open }

/// 一条待调度的通知。
class NotificationRequest {
  const NotificationRequest({
    required this.id,
    required this.title,
    required this.body,
    required this.fireAt,
    this.itemId,
    this.actions = const [NotificationAction.done, NotificationAction.snooze],
  });

  final int id;
  final String title;
  final String body;
  final DateTime fireAt;
  final String? itemId;
  final List<NotificationAction> actions;
}

/// 本地通知调度。不依赖服务端推送，与零服务端原则一致。
abstract interface class NotificationService {
  Future<bool> requestPermission();

  Future<void> schedule(NotificationRequest request);

  Future<void> cancel(int id);

  Future<void> cancelForItem(String itemId);

  /// 根界面就绪后读取冷启动点击，成功读取后只消费一次。
  Future<String?> takeLaunchItem();

  /// 用户在通知上的操作回流，用于疲劳控制与跨端去重。
  Stream<({String itemId, NotificationAction action})> get responses;
}
