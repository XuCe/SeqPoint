import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../theme/seq_tokens.dart';
import 'settings_scaffold.dart';

/// 提醒设置：工作时段、勿扰时段、晚间汇总、每日上限、P0 穿透。
class ReminderSettingsPage extends StatelessWidget {
  const ReminderSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    const policy = ReminderPolicy();
    final scope = AppScope.of(context);
    final reminders = scope.reminders;
    return SettingsScaffold(
      title: '提醒',
      footnote: '你亲手设定的提醒时间是强约束，'
          '智能策略不会延迟它，也不计入每日上限。',
      children: [
        if (reminders == null)
          SettingsCard(
            icon: Icons.notifications_off_outlined,
            title: scope.notificationError ?? '系统通知未连接',
            subtitle: '请重新启动应用后再检查。',
          )
        else
          AnimatedBuilder(
            animation: reminders,
            builder: (_, _) {
              final ok = reminders.checked && reminders.error == null &&
                  reminders.deferredCount == 0;
              return SettingsCard(
                icon: ok ? Icons.notifications_active_outlined : Icons.notifications_none,
                highlighted: ok,
                title: !reminders.checked ? '正在检查系统通知'
                  : reminders.error ?? (reminders.deferredCount > 0
                    ? '部分提醒等待安排' : '期限提醒已启用'),
                subtitle: reminders.deferredCount > 0
                  ? '系统最多保留${reminders.capacity}条待发通知，'
                    '另有${reminders.deferredCount}条等待安排。'
                    '请保持应用运行或定期打开，以补齐后续提醒。'
                  : '创建或改期后更新；完成或删除后撤销。',
                trailing: TextButton(
                  onPressed: () async { await reminders.reconcile(); },
                  child: Text(!reminders.checked ? '检查'
                    : reminders.error == null ? '重新检查' : '重试'),
                ),
              );
            },
          ),
        SettingsGroup(
          label: '一天的节奏',
          children: [
            _Row(icon: Icons.work_outline, title: '工作时段',
                value: _range(policy.workStart, policy.workEnd)),
            _Row(icon: Icons.bedtime_outlined, title: '勿扰时段',
                subtitle: '这段时间不发提醒',
                value: _range(policy.quietStart, policy.quietEnd)),
            _Row(icon: Icons.nights_stay_outlined, title: '晚间汇总',
                subtitle: '把今天没做完的事汇总提醒一次',
                value: _time(policy.digestAt)),
          ],
        ),
        SettingsGroup(
          label: '频率',
          children: [
            _Row(icon: Icons.repeat_rounded, title: '智能提醒每日上限',
                subtitle: '同一件事最多提醒这么多次',
                value: '${policy.maxSmartPerItemPerDay} 次'),
            const SwitchListTile(
              value: false,
              onChanged: null,
              secondary: Icon(Icons.priority_high_rounded, size: 20),
              title: Text('紧急事项穿透勿扰'),
              subtitle: Text('只对标记为紧急的事项生效'),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(26, 14, 24, 0),
          child: Text('当前启用精确与相对期限提醒；上面的智能策略为默认值，'
              '智能追加与晚间汇总后续接入。',
              style: TextStyle(fontSize: 12.5, height: 1.6, color: SeqTokens.inkMuted)),
        ),
      ],
    );
  }

  static String _time(TimeOfDayValue t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  static String _range(TimeOfDayValue a, TimeOfDayValue b) =>
      '${_time(a)}–${_time(b)}';
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.value, this.subtitle});

  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, size: 20, color: SeqTokens.inkSoft),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: SeqTokens.chip, borderRadius: BorderRadius.circular(8)),
          child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()])),
        ),
      );
}
