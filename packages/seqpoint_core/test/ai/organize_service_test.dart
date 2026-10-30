import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  final note = Note(id: 'local-note', kind: NoteKind.text, status: NoteStatus.active,
      rawContent: '回复客户\n整理文档', createdAt: DateTime(2026, 10, 25), updatedAt: DateTime(2026, 10, 25));
  const config = ProviderConfig(id: 'openaiCompatible', baseUrl: 'https://example.test/v1', model: 'm');
  test('云端只发送当前原文，返回绑定原文的候选，不传既有标签列表', () async {
    final provider = _Provider({'items': [
      {'title': '回复客户报价', 'lineIndex': 0, 'important': true, 'projectTagName': '客户A'},
      {'title': '整理文档', 'lineIndex': 1},
    ]});
    final result = await OrganizeService(mode: AiMode.cloud, provider: provider, config: config)
        .organize(note, apiKey: 'test-secret', knownProjectTags: ['客户A', '不应发送的项目']);
    final proposal = result.valueOrNull!;
    expect(provider.prompt, note.rawContent); expect(provider.key, 'test-secret');
    expect(provider.schema, isNot(contains('不应发送的项目'))); expect(provider.calls, 1);
    expect(proposal.noteId, note.id); expect(proposal.sourceContent, note.rawContent);
    expect(proposal.items.map((e) => e.title), ['回复客户报价', '整理文档']);
    expect(proposal.items.first.important, isTrue);
    expect(proposal.items.first.projectTagName, '客户A');
    expect(proposal.items.map((e) => e.id).toSet(), hasLength(2));
    expect(proposal.items.every((e) => e.id.isNotEmpty), isTrue);
  });
  final invalidRows = <String, Map<String, Object?>>{
    '负行号': {'title': '事项', 'lineIndex': -1},
    '越界行号': {'title': '事项', 'lineIndex': 2},
    '小数行号': {'title': '事项', 'lineIndex': 0.0},
    '缺行号': {'title': '事项'},
    '空标题': {'title': '  ', 'lineIndex': 0},
    '多行标题': {'title': 'a\nb', 'lineIndex': 0},
    '过长标题': {'title': 'a' * 501, 'lineIndex': 0},
    '未知类型': {'title': '事项', 'lineIndex': 0, 'typeTagName': '隐藏类型'},
    '坏重要程度': {'title': '事项', 'lineIndex': 0, 'important': 'yes'},
    '坏期限': {'title': '事项', 'lineIndex': 0, 'dueAt': 'tomorrow'},
    '额外模型ID': {'title': '事项', 'lineIndex': 0, 'id': 'server-controlled'},
  };
  for (final entry in invalidRows.entries) {
    test('拒绝${entry.key}，不把不可信模型字段交采纳器', () async {
      final provider = _Provider({'items': [entry.value]});
      final result = await OrganizeService(mode: AiMode.cloud, provider: provider, config: config)
          .organize(note, apiKey: 'test-secret');
      expect((result as Err<OrganizeProposal>).code, 'invalid_proposal');
    });
  }
  test('同一行多个候选或超过100项拒绝整份提案', () async {
    final row = {'title': '事项', 'lineIndex': 0};
    for (final rows in [[row, row], List.filled(101, row)]) {
      final result = await OrganizeService(mode: AiMode.cloud, config: config,
          provider: _Provider({'items': rows})).organize(note, apiKey: 'test-secret');
      expect(result, isA<Err<OrganizeProposal>>());
    }
  });
  test('已整理行过滤、空结果和合法时区期限保留', () async {
    final provider = _Provider({'items': [
      {'title': '回复', 'lineIndex': 0},
      {'title': '文档', 'lineIndex': 1, 'typeTagName': '文档', 'dueAt': '2026-11-01T09:00:00-08:00'},
    ]});
    final service = OrganizeService(mode: AiMode.cloud, config: config, provider: provider);
    final result = (await service.organize(note, apiKey: 'secret', alreadyOrganizedLines: {0})).valueOrNull!;
    expect(result.items.single.lineIndex, 1); expect(result.items.single.typeTagName, '文档');
    expect(result.items.single.dueAt, DateTime.utc(2026, 11, 1, 17));
    expect((await service.organize(note, apiKey: 'secret', alreadyOrganizedLines: {0, 1}))
        .valueOrNull!.items, isEmpty);
  });
  for (final due in ['2026-02-30T09:00:00Z', '2026-11-01', '2026-11-01T25:00:00Z']) {
    test('拒绝溢出或缺时区期限：$due', () async {
      final result = await OrganizeService(mode: AiMode.cloud, config: config,
          provider: _Provider({'items': [{'title': '事项', 'lineIndex': 0, 'dueAt': due}]}))
          .organize(note, apiKey: 'secret');
      expect(result, isA<Err<OrganizeProposal>>());
    });
  }
  test('关闭、无配置和已删除便签不触发网络', () async {
    final provider = _Provider({'items': []});
    expect(await OrganizeService(mode: AiMode.off, provider: provider, config: config)
        .organize(note, apiKey: 'secret'), isA<Err<OrganizeProposal>>());
    expect(await OrganizeService(mode: AiMode.cloud, provider: provider)
        .organize(note), isA<Err<OrganizeProposal>>());
    expect(await OrganizeService(mode: AiMode.cloud, provider: provider, config: config)
        .organize(note.copyWith(deletedAt: DateTime(2026, 10, 26)), apiKey: 'secret'),
        isA<Err<OrganizeProposal>>());
    expect(provider.calls, 0);
  });
  test('空白原文不调用模型', () async {
    final provider = _Provider({'items': []});
    final result = await OrganizeService(mode: AiMode.cloud, provider: provider, config: config)
        .organize(note.copyWith(rawContent: ' \n'), apiKey: 'secret');
    expect(result.valueOrNull!.items, isEmpty); expect(provider.calls, 0);
  });
  test('本地规则仅建议明确清单/优先级/期限，保留原文且不调用模型', () async {
    final provider = _Provider({'items': []});
    final source = note.copyWith(rawContent: '- [ ] 明天交报表 #项目A !P1\n一条想法\n每天备份\n[ ] 已整理');
    final result = await OrganizeService(mode: AiMode.localRulesOnly, provider: provider,
        clock: FakeClock(DateTime(2026, 10, 25, 10))).organize(source,
        knownProjectTags: ['项目A'], alreadyOrganizedLines: {3});
    final proposal = result.valueOrNull!;
    expect(proposal.sourceContent, source.rawContent); expect(provider.calls, 0);
    expect(proposal.items, hasLength(1));
    final item = proposal.items.single;
    expect(item.lineIndex, 0); expect(item.title, '明天交报表');
    expect(item.important, isTrue); expect(item.projectTagName, '项目A');
    expect(item.dueAt, DateTime(2026, 10, 26, 9)); expect(item.recurrence, isNull);
  });
  test('项目新词至少两个未整理候选使用才建议，单项新词不造标签', () async {
    final provider = _Provider({'items': [
      {'title': '回复', 'lineIndex': 0, 'projectTagName': '新项目'},
      {'title': '文档', 'lineIndex': 1, 'projectTagName': '新项目'},
    ]});
    final service = OrganizeService(mode: AiMode.cloud, provider: provider, config: config);
    final proposal = (await service.organize(note, apiKey: 'secret')).valueOrNull!;
    expect(proposal.items.every((e) => e.projectTagName == '新项目'), isTrue);
    final filtered = (await service.organize(note, apiKey: 'secret', alreadyOrganizedLines: {0})).valueOrNull!;
    expect(filtered.items.single.projectTagName, isNull);
  });
  test('云端schema带可保存字段和本地参照时间，不隐藏丢掉期限', () async {
    final provider = _Provider({'items': []});
    await OrganizeService(mode: AiMode.cloud, config: config, provider: provider,
        clock: FakeClock(DateTime.utc(2026, 10, 25, 12))).organize(note, apiKey: 'secret');
    expect(provider.schema, contains('dueAt')); expect(provider.schema, contains('typeTagName'));
    expect(provider.schema, contains('2026-10-25T12:00:00')); expect(provider.schema, contains('沟通'));
  });
  for (final project in ['', 'a\nb', 'a' * 101]) {
    test('拒绝非法项目标签：${project.length}', () async {
      final provider = _Provider({'items': [{'title': '事项', 'lineIndex': 0, 'projectTagName': project}]});
      final result = await OrganizeService(mode: AiMode.cloud, provider: provider, config: config)
          .organize(note, apiKey: 'secret');
      expect(result, isA<Err<OrganizeProposal>>());
    });
  }
  test('空源行与多余顶层字段拒绝，大原文在调用前拒绝', () async {
    for (final response in [
      {'items': [{'title': '事项', 'lineIndex': 0}]},
      {'items': [], 'secret': 'unexpected'},
    ]) {
      final result = await OrganizeService(mode: AiMode.cloud, config: config, provider: _Provider(response))
          .organize(note.copyWith(rawContent: '\n有效行'), apiKey: 'secret');
      expect(result, isA<Err<OrganizeProposal>>());
    }
    final provider = _Provider({'items': []});
    final result = await OrganizeService(mode: AiMode.cloud, config: config, provider: provider)
        .organize(note.copyWith(rawContent: '中' * 22000), apiKey: 'secret');
    expect(result, isA<Err<OrganizeProposal>>()); expect(provider.calls, 0);
  });
  test('提供方失败不回退为假成功，也不透传正文或异常', () async {
    for (final throwsError in [false, true]) {
      final provider = _Provider({}, failure: const Err('request_failed',
          message: 'secret private text', cause: 'secret'), throwsError: throwsError);
      final result = await OrganizeService(mode: AiMode.cloud, config: config, provider: provider)
          .organize(note, apiKey: 'secret') as Err<OrganizeProposal>;
      expect(result.message, isNull); expect(result.cause, isNull);
      expect(provider.calls, 1); expect(note.rawContent, '回复客户\n整理文档');
    }
  });
  test('本地模式超过100候选拒绝整份提案', () async {
    final result = await OrganizeService(mode: AiMode.localRulesOnly)
        .organize(note.copyWith(rawContent: List.filled(101, '[ ] 待办').join('\n')));
    expect(result, isA<Err<OrganizeProposal>>());
  });
}

class _Provider implements AiProvider {
  _Provider(this.response, {this.failure, this.throwsError = false});
  final Map<String, Object?> response;
  final Result<Map<String, Object?>>? failure;
  final bool throwsError;
  String? prompt, key, schema;
  int calls = 0;
  @override
  String get id => 'openaiCompatible';
  @override
  Future<Result<Map<String, Object?>>> complete({required String prompt, required String schemaHint,
    required String apiKey, ProviderConfig config = const ProviderConfig(id: 'openaiCompatible')}) async {
    calls++; this.prompt = prompt; key = apiKey; schema = schemaHint;
    if (throwsError) throw StateError('secret private text');
    return failure ?? Ok(response);
  }
  @override
  Future<Result<void>> ping({required String apiKey,
    ProviderConfig config = const ProviderConfig(id: 'openaiCompatible')}) async => const Ok(null);
}
