import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../theme/seq_tokens.dart';

/// 便签缩略卡。便签墙上的一张纸。
class NoteCard extends StatelessWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.doneCount,
    required this.totalCount,
    this.onTap,
  });

  final Note note;
  final int doneCount;
  final int totalCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = SeqTokens.noteColors[note.color] ?? SeqTokens.noteYellow;
    final preview = note.rawContent.trim();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(4),
            bottomRight: Radius.circular(6),
            bottomLeft: Radius.circular(14),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF5A460A).withValues(alpha: 0.18),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (note.title != null && note.title!.isNotEmpty) ...[
              Text(
                note.title!,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: SeqTokens.noteInk,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
            ],
            Expanded(
              child: Text(
                preview.isEmpty ? '（空便签）' : preview,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: SeqTokens.noteInk,
                ),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (totalCount > 0) ...[
              const SizedBox(height: 6),
              Text(
                doneCount == totalCount
                    ? '全部完成 · 可以关闭了'
                    : '$doneCount / $totalCount 完成',
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF8A7A45)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
