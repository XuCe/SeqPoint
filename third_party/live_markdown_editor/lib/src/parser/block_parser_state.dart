import 'markdown_node.dart';

/// Stateful container limits shared by full and incremental block parsing.
///
/// The limit prevents adversarial input from creating an unbounded semantic
/// tree; the rejected marker stays literal source text in the final child.
final class MarkdownContainerParserState {
  static const int maximumDepth = 4096;

  const MarkdownContainerParserState({this.depth = 0});

  final int depth;

  bool get canOpenContainer => depth < maximumDepth;

  MarkdownContainerParserState get nested =>
      MarkdownContainerParserState(depth: depth + 1);
}

/// A stable top-level parser boundary available for incremental reparsing.
final class MarkdownBlockCheckpoint {
  const MarkdownBlockCheckpoint({
    required this.sourceOffset,
    required this.blockCount,
  });

  /// UTF-16 source offset immediately after the completed block.
  final int sourceOffset;

  /// Number of completed top-level source partitions at this boundary.
  final int blockCount;
}

/// Accumulates stable source-partition checkpoints during a block parse.
final class MarkdownBlockParserState {
  final List<MarkdownBlockCheckpoint> _checkpoints = [];

  List<MarkdownBlockCheckpoint> get checkpoints =>
      List.unmodifiable(_checkpoints);

  void recordStableTopLevelBlock(MarkdownBlockNode block, int blockCount) {
    _checkpoints.add(
      MarkdownBlockCheckpoint(
        sourceOffset: block.range.end,
        blockCount: blockCount,
      ),
    );
  }

  static List<MarkdownBlockCheckpoint> checkpointsFor(
    List<MarkdownBlockNode> blocks,
  ) {
    final state = MarkdownBlockParserState();
    for (var index = 0; index < blocks.length; index++) {
      state.recordStableTopLevelBlock(blocks[index], index + 1);
    }
    return state.checkpoints;
  }
}
