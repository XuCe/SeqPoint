import 'package:flutter/widgets.dart';

import '../theme/markdown_editor_theme_data.dart';
import 'markdown_component_builders.dart';

/// Default bounded Markdown image presentation.
///
/// Loads `http`/`https` destinations through [Image.network] and relative or
/// `asset:` destinations through [Image.asset]. Empty, `file:`, malformed,
/// and unsupported scheme destinations render the alt text instead. The
/// output is wrapped in the theme's media bounds and exposes one image
/// semantics node labeled with the alt text.
class DefaultMarkdownMedia extends StatelessWidget {
  /// Creates a default media widget for [context].
  const DefaultMarkdownMedia({super.key, required this.context});

  /// The media presentation request.
  final MarkdownMediaContext context;

  @override
  Widget build(BuildContext context) {
    final media = this.context;
    final theme = media.theme;
    final destination = media.destination;
    final scheme = _schemeOf(destination);
    final image = switch (scheme) {
      'http' || 'https' => Image.network(
        destination,
        fit: theme.mediaFit,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : _placeholder(theme),
        errorBuilder: (_, _, _) => _fallback(theme),
      ),
      'asset' => Image.asset(
        destination.substring('asset:'.length),
        fit: theme.mediaFit,
        errorBuilder: (_, _, _) => _fallback(theme),
      ),
      _ when scheme.isEmpty && destination.isNotEmpty => Image.asset(
        destination,
        fit: theme.mediaFit,
        errorBuilder: (_, _, _) => _fallback(theme),
      ),
      _ => _fallback(theme),
    };
    return Semantics(
      image: true,
      label: media.alt ?? destination,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: theme.mediaMaxWidth,
          maxHeight: theme.mediaMaxHeight,
        ),
        child: image,
      ),
    );
  }

  Widget _placeholder(MarkdownEditorThemeData theme) => Container(
    color: theme.mediaPlaceholderColor,
    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
  );

  Widget _fallback(MarkdownEditorThemeData theme) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Text(
      context.alt ?? '',
      style: theme.mediaErrorStyle,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    ),
  );

  static String _schemeOf(String destination) {
    final colon = destination.indexOf(':');
    if (colon <= 0) return '';
    return destination.substring(0, colon).toLowerCase();
  }
}
