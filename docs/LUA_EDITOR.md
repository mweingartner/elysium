# Lua Editor

This document is the durable product and implementation reference for Elysium's native Lua
authoring window. The scripting language and runtime contract remain defined by
[`SCRIPTING_GUIDE.md`](SCRIPTING_GUIDE.md); this file describes editing assistance only.

## Scope and trust boundary

The editor works with the shipped deterministic Lua 5.4.8 sandbox. It does not add libraries,
permissions, globals, methods, event names, or mutation paths to that sandbox. On a host, Save uses
the same validated `ScriptStore` attach path as `/script attach`, Run uses the same
`ScriptRuntime.runEphemeral` path as `/script run`, and Check performs the editor-only
`ScriptRuntime.dryRun` without persisting. Handler Check executes a known built-in event with
deterministic, non-null representative values from `EventDescriptorRegistry`; custom events compile
only because their payload shape is not declared, and the status distinguishes that case from an
executed pass. A granted LAN guest forwards Save and Run to the host; Check is not available to a
guest.

Editor analysis is read-only and has two deliberately separate planes:

1. The **language plane** is local and deterministic. It owns syntax and semantic styling,
   completion, signatures, documentation, diagnostics, snippets, and nearby-object discovery.
2. The **proposal plane** is optional Ollama output. It can propose insertion text, but it does not
   change the deterministic completion catalog, execute Lua, receive tools, save a script, or mutate
   the world. Its text is untrusted and can be wrong; Check, Save, and the runtime remain authoritative.

All language-plane features remain available when Ollama is stopped or editor AI is disabled.

## Opening and layout

Use `/script edit [target] [name]`, Command-E while looking at an object, or **Edit Script** in the
Object Inspector. The detached native window pauses the local simulation while it is open.

The window has three working areas:

- The left side lists scripts and switches between **Snippets** and **World Objects**.
- The center contains target/mode/event controls, the source editor, signature/diagnostic status,
  and Save, Check, and Run.
- The optional right side is document-scoped Script AI. It is not the world-mutating `/ai` agent.

Handler mode shows an editable event name plus a menu of shipped built-in events and their
descriptions. A validated custom event name can still be typed directly.

The model tracks whether source or script metadata differs from the last clean state and shows an
orange **Unsaved** marker beside the target. Switching scripts, closing the window, or quitting the
application then offers Save, Discard, and Cancel. On a LAN guest, existing source remains hidden. Selecting it explains
that Save replaces the complete source; navigation/close prompts repeat that warning, and a direct
Save requires an explicit **Send Full Replacement** confirmation before the request goes to the
host. A new or renamed script cannot replace another record silently, and a host editor also asks
before replacing a same-name script that changed after the window loaded it.
Destructive confirmation carries the exact authoritative record snapshot displayed by the alert;
if that record changes again while the modal is open, Save refuses and requires a fresh review.

An editor is bound to the exact world session in which it opened. If that session ends, its draft
remains available to copy, but Save, Run, Check, object insertion, deletion, and other world-backed
actions refuse to operate on a later world. For an existing host script, ordinary source edits
preserve its enabled state. Handler saves preserve additional triggers and the first trigger's
filter and target while editing the first event name exposed by this UI.

## Language schema

`ElysiumCore.ScriptLanguageSchema` is the editor's catalog for globals, modules, callable labels,
handle members, receiver-kind restrictions, documentation, snippets, and availability. The runtime
remains authoritative. `AttributeRegistry` supplies built-in attribute names, types, mutability,
and applicability metadata. For `self` and direct aliases of the current host target, completion
filters built-in attributes against the live resolved object's applicability; guest targets and
other inferred handles use the catalog's kind-level information. `EventDescriptorRegistry`
describes the published built-in event catalog while preserving the runtime's open, validated
custom-event namespace.

The catalog also produces a non-executing LuaCATS definition string with real parameter and return
annotations plus overloads from the schema. Engine globals and the `objects`/`ai` modules are ordered
near the start so they remain inside the bounded AI schema prefix; the longer per-kind attribute and
event-class tail can still be truncated. Tests compare the runtime binding tree with the schema,
probe completable symbols in the shipped sandbox, project attribute and built-in event registries,
check representative LuaCATS signatures, validate every palette snippet, and reject historical bad
spellings. They do not prove every event producer payload or live applicability decision.

