import 'markdown_node.dart';
import 'block_parser_state.dart';

final class MarkdownDocument {
  MarkdownDocument({
    required this.source,
    required this.blocks,
    this.checkpoints = const [],
    Map<String, MarkdownLinkDefinition>? definitions,
  }) : _definitions = Map.unmodifiable(definitions ?? definitionsFor(blocks));

  final String source;

  /// Top-level source partitions. Their ranges concatenate to [source].
  final List<MarkdownBlockNode> blocks;

  /// Stable boundaries after each completed top-level source partition.
  final List<MarkdownBlockCheckpoint> checkpoints;

  /// Immutable first-definition-wins index of link reference definitions,
  /// keyed by normalized (Unicode case-folded, whitespace-collapsed) label.
  final Map<String, MarkdownLinkDefinition> _definitions;

  Map<String, MarkdownLinkDefinition> get definitions => _definitions;

  /// Collects link reference definitions from every paragraph across the
  /// block tree in source order, keeping the first definition per label.
  static Map<String, MarkdownLinkDefinition> definitionsFor(
    List<MarkdownBlockNode> blocks,
  ) {
    final definitions = <String, MarkdownLinkDefinition>{};
    void walk(MarkdownBlockNode block) {
      final definition = block.definition;
      if (block.type == MarkdownBlockType.linkDefinition &&
          definition != null) {
        definitions.putIfAbsent(definition.label, () => definition);
      }
      for (final child in block.children) {
        walk(child);
      }
    }

    for (final block in blocks) {
      walk(block);
    }
    return definitions;
  }

  /// Semantic blocks in source order, including nested children.
  Iterable<MarkdownBlockNode> get semanticBlocks sync* {
    for (final block in blocks) {
      yield* _walk(block);
    }
  }

  String textFor(MarkdownBlockNode node) => node.range.slice(source);

  String roundTrip() => blocks.map(textFor).join();

  Iterable<MarkdownBlockNode> _walk(MarkdownBlockNode block) sync* {
    yield block;
    for (final child in block.children) {
      yield* _walk(child);
    }
  }
}
