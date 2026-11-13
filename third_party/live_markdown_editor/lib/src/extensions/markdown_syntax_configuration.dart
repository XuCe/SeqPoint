import '../parser/builtin_syntax_extensions.dart';
import 'markdown_extension_error.dart';
import 'markdown_syntax_extension.dart';

/// The grammar profile selected before community extensions are applied.
enum MarkdownSyntaxProfile { commonMarkSafe, editorDefaults, customized }

/// The resolved, validated grammar consumed by the parser engines.
///
/// [MarkdownSyntaxConfiguration.grammar] produces one immutable snapshot per
/// configuration; the parser consults the slot lists at their defined
/// fallback points. Core slot override lists are `null` when no override is
/// registered (the core rule runs), and non-null (possibly empty, which
/// disables the slot) when an override replaces it.
final class MarkdownResolvedGrammar {
  const MarkdownResolvedGrammar({
    this.taskSlotRules = const [],
    this.blockFallbackRules = const [],
    this.inlineFallbackRules = const [],
    this.emphasisOverrideRules,
    this.linkOverrideRules,
    this.headingOverrideRules,
    this.decorators = const [],
    this.inlineTriggers = const {},
    this.ruleOwnerById = const {},
    this.onExtensionError,
  });

  /// Rules consulted at the task-list slot, before generic list recognition.
  final List<MarkdownBlockRule> taskSlotRules;

  /// Additive block rules consulted after core/container/leaf recognition,
  /// before paragraph fallback.
  final List<MarkdownBlockRule> blockFallbackRules;

  /// Additive inline rules consulted before literal-text fallback.
  final List<MarkdownInlineRule> inlineFallbackRules;

  /// Rules replacing the core `commonmark.inline.emphasis` slot, or null.
  final List<MarkdownInlineRule>? emphasisOverrideRules;

  /// Rules replacing the core `commonmark.inline.link` slot, or null.
  final List<MarkdownInlineRule>? linkOverrideRules;

  /// Rules replacing the core `commonmark.block.heading` slot, or null.
  final List<MarkdownBlockRule>? headingOverrideRules;

  /// Rules that may attach metadata to completed nodes.
  final List<MarkdownDecorator> decorators;

  /// Union of [MarkdownInlineRule.triggerCodeUnits] of every fallback rule.
  final Set<int> inlineTriggers;

  /// Maps a rule ID value to its owning extension ID for diagnostics.
  final Map<String, String> ruleOwnerById;

  /// Host callback for non-fatal extension failures during parsing.
  final MarkdownExtensionErrorListener? onExtensionError;
}

/// The editor-default inline additions only: strikethrough and highlight.
///
/// This is the grammar the standalone inline parser uses when a caller does
/// not supply one, preserving the package's historical inline behavior for
/// direct inline-parser consumers.
const MarkdownResolvedGrammar markdownEditorDefaultsInlineGrammar =
    MarkdownResolvedGrammar(
      inlineFallbackRules: [
        MarkdownBuiltinStrikethroughRule(),
        MarkdownBuiltinHighlightRule(),
      ],
      inlineTriggers: {0x7E, 0x3D},
      ruleOwnerById: {
        'live_markdown_editor.inline.strikethrough':
            'live_markdown_editor.strikethrough',
        'live_markdown_editor.inline.highlight':
            'live_markdown_editor.highlight',
      },
    );

/// Immutable registration of standard, additive, and overriding syntax.
final class MarkdownSyntaxConfiguration {
  const MarkdownSyntaxConfiguration.editorDefaults({
    List<MarkdownSyntaxExtension> extensions = const [],
    List<MarkdownSyntaxOverride> overrides = const [],
    this.onExtensionError,
  }) : baseProfile = MarkdownSyntaxProfile.editorDefaults,
       _extensionRegistrations = extensions,
       _overrideRegistrations = overrides;

