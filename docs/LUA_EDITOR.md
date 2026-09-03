# Lua Editor

This document is the durable product and implementation reference for Elysium's native Lua
authoring window. The scripting language and runtime contract remain defined by
[`SCRIPTING_GUIDE.md`](SCRIPTING_GUIDE.md); this file describes editing assistance only.

## Scope and trust boundary

The editor works with the shipped deterministic Lua 5.4.8 sandbox. It does not add libraries,
permissions, globals, methods, event names, or mutation paths to that sandbox. On a local host with
an active script runtime, Save uses the same validated `ScriptStore` attach path as `/script attach`,
and Check performs the editor-only `ScriptRuntime.dryRun` without persisting. Both remain available
when the world is untrusted or `doScripts` is off: Check is read-only, while Save only persists the
validated record and leaves it dormant. If no local runtime exists, Check, Save, and Run Once are
unavailable because authoritative Lua validation cannot be performed; the draft remains available
to copy. Handler Check executes a compatible built-in event with deterministic representative values
from `EventDescriptorRegistry`. It also executes a custom-event handler when that event is declared
on the current target, using representative values from its typed contract. A valid but undeclared
custom event remains compile-only, and the status distinguishes that case from an executed pass.

The local editor's explicit **Run Once** action is the one narrow trust-gate exception. It runs only a
currently visible **module** draft once through the same capability-reduced ephemeral machinery as
`/script run`, without saving or attaching the draft, loading attached scripts, or changing the
world's trust flag. It is not a dry run: permitted one-off verbs can change live game state, and
those changes may persist with the world. It still obeys `doScripts`;
**Run Once** refuses while the kill switch is off. Attached scripts, ordinary
`/script run`, AI `run_script`, and every LAN-forwarded run remain gated by both world trust and
`doScripts`. Handler mode disables Run Once because it cannot safely invent the selected event's
`ev`; use Check for a deterministic representative event or Save and trigger the real event. A
granted LAN guest forwards Save and Run to the host; the local-editor exception is never forwarded,
and Check is not available to a guest.

Editor authoring intelligence has two deliberately separate planes:

1. The **language plane** is local and deterministic. It owns syntax and semantic styling,
   completion, signatures, documentation, diagnostics, snippets, and nearby-object discovery.
2. The **proposal plane** is optional Ollama output. Inline and On Idle results remain ghost text.
   Panel **Ask** is transcript-only; explicit **Write Code** may edit the unsaved draft automatically,
   but only after the response is identity-bound, mode-checked, compiled, and passed through the
   conservative static and mutation-free validation boundaries. The
   plane does not change the deterministic completion catalog, receive tools, save, attach, execute,
   trust, enable scripts, or mutate the world. Its text is untrusted and can be wrong; Check, Save,
   and the runtime remain authoritative.

All language-plane features remain available when Ollama is stopped or editor AI is disabled.

## Opening and layout

Use `/script edit [target] [name]`, Command-E while looking at an object, or **Edit Script** in the
Object Inspector. The detached native window pauses the local simulation while it is open. With an
active local runtime, that UI pause does not disable Check or Save; Run Once is an explicit
synchronous action and follows the trust/kill-switch policy above.

The window has three working areas:

- The left side lists scripts and switches between **Snippets** and **World Objects**.
- The center contains target/mode/event controls, the source editor, signature/diagnostic status,
  and Save, Check, and Run Once.
- The optional right side is document-scoped Script AI. It is not the world-mutating `/ai` agent.

When attached execution is paused, a persistent status banner explains which gate is off and offers
the matching **Trust World**, **Turn On Scripts**, or **Trust & Turn On** action. Each first warns
that every enabled script already attached anywhere in the world may begin running. Only the
confirmed action changes the named gate or gates: trust is persisted, while turning scripts on
changes `doScripts`. Opening the editor, Check, Save, and Run never auto-trust or silently turn the
kill switch on.

