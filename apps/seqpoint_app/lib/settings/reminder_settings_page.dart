import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
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
        SettingsGroup(
          label: '系统通知',
          children: [
            if (reminders == null)
              ListTile(title: Text(scope.notificationError ?? '系统通知未连接'),
                subtitle: const Text('请重新启动应用后再检查。'))
            else
              AnimatedBuilder(
                animation: reminders,
                builder: (_, _) => ListTile(
                  title: Text(!reminders.checked ? '正在检查系统通知'
                    : reminders.error ?? (reminders.deferredCount > 0
                      ? '部分提醒等待安排' : '期限提醒已启用')),
                  subtitle: Text(reminders.deferredCount > 0
                    ? '系统最多保留${reminders.capacity}条待发通知，'
                      '另有${reminders.deferredCount}条等待安排。'
                      '请保持应用运行或定期打开，以补齐后续提醒。'
                    : '创建或改期后更新；完成或删除后撤销。'),
                  trailing: TextButton(
                    onPressed: () async { await reminders.reconcile(); },
                    child: Text(!reminders.checked ? '检查'
                      : reminders.error == null ? '重新检查' : '重试'),
                  ),
                ),
              ),
            const ListTile(subtitle: Text('当前启用精确与相对期限提醒；'
              '下方智能策略为默认值，智能追加与晚间汇总后续接入。')),
          ],
        ),
        SettingsGroup(
          label: '时段',
          children: [
            ListTile(
              title: const Text('工作时段'),
              trailing: Text(_range(policy.workStart, policy.workEnd)),
            ),
            ListTile(
              title: const Text('勿扰时段'),
              trailing: Text(_range(policy.quietStart, policy.quietEnd)),
            ),
            ListTile(
              title: const Text('晚间汇总'),
              trailing: Text(_time(policy.digestAt)),
            ),
          ],
        ),
        SettingsGroup(
          label: '频率',
          children: [
            ListTile(
              title: const Text('智能提醒每日上限'),
              subtitle: const Text('同一件事最多提醒这么多次'),
              trailing: Text('${policy.maxSmartPerItemPerDay} 次'),
            ),
            const SwitchListTile(
              value: false,
              onChanged: null,
              title: Text('紧急事项穿透勿扰'),
              subtitle: Text('只对标记为紧急的事项生效'),
            ),
          ],
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
