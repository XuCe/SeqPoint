import 'enums.dart';

/// V1内置角色身份固定；保留ID可定位仅含name的后续增量。
int? builtinTypeRole(String id, {String? kind, int? builtin, int? sort}) {
  for (var i = 0; i < builtinTypeTags.length; i++) {
    if (id == 'builtin-type:$i') return i;
  }
  if (kind != 'type' || builtin != 1 || sort == null ||
      sort < 0 || sort % 10 != 0 || sort ~/ 10 >= builtinTypeTags.length) {
    return null;
  }
  return sort ~/ 10;
}

/// 标签。两个维度：项目（#项目A）与任务类型（沟通 / 运维 / 文档…）。
///
/// AI 建议总数不超过 3 个，防止标签爆炸；"想法"类型的事项不催办。
class Tag {
  const Tag({
    required this.id,
    required this.name,
    required this.kind,
    this.logicalName,
    this.builtin = false,
    this.color,
    this.sort = 0,
  });

  final String id;
  final String name;
  /// 本机消歧前的业务名；仅派生显示名时存在，不作为同步新字段。
  final String? logicalName;
  final TagKind kind;

  /// 内置类型标签不可删除，只可重命名。
  final bool builtin;
  final String? color;
  final int sort;

  /// 内置角色不随改名漂移；普通type保留旧名称语义。
  bool get isIdea {
    final role = builtinTypeRole(id, kind: kind.dbValue,
        builtin: builtin ? 1 : 0, sort: sort);
    if (role != null) return role == 8;
    return kind == TagKind.type && (logicalName ?? name) == '想法';
  }

  Tag copyWith({String? name, TagKind? kind, String? color, int? sort}) => Tag(
        id: id,
        name: name ?? this.name,
        logicalName: name == null || name == this.name ? logicalName : null,
        kind: kind ?? this.kind,
        builtin: builtin,
        color: color ?? this.color,
        sort: sort ?? this.sort,
      );
}

/// 内置任务类型标签，首次启动时写入。
const List<String> builtinTypeTags = [
  '沟通',
  '开发',
  '运维',
  '文档',
  '采购',
  '生活',
  '学习',
  '财务',
  '想法',
];
