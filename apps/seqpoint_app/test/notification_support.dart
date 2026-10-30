import 'dart:async';

import 'package:seqpoint_platform/seqpoint_platform.dart';

class TestNotifications implements NotificationService {
  final scheduled = <NotificationRequest>[];
  final cancelled = <int>[];
  bool granted = true;
  bool failSchedule = false;
  bool failCancel = false;
  String? launchItemId;
  @override
  Future<String?> takeLaunchItem() async {
    final value = launchItemId;
    launchItemId = null;
    return value;
  }
  final events = StreamController<({String itemId, NotificationAction action})>
      .broadcast();

  @override
  Stream<({String itemId, NotificationAction action})> get responses =>
      events.stream;
  @override
  Future<bool> requestPermission() async => granted;
  @override
  Future<void> schedule(NotificationRequest request) async {
    if (failSchedule) throw StateError('schedule failed');
    scheduled.add(request);
  }
  @override
  Future<void> cancel(int id) async {
    if (failCancel) throw StateError('cancel failed');
    cancelled.add(id);
  }
  @override
  Future<void> cancelForItem(String itemId) async {}
}
