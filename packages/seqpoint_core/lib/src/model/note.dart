import '../util/clock.dart';
import 'enums.dart';

/// 桌面便签窗的位置与大小，仅桌面端使用。
class NoteWindow {
  const NoteWindow({required this.x, required this.y, required this.w, required this.h});
  final double x, y, w, h;

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};

  static NoteWindow? fromJson(Map<String, Object?>? j) => j == null
      ? null
      : NoteWindow(
          x: (j['x'] as num).toDouble(),
          y: (j['y'] as num).toDouble(),
          w: (j['w'] as num).toDouble(),
          h: (j['h'] as num).toDouble(),
        );
}

/// 便签：一次"随手记"的容器，可含 0..N 个事项。
///
/// 生命周期：打开 → 记录 → 整理 → 全部事项完成 → 关闭归档。
/// [rawContent] 永不因 AI 整理而改变，整理只是把行"升级"为事项。
class Note {
  const Note({
    required this.id,
    required this.kind,
    required this.status,
    required this.rawContent,
    required this.createdAt,
    required this.updatedAt,
    this.title,
    this.color,
    this.pinned = false,
    this.window,
    this.closedAt,
    this.deletedAt,
    this.hlc,
  });

  final String id;
  final NoteKind kind;
  final NoteStatus status;

  /// 原始文字，多行。整理不改写它。
  final String rawContent;

  /// AI 生成的短标题，可改可空。
  final String? title;
  final String? color;
  final bool pinned;
  final NoteWindow? window;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? closedAt;
  final DateTime? deletedAt;

  /// 同步用混合逻辑时钟，M4 起写入。
  final String? hlc;

  bool get isDeleted => deletedAt != null;
  bool get isClosed => status == NoteStatus.closed;

  /// 按行拆分原始内容，供"行转事项"与 AI 整理使用。
  List<String> get lines => rawContent.split('\n');

  Note copyWith({
    NoteKind? kind,
    NoteStatus? status,
    String? rawContent,
    String? title,
    String? color,
    bool? pinned,
    NoteWindow? window,
    DateTime? updatedAt,
    DateTime? closedAt,
    DateTime? deletedAt,
    String? hlc,
    bool clearClosedAt = false,
    bool clearDeletedAt = false,
  }) =>
      Note(
        id: id,
        kind: kind ?? this.kind,
        status: status ?? this.status,
        rawContent: rawContent ?? this.rawContent,
        title: title ?? this.title,
        color: color ?? this.color,
        pinned: pinned ?? this.pinned,
        window: window ?? this.window,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        closedAt: clearClosedAt ? null : (closedAt ?? this.closedAt),
        deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
        hlc: hlc ?? this.hlc,
      );

  factory Note.create({
    required String rawContent,
    NoteKind kind = NoteKind.text,
    String? title,
    String? color,
    required Clock clock,
    String? id,
  }) {
    final now = clock.now();
    return Note(
      id: id ?? '',
      kind: kind,
      status: NoteStatus.active,
      rawContent: rawContent,
      title: title,
      color: color,
      createdAt: now,
      updatedAt: now,
    );
  }
}
