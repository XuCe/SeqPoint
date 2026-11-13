# SeqPoint patches to live_markdown_editor 0.11.0

Vendored from pub.dev `live_markdown_editor` 0.11.0 (MIT, see LICENSE); only
`lib/` is kept. Wired in through `dependency_overrides` in the workspace
root `pubspec.yaml`. Drop this copy once upstream ships the same fixes.

Symptom: typing Chinese on Windows sometimes left pinyin in the note, e.g.
typing 乌镇 produced `wwuwu'z乌镇`. On Windows the engine resets its text
model on `TextInput.setClient` and on `TextInput.setEditingState`, which ends
an in-progress IME composition. After that each pinyin update is inserted as
committed text instead of replacing the composition. Whether it shows depends
on whether the next IME update lands before or after the reset, so it is
intermittent.

## 1. Do not reconnect the platform input on every rebuild

`EditableMarkdown` passes a new `inputFormatters` list and a new
`onSelectionChanged` closure on each build. `MarkdownEditableText` compared
them by identity, replaced its input client, and reconnected
(`clearClient` → `setClient` → `setEditingState`) after every keystroke.

The client now reads formatters and callbacks from the current widget when it
uses them (`inputFormattersOf`), and the client is replaced only when the
controller or `readOnly` changes.

## 2. Do not echo platform values back

`MarkdownEditableText` sent each controller value to the platform one frame
later, including values the platform had just reported. `MarkdownTextInputClient`
now reports platform values through `onPlatformValue`, and the editable records
them as already known to the platform. Only values the app or the editor changed
(formatters, commands, paste via `applyLocalEditingValue`, programmatic edits)
are sent back. This matches Flutter's `EditableText`
(`_lastKnownRemoteTextEditingValue`).

Files: `lib/src/foundation/markdown_text_input_client.dart`,
`lib/src/foundation/markdown_editable_text.dart`.
