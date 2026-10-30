import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../features/attachments/attachment_panel.dart';
import '../../features/meetings/meeting_panel.dart';
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
      child: LayoutBuilder(builder: (context, constraints) => Scaffold(
        backgroundColor: SeqTokens.noteYellow,
        bottomNavigationBar: widget.noteId == null || database == null ? null
            : SafeArea(child: ConstrainedBox(constraints: BoxConstraints(
                maxHeight: math.min(240, constraints.maxHeight / 3)),
                child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AttachmentPanel(database: database, noteId: widget.noteId, enabled: !scope.restoring),
                  MeetingPanel(database: database, noteId: widget.noteId!, noteService: scope.noteService,
                    enabled: !scope.restoring,
                    beforeOpen: () { scope.noteService.editContent(widget.noteId!, _controller.text); },
                    onChanged: () { if (mounted) { setState(() {
                      _controller.text = scope.notes.byId(widget.noteId!)?.rawContent ?? _controller.text;
                    }); } }),
                ])))),
        appBar: AppBar(
          title: Text(widget.noteId == null ? '新建便签' : '编辑便签'),
          actions: [
            VoiceInputButton(controller: _controller, enabled: !scope.restoring && !_saving),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (_, value, child) => TextButton(
                onPressed: _saving || value.text.trim().isEmpty ? null : _save,
                child: child!,
              ),
              child: const Text('保存'),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: TextField(
            controller: _controller,
            autofocus: true,
            expands: true,
            maxLines: null,
            style: const TextStyle(color: SeqTokens.noteInk, height: 1.6),
            decoration: const InputDecoration(
              labelText: '便签内容',
              hintText: '想到什么就写什么，一行一件事',
              border: InputBorder.none,
            ),
          ),
        ),
      )),
    );
  }
}
