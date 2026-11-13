## 0.11.0 - 2026-09-10

- **Feat:** Opt-in gutter with source-stable line numbers and fold affordances
  for Raw and Live (`LiveMarkdownEditor(gutter: MarkdownGutterConfiguration(...))`).
  Headings fold their section; list items, blockquotes, and fenced code fold
  beneath their first line. The gutter sits on the document's resolved-direction
  side and never lays out as a child, so tables and wrapped lines stay aligned.
- **Feat:** `MarkdownEditorController` owns fold state (`toggleFoldAt`,
  `foldedBlockStarts`, `setFoldedBlockStarts`, `clearFolds`) as view state: it
  is shared across modes and surfaces, is never an undo step, shifts through
  edits, and collapses the caret when a fold hides it.
- **Change (documented):** Raw is the exact source identity while nothing is
  folded; a user fold collapses its lines visually without changing canonical
  text, selection, or clipboard (which still copies exact source). Read renders
  the complete document and ignores fold state.
- **Fix:** Gutter numbers align against the fold slot rather than the outer
  padding, so they no longer drift away from the arrow on documents with
  multi-digit line numbers.
- **Fix:** The fold chevron carries the paint offset — it scrolls with its
  heading instead of staying screen-anchored — and the hovered affordance is
  re-evaluated while scrolling moves rows under the pointer.
- **Fix:** A fold leaves no rendering behind: tables inside a folded range drop
  their layout metadata, and blockquote, rule, and extension decorations inside
  a fold are not painted.
- **Example:** the demo is now a four-plate casebook where every content plate
  covers the complete surface, with the gutter enabled by default and studio
  toggles for line numbers and folding.

## 0.10.1 - 2026-09-10

- **Perf:** Live and Read rebuilds are far cheaper on large documents:
  projection text boundaries are walked in order instead of rescanned per text
  gap, source-position mapping binary-searches its entries instead of scanning
  them (this also removes ~87 % of caret hit-test time), and one shared line
  index replaces per-task/quote/rule `substring` + newline scans. Styled-table
  layout lookups are precomputed and per-line metrics are computed lazily.
- **Perf:** 100k-fixture stage p50s on the reference host: initial live
  projection/layout **2662 ms → 411 ms**, width/theme invalidation
  **3097 ms → 340 ms**, mode switch **1950 ms → 368–395 ms**, caret hit test
  **0.267 ms → 0.036 ms**. Parse (48 ms) and incremental parse (2.7 ms) are
  unchanged. Full table and method notes in `doc/performance.md`.

## 0.10.0 - 2026-09-10

- **Feat:** Every syntax profile now parses through the open-container engine;
  the legacy flat block parser was removed. `commonMarkSafe` and
  `editorDefaults` differ only in the built-in descriptors they install, so
  the default grammar gains nested blockquotes, tight/loose lists with nested
  items, lazy quote continuation, and multi-paragraph list items.
- **Fix:** Blockquote decorations are emitted per hard line with that line's
  resolved direction, so a wrapped quote that mixes LTR and RTL lines keeps a
  correctly sided gutter for each line.
- **Fix:** Indented code strips exactly four columns per line, fenced code
  content keeps its relative indentation, and table recognition interrupts
  paragraph and Setext accumulation under `editorDefaults`, matching the
  CommonMark 0.31.2 official examples.
- **Change:** Task recognition is consulted per list item and remains gated by
  the installed grammar: `editorDefaults` renders `[ ]`/`[x]` controls, while
  `commonMarkSafe` keeps the markers literal. Extension overrides targeting the
  built-in task-list rule keep working.
- **Migration notes:** The flat parser's per-line `taskListItem`/
  `unorderedListItem`/`orderedListItem` top-level nodes are no longer produced;
  items are `listItem` children of `list` containers and `checked` state lives
  on the item. Community extensions may still construct `taskListItem` nodes
  and renderers keep supporting them.

## 0.9.0 - 2026-09-02

- **Feat:** CommonMark 0.31.2 block and inline parsing (ATX and Setext
  headings, thematic breaks, fenced and indented code, blockquotes, tight and
  loose lists, link reference definitions, links, images, autolinks, code
  spans, emphasis and strong emphasis, entities, and backslash escapes).
  Raw HTML is deliberately excluded and stays literal in every mode; the
  compatibility claim is "CommonMark 0.31.2 except raw HTML". Official
  conformance examples are pinned in `test/fixtures/commonmark/0.31.2` and run
  in CI; the two raw-HTML sections are the only section-level exclusions.