Handler mode shows an editable event name plus a target-aware menu: compatible produced built-in
events first, then custom events declared on the current object. Rows expose whether the event is
built-in or declared custom, its payload field names/types/nullability, and its summary. A valid
undeclared custom event name can still be typed directly, with explicit guidance that payload
completion and executed Check are unavailable until that target declares it. `unload` is deliberately
not offered: it has no EventBus producer. A module instead uses `register("unload", fn)` for the
separate synchronous, no-`ev`, custom-attribute-only finalizer; the mode help and schema-backed
snippet explain that distinction to both the author and optional Ollama proposal context.

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
actions refuse to operate on a later world. In the valid local session, trust and the kill switch do
not make the document read-only: Check remains read-only, Save remains persistence-only, and the
explicit Run policy above applies. For an existing host script, ordinary source edits preserve its
enabled state. Handler saves preserve additional triggers and the first trigger's filter and target
while editing the first event name exposed by this UI. If that first event changes away from
`attribute.changed`, its now-inapplicable attribute filter is cleared before Save; the target and
remaining triggers are still preserved.

## Language schema

`ElysiumCore.ScriptLanguageSchema` is the editor's catalog for globals, modules, callable labels,
handle members, receiver-kind restrictions, documentation, snippets, and availability. The runtime
remains authoritative. `AttributeRegistry` supplies built-in attribute names, types, mutability,
and applicability metadata. For `self` and direct aliases of the current host target, completion
filters built-in attributes against the live resolved object's applicability; guest targets and
other inferred handles use the catalog's kind-level information. `EventDescriptorRegistry`
describes the published built-in event catalog while preserving the runtime's open, validated
custom-event namespace. `CustomEventStore` contributes the current target's persisted declarations,
so editor event facts are object-scoped rather than treated as a global custom-event registry. A LAN
guest uses the host's bounded, source-free mirror of names, field type tokens, and summaries for the
same projection.

The app additionally projects the current script-sound catalog into each language environment.
That list is live rather than a copied constant: it combines validated imported WAV names with
standard names discovered from `/System/Library/Sounds` and macOS ToneLibrary. The runtime remains
authoritative for case-insensitive name resolution and can still refuse playback after completion.

The catalog also produces a non-executing LuaCATS definition string with real parameter and return
annotations plus overloads from the schema. Engine globals and the `objects`/`ai` modules are ordered
near the start so they remain inside the bounded AI schema prefix; the longer per-kind attribute and
event-class tail can still be truncated. The separate bounded authoring context always carries the
current mode contract and prioritizes the selected Handler event with its whole payload schema, up
to the declaration cap. Every included compatible event is whole; explicit total, included, and
truncated counts identify any contracts that the fixed prompt budget omitted. For Module source, it
carries produced built-in payloads plus kind-compatible names and declared custom events for objects
in the bounded authorized snapshot. Nearby custom events are likewise included only as whole
contracts, with per-object and snapshot omission metadata; the model is told never to infer an
omitted schema. A selected open custom Handler event is identified as envelope-only with unknown
event-specific fields. These facts remain truthful even when either bounded section clips less
relevant entries. Current-target method facts rewrite generic documentation receivers to the real
`self` local, and the prompt explicitly states that `h`, `target`, `block`, and `furnace` are not
globals. An unresolved `h` is also a deterministic editor error with a `self` quick fix, and an AI
proposal containing it is refused before insertion. Furnace targets are taught the lifecycle-scoped
`self:setFurnaceOutput(item)` capability and the engine-produced `furnace.smeltCompleted` payload instead of
being encouraged to write read-only `be.items[2]` or treat `block.changed` as smelt completion.
Tests compare the runtime binding tree with the schema, probe completable symbols in
the shipped sandbox, project attribute and event registries, check representative LuaCATS signatures,
validate every palette snippet, and reject historical bad spellings. The palette now uses the shipped
callback parameter (`ev`), global/object `emit`, `h:attach`, `block:setBlock`/`breakBlock`, and
`objects.find`/`objects.block` spellings; the earlier mismatched forms are not retained as snippets.
These checks do not by themselves prove every producer call site or live applicability decision.

## Styling and analysis

The editor paints lexical tokens, then overlays resolved semantic roles. Current lexical categories
are keywords, strings, numbers, and comments; punctuation and operators use the ordinary text color.
Semantic roles include:

