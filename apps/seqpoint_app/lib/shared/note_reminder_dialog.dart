import 'package:flutter/material.dart';

import 'note_reminder.dart';

Future<({String title, DateTime due})?> showNoteReminder(BuildContext context, NoteReminder draft) {
  var title = draft.title;
  var due = draft.due.toLocal();
  return showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, refresh) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        title: const Text('设提醒'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (draft.command)
              TextFormField(
                initialValue: title,
                autofocus: title.isEmpty,
                decoration: const InputDecoration(labelText: '事项'),
                onChanged: (text) => refresh(() => title = text),
              )
            else
              Align(alignment: Alignment.centerLeft, child: Text(title)),
            Wrap(
              children: [
                TextButton(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      fieldHintText: '年/月/日',
                      initialDate: due,
                      firstDate: DateTime(1),
                      lastDate: DateTime(9999),
                      initialEntryMode: MediaQuery.sizeOf(context).height < 500
                          ? DatePickerEntryMode.inputOnly
                          : DatePickerEntryMode.calendar,
                    );
                    if (date != null && context.mounted) {
                      refresh(
                        () => due = DateTime(date.year, date.month, date.day, due.hour, due.minute),
                      );
                    }
                  },
                  child: Text(due.toIso8601String().substring(0, 10)),
                ),
                TextButton(
                  onPressed: () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(due),
                      initialEntryMode: MediaQuery.sizeOf(context).height < 500
                          ? TimePickerEntryMode.inputOnly
                          : TimePickerEntryMode.dial,
                    );
                    if (time != null && context.mounted) {
                      refresh(
                        () => due = DateTime(due.year, due.month, due.day, time.hour, time.minute),
                      );
                    }
                  },
                  child: Text(due.toIso8601String().substring(11, 16)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: title.trim().isEmpty
                ? null
                : () => Navigator.pop(context, (title: title.trim(), due: due)),
            child: const Text('保存并设提醒'),
          ),
        ],
      ),
    ),
  );
}
