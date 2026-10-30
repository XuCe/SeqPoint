/// 便签形态。meeting 在 M6 才启用，此处预留以保证数据库兼容。
enum NoteKind { text, meeting }

/// 便签生命周期：活跃 → 已关闭（归档）。删除走 deletedAt 软删除。
enum NoteStatus { active, closed }

/// 事项状态。UI 仅暴露这三态；数据库字段与 PRD V1.1 的八态枚举兼容。
enum ItemStatus { todo, done, canceled }

/// 优先级。内部保留 P0–P4，UI 默认只暴露"⭐ 重要"（= p1）。
enum Priority { p0, p1, p2, p3, p4 }

/// 事项来源：手动创建还是 AI 整理产出。
enum ItemSource { manual, ai }

/// 标签维度：项目 / 任务类型 / 自定义。
enum TagKind { project, type, custom }

/// 提醒模式。
enum ReminderMode { exact, relative, smart, overdue, digest }

/// 用户对提醒的反馈，用于疲劳控制。
enum ReminderFeedback { opened, ignored, snoozed, completed }

extension EnumName on Enum {
  /// 数据库存储用的名字（与 SQL CHECK 约束一致）。
  String get dbValue => name;
}

/// 从数据库值解析枚举，未知值回落到 [fallback]。
T parseEnum<T extends Enum>(List<T> values, String? raw, T fallback) {
  if (raw == null) return fallback;
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return fallback;
}
