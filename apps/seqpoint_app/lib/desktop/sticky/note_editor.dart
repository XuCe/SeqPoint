import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/app_scope.dart';
import 'note_media_bar.dart';
import '../../features/voice/voice_input_button.dart';
import '../../theme/seq_tokens.dart';

/// 便签正文编辑器。
///
/// 核心交互：
/// - 自由文本，零属性即可保存；
/// - 每行 hover 时行首出现 ○，点击把该行转为事项；
/// - 已转事项的行渲染为 checkbox 行，勾选后划线；
/// - 原始文本永不因整理而丢失——整理只是把行"升级"并附加属性。
class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key, this.noteId, this.initialText = ''});

  final String? noteId;
  final String initialText;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  final _controller = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final id = widget.noteId;
    if (id != null) {
      _controller.text = AppScope.of(context).notes.byId(id)?.rawContent ?? '';
    } else {
      _controller.text = widget.initialText;
    }
    _loaded = true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text;
    if (_saving || text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final service = AppScope.of(context).noteService;
      final id = widget.noteId;
      final note = id == null
          ? service.capture(text)
          : service.editContent(id, text);
      Navigator.of(context).pop(note.id);
    } catch (_) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存失败，请重试。输入的内容仍在。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final database = scope.database;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFFFF7D1),
        bottomNavigationBar: widget.noteId == null || database == null ? null
            : SafeArea(child: NoteMediaBar(noteId: widget.noteId!,
                beforeMeeting: () => scope.noteService.editContent(widget.noteId!, _controller.text),
                onChanged: () {
                  if (mounted) _controller.text = scope.notes.byId(widget.noteId!)?.rawContent ?? _controller.text;
                })),
        appBar: AppBar(
          toolbarHeight: 40,
          backgroundColor: const Color(0xFFFFF0AD),
          foregroundColor: SeqTokens.noteInk,
          title: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
            child: SizedBox(width: double.infinity, height: 40,
              child: Align(alignment: Alignment.centerLeft, child: Text(
                widget.noteId == null ? '新建便签' : '编辑便签',
                style: const TextStyle(fontSize: 14)))),
          ),
          actions: [
            VoiceInputButton(controller: _controller, enabled: !scope.restoring && !_saving),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (_, value, child) => TextButton(
                style: TextButton.styleFrom(foregroundColor: SeqTokens.noteInk),
                onPressed: _saving || value.text.trim().isEmpty ? null : _save,
                child: child!,
              ),
              child: const Text('保存'),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: TextField(
            controller: _controller,
            autofocus: true,
            expands: true,
            maxLines: null,
            style: const TextStyle(color: SeqTokens.noteInk, height: 1.6),
            decoration: const InputDecoration(
              hintText: '想到什么就写什么，一行一件事',
              border: InputBorder.none,
            ),
          ),
        ),
      ),
    );
  }
}
