import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_scope.dart';
import '../features/voice/voice_input_button.dart';
import '../theme/seq_tokens.dart';

/// 快速记录页：打开即聚焦输入框，3 秒内可保存。
///
/// 零属性保存——不要求标题、标签或时间。这是产品的第一原则。
class QuickCapturePage extends StatefulWidget {
  const QuickCapturePage({super.key, this.initialText = ''});
  final String initialText;

  @override
  State<QuickCapturePage> createState() => _QuickCapturePageState();
}

class _QuickCapturePageState extends State<QuickCapturePage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialText;
    // 打开即聚焦，键盘立刻弹出。
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    try {
      AppScope.of(context).noteService.capture(text);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存失败，请重试。输入的内容仍在。')),
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
        title: const Text('记一笔'),
        actions: [
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
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          maxLines: null,
          expands: true,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          style: const TextStyle(
              fontSize: 16, height: 1.6, color: SeqTokens.noteInk),
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: '想到什么就写什么，一行一件事\n之后可以让 AI 帮你整理',
            hintStyle: TextStyle(color: Color(0xFF9C8A50), height: 1.6),
          ),
          onSubmitted: (_) => _save(),
        ),
      ),
      ),
    );
  }
}
