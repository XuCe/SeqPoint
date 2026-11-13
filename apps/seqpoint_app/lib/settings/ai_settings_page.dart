import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../theme/seq_tokens.dart';
import 'settings_scaffold.dart';
import 'ai_settings_store.dart';

/// AI 设置：隐私档位、兼容接口地址、模型和系统安全存储密钥。
///
/// 密钥只存系统安全存储，界面一律脱敏显示。首次开启云端档位时
/// 必须单独告知"将发送什么内容、发到哪里"。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, this.loadSettings = AiSettingsStore.open});
  final Future<AiSettingsStore> Function() loadSettings;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  AiMode _mode = AiMode.localRulesOnly;
  bool _loading = true, _loadError = false;
  bool _saving = false;
  bool _hasKey = false;
  AiSettingsStore? _store;
  final _base = TextEditingController(), _model = TextEditingController(), _key = TextEditingController();
  @override
  void dispose() { _base.dispose(); _model.dispose(); _key.dispose(); super.dispose(); }
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() { _loading = true; _loadError = false; });
    try {
      final store = await widget.loadSettings();
      final hasKey = await store.hasKey();
      if (mounted) {
        setState(() {
          _store = store; _mode = store.mode; _loading = false; _hasKey = hasKey;
          _base.text = store.config.baseUrl ?? ''; _model.text = store.config.model ?? '';
        });
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; _loadError = true; });
    }
  }

  Future<void> _save() async {
    if (_store == null || _saving) return;
    setState(() => _saving = true);
    try {
      if (_mode == AiMode.cloud && (_store!.mode != AiMode.cloud || _store!.config.baseUrl != _base.text.trim())) {
        final confirmed = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(scrollable: true,
          title: const Text('启用云端整理'),
          content: Text('仅在你点击整理并再次确认后，当前已保存便签的原文才会发送到\n${_base.text.trim()}\n'
              '不发送其他便签或附件；密钥仅用于该地址的请求认证。'),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('启用并保存'))]));
        if (confirmed != true || !mounted) return;
      }
      await _store!.save(mode: _mode, baseUrl: _base.text, model: _model.text, apiKey: _key.text);
      if (!mounted) return;
      _key.clear(); await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('配置已保存（未测试连接）')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('无法保存AI配置，请检查地址、模型和安全存储')));
      }
    } finally { if (mounted) setState(() => _saving = false); }
  }

  Future<void> _clearKey() async {
    if (_store == null || _saving) return;
    final target = _store!.config;
    setState(() => _saving = true);
    try {
      await _store!.clearApiKey(target);
      if (mounted) {
        setState(() { _hasKey = false; _key.clear(); });
        ScaffoldMessenger.of(context)..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('已清除当前服务密钥')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('无法清除密钥，请重试')));
      }
    } finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) {
    final editable = !_loading && !_loadError && !_saving;
    return SettingsScaffold(
      title: 'AI 整理',
      footnote: '密钥只保存在这台设备的系统安全存储里，'
          '不会写进数据库、日志或导出文件。请求由本机直接发往模型服务，'
          '序点的服务器不经手。',
      children: [
        if (_loading || _saving) const LinearProgressIndicator(),
        if (_loadError) ListTile(title: const Text('无法读取AI设置'),
            trailing: TextButton(onPressed: _load, child: const Text('重试'))),
        const SettingsLabel('整理方式'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: RadioGroup<AiMode>(
            groupValue: _mode,
            onChanged: (v) {
              if (!editable) return;
              setState(() => _mode = v ?? _mode);
            },
            child: LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 600;
              final tiles = [
                for (final mode in AiMode.values)
                  _ModeTile(
                    mode: mode,
                    selected: _mode == mode,
                    enabled: editable,
                    title: _titleOf(mode),
                    subtitle: _subtitleOf(mode),
                    icon: _iconOf(mode),
                    compact: !wide,
                    onTap: () => setState(() => _mode = mode),
                  ),
              ];
              return wide
                  ? IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (var i = 0; i < tiles.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(child: tiles[i]),
                      ],
                    ]))
                  : Column(children: [
                      for (var i = 0; i < tiles.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        tiles[i],
                      ],
                    ]);
            }),
          ),
        ),
        if (_mode == AiMode.cloud) ...[
          SettingsCard(
            icon: Icons.hub_outlined,
            title: 'OpenAI 兼容接口',
            subtitle: '填写任何兼容 OpenAI 格式的服务地址、模型名和密钥',
            children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: Column(children: [
                TextField(key: const ValueKey('ai-base-url'), controller: _base,
                    enabled: editable, keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: '服务地址（HTTPS Base URL）')),
                const SizedBox(height: 12),
                TextField(key: const ValueKey('ai-model'), controller: _model,
                    enabled: editable,
                    decoration: const InputDecoration(labelText: '模型名')),
                const SizedBox(height: 12),
                TextField(key: const ValueKey('ai-key'), controller: _key, obscureText: true,
                    enabled: editable, autocorrect: false, enableSuggestions: false,
                    decoration: const InputDecoration(labelText: 'API Key', helperText: '留空保留该地址已保存的密钥')),
              ])),
              ListTile(
                  leading: Icon(_hasKey ? Icons.key_rounded : Icons.key_off_outlined, size: 20,
                      color: _hasKey ? SeqTokens.goodInk : SeqTokens.inkMuted),
                  title: Text(_hasKey ? '已保存服务的密钥：已配置' : '已保存服务的密钥：未配置'),
                  subtitle: Text(_store?.config.baseUrl ?? '尚未保存服务地址'),
                  trailing: TextButton(onPressed: _hasKey && editable ? _clearKey : null,
                      child: const Text('清除已保存密钥'))),
            ],
          ),
          const SettingsCard(
            icon: Icons.visibility_outlined,
            title: '会发送什么',
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(62, 0, 16, 14),
                child: Text(
                  '· 只在你点“整理”并再次确认后发送，不会自动上传\n'
                  '· 只发送那一张便签已保存的原文\n'
                  '· 不发送附件、录音或其他便签\n'
                  '· 整理结果先给你看，采纳前不改动任何内容',
                  style: TextStyle(fontSize: 13, height: 1.8, color: SeqTokens.inkSoft),
                ),
              ),
            ],
          ),
        ],
        Padding(padding: const EdgeInsets.fromLTRB(16, 18, 16, 0), child: Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
              onPressed: editable ? _save : null,
              style: FilledButton.styleFrom(backgroundColor: SeqTokens.ink,
                  foregroundColor: SeqTokens.paper, padding: const EdgeInsets.symmetric(horizontal: 22)),
              child: const Text('保存配置')),
        )),
      ],
    );
  }

  static IconData _iconOf(AiMode m) => switch (m) {
        AiMode.off => Icons.do_not_disturb_on_outlined,
        AiMode.localRulesOnly => Icons.rule_rounded,
        AiMode.cloud => Icons.auto_awesome_outlined,
      };

  static String _titleOf(AiMode m) => switch (m) {
        AiMode.off => '关闭',
        AiMode.localRulesOnly => '仅本地规则',
        AiMode.cloud => '云端模型',
      };

  static String _subtitleOf(AiMode m) => switch (m) {
        AiMode.off => '完全手动，不做任何自动整理',
        AiMode.localRulesOnly => '时间、标签、优先级在本机解析，内容不出设备',
        AiMode.cloud => '手动确认后将当前已保存便签的原文发送给指定服务',
      };
}

/// 一种整理方式：图标、名称、说明，右上角单选。整张卡片可点。
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.compact = false,
  });

  final AiMode mode;
  final bool selected, enabled, compact;
  final String title, subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? SeqTokens.accentSoft : SeqTokens.raised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? SeqTokens.accent : const Color(0xFFECE6D8),
              width: selected ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: compact ? Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
            child: Row(children: [
              Icon(icon, size: 20, color: selected ? SeqTokens.accentInk : SeqTokens.inkSoft),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                Text(subtitle, style: const TextStyle(fontSize: 12.5, height: 1.45,
                    color: SeqTokens.inkMuted)),
              ])),
              Radio<AiMode>(value: mode, enabled: enabled),
            ]),
          ) : Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, size: 20, color: selected ? SeqTokens.accentInk : SeqTokens.inkSoft),
                const Spacer(),
                Radio<AiMode>(value: mode, enabled: enabled),
              ]),
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(subtitle, style: const TextStyle(fontSize: 12.5, height: 1.5,
                    color: SeqTokens.inkMuted)),
              ),
            ]),
          ),
        ),
      );
}
