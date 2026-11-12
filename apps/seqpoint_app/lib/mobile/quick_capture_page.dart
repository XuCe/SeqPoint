import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:live_markdown_editor/live_markdown_editor.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../features/voice/voice_input_button.dart';
import '../shared/note_markdown_field.dart';
import '../shared/note_title_field.dart';
import '../shared/note_format_menu.dart';
import '../theme/seq_tokens.dart';

/// 快速记录页：打开即聚焦输入框，3 秒内可保存。
///
/// 零属性保存——不要求标题、标签或时间。这是产品的第一原则。
class QuickCapturePage extends StatefulWidget {
  const QuickCapturePage({super.key, this.initialText = '', this.note});
  final String initialText;
  final Note? note;

  @override
  State<QuickCapturePage> createState() => _QuickCapturePageState();
}

class _QuickCapturePageState extends State<QuickCapturePage> {
  final _controller = MarkdownEditorController();
  final _title = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.note?.rawContent ?? widget.initialText;
    _title.text = widget.note?.title ?? '';
  }

  @override
  void dispose() {
    _controller.dispose();
    _title.dispose();
    super.dispose();
  }

  void _save({String? content, int? line, DateTime? due}) {
    if (AppScope.of(context).restoring) return;
    final text = content ?? _controller.text;
    final note = widget.note;
    final title = _title.text.trim() == (note?.title ?? '') ? null : _title.text.trim();
    if (text.trim().isEmpty && _title.text.trim().isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    try {
      final service = AppScope.of(context).noteService;
      if (line != null) {
        service.saveWithItem(text, lineIndex: line, due: due, noteId: note?.id,
            title: title, expectedContent: note?.rawContent, expectedTitle: note?.title);
      } else if (note != null) {
        service.editContent(note.id, text, title: title,
            expectedContent: note.rawContent, expectedTitle: note.title);
      } else {
        service.capture(text, title: title);
      }
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error is StateError && (line != null || note != null)
            ? error.message : '保存失败，请重试。输入的内容仍在。')),
      );
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
      },
      child: Scaffold(
      backgroundColor: SeqTokens.noteYellow,
      appBar: AppBar(
        backgroundColor: SeqTokens.noteYellow,
        foregroundColor: SeqTokens.noteInk,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
          tooltip: '放弃',
        ),
        title: Text(widget.note == null ? '记一笔' : '编辑便签'),
        actions: [
          NoteFormatMenu(controller: _controller, onPromote: (line) => _save(line: line)),
          VoiceInputButton(controller: _controller, enabled: !AppScope.of(context).restoring),
          TextButton(
            onPressed: _save,
            style: TextButton.styleFrom(foregroundColor: SeqTokens.accentInk),
            child: const Text('保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(children: [
          NoteTitleField(controller: _title),
          Expanded(child: NoteMarkdownField(controller: _controller,
              onSaveItem: (text, line, due) => _save(content: text, line: line, due: due))),
        ]),
      ),
      ),
    );
  }
}
