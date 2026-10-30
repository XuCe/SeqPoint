/// AI 整理的产出：一份待用户确认的提案。
///
/// 铁律：提案在用户确认前**绝不写入任何业务对象**。
class OrganizeProposal {
  const OrganizeProposal({
    required this.noteId,
    required this.sourceContent,
    required this.items,
    this.noteTitle,
    this.nonActionLines = const [],
    this.explanation,
  });

  final String noteId;
  /// 生成提案时的已保存原文；采纳前必须与当前便签完全一致。
  final String sourceContent;

  /// AI 归纳的便签短标题（≤12 字），可空。
  final String? noteTitle;

  final List<ProposedItem> items;

  /// 被识别为"想法 / 信息"的行号，不催办、不建事项。
  final List<int> nonActionLines;

  /// 可解释性：为何这样拆、为何建议这个时间。
  final String? explanation;

  bool get isEmpty => items.isEmpty && noteTitle == null;
}

/// 提案中的单个事项。字段均为建议值，用户可逐项修改。
class ProposedItem {
  const ProposedItem({
    required this.id,
    required this.title,
    this.lineIndex,
    this.typeTagName,
    this.projectTagName,
    this.dueAt,
    this.hasExplicitClock = false,
    this.important = false,
    this.reminderHint,
    this.recurrence,
    this.accepted = true,
  });

  /// 本地生成的稳定ID，采纳后的事项继续使用它。
  final String id;
  final String title;

  /// 对应便签中的行号，用于把勾选状态回显。
  final int? lineIndex;

  /// 任务类型标签，从内置枚举中选。
  final String? typeTagName;

  /// 项目标签，优先匹配既有；新词需重复出现 ≥2 次才建议新建。
  final String? projectTagName;

  final DateTime? dueAt;
  final bool hasExplicitClock;
  final bool important;

  /// 建议的提醒时机说明，如"当天 09:00"。
  final String? reminderHint;
  final String? recurrence;

  /// 确认卡上的勾选状态，默认采纳。
  final bool accepted;

  ProposedItem copyWith({
    String? title,
    String? typeTagName,
    String? projectTagName,
    DateTime? dueAt,
    bool? important,
    bool? accepted,
    bool clearDueAt = false,
  }) =>
      ProposedItem(
        id: id,
        title: title ?? this.title,
        lineIndex: lineIndex,
        typeTagName: typeTagName ?? this.typeTagName,
        projectTagName: projectTagName ?? this.projectTagName,
        dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
        hasExplicitClock: hasExplicitClock,
        important: important ?? this.important,
        reminderHint: reminderHint,
        recurrence: recurrence,
        accepted: accepted ?? this.accepted,
      );
}
