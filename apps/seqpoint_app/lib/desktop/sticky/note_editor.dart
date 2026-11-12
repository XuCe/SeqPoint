import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:live_markdown_editor/live_markdown_editor.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/app_scope.dart';
import '../../platform/note_window_geometry.dart';
import '../../shared/note_markdown_field.dart';
import '../../shared/note_title_field.dart';
import '../../shared/note_format_menu.dart';
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
  final _controller = MarkdownEditorController();
  final _title = TextEditingController();
  String? _openedTitle;
  String? get _changedTitle => _title.text.trim() == (_openedTitle ?? '') ? null : _title.text.trim();
  NoteWindowGeometry? _draftGeometry;
  bool _loaded = false;
  String? _openedContent;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final id = widget.noteId;
    if (id != null) {
      final note = AppScope.of(context).notes.byId(id);
      _title.text = (_openedTitle = note?.title) ?? '';
      _controller.text = note?.rawContent ?? '';
      _openedContent = _controller.text;
    } else {
      _controller.text = widget.initialText;
      final windows = AppScope.of(context).windows;
      if (windows != null) {
        final geometry = _draftGeometry = NoteWindowGeometry(windows);
        windowManager.addListener(geometry);
      }
    }
    _loaded = true;
  }

  @override
  void dispose() {
    final geometry = _draftGeometry;
    if (geometry != null) windowManager.removeListener(geometry);
    _controller.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _save({String? content, int? line, DateTime? due}) async {
    if (AppScope.of(context).restoring) return;
    final text = content ?? _controller.text;
    if (_saving || (text.trim().isEmpty && _title.text.trim().isEmpty)) return;
    setState(() => _saving = true);
    try {
      final service = AppScope.of(context).noteService;
      final id = widget.noteId;
      final note = line != null
          ? service.saveWithItem(text, noteId: id, lineIndex: line, due: due, expectedContent: _openedContent,
              title: _changedTitle, expectedTitle: _openedTitle)
          : id == null
          ? service.capture(text, title: _changedTitle)
          : service.editContent(id, text, expectedContent: _openedContent, title: _changedTitle,
              expectedTitle: _openedTitle);
      final geometry = _draftGeometry;
      if (geometry != null && geometry.draftResized) {
        await geometry.saveCurrentFrame(note.id);
        if (!mounted) return;
      }
      Navigator.of(context).pop(note.id);
    } catch (error) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error is StateError
              ? error.message : '保存失败，请重试。输入的内容仍在。')));
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
                beforeMeeting: () {
                  final saved = scope.noteService.editContent(widget.noteId!, _controller.text,
                      expectedContent: _openedContent, title: _changedTitle, expectedTitle: _openedTitle);
                  _openedContent = saved.rawContent;
                  _title.text = (_openedTitle = saved.title) ?? '';
                },
                onChanged: () {
                  if (mounted) {
                    _openedContent = scope.notes.byId(widget.noteId!)?.rawContent ?? _controller.text;
                    _controller.text = _openedContent!;
                  }
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
            NoteFormatMenu(controller: _controller, onPromote: (line) => _save(line: line)),
            VoiceInputButton(controller: _controller, enabled: !scope.restoring && !_saving),
            ListenableBuilder(
              listenable: Listenable.merge([_controller, _title]),
              builder: (_, child) => TextButton(
                style: TextButton.styleFrom(foregroundColor: SeqTokens.noteInk),
                onPressed: _saving || (_controller.text.trim().isEmpty && _title.text.trim().isEmpty) ? null : _save,
                child: child!,
              ),
              child: const Text('保存'),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
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
