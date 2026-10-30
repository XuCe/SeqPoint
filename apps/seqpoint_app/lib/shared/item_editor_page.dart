import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../features/attachments/attachment_panel.dart';

class ItemEditorPage extends StatefulWidget {
  const ItemEditorPage({super.key, required this.itemId});
  final String itemId;
  static Future<bool?> open(BuildContext context, String id) => Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute(builder: (_) => ItemEditorPage(itemId: id)));
  @override
  State<ItemEditorPage> createState() => _ItemEditorPageState();
}

class _ItemEditorPageState extends State<ItemEditorPage> {
  final _title = TextEditingController();
  final _form = GlobalKey<FormState>();
  DateTime? _due;
  bool _dueEdited = false;
  Priority _priority = Priority.p4;
  late Item _original;
  late String _committedTitle;
  bool _loaded = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final item = AppScope.of(context).items.byId(widget.itemId)!;
    _original = item;
    _title.text = item.title;
    _due = item.dueAt?.toLocal();
    _priority = item.priority;
    _committedTitle = item.title;
    _loaded = true;
    _title.addListener(_inferDue);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _inferDue() {
    final value = _title.value;
    if (_dueEdited || !value.composing.isCollapsed ||
        value.text == _committedTitle) {
      return;
    }
    _committedTitle = value.text;
    const parser = TimeParser();
    final now = DateTime.now();
    final parsed = parser.parse(value.text, now);
    final keepOriginal = _original.dueAt != null &&
        parsed?.matchedText == parser.parse(_original.title, now)?.matchedText;
    setState(() => _due = keepOriginal ? _original.dueAt!.toLocal()
        : parsed?.dateTime ?? _original.dueAt?.toLocal());
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialEntryMode: MediaQuery.sizeOf(context).height < 500
          ? DatePickerEntryMode.inputOnly
          : DatePickerEntryMode.calendar,
      initialDate: _due ?? DateTime.now(),
      firstDate: DateTime(1),
      lastDate: DateTime(9999),
    );
    if (date == null || !mounted) return;
    _dueEdited = true;
    setState(
      () => _due = DateTime(
        date.year,
        date.month,
        date.day,
        _due?.hour ?? 23,
        _due?.minute ?? 59,
      ),
    );
  }

  Future<void> _pickTime() async {
    final due = _due!;
    final time = await showTimePicker(
      context: context,
      initialEntryMode: MediaQuery.sizeOf(context).height < 500
          ? TimePickerEntryMode.inputOnly
          : TimePickerEntryMode.dial,
      initialTime: TimeOfDay.fromDateTime(due),
    );
    if (time == null || !mounted) return;
    _dueEdited = true;
    setState(
      () =>
          _due = DateTime(due.year, due.month, due.day, time.hour, time.minute),
    );
  }

  void _save() {
    if (!_title.value.composing.isCollapsed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请先确认输入法候选词后再保存')));
      return;
    }
    if (!(_form.currentState?.validate() ?? false)) return;
    try {
      final items = AppScope.of(context).items;
      final saved = items.saveEdits(_original,
        title: _title.text.trim(), priority: _priority, dueAt: _due);
      if (!saved) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('事项已在其他窗口修改，请重新打开后核对')));
        return;
      }
      Navigator.of(context).pop(true);
    } catch (_) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('编辑事项'),
      actions: [TextButton(onPressed: _save, child: const Text('保存'))],
    ),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (AppScope.of(context).database case final database?)
            AttachmentPanel(database: database, itemId: widget.itemId,
                enabled: !AppScope.of(context).restoring),
          TextFormField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: '事项标题',
              hintText: '例如：下周一提交报告、今晚八点开会',
            ),
            minLines: 1,
            maxLines: 3,
            validator: (value) =>
                value == null || value.trim().isEmpty ? '请输入事项标题' : null,
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_today_outlined),
            title: const Text('截止日期'),
            subtitle: Text(
              _due == null
                  ? '未设置'
                  : '${_due!.year}/${_due!.month}/${_due!.day}',
            ),
            onTap: _pickDate,
          ),
          if (_due != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.access_time),
              title: const Text('截止时间'),
              subtitle: Text(TimeOfDay.fromDateTime(_due!).format(context)),
              onTap: _pickTime,
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () {
                  final now = DateTime.now();
                  setState(() {
                    _dueEdited = true;
                    _due = DateTime(now.year, now.month, now.day, 23, 59);
                  });
                },
                child: const Text('今天到期'),
              ),
              if (_due != null)
                TextButton(
                  onPressed: () => setState(() {
                    _dueEdited = true;
                    _due = null;
                  }),
                  child: const Text('清除截止时间'),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('重要'),
            secondary: const Icon(Icons.star_outline),
            value: _priority == Priority.p0 || _priority == Priority.p1,
            onChanged: (value) =>
                setState(() => _priority = value ? Priority.p1 : Priority.p4),
          ),
        ],
      ),
    ),
  );
}
