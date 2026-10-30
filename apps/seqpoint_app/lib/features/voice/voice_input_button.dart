import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'voice_input_page.dart';

class VoiceInputButton extends StatelessWidget {
  const VoiceInputButton({
    super.key,
    required this.controller,
    this.enabled = true,
    this.speech,
  });
  final TextEditingController controller;
  final bool enabled;
  final SpeechToText? speech;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '语音输入',
    icon: const Icon(Icons.mic_none),
    onPressed: !enabled
        ? null
        : () async {
            final text = await Navigator.of(context).push<String>(
              MaterialPageRoute(
                builder: (_) => VoiceInputPage(speech: speech),
                fullscreenDialog: true,
              ),
            );
            if (!context.mounted || text == null || text.isEmpty) return;
            final current = controller.value;
            final selection = current.selection;
            final start = selection.isValid
                ? selection.start
                : current.text.length;
            final end = selection.isValid ? selection.end : current.text.length;
            controller.value = TextEditingValue(
              text: current.text.replaceRange(start, end, text),
              selection: TextSelection.collapsed(offset: start + text.length),
            );
          },
  );
}
