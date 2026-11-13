import '../model/source_range.dart';

/// The extension boundary that reported an error to the host.
enum MarkdownExtensionPhase { configuration, parse, presentation, editing }

/// Diagnostic information for an extension that could not be used safely.
final class MarkdownExtensionError {
  const MarkdownExtensionError({
    required this.extensionId,
    required this.phase,
    required this.error,
    this.sourceRange,
  });

  final String extensionId;
  final MarkdownExtensionPhase phase;
  final Object error;
  final SourceRange? sourceRange;
}

/// Receives a non-fatal extension failure reported by the editor.
typedef MarkdownExtensionErrorListener = void Function(
  MarkdownExtensionError error,
);
