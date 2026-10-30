import 'package:flutter/material.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

import 'ai_settings_page.dart';
import 'backup_settings_page.dart';
import 'hotkey_settings_page.dart';
import 'reminder_settings_page.dart';
import 'settings_scaffold.dart';
import 'sync_settings_page.dart';
import 'update_settings_page.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key, this.bindings});
  final Map<HotkeyAction, HotkeyBinding>? bindings;

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '设置',
    children: [
      SettingsGroup(
        children: [
          for (final (icon, title, page) in [
            (Icons.auto_awesome, 'AI 整理', AiSettingsPage()),
            (Icons.notifications_none, '提醒', ReminderSettingsPage()),
            (Icons.keyboard, '快捷键', HotkeySettingsPage(bindings: bindings)),
            (Icons.sync, '同步', SyncSettingsPage()),
            (Icons.backup_outlined, '备份与导出', BackupSettingsPage()),
            (Icons.system_update_alt, '应用更新', const UpdateSettingsPage()),
          ])
            ListTile(
              leading: Icon(icon),
              title: Text(title),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => page)),
            ),
        ],
      ),
    ],
  );
}