- locals, parameters, functions, and inferred table fields;
- Elysium globals and modules;
- object handles, methods, properties, built-in attributes, and live custom attributes;
- event names and known event payload fields; and
- a fixed set of unavailable sandbox globals.

Read-only metadata and the remaining accepted-but-currently-no-op status (such as `particles`)
appear in completion documentation, but
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
| `handle:` | generic handle methods, including `events`, `declareEvent`, `undeclareEvent`, `on`, `onAttribute`, and `emit`, plus kind-specific methods such as block replacement |
| `self.attrs.` or a straightforward alias | live custom attributes for the editor target only |
| `on("` / `self:on("` | built-in events compatible with the current target plus its declared custom events |
| `emit("` / `self:emit("` | only custom events declared on the current target; engine-produced built-ins are not manually emittable |
| first argument of `sound(` / `sound("` | currently playable imported and macOS sound names; imported names are ordered before built-ins |
| `objects.` | `get`, `find`, and `block` |
| `ai.` | `ask` and `await` |
| handler `ev.` or a locally declared callback event | common event fields and payload fields for the compatible built-in or target-declared custom event |
| `math.`, `string.`, `table.`, `utf8.` | only the sandbox allowlist |
| a locally inferred table literal followed by `.` | that table's known named fields |

Sound-name completion is limited to `sound`'s first argument. It replaces the whole string token
with a canonical double-quoted Lua literal, escaping quotes, backslashes, and line controls; an
unquoted first argument receives the same quoted form. Names are matched and ranked locally,
case-insensitively, with the app's catalog order as the deterministic tie-break. **Options... →
Audio → Script Sounds...** imports, previews, and deletes managed `.wav` files; catalog-change
notifications refresh editor environments. Imported names cannot shadow built-ins, so completion
and runtime resolve the same name. A LAN guest uses the host-published catalog because its scripts
execute and play audio on the host; changes arrive with host world-summary replication.

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
for Save, Check, and Run Once. Current editor diagnostics cover unmatched `()[]{}`, a fixed
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
Check and automatic proposal validation also use a fixed validation identity, so they do not
consume the live scheduler/RNG ordinal.

The editor does not yet diagnose general Lua grammar, undefined globals, wrong arity, or remaining
accepted-but-no-op calls such as `particles`. Available quick fixes appear as buttons in the
Problems pane and apply immediately; there is no preview command. Quick fixes, palette insertions, and other ranged
model-driven edits are bridged through `NSTextView` insertion and participate in native undo. A
whole-document load/new/script-switch boundary clears the prior document's undo history.

## World Objects

On a host, the World Objects browser snapshots the `ObjectGraph`, `AttributeStore`, and `ScriptStore`
read paths used by scripting commands. A LAN guest instead combines its client-side graph with
replicated attribute, script, and custom-event metadata; it receives no host-only discovery surface.
The snapshot includes the script target, player, world, current dimension, crosshair target, nearby
live entities/players, and nearby blocks that already carry object records. It does not scan every
ordinary terrain cell while typing.

The default nearby query is radius 16 and limit 32. Rows show display name, exact canonical ref,
kind, distance, live/stale status, custom-attribute count, and script count. Search matches names,
refs, and kinds. The selected target's event catalog is a separate immutable projection, so custom
declarations do not cause arbitrary terrain scans while typing. Rows can be pinned and can insert either:

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
every explicit ref sent by a granted guest. Each host snapshot carries the custom attribute's
inferred Lua type and read-only state through exact-object member completion and the bounded AI
projection. The LAN protocol does not replicate a custom attribute's
read-only bit; guest completion therefore cannot promise mutability. It does replicate bounded event
names, field type tokens, and summaries for target-aware authoring, but not declaration provenance or
script source. The host remains authoritative for every write, declaration, subscription, emission,
and execution.

## Optional Ollama completion

Editor AI has three modes:

- **Off** — editor completion, panel prompts, model discovery, model warmup, and generation do not contact
  Ollama.
- **Manual** — the default; only an explicit request generates a suggestion or sends authoring
  context. Opening the editor may still warm the exact configured local model with a context-free
  request, even while the Script AI panel is closed.
