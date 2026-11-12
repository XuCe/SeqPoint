import 'package:flutter/material.dart';

import '../theme/seq_tokens.dart';

class NoteTitleField extends StatelessWidget {
  const NoteTitleField({super.key, required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    textInputAction: TextInputAction.next,
    cursorColor: SeqTokens.noteInk,
    style: const TextStyle(color: SeqTokens.noteInk, fontSize: 17, fontWeight: FontWeight.w600),
    decoration: const InputDecoration(
      hintText: '标题（选填）',
      hintStyle: TextStyle(color: SeqTokens.inkMuted),
      border: InputBorder.none,
      filled: false,
      isDense: true,
      contentPadding: EdgeInsets.only(bottom: 7, top: 2),
    ),
  );
}
