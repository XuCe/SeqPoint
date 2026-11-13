import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../desktop/panel/closed_view.dart';
import '../settings/ai_settings_page.dart';
import '../settings/backup_settings_page.dart';
import '../settings/reminder_settings_page.dart';
import '../settings/sync_settings_page.dart';
import '../settings/update_settings_page.dart';
import '../shared/seq_widgets.dart';
import '../theme/seq_tokens.dart';
import 'tags_page.dart';

/// 我的：设备同步状态、已关闭与标签、各项设置。
class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final archivedCount = scope.notes.closed().length;
    final trashedCount = scope.notes.trashed().length;
    final peers = scope.sync?.verifiedPeers.length ?? 0;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _Header(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SeqCard(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(width: 9, height: 9, decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: peers > 0 ? SeqTokens.syncDot : SeqTokens.inkFaint)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(peers > 0 ? '已和 $peers 台设备配对' : '仅本机',
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600))),
                ]),
                const SizedBox(height: 6),
                Text(peers > 0
                    ? '修改经同步服务器自动交换，设备不必同时在线。'
                    : '数据只在这台设备上。连接同步服务器后，其他设备扫码即可加入。',
                    style: const TextStyle(fontSize: 13, height: 1.55, color: SeqTokens.inkMuted)),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: () => _push(context, const SyncSettingsPage()),
                    style: FilledButton.styleFrom(
                      backgroundColor: SeqTokens.chip,
                      foregroundColor: SeqTokens.ink,
                    ),
                    child: Text(peers > 0 ? '管理设备' : '添加设备'),
                  ),
                ),
              ]),
            ),
          ),
          const _GroupLabel('整理过的'),
          _Group(children: [
            _Row(
              icon: Icons.inventory_2_outlined,
              label: '已关闭',
              detail: '揭走 $archivedCount · 回收站 $trashedCount',
              onTap: () => _push(context, Scaffold(
                appBar: AppBar(title: const Text('已关闭')),
                body: const ClosedView(showHeader: false,
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 24)),
              )),
            ),
            _Row(
              icon: Icons.tag,
              label: '标签',
              detail: '${scope.tags.all().length} 个',
              onTap: () => _push(context, const TagsPage()),
            ),
          ]),
          const _GroupLabel('设置'),
          _Group(children: [
            _Row(
              icon: Icons.auto_awesome_outlined,
              label: 'AI 整理',
              onTap: () => _push(context, const AiSettingsPage()),
            ),
            _Row(
              icon: Icons.notifications_none,
              label: '提醒',
              detail: '勿扰 22:00–08:00',
              onTap: () => _push(context, const ReminderSettingsPage()),
            ),
            _Row(
              icon: Icons.devices_outlined,
              label: '设备与同步',
              detail: peers > 0 ? '$peers 台设备' : '仅本机',
              onTap: () => _push(context, const SyncSettingsPage()),
            ),
            _Row(
              icon: Icons.shield_outlined,
              label: '备份与恢复',
              onTap: () => _push(context, const BackupSettingsPage()),
            ),
            _Row(
              icon: Icons.info_outline,
              label: '关于与更新',
              onTap: () => _push(context, const UpdateSettingsPage()),
            ),
          ]),
          const Padding(
            padding: EdgeInsets.fromLTRB(22, 22, 22, 0),
            child: Text('没有账号，数据只在你的设备上。',
                style: TextStyle(fontSize: 12, color: SeqTokens.inkMuted)),
          ),
        ],
      ),
    );
  }

  Future<void> _push(BuildContext context, Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Text('我的',
          style: Theme.of(context).textTheme.displaySmall?.copyWith(fontSize: 28)),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 0),
        child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
            letterSpacing: 1, color: SeqTokens.inkMuted)),
      );
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: SeqTokens.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFECE6D8)),
        ),
        child: Column(children: children),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.onTap,
    this.detail,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: SeqTokens.chip, borderRadius: BorderRadius.circular(9)),
        child: Icon(icon, size: 18, color: SeqTokens.inkSoft),
      ),
      title: Text(label, style: const TextStyle(fontSize: 15)),
      subtitle: detail == null ? null : Text(detail!,
          style: const TextStyle(fontSize: 12.5, color: SeqTokens.inkMuted)),
      trailing: const Icon(Icons.chevron_right, size: 18, color: SeqTokens.inkFaint),
      onTap: onTap,
    );
  }
}