- **On Idle** — optional; an explicit user preference requests a ghost-text proposal after a short
  typing pause. Opening the editor performs the same context-free warmup as Manual.

Use **Edit > Request AI Suggestion** or Option-Command-/ in Manual or On Idle mode. The exact
local model selected under Options > AI is used. Cloud-tagged model names remain refused. Selecting
a model does not enable On Idle. The chosen editor-AI mode persists across application sessions;
switch back to Manual or Off whenever automatic requests are no longer wanted. When the native
editor opens in Manual or On Idle, it begins one shared warmup for the exact saved selection through
an empty, non-streaming loopback Ollama request with a 30-minute keep-alive. The warmup contains no
script source, world metadata, authoring prompt, generation tools, or generated suggestion. It runs
whether the panel is open or closed. A generation request waits for the same in-flight warmup rather
than racing it; if an earlier warmup failed, the same explicit request retries readiness before
generation instead of consuming a sacrificial first attempt. Choosing another model invalidates the
old readiness and warms that exact replacement. The visible panel separately refreshes the installed
local-model list, and **Refresh local models** remains available as a retry. Turning editor AI Off,
closing the editor, or ending the world session cancels unfinished work; a completed warmup may
remain in Ollama memory for its requested keep-alive. Every generated editor request also asks
Ollama to retain the selected model for 30 minutes. Source-bearing generation uses a dedicated
ephemeral loopback session with a 90-second request deadline and a 120-second hard resource deadline,
rather than the ordinary 45-second session cap.

The read-only completion request is bounded to source before/after the caret, script mode/event,
current diagnostics, a target authoring contract, and the current bounded World Objects snapshot.
That snapshot leaves the app only after a manual suggestion request or after the user explicitly
enables On Idle. The authoring contract lists the mode rule and target members. Handler requests
carry target-compatible produced built-ins and target declarations. The selected Handler contract is
prioritized and never field-clipped; current-target members are budgeted next, before the remaining
event catalog. Every other included event is also a whole contract, while counts state whether the
prompt budget omitted any contracts. Module requests add produced built-in payloads
and, for each included object in the bounded authorized snapshot, compatible built-in names plus as many
whole declared custom-event contracts as fit. Snapshot and per-object total/included/truncated metadata
makes every omission explicit. An undeclared custom event explicitly
selected for Handler mode is marked envelope-only with unknown event-specific payload. The request
contains no tools, mutation context, save data, unrelated scripts, raw world state, or hidden LAN
data. System-side authoring facts and request-side source are separate nonce-fenced JSON objects.
Only the explicit `editor_instruction` field is task intent; source, selection, object names,
attributes, event summaries, and diagnostics remain data even when their text resembles a prompt
delimiter or instruction. It also includes the first 6,500
characters of generated LuaCATS text. Engine globals and modules are deliberately ordered into that
prefix; even if later per-kind classes are omitted, the bounded authoring contract keeps facts needed
for this target and selected event. The request uses a 16,384-token context. The runtime validator,
not this prompt, remains the API authority.

`/api/show` is a required, source-free locality preflight: a response that identifies a remote model
or remote host is rejected before warmup or source-bearing generation. Capability and template hints
from the accepted response remain advisory. The product currently uses the safe nonce-fenced JSON
prompt path and always disables Ollama's fill-in-the-middle `suffix` field. The service has an internal
explicit-FIM policy seam, but there is no product preference for it and model-hint compatibility is
not currently an enforcement gate.

Production editor requests use the numeric loopback endpoint `127.0.0.1`, an ephemeral URL session
with system proxies, caches, cookies, and credential storage disabled, and a delegate that rejects
all HTTP redirects. Model-list, metadata, and generation responses are incrementally byte-bounded
before decoding; generated text is also capped by character and line counts. These transport limits
contain the reply but do not make its Lua correct.

Inline and On Idle output appears as visually distinct ghost text labeled with the selected model.
It is never mixed into deterministic member results, never edits the source without acceptance, and
is bounded and checked for safe text and document size before display. An accepted inline proposal
still requires Check before reliance because an in-progress insertion need not compile by itself.