  const MarkdownSyntaxConfiguration.commonMarkSafe({
    List<MarkdownSyntaxExtension> extensions = const [],
    List<MarkdownSyntaxOverride> overrides = const [],
    this.onExtensionError,
  }) : baseProfile = MarkdownSyntaxProfile.commonMarkSafe,
       _extensionRegistrations = extensions,
       _overrideRegistrations = overrides;

  /// The selected core and built-in syntax profile before overrides.
  final MarkdownSyntaxProfile baseProfile;
  final List<MarkdownSyntaxExtension> _extensionRegistrations;
  final List<MarkdownSyntaxOverride> _overrideRegistrations;
  final MarkdownExtensionErrorListener? onExtensionError;

  /// Additive descriptors. Overrides are rejected from this lane.
  List<MarkdownSyntaxExtension> get extensions =>
      List.unmodifiable(_extensionRegistrations);

  /// Explicit grammar replacements.
  List<MarkdownSyntaxOverride> get overrides =>
      List.unmodifiable(_overrideRegistrations);

  /// The profile label used for compatibility and cache identity.
  MarkdownSyntaxProfile get effectiveProfile => _overrideRegistrations.isEmpty
      ? baseProfile
      : MarkdownSyntaxProfile.customized;

  /// Stable identity for parser snapshots created from this configuration.
  String get parserCacheKey {
    validate();
    return [
      baseProfile.name,
      for (final extension in _extensionRegistrations)
        '${extension.id}@${extension.apiVersion}('
            '${extension.rules.map((rule) => rule.id.value).join(',')})',
      for (final override in _overrideRegistrations)
        '${override.id}@${override.apiVersion}->${override.replaces.value}',
    ].join('|');
  }

  /// The built-in descriptors selected by [baseProfile].
  List<MarkdownSyntaxExtension> get _profileExtensions =>
      baseProfile == MarkdownSyntaxProfile.editorDefaults
      ? markdownBuiltinExtensions
      : const [];

  /// All active extensions (built-ins first, then community) in validated
  /// dependency order with registration order as the tie-breaker.
  ///
  /// Used for session creation and editing-rule composition.
  List<MarkdownSyntaxExtension> get orderedExtensions {
    validate();
    final byId = <String, MarkdownSyntaxExtension>{
      for (final extension in [
        ..._profileExtensions,
        ..._extensionRegistrations,
      ])
        extension.id: extension,
    };
    final ordered = <MarkdownSyntaxExtension>[];
    final seen = <String>{};
    void visit(MarkdownSyntaxExtension extension) {
      if (!seen.add(extension.id)) return;
      for (final dependency in extension.dependencies) {
        visit(byId[dependency]!);
      }
      ordered.add(extension);
    }

    for (final extension in _profileExtensions) {
      visit(extension);
    }
    for (final extension in _extensionRegistrations) {
      visit(extension);
    }
    return List.unmodifiable(ordered);
  }

  /// The active extension registered under [id], or null.
  MarkdownSyntaxExtension? extensionById(String id) {
    for (final extension in orderedExtensions) {
      if (extension.id == id) return extension;
    }
    return null;
  }

  /// All editing rules from active extensions in dependency/registration
  /// order, each paired with its owning extension ID for diagnostics.
  List<({MarkdownEditingRule rule, String extensionId})> get editingRules =>
      List.unmodifiable([
        for (final extension in orderedExtensions)
          for (final rule in extension.editingRules)
            (rule: rule, extensionId: extension.id),
      ]);

