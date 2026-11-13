import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../theme/seq_tokens.dart';

/// 便签缩略卡。便签墙上的一张纸：标题、前几行、进度。
///
/// 事项全部完成时卡片底部换成"揭走"按钮——这是一张便签的终点。
class NoteCard extends StatelessWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.doneCount,
    required this.totalCount,
    this.onTap,
    this.onPeel,
  });

  final Note note;
  final int doneCount;
  final int totalCount;
  final VoidCallback? onTap;
  final VoidCallback? onPeel;

  @override
  Widget build(BuildContext context) {
    final color = SeqTokens.noteColors[note.color] ?? SeqTokens.noteYellow;
    final lines = note.lines
        .map(Note.lineTitle)
        .where((l) => l.isNotEmpty)
        .toList();
    final hasTitle = note.title != null && note.title!.trim().isNotEmpty;
    final title = hasTitle
        ? note.title!.trim()
        : (lines.isEmpty ? '（空便签）' : lines.first);
    final body = hasTitle ? lines : lines.skip(1).toList();
    final allDone = totalCount > 0 && doneCount == totalCount;

    const shape = BorderRadius.only(
      topLeft: Radius.circular(4),
      topRight: Radius.circular(4),
      bottomRight: Radius.circular(6),
      bottomLeft: Radius.circular(16),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: shape,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5A460A).withValues(alpha: 0.14),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: shape,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontFamily: SeqFonts.serif.first,
                          fontFamilyFallback: SeqFonts.serif,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: SeqTokens.noteInk,
                        ),
                        maxLines: hasTitle ? 1 : 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (note.pinned)
                      const Icon(
                        Icons.push_pin,
                        size: 14,
                        color: Color(0xFF8A7A45),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(
                    body.join('\n'),
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.55,
                      color: SeqTokens.noteInk,
                    ),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 8),
                if (totalCount == 0)
                  const Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_outlined,
                        size: 13,
                        color: Color(0xFF8A7A45),
                      ),
                      SizedBox(width: 6),
                      Text(
                        '待整理',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF7A6620),
                        ),
                      ),
                    ],
                  )
                else if (allDone && onPeel != null)
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '都办完了',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6B5A20),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: onPeel,
                        style: TextButton.styleFrom(
                          foregroundColor: SeqTokens.noteInk,
                          backgroundColor: SeqTokens.noteInk.withValues(
                            alpha: 0.08,
                          ),
                          minimumSize: const Size(0, 30),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text(
                          '揭走',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: doneCount / totalCount,
                            minHeight: 3,
                            backgroundColor: SeqTokens.noteInk.withValues(
                              alpha: 0.12,
                            ),
                            color: SeqTokens.noteInk.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        allDone ? '全部完成' : '$doneCount / $totalCount 完成',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF6B5A20),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
