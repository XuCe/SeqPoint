import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'render_markdown_editable.dart';

const double _minimumInteractiveDimension = 48;

/// Identifies the source selection endpoint controlled by a rendered handle.
enum MarkdownSelectionEndpoint { start, end, collapsed }

/// A package-owned selection overlay that renders and drags configured handles.
///
/// The overlay measures the source-aware [RenderMarkdownEditable] after layout,
/// then positions handles in this widget's coordinate space. It deliberately
/// does not use Flutter's editable/selectable widgets or their private overlay
/// implementation.
final class MarkdownSelectionOverlay extends StatefulWidget {
  const MarkdownSelectionOverlay({
    required this.renderKey,
    required this.selection,
    required this.selectionControls,
    required this.textDirectionForOffset,
    required this.positionForGlobalOffset,
    required this.onSelectionHandleChanged,
    required this.child,
    this.visible = true,
    this.interactive = true,
    this.dragStartBehavior = DragStartBehavior.start,
    this.onHandleTap,
    this.onHandleDragStart,
    this.onHandleDragEnd,
    super.key,
  });

  final GlobalKey renderKey;
  final TextSelection selection;
  final TextSelectionControls selectionControls;
  final TextDirection Function(int sourceOffset) textDirectionForOffset;
  final TextPosition Function(Offset globalOffset) positionForGlobalOffset;
  final void Function(MarkdownSelectionEndpoint endpoint, TextPosition position)
  onSelectionHandleChanged;
  final Widget child;
  final bool visible;
  final bool interactive;
  final DragStartBehavior dragStartBehavior;
  final VoidCallback? onHandleTap;
  final ValueChanged<MarkdownSelectionEndpoint>? onHandleDragStart;
  final VoidCallback? onHandleDragEnd;

  @override
  State<MarkdownSelectionOverlay> createState() =>
      MarkdownSelectionOverlayState();
}