  /// Resolves this configuration into the ordered grammar the parser runs.
  ///
  /// Additive rules (built-ins first, then community extensions) are
  /// topologically ordered with registration order as the tie-breaker, and
  /// any rule targeted by an explicit override is substituted by the
  /// override's own rules.
  MarkdownResolvedGrammar get grammar {
    validate();
    final overrideByTarget = <MarkdownSyntaxRuleId, MarkdownSyntaxOverride>{
      for (final override in _overrideRegistrations)
        override.replaces: override,
    };
    final byId = <String, MarkdownSyntaxExtension>{
      for (final extension in [
        ..._profileExtensions,
        ..._extensionRegistrations,
      ])
        extension.id: extension,
    };
    final ordered = <MarkdownSyntaxRule>[];
    final seen = <String>{};

    void visit(MarkdownSyntaxExtension extension) {
      if (!seen.add(extension.id)) return;
      for (final dependency in extension.dependencies) {
        visit(byId[dependency]!);
      }
      ordered.addAll(extension.rules);
    }

    for (final extension in _profileExtensions) {
      visit(extension);
    }
    for (final extension in _extensionRegistrations) {
      visit(extension);
    }

    final ownerById = <String, String>{};
    for (final extension in [
      ..._profileExtensions,
      ..._extensionRegistrations,
      ..._overrideRegistrations,
    ]) {
      for (final rule in extension.rules) {
        ownerById[rule.id.value] = extension.id;
      }
    }

    final taskSlot = <MarkdownBlockRule>[];
    final blockFallback = <MarkdownBlockRule>[];
    final inlineFallback = <MarkdownInlineRule>[];
    final decorators = <MarkdownDecorator>[];

    void addRule(MarkdownSyntaxRule rule) {
      if (rule is MarkdownBlockRule) {
        if (rule.id == markdownBuiltinTaskListRuleId) {
          taskSlot.add(rule);
        } else {
          blockFallback.add(rule);
        }
      } else if (rule is MarkdownInlineRule) {
        inlineFallback.add(rule);
      } else if (rule is MarkdownDecorator) {
        decorators.add(rule);
      }
    }

    for (final rule in ordered) {
      final override = overrideByTarget[rule.id];
      if (override != null) {
        for (final replacement in override.rules) {
          addRule(replacement);
        }
      } else {
        addRule(rule);
      }
    }

    return MarkdownResolvedGrammar(
      taskSlotRules: List.unmodifiable(taskSlot),
      blockFallbackRules: List.unmodifiable(blockFallback),
      inlineFallbackRules: List.unmodifiable(inlineFallback),
      emphasisOverrideRules: _overrideInlineRules(
        overrideByTarget[_emphasisRuleId],
      ),
      linkOverrideRules: _overrideInlineRules(overrideByTarget[_linkRuleId]),
      headingOverrideRules: _overrideBlockRules(
        overrideByTarget[_headingRuleId],
      ),
      decorators: List.unmodifiable(decorators),
      inlineTriggers: {
        for (final rule in inlineFallback) ...rule.triggerCodeUnits,
      },
      ruleOwnerById: Map.unmodifiable(ownerById),
      onExtensionError: onExtensionError,
    );
  }

  List<MarkdownInlineRule>? _overrideInlineRules(
    MarkdownSyntaxOverride? override,
  ) {
    if (override == null) return null;
    return List.unmodifiable(override.rules.whereType<MarkdownInlineRule>());
  }

  List<MarkdownBlockRule>? _overrideBlockRules(
    MarkdownSyntaxOverride? override,
  ) {
    if (override == null) return null;
    return List.unmodifiable(override.rules.whereType<MarkdownBlockRule>());
  }

