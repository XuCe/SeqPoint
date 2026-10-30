import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class MeetingTranscriptPage extends StatefulWidget {
  const MeetingTranscriptPage({
    super.key,
    required this.database,
    required this.noteId,
    required this.noteService,
  });
  final SeqDatabase database;
  final String noteId;
  final NoteService noteService;
  @override
  State<MeetingTranscriptPage> createState() => _MeetingTranscriptPageState();
}

class _MeetingTranscriptPageState extends State<MeetingTranscriptPage> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = MeetingTranscriptService(
        db: widget.database,
        notes: widget.noteService,
      );
      final draft = service.prepare(widget.noteId, _text.text);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: const Text('确认追加到便签'),
          content: SelectableText(draft.text),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('追加原文'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      service.apply(draft);
      Navigator.of(context).pop(true);
    } on ArgumentError {
      if (mounted) setState(() => _error = '请输入 1 至 50000 字转写文字');
    } catch (_) {
      if (mounted) setState(() => _error = '导入失败，便签已变化或不可用，请重新预览');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('导入会议转写'),
      actions: [
        TextButton(
          onPressed: _busy ? null : _preview,
          child: const Text('预览导入'),
        ),
      ],
    ),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Text(
            '粘贴已有转写文字，确认后追加到当前便签，随后可使用整理提取事项。'
            '这里不会上传录音或自动转写；导入文字仍需校对。',
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _text,
              readOnly: _busy,
              expands: true,
              maxLines: null,
              maxLength: 50000,
              maxLengthEnforcement: MaxLengthEnforcement.none,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                labelText: '转写文字',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
