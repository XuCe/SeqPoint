import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'markdown_component_builders.dart';

/// The default task checkbox: a semantic, keyboard-driven toggle that
/// paints its hover, focus, press, and disabled states from the theme.
final class DefaultTaskToggle extends StatefulWidget {
  /// Creates a toggle for [context] from the component-builder contract.
  const DefaultTaskToggle({required this.context, super.key});

  /// The task configuration, including its [SourceRange] and toggle callback.
  final MarkdownTaskToggleContext context;

  @override
  State<DefaultTaskToggle> createState() => _DefaultTaskToggleState();
}

final class _DefaultTaskToggleState extends State<DefaultTaskToggle> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;
  final FocusNode _focusNode = FocusNode(debugLabel: 'DefaultTaskToggle');

  @override
  void didUpdateWidget(DefaultTaskToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.context.enabled && !widget.context.enabled) {
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  MarkdownTaskToggleContext get contextValue => widget.context;

  Color get _stateColor {
    final theme = contextValue.theme;
    if (!contextValue.enabled) return theme.taskDisabledColor;
    if (_pressed) return theme.taskPressedColor;
    if (_focused) return theme.taskFocusColor;
    if (_hovered) return theme.taskHoverColor;
    return const Color(0x00000000);
  }

  @override
  Widget build(BuildContext buildContext) => Directionality(
    textDirection: contextValue.textDirection,
    child: Semantics(
      label: contextValue.checked ? 'Completed task' : 'Incomplete task',
      checked: contextValue.checked,
      enabled: contextValue.enabled,
      button: true,
      onTap: contextValue.enabled ? contextValue.onToggle : null,
      child: CallbackShortcuts(
        bindings: contextValue.enabled
            ? {
                const SingleActivator(LogicalKeyboardKey.space):
                    contextValue.onToggle,
                const SingleActivator(LogicalKeyboardKey.enter):
                    contextValue.onToggle,
              }
            : const <ShortcutActivator, VoidCallback>{},
        child: Focus(
          focusNode: _focusNode,
          canRequestFocus: contextValue.enabled,
          onFocusChange: (value) => setState(() => _focused = value),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
            cursor: contextValue.enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: contextValue.enabled
                  ? (_) {
                      _focusNode.requestFocus();
                      setState(() => _pressed = true);
                    }
                  : null,
              onTapUp: contextValue.enabled
                  ? (_) => setState(() => _pressed = false)
                  : null,
              onTapCancel: contextValue.enabled
                  ? () => setState(() => _pressed = false)
                  : null,
              onTap: contextValue.enabled ? contextValue.onToggle : null,
              child: SizedBox.square(
                dimension: contextValue.theme.taskHitTargetSize,
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _stateColor,
                      borderRadius: BorderRadius.circular(
                        contextValue.theme.taskSize * 0.3,
                      ),
                    ),
                    child: SizedBox.square(
                      dimension: contextValue.theme.taskSize,
                      child: CustomPaint(
                        painter: _TaskTogglePainter(
                          checked: contextValue.checked,
                          borderColor: contextValue.theme.taskBorderColor,
                          checkedColor: contextValue.theme.taskCheckedColor,
                          checkColor: contextValue.theme.backgroundColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

final class _TaskTogglePainter extends CustomPainter {
  const _TaskTogglePainter({
    required this.checked,
    required this.borderColor,
    required this.checkedColor,
    required this.checkColor,
  });

  final bool checked;
  final Color borderColor;
  final Color checkedColor;
  final Color checkColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.shortestSide * 0.22);
    final paint = Paint()
      ..style = checked ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = checked ? checkedColor : borderColor;
    canvas.drawRRect(RRect.fromRectAndRadius(rect.deflate(1), radius), paint);
    if (!checked) return;
    final check = Path()
      ..moveTo(size.width * 0.25, size.height * 0.52)
      ..lineTo(size.width * 0.43, size.height * 0.70)
      ..lineTo(size.width * 0.76, size.height * 0.32);
    canvas.drawPath(
      check,
      Paint()
        ..color = checkColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TaskTogglePainter oldDelegate) =>
      checked != oldDelegate.checked ||
      borderColor != oldDelegate.borderColor ||
      checkedColor != oldDelegate.checkedColor ||
      checkColor != oldDelegate.checkColor;
}
