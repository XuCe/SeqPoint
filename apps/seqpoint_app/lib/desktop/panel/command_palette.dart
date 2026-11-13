import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/seq_widgets.dart';
import '../../theme/seq_tokens.dart';

/// ⌘K 面板选中的结果：要么是一条命令，要么是一条搜索命中。
sealed class PaletteChoice {
  const PaletteChoice();
}

class PaletteCommand extends PaletteChoice {
  const PaletteCommand(this.id, this.label, this.icon, {this.hint});
  final String id;
  final String label;
  final IconData icon;
  final String? hint;
}

class PaletteHit extends PaletteChoice {
  const PaletteHit(this.hit);
  final SearchHit hit;
}

/// 搜索或跳转：一个入口里搜便签和事项、切换页面、新建便签。
///
/// ↑↓ 选择，回车执行，Esc 关闭。
Future<PaletteChoice?> showCommandPalette(
  BuildContext context, {
  required List<PaletteCommand> commands,
}) =>
    showDialog<PaletteChoice>(
      context: context,
      barrierColor: const Color(0x33262219),
      builder: (_) => _CommandPalette(
        search: AppScope.of(context).search,
        commands: commands,
      ),
    );

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({required this.search, required this.commands});

  final SearchService search;
  final List<PaletteCommand> commands;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  List<SearchHit> _hits = const [];
  int _selected = 0;
  int _searchSeq = 0;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<PaletteCommand> get _commands {
    final q = _query.text.trim();
    if (q.isEmpty) return widget.commands;
    return widget.commands.where((c) => c.label.contains(q)).toList();
  }

  List<PaletteChoice> get _choices => [..._commands, for (final h in _hits) PaletteHit(h)];

  void _changed(String value) {
    setState(() => _selected = 0);
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() => _hits = const []);
      return;
    }
    final seq = ++_searchSeq;
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      try {
        final hits = await widget.search.query(query);
        if (mounted && seq == _searchSeq) setState(() => _hits = hits.take(20).toList());
      } catch (_) {
        if (mounted && seq == _searchSeq) setState(() => _hits = const []);
      }
    });
  }

  void _move(int delta) {
    final count = _choices.length;
    if (count == 0) return;
    setState(() => _selected = (_selected + delta) % count);
  }

  void _submit() {
    final choices = _choices;
    if (choices.isEmpty) return;
    Navigator.of(context).pop(choices[_selected.clamp(0, choices.length - 1)]);
  }

  @override
  Widget build(BuildContext context) {
    final commands = _commands;
    final query = _query.text.trim();
    var index = 0;
    Widget row(PaletteChoice choice) {
      final i = index++;
      final selected = i == _selected;
      final (icon, title, hint) = switch (choice) {
        PaletteCommand c => (c.icon, c.label, c.hint),
        PaletteHit(:final hit) => (
            hit.isNote ? Icons.sticky_note_2_outlined : Icons.radio_button_unchecked,
            hit.text.replaceAll('\n', ' '),
            '${hit.isNote ? '便签' : '事项'}${hit.archived ? ' · 已关闭' : ''}',
          ),
      };
      return Material(
        color: selected ? SeqTokens.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.of(context).pop(choice),
          onHover: (hovering) {
            if (hovering && _selected != i) setState(() => _selected = i);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              Icon(icon, size: 17, color: SeqTokens.inkMuted),
              const SizedBox(width: 12),
              Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14))),
              if (hint != null) ...[
                const SizedBox(width: 12),
                Text(hint, style: const TextStyle(fontSize: 12, color: SeqTokens.inkFaint)),
              ],
            ]),
          ),
        ),
      );
    }

    return Align(
      alignment: const Alignment(0, -0.55),
      child: Material(
        key: const ValueKey('command-palette'),
        color: SeqTokens.raised,
        elevation: 24,
        shadowColor: const Color(0x55262219),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600, maxHeight: 480),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
            },
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 12, 4),
                child: Row(children: [
                  const Icon(Icons.search, color: SeqTokens.inkMuted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('palette-input'),
                      controller: _query,
                      focusNode: _focus,
                      autofocus: true,
                      onChanged: _changed,
                      onSubmitted: (_) => _submit(),
                      style: const TextStyle(fontSize: 16),
                      decoration: const InputDecoration(
                        hintText: '搜索便签和事项，或输入命令',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  if (query.isNotEmpty)
                    IconButton(
                      tooltip: '清空',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _query.clear();
                        _changed('');
                      },
                    ),
                  const KbdHint('Esc'),
                ]),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(8),
                  children: [
                    if (commands.isNotEmpty) ...[
                      const _GroupLabel('命令'),
                      for (final c in commands) row(c),
                    ],
                    if (query.isNotEmpty) ...[
                      const _GroupLabel('便签和事项'),
                      if (_hits.isEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(12, 6, 12, 10),
                          child: Text('没有找到相关便签或事项',
                              style: TextStyle(fontSize: 13, color: SeqTokens.inkMuted)),
                        )
                      else
                        for (final h in _hits) row(PaletteHit(h)),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(text, style: const TextStyle(fontSize: 11.5, letterSpacing: 1,
            fontWeight: FontWeight.w600, color: SeqTokens.inkFaint)),
      );
}
