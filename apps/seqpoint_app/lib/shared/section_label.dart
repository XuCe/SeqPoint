import 'package:flutter/material.dart';

import '../theme/seq_tokens.dart';

/// 分区标题：小字 + 可选计数徽标 + 一条延伸到右侧的细线。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.badge, this.danger = false});

  final String text;
  final String? badge;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Row(
        children: [
          Text(text, style: Theme.of(context).textTheme.labelSmall),
          if (badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: danger ? SeqTokens.dangerBg : SeqTokens.accentSoft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                badge!,
                style: TextStyle(
                  fontSize: 11,
                  color: danger ? SeqTokens.dangerInk : SeqTokens.accentInk,
                ),
              ),
            ),
          ],
          const SizedBox(width: 12),
          const Expanded(child: Divider(height: 1)),
        ],
      ),
    );
  }
}
