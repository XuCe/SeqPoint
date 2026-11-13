import 'package:flutter/widgets.dart';

final class MarkdownEditorOverlay extends StatefulWidget {
  const MarkdownEditorOverlay({required this.child, super.key});

  final Widget child;

  @override
  State<MarkdownEditorOverlay> createState() => _MarkdownEditorOverlayState();
}

final class _MarkdownEditorOverlayState extends State<MarkdownEditorOverlay> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (context) => widget.child,
  );

  @override
  void didUpdateWidget(MarkdownEditorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _entry.remove();
    WidgetsBinding.instance.addPostFrameCallback((_) => _entry.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}
