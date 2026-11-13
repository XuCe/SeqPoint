import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

import '../theme/seq_tokens.dart';

import 'settings_scaffold.dart';
import 'full_update_section.dart';

class UpdateSettingsPage extends StatefulWidget {
  const UpdateSettingsPage({super.key, this.updater});
  final ShorebirdUpdater? updater;

  @override
  State<UpdateSettingsPage> createState() => _UpdateSettingsPageState();
}

class _UpdateSettingsPageState extends State<UpdateSettingsPage> {
  late final _updater = widget.updater ?? ShorebirdUpdater();
  String _message = '检查是否有可用更新';
  bool _busy = false;
  UpdateStatus? _status;
  String? _version;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    }, onError: (Object _) {});
  }

  Future<void> _check() async {
    if (_busy || !_updater.isAvailable) return;
    final download = _status == UpdateStatus.outdated;
    setState(() {
      _busy = true;
      _message = download ? '正在下载更新…' : '正在检查更新…';
    });
    try {
      if (download) await _updater.update();
      final status = await _updater.checkForUpdate();
      if (!mounted) return;
      _status = status;
      _message = switch (status) {
        UpdateStatus.upToDate => '当前已是最新补丁',
        UpdateStatus.outdated => download ? '更新尚未就绪，请稍后重试' : '发现可用更新',
        UpdateStatus.restartRequired => '更新已就绪，下次启动生效',
        UpdateStatus.unavailable => '此安装包暂不支持热更新',
      };
    } on Exception {
      if (!mounted) return;
      _message = download ? '下载失败，请检查网络后重试' : '检查失败，请检查网络后重试';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '关于与更新',
    footnote:
        '热更新补丁无需重新安装；完整版本通过系统安装器更新。'
        '补丁将在下次启动时生效。桌面端请从托盘退出后重新打开，关闭窗口不会退出应用。',
    children: [
      SettingsGroup(children: [
        Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/brand/logo.png', width: 52, height: 52,
                  excludeFromSemantics: true),
            ),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('序点', style: TextStyle(fontFamily: SeqFonts.serif.first,
                  fontFamilyFallback: SeqFonts.serif, fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(_version == null ? '随手记，按时序办完' : '版本 $_version · 随手记，按时序办完',
                  style: const TextStyle(fontSize: 13, color: SeqTokens.inkMuted)),
            ])),
          ]),
        ),
      ]),
      SettingsGroup(
        label: '小更新（不用重新安装）',
        children: [
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: Semantics(
              liveRegion: true,
              child: Text(_updater.isAvailable ? _message : '热更新不可用'),
            ),
            subtitle: Text(
              _updater.isAvailable
                  ? '启动时也会在后台自动检查更新'
                  : '此安装包未启用热更新，请安装支持更新的正式版本',
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: _updater.isAvailable && !_busy ? _check : null,
              child: Text(
                _busy
                    ? '请稍候…'
                    : _status == UpdateStatus.outdated
                    ? '下载更新'
                    : '检查更新',
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
      const FullUpdateSection(),
    ],
  );
}
