import 'package:flutter/material.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

import '../theme/seq_tokens.dart';
import 'ai_settings_page.dart';
import 'backup_settings_page.dart';
import 'hotkey_settings_page.dart';
import 'reminder_settings_page.dart';
import 'sync_settings_page.dart';
import 'update_settings_page.dart';

/// 设置分类。顺序即左栏顺序。
enum SettingsSection { sync, ai, reminders, backup, hotkeys, about }

extension SettingsSectionInfo on SettingsSection {
  String get label => switch (this) {
        SettingsSection.sync => '设备与同步',
        SettingsSection.ai => 'AI 整理',
        SettingsSection.reminders => '提醒',
        SettingsSection.backup => '备份与恢复',
        SettingsSection.hotkeys => '快捷键',
        SettingsSection.about => '关于与更新',
      };

  IconData get icon => switch (this) {
        SettingsSection.sync => Icons.devices_outlined,
        SettingsSection.ai => Icons.auto_awesome_outlined,
        SettingsSection.reminders => Icons.notifications_none,
        SettingsSection.backup => Icons.shield_outlined,
        SettingsSection.hotkeys => Icons.keyboard_outlined,
        SettingsSection.about => Icons.info_outline,
      };
}

/// 桌面设置：左栏分类、右栏内容，不再一层层点进去。
class SettingsView extends StatefulWidget {
  const SettingsView({super.key, this.bindings});
  final Map<HotkeyAction, HotkeyBinding>? bindings;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  SettingsSection _section = SettingsSection.sync;

  Widget _page(SettingsSection section) => switch (section) {
        SettingsSection.sync => const SyncSettingsPage(),
        SettingsSection.ai => const AiSettingsPage(),
        SettingsSection.reminders => const ReminderSettingsPage(),
        SettingsSection.backup => const BackupSettingsPage(),
        SettingsSection.hotkeys => HotkeySettingsPage(bindings: widget.bindings),
        SettingsSection.about => const UpdateSettingsPage(),
      };

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 220,
            color: SeqTokens.paper,
            padding: const EdgeInsets.fromLTRB(12, 26, 12, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                child: Text('设置', style: Theme.of(context).textTheme.displaySmall
                    ?.copyWith(fontSize: 24)),
              ),
              for (final section in SettingsSection.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Material(
                    color: _section == section ? SeqTokens.chip : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(9),
                      onTap: () => setState(() => _section = section),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(children: [
                          Icon(section.icon, size: 18, color: _section == section
                              ? SeqTokens.ink : SeqTokens.inkMuted),
                          const SizedBox(width: 10),
                          Text(section.label, style: TextStyle(fontSize: 14,
                              color: _section == section ? SeqTokens.ink : SeqTokens.inkSoft,
                              fontWeight: _section == section ? FontWeight.w600 : FontWeight.w500)),
                        ]),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: Text('没有账号，数据只在你的设备上。',
                    style: TextStyle(fontSize: 12, height: 1.6, color: SeqTokens.inkMuted)),
              ),
            ]),
          ),
          const VerticalDivider(width: 1, color: SeqTokens.line),
          Expanded(
            child: KeyedSubtree(key: ValueKey(_section), child: _page(_section)),
          ),
        ],
      );
}
