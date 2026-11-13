import 'package:flutter/services.dart';

import '../parser/markdown_node.dart';
import 'markdown_extension_presentation.dart';
import 'markdown_parse_context.dart';

/// Identifies one built-in or community grammar rule.
final class MarkdownSyntaxRuleId {
  const MarkdownSyntaxRuleId(this.value) : assert(value != '');

  final String value;

  @override
  bool operator ==(Object other) =>
      other is MarkdownSyntaxRuleId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Describes how far an edit can invalidate an extension parse.
enum MarkdownExtensionInvalidationScope { localBlock, forward, document }

/// A grammar rule supplied by a syntax extension.
abstract interface class MarkdownSyntaxRule {
  MarkdownSyntaxRuleId get id;
  MarkdownExtensionInvalidationScope get invalidationScope;
}

/// An inline recognizer rule.
///
/// The engine consults additive inline rules at the pre-literal-text fallback
/// point, or at a named core slot when the rule is registered through an
/// explicit override. A match must start at the offered cursor, stay inside
/// the context, make forward progress, and declare ordered child ranges that
/// the engine parses recursively.
abstract interface class MarkdownInlineRule implements MarkdownSyntaxRule {
  /// Code units at which the engine must pause literal-text scanning so this
  /// rule can be consulted at the fallback point.
  Set<int> get triggerCodeUnits;

  /// Returns an immutable match starting at [MarkdownInlineParseContext.cursor],
  /// or null when this rule declines the offered position.
  MarkdownInlineMatch? matchInline(MarkdownInlineParseContext context);
}

/// A block recognizer rule.
///
/// The engine consults additive block rules after core/container/leaf
/// recognition but before paragraph fallback, or at a named core slot when
/// the rule is registered through an explicit override.
abstract interface class MarkdownBlockRule implements MarkdownSyntaxRule {
  MarkdownBlockMatch? matchBlock(MarkdownBlockParseContext context);
}

/// Attaches immutable extension metadata to a completed node.
///
/// Decorators never rewrite source structure; they may only attach
/// [MarkdownExtensionNodeData] to a node that does not already carry any.
abstract class MarkdownDecorator implements MarkdownSyntaxRule {
  const MarkdownDecorator();

  MarkdownExtensionNodeData? decorateBlock(MarkdownBlockNode node) => null;
  MarkdownExtensionNodeData? decorateInline(MarkdownInlineNode node) => null;
}

/// Per-editor state owned by one registered syntax extension.
///
/// A descriptor returns one session per editor surface from
/// [MarkdownSyntaxExtension.createSession]; the editor reuses it across
/// rebuilds and disposes it exactly once when the surface is disposed.
abstract interface class MarkdownSyntaxSession {
  /// Releases recognizers and other disposable resources.
  void dispose();
}

/// A pure syntax-specific transformation of a proposed [TextEditingValue].
///
/// Runs after core text-input behavior, in dependency/registration order.
/// Returning null declines the edit; returning a value replaces the proposed
/// value. The editor validates the returned selection/composing ranges and
/// applies the accepted value once through the controller so one input event
/// creates one undo transaction.
abstract interface class MarkdownEditingRule {
  /// Unique rule identifier.
  MarkdownSyntaxRuleId get id;

  /// Transforms [proposed], or returns null to leave it unchanged.
  TextEditingValue? apply(TextEditingValue proposed);
}

/// A stateless package descriptor that adds Markdown syntax.
abstract class MarkdownSyntaxExtension {
  /// Creates a descriptor. Subclasses should declare a const constructor.
  const MarkdownSyntaxExtension();

  static const apiVersion1 = 1;

  /// Maximum extension child recursion depth enforced by the engine.
  ///
  /// A match whose child parse would exceed this limit is invalidated: the
  /// construct becomes literal source and a [MarkdownExtensionError] with
  /// phase [MarkdownExtensionPhase.parse] is reported to the host.
  static const int maximumChildRecursionDepth = 256;

  String get id;
  int get apiVersion;
  List<String> get dependencies;
  List<MarkdownSyntaxRule> get rules;

  /// Creates per-editor session state, or null when stateless.
  ///
  /// Called once per editor surface that renders this extension; the returned
  /// session is disposed exactly once with the surface.
  MarkdownSyntaxSession? createSession() => null;

  /// Presents an extension-owned block node.
  ///
  /// May only present nodes this extension created or explicitly decorated.
  /// Returning null keeps the node literal. Implementations must return
  /// immutable presentations; the core validates them.
  MarkdownExtensionPresentation? presentBlock(
    MarkdownExtensionPresentationContext context,
    MarkdownBlockNode node,
  ) => null;

  /// Presents an extension-owned inline node.
  MarkdownExtensionPresentation? presentInline(
    MarkdownExtensionPresentationContext context,
    MarkdownInlineNode node,
  ) => null;

  /// Pure editing rules run after core typing behavior.
  List<MarkdownEditingRule> get editingRules => const [];
}

/// A syntax descriptor that explicitly replaces one registered grammar rule.
abstract interface class MarkdownSyntaxOverride
    implements MarkdownSyntaxExtension {
  MarkdownSyntaxRuleId get replaces;
}
