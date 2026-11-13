import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// The precision family used for one text-selection interaction.
enum MarkdownSelectionInput { touch, precise }

/// Resolves one owner and gesture family for a selection interaction.
@immutable
final class MarkdownSelectionInteractionPolicy {
  const MarkdownSelectionInteractionPolicy({
    required this.isWeb,
    required this.platform,
    required this.input,
    required this.interactiveSelectionEnabled,
  });

  factory MarkdownSelectionInteractionPolicy.resolve({
    required bool isWeb,
    required TargetPlatform platform,
    required PointerDeviceKind? pointerKind,
    required bool interactiveSelectionEnabled,
  }) => MarkdownSelectionInteractionPolicy(
    isWeb: isWeb,
    platform: platform,
    input: switch (pointerKind) {
      PointerDeviceKind.mouse ||
      PointerDeviceKind.trackpad ||
      PointerDeviceKind.invertedStylus => MarkdownSelectionInput.precise,
      PointerDeviceKind.touch ||
      PointerDeviceKind.stylus ||
      PointerDeviceKind.unknown ||
      null => MarkdownSelectionInput.touch,
    },
    interactiveSelectionEnabled: interactiveSelectionEnabled,
  );

  final bool isWeb;
  final TargetPlatform platform;
  final MarkdownSelectionInput input;
  final bool interactiveSelectionEnabled;

  bool get isMobileTarget =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;

  bool get usesPackageTouchUi =>
      interactiveSelectionEnabled && input == MarkdownSelectionInput.touch;

  bool get usesBrowserMenu => isWeb && !usesPackageTouchUi;

  bool get showsTouchHandles => usesPackageTouchUi;

  bool isStrictlyInsideSelection(TextSelection selection, TextPosition hit) =>
      selection.isValid &&
      !selection.isCollapsed &&
      hit.offset > selection.start &&
      hit.offset < selection.end;
}