## Styling and analysis

The editor paints lexical tokens, then overlays resolved semantic roles. Current lexical categories
are keywords, strings, numbers, and comments; punctuation and operators use the ordinary text color.
Semantic roles include:

- locals, parameters, functions, and inferred table fields;
- Elysium globals and modules;
- object handles, methods, properties, built-in attributes, and live custom attributes;
- event names and known event payload fields; and
- a fixed set of unavailable sandbox globals.

Read-only metadata and accepted-but-currently-no-op status appear in completion documentation, but
do not currently receive distinct source styles. TextKit ranges use UTF-16 offsets throughout.
Local language analysis is synchronous and error tolerant; it is recalculated from the current
source rather than published asynchronously. Ollama proposals separately carry document and context
identity so a stale response is not inserted.

## Completion

Typing `.` or `:` opens the member flyout immediately, including when no prefix follows the
separator. A nonempty ordinary identifier prefix also opens keyword/global completion while typing.
Control-Space explicitly requests completion, including with an empty prefix.

The receiver determines the candidates:

| Context | Result |
|---|---|
| host `self.` / a direct target alias followed by `.` | handle properties and live-applicable built-in fields whose names are valid after a dot |
| guest `self.` | handle properties and kind-level built-in fields whose names are valid after a dot |
| `player.` / another inferred handle followed by `.` | handle properties and kind-level built-in fields whose names are valid after a dot |
| `handle:` | generic handle methods plus kind-specific methods such as block replacement |
| `self.attrs.` or a straightforward alias | live custom attributes for the editor target only |
| `objects.` | `get`, `find`, and `block` |
| `ai.` | `ask` and `await` |
| handler `ev.` or a locally declared callback event | common event fields and payload fields for the known event |
| `math.`, `string.`, `table.`, `utf8.` | only the sandbox allowlist |
| a locally inferred table literal followed by `.` | that table's known named fields |

Rows visibly contain a symbol-kind icon, name, and signature/type detail. A documentation pane shows
the selected item's description and read-only state; provenance is retained internally but is not
currently displayed. Filtering supports prefix, substring, acronym/CamelCase, and subsequence
matches. Ranking is deterministic and favors exact, receiver-valid, local, and live-object results.

The service infers `self`, `world`, and `player`; straightforward preceding local aliases and table
literals; and the direct return shapes of `objects.get`, `objects.block`, and `objects.find`.
Implicit `ev` is offered only in handler mode; callback parameters and other local declarations are
offered from the document. Inference does not yet model lexical scope, infer the loop value of
`objects.find`, or consume user LuaCATS annotations. Generated definition text is never loaded or
executed by the sandbox.

### Completion keys

| Key | Action |
|---|---|
| Control-Space | Open deterministic completion |
| Up/Down | Change the selected result |
| Return or Tab | Insert the selected deterministic result |
| Escape | Close deterministic completion, or dismiss a visible AI proposal when completion is closed |
| Tab with a selected line or lines | Indent the selected lines by two spaces |
| Shift-Tab with a selected line or at a caret | Outdent the affected line or lines |
| Command-S | Save through the authoritative attach path |
| Command-F | Open the native Find panel |
| Command-Plus / Command-Minus | Increase or decrease editor text size |
| Command-0 | Reset editor text size |

There is no snippet-placeholder mode yet. Tab accepts deterministic completion first, then a visible
AI proposal; with no selection it otherwise inserts two spaces, and with selected text it indents
the selected lines. Shift-Tab outdents lines. Option-Return has no editor-specific quick-fix behavior.

## Diagnostics and signatures

