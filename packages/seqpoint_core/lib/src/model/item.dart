import 'enums.dart';

/// 事项来源引用：由哪个会议 / 便签的哪个时间点产生。M6 会议模块使用。
class SourceRef {
  const SourceRef({required this.noteId, this.timestampMs});
  final String noteId;
  final int? timestampMs;

  Map<String, Object?> toJson() => {'note_id': noteId, 'timestamp_ms': timestampMs};

  static SourceRef? fromJson(Map<String, Object?>? j) => j == null
      ? null
      : SourceRef(noteId: j['note_id'] as String, timestampMs: j['timestamp_ms'] as int?);
}

/// 事项：可勾选、可打标签、可提醒的执行单元。
///
/// [noteId] 可空——不依附便签的快速待办也是合法的。
class Item {
  const Item({
    required this.id,
    required this.title,
    required this.status,
    required this.priority,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.noteId,
    this.lineIndex,
    this.dueAt,
    this.completedAt,
    this.sourceRef,
    this.deletedAt,
    this.hlc,
  });

  final String id;
  final String? noteId;

  /// 该事项对应便签中的行号，用于把勾选状态回显到便签上。
  final int? lineIndex;

  final String title;
  final ItemStatus status;
  final Priority priority;
  final ItemSource source;

  final DateTime? dueAt;
  final DateTime? completedAt;
  final SourceRef? sourceRef;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final String? hlc;

  bool get isDone => status == ItemStatus.done;
  bool get isOpen => status == ItemStatus.todo && deletedAt == null;

  /// UI 上的"⭐ 重要"开关：p0 或 p1 视为重要。
  bool get isImportant => priority == Priority.p0 || priority == Priority.p1;

  bool isOverdue(DateTime now) =>
      isOpen && dueAt != null && dueAt!.isBefore(now);

  Item copyWith({
    String? noteId,
    int? lineIndex,
    String? title,
    ItemStatus? status,
    Priority? priority,
    ItemSource? source,
    DateTime? dueAt,
    DateTime? completedAt,
    SourceRef? sourceRef,
    DateTime? updatedAt,
    DateTime? deletedAt,
    String? hlc,
    bool clearDueAt = false,
    bool clearCompletedAt = false,
    bool clearDeletedAt = false,
  }) =>
      Item(
        id: id,
        noteId: noteId ?? this.noteId,
        lineIndex: lineIndex ?? this.lineIndex,
        title: title ?? this.title,
        status: status ?? this.status,
        priority: priority ?? this.priority,
        source: source ?? this.source,
        dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
        completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
        sourceRef: sourceRef ?? this.sourceRef,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
        hlc: hlc ?? this.hlc,
      );
}