The panel makes intent app-owned and explicit. **Ask** always leaves its answer in the transcript,
even if the answer is valid Lua, and does not require a Handler event selection. **Write Code** is
the explicit edit request. Its response is bound to the captured document identity, source
revision/hash, UTF-16 selection, target, mode/event, model, and authoring-context revision. The
editor extracts only safe insertable Lua, then checks the complete candidate against the active mode,
compiler, blocking diagnostics, conservative lexical unresolved-global/call-target/callback and
dynamic-`_ENV` checks, and the mutation-free validation boundary before replacing that captured
selection as one normal undoable draft edit. A request may replace a selection only when its complete
text fits the 4,096-character selection budget; a larger selection is refused before warmup or
generation and remains byte-for-byte unchanged. The production completion service independently
enforces the same bound before any metadata or generation request.

That boundary may complete, stop at its first legal suspension, or compile-only for an
undeclared Handler event; static checks protect the unexecuted suffix. Module mode accepts module source or callback
registrations and permits `ev` only inside callbacks. Handler mode requires a valid selected event
and accepts only that event's body with its implicit `ev`; a second `on`/`subscribe`/`function(ev)`
wrapper is refused. The prompt explicitly distinguishes inability to perform an action from the
ability to propose a shipped mutation call: editor AI may author valid `emit`, `attach`, `detach`,
`player:give`, or furnace-output Lua when the authorized target contract supports it, but it cannot
perform or claim that it performed those actions. Furnace-output methods and completion events are
advertised for a current target only when it is a loaded furnace, blast furnace, or smoker.

Prose-only replies, unsafe text, mode violations, parse failures, and dry-run
failures remain in the transcript or visible refusal state and leave the draft byte-for-byte
unchanged. Automatic insertion requires the local authoritative runtime and is refused for LAN
guests or a missing runtime. It never saves, attaches, runs, changes world trust or `doScripts`, or
grants the proposal service world-mutation authority.

| Key | AI action |
|---|---|
| Option-Command-/ | Request one proposal |
| Tab | Accept the visible proposal |
| Command-Right | Accept the next word of a visible proposal |
| Command-Control-Right | Accept the next line of a visible proposal |
| Escape | Cancel an in-flight inline request or dismiss its visible proposal |

In the Script AI input, Return submits, Shift-Return inserts a newline, and Up/Down recall prompt
history only when the caret is on the first/last line respectively; otherwise they move the caret.
The visible bubbles are a local review transcript, not model conversation memory: every request is
independent and receives the current script/context plus that request only. The panel states this
directly so a follow-up must restate any fact that exists only in an earlier bubble.

Every request carries a distinct document identity in addition to the document revision, UTF-16
caret, source hash, model, target, mode/event, and authoring-context revision. Editing, moving the
caret, switching target/script/model, refreshing
World Objects, pressing Escape, or ending the world session cancels the inline request and makes late
responses ineligible for insertion. The right-hand Script AI panel owns its task separately:
**Stop**, closing the panel, switching AI Off, or ending the world session cancels it, while any
document/selection/context change makes its eventual response stale before automatic insertion.
New/Switch also clears the panel transcript and prompt history so even byte-identical scripts cannot
share conversational state.

Write Code asks Ollama not to use Markdown fences. A complete returned fence is unwrapped only when
all exterior text is clearly explanatory and contains no Lua shape. Ask preserves explanatory
transcript text, including fenced examples. An unfenced Write Code reply may drop only a clearly
explanatory, non-Lua suffix before the complete candidate crosses the mode, compiler, static, and
mutation-free gates. A code-like suffix refuses automatic insertion rather than silently inserting
a partial program; prose is never inserted as source.

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
- Ollama transport work is asynchronous. A request may wait on the shared exact-model warmup without
  blocking editing or Save/Run. Inline work is canceled on editor changes; panel work has its
  separate **Stop** action.

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
- a richer full-schema AI projection beyond the shipped bounded target contract,
  model-compatible FIM gating if FIM is exposed, and optional preflight of AI proposals before
  display; and
- measured completion latency plus installed-app keyboard, mouse, and VoiceOver regression coverage.