Signature help recognizes cataloged calls after `(` and commas. Engine signatures carry typed
parameter/return descriptors and overloads; Lua standard-library parameter names and counts are
derived from their display labels, with general `any` parameter types where the catalog has no more
specific type. Diagnostics are advisory while editing; the runtime validator remains authoritative
for Save, Check, and Run. Current editor diagnostics cover unmatched `()[]{}`, a fixed
set of unavailable globals, invalid or reserved event names in recognized calls, unsupported
`pairs(handle.attrs)`, wrong `.`/`:` member access, unknown members on inferred closed receivers, and
direct assignment to a cataloged read-only dotted member. The language service has checks for
non-yieldable `wait`/`ai.await`. Ordinary editing is analyzed as yieldable because attached module
and handler scripts may suspend. The immediate **Run** action repeats that check in its
non-yieldable context, selects the offending call, and directs the author to Save instead. **Check**
uses a throwaway coroutine: it accepts and closes at the first legal suspension without scheduling
work or contacting AI, so a valid attached `while true do wait(...) end` loop is not falsely failed.
Its success status explicitly says that source after that suspension was not executed. The shallow
symbol table keeps locally shadowed `wait` and `ai` values out of these diagnostics. Run and Check
use isolated transient RNG streams rather than changing any attached script's persisted sequence.

The editor does not yet diagnose general Lua grammar, undefined globals, wrong arity, or
accepted-but-no-op calls. Available quick fixes appear as buttons in the Problems pane and apply
immediately; there is no preview command. Quick fixes, palette insertions, and other ranged
model-driven edits are bridged through `NSTextView` insertion and participate in native undo. A
whole-document load/new/script-switch boundary clears the prior document's undo history.

## World Objects

On a host, the World Objects browser snapshots the `ObjectGraph`, `AttributeStore`, and `ScriptStore`
read paths used by scripting commands. A LAN guest instead combines its client-side graph with
replicated attribute and script metadata; it receives no host-only discovery surface. The snapshot
includes the script target, player, world, current dimension, crosshair target, nearby live
entities/players, and nearby blocks that already carry object records. It does not scan every
ordinary terrain cell while typing.

The default nearby query is radius 16 and limit 32. Rows show display name, exact canonical ref,
kind, distance, live/stale status, custom-attribute count, and script count. Search matches names,
refs, and kinds. Rows can be pinned and can insert either:

```lua
objects.get("block:overworld:10,64,3")
```

or a stable local binding:

```lua
local door = objects.get("block:overworld:10,64,3")
```

Display names are never used as identity. Object-reference completion includes live entries only.
The palette can retain a missing pinned ref as a visibly stale row, but its Insert and Bind controls
are disabled; the model also rechecks liveness immediately before any insertion. The host validates
every explicit ref sent by a granted guest. The LAN protocol does not replicate a custom attribute's
read-only bit; guest completion therefore cannot promise mutability, and the host remains
authoritative for writes.

## Optional Ollama completion

Editor AI has three modes:

- **Off** — editor completion, panel prompts, and editor model discovery do not contact Ollama.
- **Manual** — the default; only an explicit request contacts Ollama.
- **On Idle** — optional; an explicit user preference requests after a short typing pause.

Use **Edit > Request AI Suggestion** or Option-Command-/ in Manual or On Idle mode. The exact
local model selected under Options > AI is used. Cloud-tagged model names remain refused. Selecting
a model does not enable On Idle. The chosen editor-AI mode persists across application sessions;
switch back to Manual or Off whenever automatic requests are no longer wanted. Opening the panel does not enumerate models: **Load local models**
or **Refresh local models** starts that request explicitly. Model discovery is canceled when the
panel closes, editor AI switches Off, or the world session ends.

The read-only completion request is bounded to source before/after the caret, script mode/event,
current diagnostics, and a small caller-authorized World Objects projection. It contains no tools,
mutation context, save data, unrelated scripts, raw world state, or hidden LAN data. It includes the
first 6,000 characters of the generated LuaCATS text. Engine globals and modules are deliberately
ordered into that prefix, while later per-kind attributes and event classes can still be omitted;
the runtime validator, not this prompt, remains the API authority.

`/api/show` metadata is fetched as advisory model information. The product currently uses the safe
cursor-marker prompt path and always disables Ollama's fill-in-the-middle `suffix` field. The service
has an internal explicit-FIM policy seam, but there is no product preference for it and model-hint
compatibility is not currently an enforcement gate.

