import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../updates/github_release.dart';
import '../updates/full_update_installer.dart';
import 'settings_scaffold.dart';

class FullUpdateSection extends StatefulWidget {
  const FullUpdateSection({super.key, this.loadRelease, this.installer});
  final Future<FullRelease> Function()? loadRelease;
  final FullUpdateInstaller? installer;
  @override
  State<FullUpdateSection> createState() => _FullUpdateSectionState();
}

class _FullUpdateSectionState extends State<FullUpdateSection> {
  late final _installer = widget.installer ?? fullUpdateInstaller;
  String? _installed;
  String _message = '检查是否有新的完整版本';
  bool _checking = false;
  FullRelease? _release;
  @override
  void initState() {
    super.initState();
    _installer.addListener(_refresh);
    unawaited(
      _readVersion().catchError((Object _) {
        if (mounted) setState(() => _message = '无法读取版本，请重试检查');
      }),
    );
  }

  Future<void> _readVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _installed = '${info.version}+${info.buildNumber}');
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _installer.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _release = null;
      _message = '正在检查完整版本…';
    });
    try {
      await _readVersion();
      final release = await (widget.loadRelease ?? fetchLatestRelease)();
      if (!mounted) return;
      final newer = release.isNewerThan(_installed!);
      _release = newer ? release : null;
      _message = newer ? '发现新版本 ${release.version}' : '当前已是最新完整版本';
    } catch (_) {
      if (mounted) _message = '检查失败，请检查网络后重试';
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _install() async {
    try {
      await _installer.install(_release!);
    } catch (_) {
      if (mounted) setState(() => _message = '无法启动安装，请先保存并关闭便签后重试');
    }
  }

  @override
  Widget build(BuildContext context) => SettingsGroup(
    label: '完整版本更新',
    children: [
      ListTile(
        leading: const Icon(Icons.download_for_offline_outlined),
        title: Text(_installed == null ? '正在读取当前版本…' : '当前版本 $_installed'),
        subtitle: Semantics(liveRegion: true, child: Text(_message)),
      ),
      if (_release != null && _release!.downloadUrl == null)
        const ListTile(
          title: Text('此平台暂未提供可安装版本'),
          subtitle: Text('iOS 未签名归档不能直接安装。'),
        ),
      if (_release != null && _release!.notes.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _release!.notes,
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (_installer.message.isNotEmpty)
        ListTile(
          title: Semantics(liveRegion: true, child: Text(_installer.message)),
        ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _checking || _installer.busy ? null : _check,
              child: Text(_checking ? '正在检查…' : '检查完整版本'),
            ),
            if (_release?.downloadUrl != null)
              FilledButton(
                onPressed: _checking || _installer.busy ? null : _install,
                child: const Text('下载并安装'),
              ),
            if (_installer.downloading)
              TextButton(
                onPressed: () async {
                  try {
                    await _installer.cancelDownload();
                  } catch (_) {
                    if (mounted) setState(() => _message = '取消失败，请稍后重试');
                  }
                },
                child: const Text('取消下载'),
              ),
          ],
        ),
      ),
      if (_checking || _installer.busy)
        LinearProgressIndicator(value: _checking ? null : _installer.progress),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Text('在应用内下载并校验安装包。安装时可能需要系统确认并退出应用，请先保存未完成的编辑。'),
      ),
    ],
  );
}
