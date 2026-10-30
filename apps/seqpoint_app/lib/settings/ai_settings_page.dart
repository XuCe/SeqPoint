import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

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
    return SettingsScaffold(
      title: 'AI 整理',
      footnote: '密钥只保存在这台设备的系统安全存储里，'
          '不会写进数据库、日志或导出文件。请求由本机直接发往模型服务，'
          '序点的服务器不经手。',
      children: [
        if (_loading || _saving) const LinearProgressIndicator(),
        if (_loadError) ListTile(title: const Text('无法读取AI设置'),
            trailing: TextButton(onPressed: _load, child: const Text('重试'))),
        SettingsGroup(
          label: '隐私档位',
          children: [
            RadioGroup<AiMode>(
              groupValue: _mode,
              onChanged: (v) {
                if (_loading || _loadError || _saving) return;
                setState(() => _mode = v ?? _mode);
              },
              child: Column(
                children: [
                  for (final mode in AiMode.values)
                    RadioListTile<AiMode>(
                      enabled: !_loading && !_loadError && !_saving,
                      value: mode,
                      title: Text(_titleOf(mode)),
                      subtitle: Text(_subtitleOf(mode)),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (_mode == AiMode.cloud)
          SettingsGroup(
            label: 'OpenAI兼容接口',
            children: [
              Padding(padding: const EdgeInsets.all(16), child: Column(children: [
                TextField(key: const ValueKey('ai-base-url'), controller: _base,
                    enabled: !_saving && !_loading && !_loadError, keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: '服务地址（HTTPS Base URL）')),
                const SizedBox(height: 16),
                TextField(key: const ValueKey('ai-model'), controller: _model,
                    enabled: !_saving && !_loading && !_loadError,
                    decoration: const InputDecoration(labelText: '模型名')),
                const SizedBox(height: 16),
                TextField(key: const ValueKey('ai-key'), controller: _key, obscureText: true,
                    enabled: !_saving && !_loading && !_loadError, autocorrect: false, enableSuggestions: false,
                    decoration: const InputDecoration(labelText: 'API Key', helperText: '留空保留该地址已保存的密钥')),
              ])),
              ListTile(title: Text(_hasKey ? '已保存服务的密钥：已配置' : '已保存服务的密钥：未配置'),
                  subtitle: Text(_store?.config.baseUrl ?? '尚未保存服务地址'),
                  trailing: TextButton(onPressed: _hasKey && !_saving && !_loading && !_loadError ? _clearKey : null,
                      child: const Text('清除已保存密钥'))),
            ],
          ),
        Padding(padding: const EdgeInsets.all(16), child: FilledButton(
            onPressed: _loading || _loadError || _saving ? null : _save, child: const Text('保存配置'))),
      ],
    );
  }

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