  /// Validates IDs, API versions, dependency graphs, and replacement targets.
  void validate() {
    final descriptors = <MarkdownSyntaxExtension>[
      ..._extensionRegistrations,
      ..._overrideRegistrations,
    ];
    final byId = <String, MarkdownSyntaxExtension>{};
    for (final extension in descriptors) {
      if (extension.apiVersion != MarkdownSyntaxExtension.apiVersion1) {
        throw ArgumentError(
          'Extension ${extension.id} uses unsupported API version '
          '${extension.apiVersion}.',
        );
      }
      if (extension.id.isEmpty || byId.containsKey(extension.id)) {
        throw ArgumentError(
          'Duplicate or empty extension ID: ${extension.id}.',
        );
      }
      byId[extension.id] = extension;
    }
    for (final extension in _extensionRegistrations) {
      if (extension is MarkdownSyntaxOverride) {
        throw ArgumentError(
          'Override ${extension.id} must be registered in overrides.',
        );
      }
    }
    _validateDependencies(byId);

    final ruleIds = <MarkdownSyntaxRuleId>{..._coreRuleIds};
    for (final extension in [
      ..._profileExtensions,
      ..._extensionRegistrations,
    ]) {
      for (final rule in extension.rules) {
        if (!ruleIds.add(rule.id)) {
          throw ArgumentError('Duplicate syntax rule ${rule.id}.');
        }
      }
    }

    final replacedBy = <MarkdownSyntaxRuleId, MarkdownSyntaxOverride>{};
    for (final override in _overrideRegistrations) {
      if (!ruleIds.contains(override.replaces)) {
        throw ArgumentError(
          'Override ${override.id} targets unknown rule ${override.replaces}.',
        );
      }
      final previous = replacedBy[override.replaces];
      if (previous != null) {
        throw ArgumentError(
          'Overrides ${previous.id} and ${override.id} both replace '
          '${override.replaces}.',
        );
      }
      replacedBy[override.replaces] = override;
      final isInlineSlot = _inlineRuleIds.contains(override.replaces);
      final isBlockSlot = _blockRuleIds.contains(override.replaces);
      for (final rule in override.rules) {
        if (isInlineSlot && rule is! MarkdownInlineRule) {
          throw ArgumentError(
            'Override ${override.id} replaces inline rule '
            '${override.replaces} with a non-inline rule.',
          );
        }
        if (isBlockSlot && rule is! MarkdownBlockRule) {
          throw ArgumentError(
            'Override ${override.id} replaces block rule '
            '${override.replaces} with a non-block rule.',
          );
        }
      }
    }
  }

  void _validateDependencies(Map<String, MarkdownSyntaxExtension> byId) {
    final states = <String, int>{};

    void visit(MarkdownSyntaxExtension extension) {
      final state = states[extension.id] ?? 0;
      if (state == 1) {
        throw ArgumentError('Cyclic extension dependency at ${extension.id}.');
      }
      if (state == 2) return;
      states[extension.id] = 1;
      for (final dependency in extension.dependencies) {
        final target = byId[dependency];
        if (target == null) {
          throw ArgumentError(
            'Extension ${extension.id} depends on missing extension '
            '$dependency.',
          );
        }
        visit(target);
      }
      states[extension.id] = 2;
    }

    for (final extension in byId.values) {
      visit(extension);
    }
  }

  static const MarkdownSyntaxRuleId _emphasisRuleId = MarkdownSyntaxRuleId(
    'commonmark.inline.emphasis',
  );
  static const MarkdownSyntaxRuleId _linkRuleId = MarkdownSyntaxRuleId(
    'commonmark.inline.link',
  );
  static const MarkdownSyntaxRuleId _headingRuleId = MarkdownSyntaxRuleId(
    'commonmark.block.heading',
  );

  static final _coreRuleIds = <MarkdownSyntaxRuleId>{
    _emphasisRuleId,
    _linkRuleId,
    _headingRuleId,
  };

  static final _inlineRuleIds = <MarkdownSyntaxRuleId>{
    _emphasisRuleId,
    _linkRuleId,
    const MarkdownSyntaxRuleId('live_markdown_editor.inline.strikethrough'),
    const MarkdownSyntaxRuleId('live_markdown_editor.inline.highlight'),
  };

  static final _blockRuleIds = <MarkdownSyntaxRuleId>{
    _headingRuleId,
    const MarkdownSyntaxRuleId('live_markdown_editor.block.table'),
    markdownBuiltinTaskListRuleId,
  };
}