- **Feat:** Standard Markdown images render as bounded widgets with alt-text
  fallback and semantics; `MarkdownMediaBuilder` lets cached-image packages
  replace the default network/asset widget. The core adds no caching or
  filesystem dependency.
- **Feat:** Public syntax-extension API: additive `MarkdownSyntaxExtension`s
  and explicit `MarkdownSyntaxOverride`s register through
  `MarkdownSyntaxConfiguration`; validated presentations, per-editor sessions,
  semantics, and pure editing rules run inside guarded boundaries with
  `onExtensionError` diagnostics. Invalid or throwing extensions literalize
  their construct and never corrupt canonical source or mapping.
- **Feat:** Incremental parsing now reuses stable top-level subtrees across
  edits with checkpoint convergence, external reference definitions, and
  definition-index invalidation; 100k initial parse p95 ≤ 100 ms and
  single-line incremental p95 ≤ 16 ms on the reference host.
- **Perf:** Parsing and rendering remain source-preserving and deterministic;
  benchmark results for both the editor-default and core-safe profiles are
  recorded in `doc/performance.md`.
- **Migration notes:** `MarkdownSyntaxExtension` descriptors now extend an
  abstract class with defaulted hooks (`createSession`, `presentBlock`,
  `presentInline`, `editingRules`); the barrel exports the extension-authoring
  types (nodes, parse contexts, presentation). Raw mode is the exact source
  identity in every surface; inactive Live and Read hide supported syntax and
  reveal it at the caret.

## 0.8.1 - 2026-08-31

- **Fix:** The hover scrollbar for a wide table now supports native thumb
  dragging without moving the text selection.
- **Fix:** Raw mode now keeps GFM tables as literal Markdown source. It no
  longer applies column layout, table scrolling, borders, or a hover scrollbar
  to source rows.

- **Fix:** Wide tables now follow direct touch drags instead of moving in the
  reversed direction. Table panning is limited to touch input on any
  touchscreen; mouse and stylus drags remain text selection, while long-press
  or double-tap plus selection handles remains the touch-selection path.
- **Fix:** Linux-style trackpad pan/zoom events now scroll wide tables alongside
  the existing horizontal pointer-scroll protocol used by web and desktop.
- **Feat:** Hovering a wide table reveals a proportional, framework-neutral
  horizontal scrollbar in light and dark editor themes.

## 0.8.0 - 2026-08-30

- **Feat:** Tables are fully themeable with collapsed or separated borders,
  solid/dashed/dotted sides, outer and cell radii, directional padding,
  independent row/column gaps, layered backgrounds, header/body typography,
  and a source-indexed per-cell resolver. The default remains borderless and
  preserves the previous table appearance.
- **Fix:** Styled tables no longer reserve a blank separator row, leave gaps
  between collapsed cells, or paint only fragments of shared edges. Vertical
  padding now participates in row geometry, and wider/later per-cell sides win
  collapsed conflicts deterministically.
- **Fix:** Table paint, text, caret, selection, hit testing, horizontal scroll,
  and mixed LTR/RTL layout now consume the same cell slots. Styling does not
  change canonical Markdown or projection offsets.

## 0.7.2 - 2026-08-30

- **Fix:** Interactive parts inside the editor (task toggles, links) keep the
  click cursor on hover. Links previously resolved to the text cursor, and on
  web the engine's transparent editing overlay forced the writing cursor over
  the whole focused surface; the overlay cursor now follows the framework's
  hover resolution.
- **Feat:** Rebuilt the example as a cool-neutral, editor-first responsive
  studio. Phones keep only a compact mode row while documents, settings,
  appearance, and Foundation/Material/Cupertino previews open on demand;
  tablet and desktop progressively reveal more workspace context.
- **Fix:** Tables now use explicit source-indexed column slots. Mixed Arabic,
  English, and numeric values align with their matching headers without
  overlap, while Raw and active Live keep visible pipes structurally between
  per-cell bidi paragraphs instead of reordering the whole row.

## 0.7.1 - 2026-08-29

- **Fix:** RTL tables sit at the right edge of the viewport in every mode,
  with columns flowing right-to-left (the first source column at the far
  right), so headers and values stay aligned; an LTR table keeps source
  order. Only the row's placement follows the line direction.
