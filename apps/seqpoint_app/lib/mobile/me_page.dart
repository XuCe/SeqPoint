import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../desktop/panel/archive_view.dart';
import '../desktop/panel/trash_view.dart';
import '../settings/ai_settings_page.dart';
import '../settings/backup_settings_page.dart';
import '../settings/reminder_settings_page.dart';
import '../settings/sync_settings_page.dart';
import '../settings/update_settings_page.dart';
import '../theme/seq_tokens.dart';
import 'tags_page.dart';

/// 我的：标签、提醒策略、AI 设置、同步、备份、回收站。
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

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const _Header(),
          _Group(children: [
            _Row(
              icon: Icons.auto_awesome,
              label: 'AI 整理',
              detail: '未配置',
              onTap: () => _push(context, const AiSettingsPage()),
            ),
            _Row(
              icon: Icons.notifications_none,
              label: '提醒',
              detail: '勿扰 22:00–08:00',
              onTap: () => _push(context, const ReminderSettingsPage()),
            ),
          ]),
          _Group(children: [
            _Row(
              icon: Icons.sync,
              label: '同步',
              detail: '仅本机',
              onTap: () => _push(context, const SyncSettingsPage()),
            ),
            _Row(
              icon: Icons.backup_outlined,
              label: '备份与导出',
              onTap: () => _push(context, const BackupSettingsPage()),
            ),
            _Row(
              icon: Icons.system_update_alt,
              label: '应用更新',
              onTap: () => _push(context, const UpdateSettingsPage()),
            ),
          ]),
          _Group(children: [
            _Row(
              icon: Icons.sell_outlined,
              label: '标签',
              detail: '${scope.tags.all().length} 个',
              onTap: () => _push(context, const TagsPage()),
            ),
            _Row(
              icon: Icons.inventory_2_outlined,
              label: '已归档',
              detail: '$archivedCount 张',
              onTap: () => _push(context, Scaffold(
                appBar: AppBar(title: const Text('已归档')),
                body: const ArchiveView(),
              )),
            ),
            _Row(
              icon: Icons.delete_outline,
              label: '回收站',
              detail: trashedCount == 0 ? null : '$trashedCount 张',
              onTap: () => _push(context, Scaffold(
                appBar: AppBar(title: const Text('回收站')),
                body: const TrashView(),
              )),
            ),
          ]),
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
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          Text('我的',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontSize: 26,
                  )),
          const Spacer(),
          const Text('无需注册',
              style: TextStyle(fontSize: 12, color: SeqTokens.inkMuted)),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: SeqTokens.line),
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
      leading: Icon(icon, size: 20, color: SeqTokens.inkMuted),
      title: Text(label, style: const TextStyle(fontSize: 15)),
      subtitle: detail == null ? null : Text(detail!,
          style: const TextStyle(fontSize: 13, color: SeqTokens.inkMuted)),
      trailing: const Icon(Icons.chevron_right, size: 18, color: SeqTokens.inkMuted),
      onTap: onTap,
    );
  }
}