Production editor requests use the numeric loopback endpoint `127.0.0.1`, an ephemeral URL session
with system proxies, caches, cookies, and credential storage disabled, and a delegate that rejects
all HTTP redirects. Model-list, metadata, and generation responses are incrementally byte-bounded
before decoding; generated text is also capped by character and line counts. These transport limits
contain the reply but do not make its Lua correct.

AI output appears as visually distinct ghost text labeled with the selected model. It is never
mixed into deterministic member results. Before display it is bounded and checked for safe text and
document size, but it is not compiled or schema-validated; use Check before relying on it.

| Key | AI action |
|---|---|
| Option-Command-/ | Request one proposal |
| Tab | Accept the visible proposal |
| Command-Right | Accept the next word of a visible proposal |
| Command-Control-Right | Accept the next line of a visible proposal |
| Escape | Cancel an in-flight inline request or dismiss its visible proposal |

In the Script AI input, Return submits, Shift-Return inserts a newline, and Up/Down recall prompt
history only when the caret is on the first/last line respectively; otherwise they move the caret.

Every request carries the document revision, UTF-16 caret, source hash, model, target, mode/event,
and authoring-context revision. Editing, moving the caret, switching target/script/model, refreshing
World Objects, pressing Escape, or ending the world session cancels the inline request and makes late
responses ineligible for insertion. The right-hand Script AI panel owns its task separately:
**Stop**, closing the panel, switching AI Off, or ending the world session cancels it, while other
document/context changes make its eventual response stale before it can be used against the changed
document.

The panel asks Ollama not to use Markdown fences, and the service strips a fence wrapper when one is
returned. After reviewing any successful reply, the user can explicitly insert the complete bounded
reply at the editor cursor; insertion is never automatic.

## Accessibility and performance

- Source text and chrome use scalable system typography; the code font remains monospaced.
- Completion rows expose name, kind, detail, and read-only state to VoiceOver. World Objects rows
  expose display name, kind, liveness, canonical ref, and metadata counts.
- Diagnostics and object liveness use icons/text in addition to color. Completion selection uses the
  native table selection highlight and accessibility selection state; it has no extra visible marker.
- The source editor, deterministic completion, visible AI proposal, line indent/outdent, and ordinary
  SwiftUI controls are keyboard reachable. Snippet navigation and keyboard quick-fix preview are
  future work.
- Sub-50 ms local completion at the 16 KiB source maximum is a performance target, not a measured
  release guarantee. Current analysis rescans synchronously after an edit.
- World Objects refresh explicitly and never scan on each keystroke.
- Ollama transport work is asynchronous. Inline work is canceled on editor changes; panel work has
  its separate **Stop** action. Neither path blocks editing or Save/Run.

## Verification

Changes to this editor require, proportionate to the affected surface:

```bash
swift build -c release
swift test
bash scripts/security-scan.sh
swift run -c release elysmoke
```

Release/deployment readiness additionally requires `bash scripts/pipeline.sh`, which packages and
installs the verified candidate at `/Applications/Elysium.app`. The automated editor suites exercise
the lexer, language service, proposal service, schema, snippets, and editor model; focused windowless
AppKit tests also cover the nonactivating completion panel's focus and reuse lifecycle. They do not
replace rendered toolbar, mouse, or VoiceOver proof. When a UI-affecting change is released, manually
verify observable keyboard, mouse, accessibility, and installed-app behavior under `caffeinate`, and
stop the task-owned keep-awake process afterward.

## Future authoring targets

The following remain design targets rather than delivered behavior:

- a scope-aware Lua parser, general syntax/undefined-name/arity diagnostics, and LuaCATS annotation
  ingestion, including `objects.find` loop-value inference;
- richer completion rows that visibly identify provenance and mutability, more precise types for
  standard-library parameters, and editing of every persisted trigger/filter/target rather than
  only the first trigger's event name;
- snippet placeholders with forward/backward navigation and previewable quick fixes;
- replication of enough LAN attribute metadata to show mutability accurately;
- a context-tailored AI schema projection that keeps every relevant per-kind/event definition inside
  its bound, model-compatible FIM gating if FIM is exposed, and optional preflight of AI proposals
  before display; and
- measured completion latency plus installed-app keyboard, mouse, and VoiceOver regression coverage.
