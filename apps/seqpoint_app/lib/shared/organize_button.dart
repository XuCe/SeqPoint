import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import '../app/app_scope.dart';
import '../settings/ai_settings_store.dart';
import 'organize_confirm_card.dart';

class OrganizeButton extends StatefulWidget {
  const OrganizeButton({super.key, required this.noteId, required this.onApplied,
    this.compact = false, this.loadSettings = AiSettingsStore.open, this.provider});
  final String noteId;
  final VoidCallback onApplied;
  final bool compact;
  final Future<AiSettingsStore> Function() loadSettings;
  final AiProvider? provider;
  @override
  State<OrganizeButton> createState() => _OrganizeButtonState();
}

class _OrganizeButtonState extends State<OrganizeButton> {
  bool _busy = false;
  bool _current(SeqDatabase database) => mounted && !AppScope.of(context).restoring &&
      identical(AppScope.of(context).database, database);
  bool _unchanged(Note note, SeqDatabase database) {
    if (!_current(database)) return false;
    final current = AppScope.of(context).notes.byId(note.id);
    return current != null && !current.isDeleted && current.rawContent == note.rawContent;
  }
  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(SnackBar(content: Text(message)));
  }
  Future<bool> _confirmSend(Note note, ProviderConfig config) async =>
      await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(scrollable: true,
        title: const Text('发送当前便签整理'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('服务：${config.baseUrl}\n模型：${config.model}'),
          const SizedBox(height: 12), const Text('仅发送以下已保存原文：'), SelectableText(note.rawContent),
        ]), actions: [TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: const Text('发送并整理'))])) ?? false;
  Future<void> _organize() async {
    final scope = AppScope.of(context); final database = scope.database;
    if (_busy || scope.restoring || database == null) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    setState(() => _busy = true);
    try {
      final settings = await widget.loadSettings();
      if (!_current(database)) return;
      final mode = settings.mode;
      if (mode == AiMode.off) { _notice('请先在AI设置中启用整理'); return; }
      final note = scope.notes.byId(widget.noteId);
      if (note == null || note.isDeleted) { _notice('便签不存在或已删除'); return; }
      final config = settings.config;
      String? apiKey;
      if (mode == AiMode.cloud) {
        if (!await _confirmSend(note, config) || !_current(database)) return;
        if (!_unchanged(note, database)) { _notice('便签已变化，请重新整理'); return; }
        apiKey = await settings.readApiKey(config);
        if (!_current(database)) return;
        if (!_unchanged(note, database)) { _notice('便签已变化，请重新整理'); return; }
        if (apiKey == null || apiKey.isEmpty) { _notice('请先在AI设置中配置该服务的密钥'); return; }
      }
      final result = await OrganizeService(mode: mode, config: config,
          provider: widget.provider ?? OpenAiCompatibleProvider()).organize(note, apiKey: apiKey,
          alreadyOrganizedLines: scope.items.byNote(note.id).map((item) => item.lineIndex).whereType<int>().toSet(),
          knownProjectTags: scope.tags.all(kind: TagKind.project).map((tag) => tag.name).toList());
      if (!_current(database)) return;
      if (!_unchanged(note, database)) { _notice('便签已变化，请重新整理'); return; }
      if (result is Err<OrganizeProposal>) {
        _notice(switch (result.code) {
          'request_timeout' => '模型请求超时，请重试',
          'request_failed' => '整理请求失败，请检查网络和配置',
          'invalid_proposal' || 'invalid_response' => '整理结果无效，请重试',
          'invalid_request' => '便签过长，请缩短后重试',
          'invalid_config' || 'ai_not_configured' => '请先在AI设置中配置服务地址、模型和密钥',
          _ => '整理失败，请重试',
        });
        return;
      }
      final proposal = result.valueOrNull;
      if (proposal == null || proposal.items.isEmpty) { _notice('没有可采纳的新事项'); return; }
      final count = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (preview) => Scaffold(
        appBar: AppBar(title: const Text('整理预览')),
        body: OrganizeConfirmCard(proposal: proposal,
          onCancel: () => Navigator.of(preview).pop(), onAccept: (value) async {
            if (!_current(database)) throw StateError('数据已切换，请重新整理');
            final created = OrganizeApplier(database).apply(value);
            Navigator.of(preview).pop(created.length);
          }),
      )));
      if (_current(database) && count != null) {
        widget.onApplied(); _notice(count == 0 ? '未新增事项，已跳过重复建议' : '已采纳 $count 项');
      }
    } catch (_) {
      if (_current(database)) _notice('整理失败，请重试');
    } finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return IconButton(tooltip: _busy ? '正在整理' : '整理',
        icon: _busy ? SizedBox.square(dimension: widget.compact ? 14 : 20,
            child: const CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.auto_awesome, size: widget.compact ? 14 : null),
        padding: widget.compact ? EdgeInsets.zero : null,
        constraints: widget.compact ? const BoxConstraints.tightFor(width: 26, height: 26) : null,
        onPressed: _busy || scope.restoring || scope.database == null ? null : _organize);
  }
}
