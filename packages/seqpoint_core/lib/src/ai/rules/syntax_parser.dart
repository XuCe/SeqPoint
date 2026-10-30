/// 快速输入语法的解析结果。
class ParsedSyntax {
  const ParsedSyntax({
    required this.cleanTitle,
    this.tagNames = const [],
    this.priorityName,
  });

  /// 剥离语法标记后的干净标题。
  final String cleanTitle;

  /// `#标签` 提取出的名字，按出现顺序、已去重。
  final List<String> tagNames;

  /// 'p0'..'p3'，未指定为 null。
  final String? priorityName;

  bool get isEmpty =>
      cleanTitle.isEmpty && tagNames.isEmpty && priorityName == null;
}

/// 快速输入语法解析：`#标签`、`!P0`~`!P3`。纯本地规则，不调用模型。
///
/// 例：`回复张三报价 #项目A !P1 明天上午10点`
/// → 标题「回复张三报价 明天上午10点」、标签「项目A」、优先级 p1。
///
/// 时间短语不在这里处理，交给 [TimeParser]——两者对同一行各取所需。
class SyntaxParser {
  const SyntaxParser();

  /// 标签：# 后跟非空白、非 # 的字符。中文无需空格分隔，故以空白或 # 结束。
  static final _tagPattern = RegExp(r'#([^\s#!]+)');

  /// 优先级：!P0 ~ !P3，大小写不敏感。
  static final _priorityPattern = RegExp(r'!\s*[Pp]([0-3])');

  ParsedSyntax parse(String line) {
    final tagNames = <String>[];
    var rest = line;

    for (final m in _tagPattern.allMatches(line)) {
      final name = m.group(1)!;
      if (!tagNames.contains(name)) tagNames.add(name);
    }
    rest = rest.replaceAll(_tagPattern, ' ');

    String? priority;
    final pm = _priorityPattern.firstMatch(rest);
    if (pm != null) {
      priority = 'p${pm.group(1)}';
      rest = rest.replaceFirst(_priorityPattern, ' ');
    }

    return ParsedSyntax(
      cleanTitle: _squeeze(rest),
      tagNames: tagNames,
      priorityName: priority,
    );
  }

  /// 压缩多余空白。中文之间不补空格，只是把连续空白折成一个。
  static String _squeeze(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