/// State access used by the owning editor to refresh geometry after transforms.
final class MarkdownSelectionOverlayState
    extends State<MarkdownSelectionOverlay> {
  final GlobalKey _overlayKey = GlobalKey();
  _SelectionOverlayGeometry? _geometry;
  bool _geometryUpdateScheduled = false;
  Offset? _dragPositionCorrection;

  @override
  void initState() {
    super.initState();
    updateGeometry();
  }

  @override
  void didUpdateWidget(MarkdownSelectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateGeometry();
  }

  /// Coalesces a source-handle geometry refresh until after the current layout.
  void updateGeometry() {
    if (_geometryUpdateScheduled) return;
    _geometryUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryUpdateScheduled = false;
      if (!mounted) return;
      _measureGeometry();
    });
  }

  void _measureGeometry() {
    final next = _calculateGeometry();
    if (next != _geometry) setState(() => _geometry = next);
  }

  _SelectionOverlayGeometry? _calculateGeometry() {
    if (!widget.visible || !widget.interactive || !widget.selection.isValid) {
      return null;
    }
    final render = widget.renderKey.currentContext?.findRenderObject();
    final overlay = _overlayKey.currentContext?.findRenderObject();
    if (render is! RenderMarkdownEditable ||
        overlay is! RenderBox ||
        !render.attached ||
        !overlay.attached ||
        !render.hasSize ||
        !overlay.hasSize) {
      return null;
    }

    ({Offset point, double lineHeight}) endpointFor(
      int offset,
      TextAffinity affinity,
    ) {
      final caret = render.caretRectForSourceOffset(offset, affinity: affinity);
      return (
        point: overlay.globalToLocal(render.localToGlobal(caret.bottomCenter)),
        lineHeight: caret.height,
      );
    }

    final selection = widget.selection;
    if (selection.isCollapsed) {
      final endpoint = endpointFor(selection.extentOffset, selection.affinity);
      return _SelectionOverlayGeometry(
        start: endpoint.point,
        end: null,
        startLineHeight: endpoint.lineHeight,
        endLineHeight: null,
      );
    }
    final start = endpointFor(selection.start, TextAffinity.downstream);
    final end = endpointFor(selection.end, TextAffinity.upstream);
    return _SelectionOverlayGeometry(
      start: start.point,
      end: end.point,
      startLineHeight: start.lineHeight,
      endLineHeight: end.lineHeight,
    );
  }

  TextSelectionHandleType _handleType(
    MarkdownSelectionEndpoint endpoint,
    int sourceOffset,
  ) {
    if (endpoint == MarkdownSelectionEndpoint.collapsed) {
      return TextSelectionHandleType.collapsed;
    }
    final direction = widget.textDirectionForOffset(sourceOffset);
    final startsOnLeft = direction == TextDirection.ltr;
    return switch (endpoint) {
      MarkdownSelectionEndpoint.start =>
        startsOnLeft
            ? TextSelectionHandleType.left
            : TextSelectionHandleType.right,
      MarkdownSelectionEndpoint.end =>
        startsOnLeft
            ? TextSelectionHandleType.right
            : TextSelectionHandleType.left,
      MarkdownSelectionEndpoint.collapsed => TextSelectionHandleType.collapsed,
    };
  }

  Widget _buildHandle({
    required MarkdownSelectionEndpoint endpoint,
    required Offset localTarget,
    required int sourceOffset,
    required double lineHeight,
  }) {
    final controls = widget.selectionControls;
    final type = _handleType(endpoint, sourceOffset);
    final handleSize = controls.getHandleSize(lineHeight);
    final handleAnchor = controls.getHandleAnchor(type, lineHeight);
    final interactiveSize = Size(
      math.max(handleSize.width, _minimumInteractiveDimension),
      math.max(handleSize.height, _minimumInteractiveDimension),
    );
    final padding = Offset(
      (interactiveSize.width - handleSize.width) / 2,
      (interactiveSize.height - handleSize.height) / 2,
    );
    final visualTopLeft = localTarget - handleAnchor;
    final interactiveTopLeft = visualTopLeft - padding;

    return Positioned(
      left: interactiveTopLeft.dx,
      top: interactiveTopLeft.dy,
      width: interactiveSize.width,
      height: interactiveSize.height,
      child: GestureDetector(
        key: ValueKey<String>('markdown-selection-handle-${endpoint.name}'),
        behavior: HitTestBehavior.translucent,
        dragStartBehavior: widget.dragStartBehavior,
        onPanDown: (details) {
          final overlay =
              _overlayKey.currentContext!.findRenderObject()! as RenderBox;
          final targetGlobal = overlay.localToGlobal(localTarget);
          _dragPositionCorrection = targetGlobal - details.globalPosition;
        },
        onPanStart: (_) {
          widget.onHandleDragStart?.call(endpoint);
        },
        onPanUpdate: (details) {
          final position = widget.positionForGlobalOffset(
            details.globalPosition + (_dragPositionCorrection ?? Offset.zero),
          );
          widget.onSelectionHandleChanged(endpoint, position);
        },
        onPanEnd: (_) {
          _dragPositionCorrection = null;
          widget.onHandleDragEnd?.call();
        },
        onPanCancel: () {
          _dragPositionCorrection = null;
          widget.onHandleDragEnd?.call();
        },
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            padding.dx,
            padding.dy,
            padding.dx,
            padding.dy,
          ),
          child: controls.buildHandle(
            context,
            type,
            lineHeight,
            widget.onHandleTap,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final geometry = _calculateGeometry() ?? _geometry;
    final selection = widget.selection;
    return Stack(
      key: _overlayKey,
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (geometry != null &&
            selection.isValid &&
            widget.visible &&
            widget.interactive)
          if (selection.isCollapsed)
            _buildHandle(
              endpoint: MarkdownSelectionEndpoint.collapsed,
              localTarget: geometry.start,
              sourceOffset: selection.extentOffset,
              lineHeight: geometry.startLineHeight,
            )
          else ...[
            _buildHandle(
              endpoint: MarkdownSelectionEndpoint.start,
              localTarget: geometry.start,
              sourceOffset: selection.start,
              lineHeight: geometry.startLineHeight,
            ),
            _buildHandle(
              endpoint: MarkdownSelectionEndpoint.end,
              localTarget: geometry.end!,
              sourceOffset: selection.end,
              lineHeight: geometry.endLineHeight ?? geometry.startLineHeight,
            ),
          ],
      ],
    );
  }
}

final class _SelectionOverlayGeometry {
  const _SelectionOverlayGeometry({
    required this.start,
    required this.end,
    required this.startLineHeight,
    required this.endLineHeight,
  });

  final Offset start;
  final Offset? end;
  final double startLineHeight;
  final double? endLineHeight;

  @override
  bool operator ==(Object other) =>
      other is _SelectionOverlayGeometry &&
      other.start == start &&
      other.end == end &&
      other.startLineHeight == startLineHeight &&
      other.endLineHeight == endLineHeight;

  @override
  int get hashCode => Object.hash(start, end, startLineHeight, endLineHeight);
}
