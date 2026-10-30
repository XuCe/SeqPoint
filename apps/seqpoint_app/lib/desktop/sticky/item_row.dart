import 'package:flutter/material.dart';

import '../../theme/seq_tokens.dart';

/// 便签内的一行。三种形态：纯文本行、待办行（○）、已完成行（划线）。
///
/// 纯文本行 hover 时行首浮现 ○，点击即把该行转为事项——这是 AI 关闭时的手动路径。
class ItemRow extends StatefulWidget {
  const ItemRow({
    super.key,
    required this.text,
    this.isItem = false,
    this.isDone = false,
    this.onToggle,
    this.onConvert,
    this.onEdit,
    this.onFocusChange,
  });

  final String text;
  final bool isItem;
  final bool isDone;
  final VoidCallback? onToggle;
  final VoidCallback? onConvert;
  final VoidCallback? onEdit;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<ItemRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final showCircle = widget.isItem || (_hovered && widget.onConvert != null);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.isItem ? widget.onToggle : widget.onConvert,
        onFocusChange: widget.onFocusChange,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26,
                child: showCircle
                    ? _Circle(done: widget.isDone, faded: !widget.isItem)
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: Text(
                  widget.text.isEmpty ? ' ' : widget.text,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.5,
                    color: widget.isDone
                        ? const Color(0xFF8A7A45)
                        : SeqTokens.noteInk,
                    decoration: widget.isDone
                        ? TextDecoration.lineThrough
                        : null,
                    decorationColor: const Color(0xFF8A7A45),
                  ),
                ),
              ),
              if (widget.isItem && widget.onEdit != null)
                IconButton(
                  tooltip: '编辑事项',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: widget.onEdit,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle({required this.done, required this.faded});

  final bool done;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: faded ? 0.45 : 1,
      child: Container(
        width: 17,
        height: 17,
        margin: const EdgeInsets.only(top: 3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? SeqTokens.accentInk : null,
          border: done
              ? null
              : Border.all(color: SeqTokens.accentInk, width: 1.5),
        ),
        child: done
            ? const Icon(Icons.check, size: 12, color: SeqTokens.noteYellow)
            : null,
      ),
    );
  }
}
