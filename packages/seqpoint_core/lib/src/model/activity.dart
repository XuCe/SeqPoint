/// 操作留痕。从第一版就保留：用于撤销、审计、同步冲突回看。
class Activity {
  const Activity({
    required this.id,
    required this.objectType,
    required this.objectId,
    required this.action,
    required this.createdAt,
    this.oldValue,
    this.newValue,
  });

  final String id;

  /// 'note' | 'item' | 'tag' | 'reminder'
  final String objectType;
  final String objectId;

  /// 见 [ActivityAction]。
  final String action;
  final String? oldValue;
  final String? newValue;
  final DateTime createdAt;
}

/// Activity 的 action 取值。用常量而非枚举，便于未来扩展不破坏旧数据。
abstract final class ActivityAction {
  static const noteCreated = 'note_created';
  static const noteEdited = 'note_edited';
  static const noteClosed = 'note_closed';
  static const noteReopened = 'note_reopened';
  static const noteTrashed = 'note_trashed';
  static const itemCreated = 'item_created';
  static const itemStatusChanged = 'item_status_changed';
  static const itemPriorityChanged = 'item_priority_changed';
  static const itemDueChanged = 'item_due_changed';
  static const itemTagsChanged = 'item_tags_changed';
  static const aiOrganizeApplied = 'ai_organize_applied';
  static const aiOrganizeUndone = 'ai_organize_undone';
  static const reminderFired = 'reminder_fired';
  static const reminderSnoozed = 'reminder_snoozed';
  static const syncConflictResolved = 'sync_conflict_resolved';
  static const deviceAdded = 'device_added';
  static const deviceRevoked = 'device_revoked';
}