- **Fix:** An active Live table (caret inside, pipes revealed) renders each
  row as one paragraph in the table's direction, exactly like Raw, so every
  row agrees on column order; the row keeps its horizontal viewport for
  typing in wide tables.
- **Fix:** Activating a table that follows hidden syntax (a heading, task
  marker, or fence prefix) no longer throws while resolving whole-row
  chunks — row matching is source-order-based, not offset-based.

## 0.7.0 - 2026-08-28

- **Feat:** GFM pipe-table support end to end. Parser recognizes tables with
  alignment separators (`:---`, `---:`, `:---:`), escaped pipes, and pipes in
  code spans.
- **Feat:** Live mode hides pipes and the separator row outside the caret and
  aligns columns from measured cell widths; Read mode strips delimiters and
  pads to aligned columns; Raw mode stays literal.
- **Feat:** Bidi-aware tables: every cell is its own paragraph with its own
  base direction; table direction drives column order and alignment.
- **Feat:** Tables wider than the editor scroll horizontally in place
  (drag, trackpad, semantics scroll actions); typing beyond the visible edge
  auto-reveals the caret.
- **Feat:** Obsidian-style editing: Enter splits the row and inserts a new
  row, Tab/Shift+Tab move between cells (Tab on the last cell appends a row),
  and deletion never removes pipes, row newlines, or separator hyphens —
  edits crossing the table boundary stay unrestricted. Separator-row typing
  is a no-op.

## 0.5.5 - 2026-08-27

- **Fix:** Caret geometry now matches the tight glyph box used by selection
  highlights. A caret in a heading follows the heading's selected-text height
  (including wrapped heading lines), rather than inheriting body-size or full
  line-box height.
- **Fix:** Selection handles use each endpoint's own caret geometry, so a
  handle on a heading follows that heading's selection-height caret rather
  than the first line's height.
- **Fix:** An ordinary touch/stylus tap now places a caret without showing a
  collapsed selection handle. Long-press/double-tap word selection and handle
  dragging retain touch handles.

## 0.5.4 - 2026-08-27

- **Fix:** Ordered task items (`1. [ ]`, `3) [x]`) now parse, render, and
  toggle exactly like bullet tasks; smart-list continuation increments the
  number (`1. [ ]` + Enter → `2. [ ]`), and backspace exits an empty ordered
  task line.
- **Fix:** Code spans support multi-backtick delimiters (`` ``code`` ``) with
  CommonMark run-length matching, so a longer backtick run no longer closes a
  shorter opener.
- **Fix:** Inline links accept an optional quoted title
  (`[label](url "title")` / `[label](url 'title')`) parsed separately from the
  destination instead of being folded into it.
- **Fix:** Ordered task items keep their numeric prefix visible beside the
  checkbox in Live mode. When the caret or composing range touches `[ ]` or
  `[x]`, the literal ordered marker is revealed for editing; a selection that
  merely crosses the marker keeps the checkbox control.
- Expanded the example casebook with ordered tasks, multi-backtick code-span
  cases, and titled links so the newly supported behavior is directly
  testable.

## 0.5.3 - 2026-08-26

- **Fix:** Preserved the newline after an inactive fenced code block so the
  first RTL heading after code keeps its correct right-to-left alignment.
  Added a regression test covering the source-to-visual direction mapping.

## 0.5.2 - 2026-08-26

- **Fix:** Ordered list (`1.`, `2.`) and unordered list (`-`, `*`, `+`) item
  prefixes remain persistently visible in Live mode, styled with the muted text
  color, rather than disappearing when the caret is on another line.

## 0.5.1 - 2026-08-26

- The editor now consumes the published `native_adaptive_toolbox` 0.1.0
  (hosted on pub.dev) instead of a sibling path.
- Redesigned the example as the **Manuscript Casebook**: an editorial,
  bilingual showcase with bundled Fraunces/Amiri/IBM Plex Sans typography,
  a light and a dark palette, a casebook rail with curated documents
  (English field notes, an Arabic manuscript with tasks/headlines/quotes,
  a mixed-bidi proof, and a blank folio), and fully responsive layouts for
  phone, tablet, desktop, and short landscape viewports. The editor keeps
  its framework-neutral, Material, and Cupertino host proof.
- Settings chrome adapts to short viewports: the press sheet collapses to
  a single header row (tap to expand), the stats ticker hides, and the
  masthead compacts in two height tiers, so the editor always owns most of
  the screen.

## 0.5.0 - 2026-08-26
