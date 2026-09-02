# Scripting Guide

Elysium's object graph, event bus, embedded Lua runtime, and AI tool loop let you (and the local
AI) attach small pieces of behavior to blocks, entities, players, dimensions, and the world itself.
This guide covers both halves: driving scripting from chat/the in-game editor, and writing the Lua
scripts themselves. It assumes you've read the "Scripting, attributes, events, and AI" section of
[PLAYER_GUIDE.md](../PLAYER_GUIDE.md) for the first-run picture; this document is the full
reference.

The commands, method names, payloads, and limits below follow the shipped registries and execution
boundaries. File references point to the canonical implementation; the generated editor/AI schema
uses those same registries so it does not maintain a second handwritten API.

## 1. Overview and trust model

Every mutation — an attribute write, a script attach, a declaration, a subscription, or an emitted
event — runs through the same executors regardless of who initiated it (you, another script, or the
AI): `AttributeStore`, `ScriptStore`, `CustomEventStore`, and `EventBus`. Two independent gates
govern script execution, re-checked every phase, never cached:

- **The trust gate** — `WorldRecord.scriptsEnabled`. A world you create yourself starts trusted.
  A world you imported or migrated from elsewhere starts untrusted: no script on it runs, even one
  already attached, until you run `/script trust` once. This is a one-way switch for that world (no
  `/script untrust`).
- **The kill switch** — the `doScripts` game rule (`/script off` / `/script on`). Independent of
  trust: flips instantly, stops or resumes every script the very next tick regardless of how
  hostile a world's own scripts might be.
  (`Sources/ElysiumCore/Scripting/ScriptRuntime.swift:22-26`, `scriptsEffectivelyEnabled`.)

With an active local runtime, the editor stays useful on an untrusted or paused world without
weakening those runtime gates. **Check** is read-only and ignores both switches. **Save** may persist
a validated attached script while either switch is off, but does not run it. An explicit
local-editor **Run Once** may execute only the visible module draft once while the world is untrusted; it
does not save or attach that draft, trust the world, or load other scripts, but its permitted
live-world mutations may persist. It still refuses when `doScripts` is off. If no local runtime
exists, Check, Save, and Run Once are unavailable because authoritative validation cannot be
performed. Handler Run Once is disabled because there is no real event from which to construct
`ev`; use Check for representative payload validation or Save and trigger the event. Attached
scripts, `/script run`, AI `run_script`, and LAN-forwarded runs remain fully gated. The editor never
auto-trusts a world.

Execution is **host-only**, always. A LAN guest never runs a script on their own machine, even
their own — every scripting command is refused outright on a joined LAN world unless the host has
explicitly granted that guest scripting (§10, "LAN guest scripting"), in which case the guest's
commands are forwarded to and executed by the host. The full gated command list is `attr`,
`inspect`, `objects`, `on`, `unsubscribe`, `events`, `script`, `ai`/`agent`
(`Sources/ElysiumCore/Scripting/ScriptingCommands.swift:95-97`, `lanGatedCommands`).

The Lua sandbox has no filesystem, network, process, or dynamic-loading access, no `coroutine`
library, and no `os`/`io`/`debug`/`package` — see `SECURITY.md`'s "Embedded Lua script runtime" row
for the full boundary. This guide only covers the scripting surface itself.

## 2. The object model

Every scriptable thing is one of five kinds (`Sources/ElysiumCore/Scripting/ObjectRef.swift:14-16`):

| Kind | Canonical ref | Notes |
|---|---|---|
| world | `world` | one per save |
| dim | `dim:overworld` \| `dim:nether` \| `dim:end` | a dimension |
| block | `block:overworld:10,64,3` | `dim:x,y,z`; `x`/`z` in `-30000000...30000000`, `y` within the dimension's height |
| entity | `entity:12` | a persisted uid (never the player) |
| player | `player` | your own player; on a LAN world a guest is `player:lan:<peerID>` |

Every object can carry:

- **Built-in attributes** — fixed fields the engine already knows about (a block's `facing`, a
  living thing's `health`/`max_health`, a door's `open`). Some are read-only (a block's `name`,
  `waterlogged`). Registered per kind in `AttributeRegistry`
  (`Sources/ElysiumCore/Scripting/AttributeRegistry.swift`).
- **Custom attributes** — arbitrary named values you or a script define, stored per object in an
  `ObjectRecord`. A name is `[a-z][a-z0-9_]{0,31}` — lowercase letters, digits, underscore, up to
  32 bytes, first character a letter
  (`Sources/ElysiumCore/Scripting/ObjectRecord.swift:64-76`, `isValidAttributeName`). A name outside
  that grammar is refused by commands and tools with a normalized-name suggestion. Lua handle access
  is more ergonomic: script-supplied camelCase such as `doorRef` is folded to `door_ref`, then other
  invalid bytes are normalized when possible (`ScriptRuntimeAPI.normalizedCustomAttributeName`).
  Existing worlds written by the earlier collapsed-lowercase rule remain compatible: unchanged
  camelCase Lua first prefers `door_ref`, then falls back to an existing `doorref`, and keeps
  updating whichever entry already exists. If both exist, the canonical snake_case entry wins.
  Attribute-handler filters use the same resolution before registration and persistence, so
  `attr="doorRef"` becomes the codec-safe `door_ref`. A canonical custom filter also recognizes
  the old collapsed event key at delivery, using one bounded subscription/index slot rather than
  duplicating kind-wide registrations. If both physical keys are independently changed, they are
  distinct changes and the compatibility filter receives both. Saved camelCase filters from the
  earlier broken `h:attach` shape are upgraded deterministically (`doorRef` -> `doorref`, while a
  camelCase built-in such as `maxHealth` -> `max_health`). Registry built-ins with punctuation,
  including `be.name`, `inventory[0]`, `stats.<id>`, and `gamerule.<name>`, remain valid filters.
  A custom attribute can be declared `readonly` (locked against a plain `/attr set` /
  `h:set`, only a `--force`d `/attr define` or `h:define(..., {force=true})` can overwrite it).
- **Up to 8 attached scripts** — Lua chunks in **module** or **handler** mode (§4). Source is
  capped at 16 KiB (`Sources/ElysiumCore/Scripting/ScriptStore.swift:31-32,97`).
- **Object-scoped custom event declarations** — discoverable payload contracts for that object's
  custom events. A declaration is metadata separate from attributes and scripts: it does not
  subscribe a handler or make the event fire by itself. It lets chat, Lua, the editor, LAN guest
  authoring, validation, and the AI agree on the event's exact fields. Up to 16 declarations may
  live on one object, with up to 32 fields per declaration and a 256-byte optional summary. They
  share the containing object's 64-entry and record/chunk/world persistence budgets.

Custom attributes and attached scripts share one name namespace on an object. Neither API silently
changes an entry into the other kind: attribute set/define/remove refuses an attached-script name,
and script attach/detach/enable refuses a custom-attribute name. Explicitly detach the script or
remove the attribute first; a refusal does not change the object revision or queue lifecycle work.

Any running script may read or mutate attributes, declarations, handlers, and scripts on any
**live handle** it can resolve; these capabilities are not restricted to the object that owns the
script. Liveness, host authority, storage, event, and per-tick lifecycle budgets still apply.

## 3. Ref grammar

The strict, canonical parser lives in `ObjectRef.parse(_:)`
(`Sources/ElysiumCore/Scripting/ObjectRef.swift:74-115`) — no case folding, no whitespace, ≤ 128
bytes, and every case round-trips (`parse(canonical(r)) == r`):

```
world
dim:<overworld|nether|end>
block:<dim>:<x>,<y>,<z>
entity:<uid>                -- uid >= 1, no leading zeros
player
player:lan:<peerID>         -- a connected LAN guest (host-side only)
```

Commands and Lua both also accept a handful of **aliases**, resolved by `ObjectTargetContext.resolve`
(`Sources/ElysiumCore/Scripting/ObjectRef.swift:251-270`):

| Alias | Resolves to |
|---|---|
| `self` | the command issuer's own player (`.player`) on a host's own command; a guest's own `player:lan:<peerID>` on a forwarded guest command |
| `looking` / `cursor` | whatever's under your crosshair within reach — an entity if one is closer than the block hit, else the block, else nothing |
| `player` | always your own local player, regardless of `self`'s meaning above |
| `world` | the world |
| `dim` | your current dimension |
| `block:<x>,<y>,<z>` | shorthand for a block in your current dimension |

`self` and `player` are deliberately distinct: on a forwarded guest command, `self` means *that
guest's own player object*, while the literal alias `player` still names the host's own player —
so a guest can address the host's player explicitly if they want to.

## 4. Value grammar

`/attr set|define`'s `<value>` (and a Lua `h:set`/`h:define`'s second argument) is one of, checked
in this order (`Sources/ElysiumCore/Scripting/ScriptingCommands.swift:221-249`, `parseValueTokens` —
single command-line token only unless noted):

| Written as | Becomes |
|---|---|
| `null` | `AttrValue.null` |
| `true` / `false` | `.bool` |
| `12`, `-4` | `.int` (parses as `Int64` first) |
| `1.5`, `-0.25` | `.number` (a finite `Double`) |
| `ref:<alias-or-canonical-ref>` | `.ref(...)` — the same alias/ref grammar as a command target |
| `str:<text>` | `.string(text)` — forces string even if `text` looks numeric |
| `[...]` or `{...}` | decoded as canonical JSON (`AttrValueCodec.decode`) — a list or a map |
| anything else (one token or several) | `.string(...)`, the token(s) joined by a single space |

A multi-token value that doesn't start with `[` or `{` is *always* a plain string of the joined
tokens — `/attr set self mood very curious` needs no quotes at all and stores `"very curious"`.
Quoting (`"..."` or `'...'`, handled by the chat-line tokenizer itself, not this grammar) only
matters when you need to force one thing that would otherwise be split, or when you're inside a
one-line Lua source string (§6's escaping note).

Canonical JSON encoding (`AttrValueCodec.encode`,
`Sources/ElysiumCore/Scripting/AttrValueCodec.swift:108-150`) is what `/attr get`/`/attr list`
print back: `null`, `true`/`false`, a bare number, a `"quoted string"`, `[...]` for a list, sorted
`{"key":...}` for a map, and `{"$ref":"<canonical>"}` for a ref value.

## 5. Command reference

Everything here is host-only unless marked guest-forwardable (§10). Grammar quoted verbatim from
`Sources/ElysiumCore/Scripting/ScriptingCommands.swift`'s own usage constants unless cited
otherwise.

### `/attr` — `Usage: /attr list|get|set|define|remove <target> [name] [value] [readonly] [--force]`

- `/attr list <target>` — every attribute on the target, plus a summary line (entry count, byte
  size, revision). *(guest-forwardable: no)*
- `/attr get <target> <name>` — one value; a built-in that doesn't apply says so, an unknown custom
  name refuses. *(no)*
- `/attr set <target> <name> <value...>` — write a value. Refuses on a readonly attribute or a
  wrong-shaped built-in. *(yes)*
- `/attr define <target> <name> <value...> [readonly] [--force]` — declare a *custom* attribute,
  setting its initial value. Later writes may use a different supported value type. `readonly`
  locks it, while `--force` overwrites an existing readonly value. Trailing `readonly`/`--force`
  tokens are stripped from the end before the value is parsed. `set` instead treats all remaining
  text as the value; `remove` accepts only its documented optional trailing `--force`. *(yes)*
- `/attr remove <target> <name> [--force]` — clear one custom attribute. *(yes)*

### `/inspect [target] [--all]`

A readable dump: the target's built-in fields (block state, health, etc. — indexed families like
`inventory[n]` are summarized to one count line unless `--all` expands every index), then every
custom attribute, then a script count. Unlike every other command here, the target is *optional*:
omitted, it defaults to `looking`, falling back to `self` only when `looking` names nothing at all
(not merely something unloaded — an unloaded `looking` target still reports its own specific
refusal). *(no)*

### `/objects near [radius] [--kind entity|block]`

Nearby entities and attributed blocks within `radius` (default 8, up to 32 results), closest first,
each line showing its ref, kind, display name, distance, and attribute count. Never lists your own
player entity. *(no)*

### `/on <target> <event> [attr] <script>.<handler>` — `Usage: /on <target> <event> [attr] <script.handler>`

Subscribes. The **subscriber is always you** (`self`) — `<script>` must therefore be a script
attached to *your own* player object (`/script attach self <script> module ...`), because delivery
looks the subscription up as `<subscriber>#<script>#<handler>`
(`Sources/ElysiumCore/Scripting/ScriptRuntime.swift:306-310`, `invokeNamed`). `<target>` is what's
watched, not who owns the handler — resolved by `parseSubscriptionTarget`
(`ScriptingCommands.swift:586-603`):

| `<target>` | Meaning |
|---|---|
| `any` | every object (refused for `attribute.changed`/`block.changed`, which need a narrower target) |
| a bare kind — `entity`, `player`, `block`, `world`, `dim` | every object of that kind |
| `entity:<type>` / `block:<name>` | that kind, filtered to one type — recognized as a filter only when there's *no second* `:` after it, so `block:overworld:10,64,3` still parses as a specific block first |
| anything else | resolved exactly like a command target (`self`/`looking`/`world`/`dim`/a canonical ref) |

`<event>` is a catalog name (§7) or a custom one, `[attr]` narrows an `attribute.changed`
subscription to one attribute name. `<script>.<handler>` names the script and a handler *name* the
script's own module body registered at load — with `register(name, fn)` or `on(event, {name=...},
fn)` (§8). Naming a handler that never registered itself is not an error: the subscription is
created, and simply never fires until (if ever) that name gets registered. *(yes)*

### `/unsubscribe <id>` — `Usage: /unsubscribe <id>`

Removes a subscription by the numeric id `/on` printed. *(yes)*

### `/events` — inspect standard events; declare, remove, and emit custom events

- `/events recent [limit]` — list the most recent events the bus has seen. *(guest-forwardable: no)*
- `/events list <target>` — list every compatible produced built-in event plus the typed custom
  declarations owned by the target. Reserved built-in names with no producer are omitted. *(no)*
- `/events define <target> <event> [field:type ...] [--summary "text"]` — create or replace an
  object-scoped custom event declaration. An identical redeclaration is an idempotent no-op. Each
  field name follows the custom-attribute name grammar; `kind`, `subject`, `tick`, and `source` are
  reserved because the runtime adds those envelope fields to every `ev`. Field types are `any`,
  `boolean`, `integer`, `number`, `string`, `object`, `list`, or `map`; append `?` when a field is
  nullable and therefore optional, such as `actor:object?`. A built-in event name cannot be
  redeclared. *(yes)*
- `/events remove <target> <event>` — remove that target's custom event declaration. This removes
  discovery and strict payload validation, not subscriptions or the open event name itself. *(yes)*
- `/events emit <target> <custom-event> [payload-json]` — raise a custom event by hand. The optional payload must
  be a JSON object. If the target declares that event, the payload must contain every required field,
  no undeclared field, and values of the declared types. With no matching declaration, a valid custom
  event remains legal and open for compatibility. Built-in events are engine-produced facts and are
  rejected by every manual emission path. *(yes)*

For example:

```text
/events define looking machine.ready item:string count:integer --summary "A machine completed a batch"
/events list looking
/events emit looking machine.ready {\"item\":\"iron_ingot\",\"count\":4}
```

The backslashes preserve JSON's quote characters through the one-line command tokenizer. In Lua,
payloads are ordinary string-keyed tables and need no JSON escaping.

### `/script ...` — `Usage: /script list [target] | show <target> <name> | attach <target> <name> module <source...> | attach <target> <name> handler <event> <source...> | detach <target> <name> | run <target> <source...> | stats | journal | undo-ai [n] | trust | off | on`

- `list [target]` (default `self`) — each script's mode, and `(disabled)`/last-error if any. *(no)*
- `show <target> <name>` — full source (first 30 lines), mode, author, trigger(s), last error. *(no)*
- `attach <target> <name> module <source...>` — a **module**-mode script: runs once at load, is
  expected to call `on`/`subscribe`/`every`/`after`/`register` to set itself up. *(yes)*
- `attach <target> <name> handler <event> <source...>` — a **handler**-mode script: the whole
  source *is* the handler, auto-subscribed to `<event>` on the attach target itself (an `ev` local
  is bound automatically, no `on(...)` call needed). Attaching from chat can only trigger on the
  target you attach it to; a script's own `h:attach(...)` can target a trigger anywhere (§8). *(yes)*
- `detach <target> <name>` — remove a script. *(yes)*
- `run <target> <source...>` — run source once, immediately, capability-reduced: the source is not
  saved or attached, though permitted live-world changes may persist. `wait`/`ai.await`/subscribing/
  timers all fail rather than hang. Unlike the local editor's
  explicit Run button, this command requires both a trusted world and `doScripts` on
  (`ScriptRuntime.runEphemeral`). *(yes)*
- `stats` — live/suspended script counts, durable timers, pending events, and global Lua instruction
  tokens charged/remaining this simulation tick. Ordered work that exceeds the current token budget
  remains pending for a later tick. *(no)*
- `journal [limit]` (default 32) — what `/ai` has done to this world, most recent first: request,
  entry, tick, tool, object, name, kind of change, model. Only AI mutations appear here. *(no)*
- `undo-ai [n]` (default 1) — reverts the `n` most recent `/ai` requests' worth of mutations, most
  recent first; refuses (rather than clobber) a script edited since the AI touched it. *(no)*
- `trust` — trusts the *current world* (§1). *(no)*
- `off` / `on` — the kill switch (§1). *(no)*
- `trust <peer> [ai] [off]` — **host-only, LAN**: grants/revokes a connected guest's scripting
  and/or AI permission (§10). Intercepted at the app layer before reaching this Core command set
  (`Sources/Elysium/CommandsM.swift:70-91`) — a different thing from the bare `/script trust` above.

#### Runtime budgets and backpressure

Attached scripts share a deterministic token bucket: 50,000 instructions refill per simulation
tick, with up to 250,000 banked after idle ticks. A single callback runs for at most 5,000
instructions before preemption and 100,000 across its lifetime. Because CLua counts at a pinned
1,000-instruction hook quantum, a shorter resume is conservatively charged 1,000 and a sub-quantum
overrun becomes signed debt repaid by later refills. Twenty consecutive preemptions fault a busy
loop. Each script may retain at most 64 suspended callbacks and the world may retain at most 1,024;
an already-running callback that would exceed either limit is closed and faulted without growing the
scheduler. A new closure timer refused at capacity instead returns the normal catchable host-call
error, so the current callback may recover with `pcall`.

Event delivery is backpressured against this bucket one ordered recipient at a time. When tokens run
out, `EventBus` keeps the exact event/recipient cursor, so no later subscriber overtakes it and no
unrun handler is counted as delivered. Due resumptions, AI replies, timers, loads, and event handlers
all use the same budget. Loads reserve one 1,000-instruction quantum for each downstream lane; AI
replies, resumptions, and timers release their reservation in phase order, guaranteeing progress for
all five lanes under the production budget. An awaited AI reply is not consumed—and does not release
its in-flight slot—until its exact coroutine has instruction credit to resume. Use events, `wait`,
and named `after`/`every` handlers instead of polling.

Definition discovery is bounded separately from Lua instructions. Attach, detach, enable/disable,
save hydration, and object unload enqueue the exact canonical object ref; the runtime never performs
a periodic whole-world definition scan. Dimension travel requeues only the old and new dimension
bags. One script phase reconciles at most 64 dirty refs and starts
at most 64 pending definitions. Larger hydration bursts and later edits retain their canonical
continuation for following phases, so loading may be delayed under a burst but no queued suffix is
forgotten.

`/script edit [target] [name]` (default target `self`) is not a Core command at all — it's an
app-layer action (`Sources/Elysium/CommandsM.swift:92-117`) that opens the in-game script editor
(§6); a host or guest alike falls through to it identically, and the editor itself is what sends a
guest's `Save`/`Run`.

### `/inspector`

Opens the **Object Inspector** screen: attributes, attached scripts, and subscriptions for whatever
you're looking at (or self/player/world — **Retarget** cycles). Distinct from `/inspect`: never
refused for a guest (reading is always fine), but a guest only ever sees the host's replicated,
read-only mirror. Select a script row and **Edit Script** jumps into the editor for it
(`Sources/Elysium/InspectorScreen.swift`).

### `/ai <request>` / `/ai cancel`

Sends `<request>` to the configured local Ollama model. §9 covers this in depth. *(yes, including
`cancel` is not forwarded — a guest can't cancel a forwarded request yet)*

## 6. The in-game script editor

`/script edit [target] [name]` opens the native multi-line editor: type directly or paste (⌘V) up
to 16 KiB, choose **module** or **handler** mode, and use **Save**, **Check**, or **Run Once**. On a
local host with an active script runtime, Check stays available regardless of world trust or
`doScripts` and performs a mutation-free dry run. Save attaches through `ScriptStore` even while
scripting is paused, but saving never runs the record; an untrusted or kill-switched world leaves it
dormant. The explicit editor Run Once executes only the visible module draft once without saving or
attaching that draft. It can do that while the world remains untrusted, but it is not read-only and
its permitted one-off verbs can change live game state; those changes may persist with the world. It
still refuses when `doScripts` is off. If no local runtime exists, Check, Save, and Run Once are
unavailable because authoritative validation cannot be performed; the draft remains available to
copy. Run is synchronous, so the editor highlights
`wait`/`ai.await` and directs you to Save the script for attached, yieldable execution. Check uses a
throwaway coroutine and treats its first legal yield as a successful validation boundary without
scheduling it or contacting AI. The runtime validator remains authoritative and reports the
offending line. In handler mode, Check supplies the selected event kind and deterministic
representative values from the target-aware catalog. That means it executes both a compatible
built-in handler and a custom-event handler whose payload contract is declared on the current
target. A valid but undeclared custom event still reports compile-only success because there is no
authoritative payload shape to invent. Handler mode disables Run Once rather than executing with a
missing or invented `ev`. Check's fixed validation identity and transient RNG do not consume the
live scheduler/RNG ordinal.

When attached execution is paused, the editor's persistent status banner offers the applicable
**Trust World**, **Turn On Scripts**, or **Trust & Turn On** action. Its confirmation warns that all
enabled scripts already attached across the world may start running. Confirming changes only the
named gate or gates; opening the editor, saving, checking, or running a draft never grants trust or
turns on the kill switch implicitly. The Run exception is deliberately local: ordinary
`/script run`, AI `run_script`, attached/background execution, and every guest-forwarded run
continue to require both gates.

The editor's local language service adds semantic styling, receiver-correct completion and
documentation, signature help, diagnostics, validated snippets, and a searchable **World Objects**
browser. Its handler-event picker is target-aware: it shows only compatible produced built-ins,
followed by custom events declared on that exact object, with typed payload details. Typing `.` or
`:` opens the member list immediately; Control-Space requests completion elsewhere. `self.attrs.`
includes the current object's live custom attributes, and `ev.` includes the selected built-in or
declared-custom payload fields; `objects.`, `ai.`, the sandbox libraries, and locally inferred Lua
tables each receive their own factual members. Event-name completion separates subscription from
emission: `on` offers compatible built-ins and target declarations, while `emit` offers only custom
events declared on the current target because engine events cannot be forged. These features never
execute Lua and do not require Ollama.

Ollama editor proposals are optional and separate from factual completion. **Manual** is the
default. Opening the native editor in Manual or On Idle warms the exact selected local model with an
empty request, even when the Script AI panel is closed; it sends no source, world context, prompt, or
tools. A required source-free `/api/show` preflight rejects a selection identified by Ollama as a
remote model or host before any authoring source is sent. A generation request waits for shared
readiness and retries a failed warmup in the same explicit interaction. **Off** performs no editor
model discovery, warmup, or generation.
Option-Command-/ and On Idle produce ghost text that still requires Tab or another explicit acceptance,
and Escape dismisses/cancels it.

The Script AI panel has explicit **Write Code** and **Ask** intents. Ask is transcript-only—even when
the answer looks like Lua—and does not require a Handler event. Write Code is an explicit draft-edit
request. Its destination identity is captured before readiness waits; any draft, selection, mode,
event, model, or authoring-context change makes the reply stale and unapplied. In Handler mode, its
bounded text-only prompt includes the selected event and current target's compatible catalog, and only a
mode-correct selected-event body using implicit `ev` may be inserted. In Module mode, the prompt
includes every produced built-in payload plus each explicitly authorized nearby object's compatible
built-ins and declared custom-event payloads, and the insertion must be valid module/callback source.
A valid selected but undeclared Handler event is labeled envelope-only with unknown event-specific
payload rather than omitted. The request also includes target members and diagnostics; it receives
no world-mutation tools. With a local authoritative runtime, the editor automatically replaces the
captured selection as one Command-Z-undoable edit only with safe Lua accepted by the compiler,
blocking diagnostics, conservative lexical unresolved-global/call-target/callback and
dynamic-`_ENV` checks, and the mutation-free validation boundary. LAN guests and missing-runtime
sessions keep code in the transcript. Write Code may omit only clearly explanatory, non-Lua text
outside a complete fence or at the end of an unfenced reply; the full reply remains visible and the
omission is reported. Prose-only, code-like exterior or suffix, unsafe, or invalid output leaves the
draft unchanged. This never saves, attaches, runs, trusts the world, turns on `doScripts`, or mutates
game state. Save/Check/Run remain separate authoring and execution actions. See
[`LUA_EDITOR.md`](LUA_EDITOR.md) for the complete UI, key, data-sharing, accessibility, and
cancellation contract.

Unsaved changes are protected when switching scripts, closing the window, or quitting Elysium. On a joined LAN world
(once granted), reopening an existing script still never reveals its source: the name/mode are
replicated, the body starts blank, and an explicit warning precedes a full replacement sent to and
executed by the host. A guest's Run is the ordinary fully gated host command path, never the local
editor-only trust exception.

**One-line chat commands have a quoting gotcha worth knowing.** `/script attach`/`run`/`/on`'s
`<source...>` is parsed by the *same* chat-line tokenizer as every other command argument
(`Sources/ElysiumCore/Game/CommandLineSupport.swift:28-64`, `splitCommandLineArguments`): a bare
`"` or `'` opens/closes a quoted argument and is then *dropped*, not kept as a literal character —
so `say("hi")` typed directly into a one-line command loses its quotes and becomes invalid Lua.
Escape a literal quote with a backslash (`say(\"hi\")`) to get it through untouched, or write
anything that needs string literals in the editor instead, which pastes your text through
unmodified.

## 7. Events and subscriptions

An event has a `kind`, a `subject` (an object handle), a `tick`, a `source`, and a payload of extra
fields merged in directly — so a handler reads `ev.kind`, `ev.subject`, `ev.tick`, `ev.source`
("player"/"ai"/"lan"/`"script:<owner>"`/"engine"), plus whatever payload keys that event kind
carries (`ScriptRuntime.eventValue`).

### Standard event catalog

`EventDescriptorRegistry` is the canonical produced-event catalog shared by the runtime, editor,
commands, and AI prompt. Every payload below is merged with the common `kind`, `subject`, `tick`,
and `source` fields. `?` means nullable.

| Subject kind | Produced event | Event-specific payload |
|---|---|---|
| every object | `attribute.changed` | `key:string`, `old:any?`, `new:any?` |
| every object | `load` | `name:string` |
| every object | `timer.fired` | `name:string` |
| every object | `script.faulted` | `name:string`, `message:string` |
| every object | `script.attached` | `name:string` |
| block | `block.placed` | `by:object`, `item:string` |
| block | `block.toolStrike` | `by:object`, `item:string`, `blockName:string`, `face:string`, `toolType:string`, `tier:integer`, `instant:boolean` |
| block | `block.broken` | `by:object`, `item:string?`, `blockName:string` |
| block | `block.changed` | `oldName:string`, `newName:string`, `oldMeta:integer`, `newMeta:integer` |
| block | `block.used` | `by:object`, `item:string?` |
| block | `block.neighborChanged` | `from:object` |
| entity and player | `entity.spawned`, `entity.removed` | none |
| entity and player | `entity.damaged` | `amount:number`, `cause:string`, `attacker:object?` |
| entity and player | `entity.died` | `cause:string`, `attacker:object?` |
| entity and player | `entity.healed` | `amount:number` |
| entity | `entity.interacted` | `by:object`, `item:string?` |
| entity | `entity.targetChanged` | `old:object?`, `new:object?` |
| player | `player.joined`, `player.left`, `player.respawned`, `player.slept` | none |
| player | `player.dimensionChanged` | `old:string`, `new:string` |
| player | `player.pickedUp`, `player.dropped` | `item:string`, `count:integer` |
| player | `player.attacked` | `target:object` |
| player | `player.leveled` | `old:integer`, `new:integer` |
| player | `player.advancement` | `id:string` |
| dimension | `dim.dayPhaseChanged` | `old:string`, `new:string` |
| dimension | `dim.weatherChanged` | `key:string`, `old:boolean`, `new:boolean` |
| dimension | `explosion` | `x:number`, `y:number`, `z:number`, `power:number`, `by:object?` |
| world | `world.gameruleChanged` | `key:string`, `old:number`, `new:number` |
| world | `world.difficultyChanged` | `old:integer`, `new:integer` |
| world | `ai.replied` | `requestId:integer`, `text:string?`, `error:string?` |
| world | `script.overBudget` | `message:string` |

`block.toolStrike` is a semantic first-strike event, not a repeated swing/hit-sound event. It fires
once when mining first transitions to a new block target, and only when the held registered item is
an actual tool. An unbreakable block still receives this first-contact event. Holding the button on
that same target does not re-fire it. `instant` is true for a
Creative strike or when the current tool/block combination can finish in one mining step. This makes
it suitable for alarms, durability displays, reactive blocks, and other “a tool first touched me”
behaviour without a per-frame event storm.

`block.changed` covers every observed non-silent cell write, including redstone, growth, placement,
and breaking, including metadata-only writes for which `oldName == newName` but `oldMeta != newMeta`;
its hot path is skipped unless the block already has an object record or an indexed subscription could
match it. `block.neighborChanged` follows the same fast-path principle: it is produced for a notified
block that has an object record or matches an exact-object, block-kind (optionally type-filtered), or
all-object subscription.
Consequently, `target:on("block.neighborChanged", fn)` can observe a plain block even if the target has
no attribute, declaration, or attached script of its own. Entity
damage/death events use `cause` for the engine damage identifier; `ev.source` remains event
provenance. `block.broken.blockName` is the registered block name before removal.

A successful scripting-API write that changes a built-in or custom value publishes
`attribute.changed` with the writer's provenance. Engine-driven built-in fields are read only while a
matching indexed subscription exists. Their first polled value establishes a baseline and emits no
synthetic event; later differences publish `key`, `old`, and `new`. Exact block observers also poll
dynamic light and block-entity fields, while metadata-backed block fields publish from the same
`World.setBlock` hook as `block.changed`. Entity/player movement is exposed as an explicitly filtered
synthetic `pos` change, quantized to one tenth of a block and omitted from the recent-event feed. A
real custom attribute also named `pos` remains ordinary extensible state: it reaches unfiltered
handlers and uses a separate coalescing lane, so movement can never merge with or hide that value.

`block.replaced`, `block.scheduledTick`, and `unload` are reserved EventBus names but have no shipped
producer; the editor, AI discovery, and `/events list` omit them. Do not build an `on`, `subscribe`,
or handler-mode script that depends on them firing. Module scripts do have a separate synchronous
`register("unload", fn)` finalizer, documented below; it is not an event and receives no `ev`.

### Custom event declarations

Custom names (`machine.ready`, `lumber.milestone`) share the event grammar: 1-4 dot-separated
segments, each `[a-z][a-z0-9_]{0,31}`, at most 64 bytes total. An object may publish a typed contract
for one with `/events define` or `h:declareEvent`. Declarations persist beside that object's
attributes and scripts, carry provenance, and are included in the target-aware editor/AI/LAN
authoring metadata. They are not a global registry: `machine.ready` may be declared differently on
two objects, and emission is validated against the declaration on the **event subject**.

A matching declaration makes emission strict: required fields must exist; nullable fields may be
absent or `nil`; extra fields and wrong types are rejected. The `number` type accepts Lua integers
or numbers, while `integer` requires an integer. Removing or never creating a declaration leaves the
open custom event legal, preserving existing scripts and subscriptions. Prefer declarations for any
event intended for reuse so the editor, another author, and AI can discover its payload accurately.

Event payloads have hard shape and memory limits even when the custom event is undeclared. Lua values
retain the ordinary limits (4,096 UTF-8 bytes per string, 256 entries per list, 64 keys per map, depth
4, and 1,024 total nodes); every map key is checked in both marshal directions and custom emission
further limits it to 256 UTF-8 bytes. The EventBus accepts at most 16 KiB of canonical payload per
event, 4 MiB across pending events plus a stalled delivery cursor and its single deferred diagnostic,
and 512 KiB in the recent-event feed (also capped at 128 events). Invalid Lua value shapes are host
errors. An otherwise-valid payload or coalesced replacement that would cross an EventBus byte limit is
refused without replacing the older queued event; `emit`/`h:emit` returns `false`, and one bounded
`script.overBudget` diagnostic is published for that tick.

`attribute.changed` and `block.changed` require a narrower subscription than `any`/a bare block kind
(an exact object, or a block type filter where applicable); every other produced event accepts the
broader targets documented by `subscribe`.

A script reacts to events one of two ways:

- **Handler-mode attach** — the attached chunk's whole body is the handler:
  ```lua
  -- /script attach <lamp> pulse handler attribute.changed <source below>
  local low = ev.new / ev.subject.maxHealth < 0.3
  self:setBlock(low and "glowstone" or "sea_lantern")
  self.attrs.lastHealth = ev.new
  ```
  (Attaching from chat always triggers on the object you attached it to; the trigger's own
  `attribute`/`target` narrowing beyond that needs a script's own `h:attach` call, §8.)
- **Module-mode `on`/`subscribe`** — the module registers a closure at load:
  ```lua
  -- on(event, fn) — subscribes on self, for one event
  on("entity.interacted", function(ev)
    if ev.by.kind ~= "player" then return end
    -- ...
  end)

  -- subscribe(target, event[, opts], fn) — subscribes anywhere
  subscribe({kind = "block"}, "block.broken", {}, function(ev)
    -- ...
  end)

  -- object-first helpers are easiest when you already have the handle
  local door = objects.get("block:overworld:10,64,3")
  door:on("block.used", function(ev)
    say("Door used by " .. ev.by.name)
  end)

  player:onAttribute("health", function(ev)
    say("Health is now " .. tostring(ev.new))
  end)
  ```
  `h:on` watches exactly `h`; `h:onAttribute(name, fn)` is shorthand for that object's
  `attribute.changed` event filtered to one built-in or custom attribute. `subscribe` is the
  compatibility/general form whose target may be a handle, `{kind=..., type=...}`, or `"any"`.

Persisted and script-owned subscriptions share firm limits: at most 32 registrations per owning
object and 512 per world. The bus indexes exact event names and object/kind interest, so raising an
event with no matching listeners and checking an unrelated observable event are O(1) hot paths;
delivery examines only the bounded bucket for that event rather than scanning the world's scripts.

### Unload finalizer (not an EventBus event)

A module can reserve one named callback for deterministic cleanup:

```lua
register("unload", function()
  self.attrs.last_state = "stopped"
  world:define("last_controller", self.ref)
end)
```

The runtime invokes it synchronously when that live script is edited, disabled, detached, its object
unloads, or the world session shuts down. It receives no arguments and is not available in handler
mode. Its only permitted persistent side effects are final custom-attribute writes on live handles,
including `h:set`, `h:define`, direct custom fields, and `h.attrs`; custom reads and ordinary local
computation remain available. It cannot yield or wait, schedule timers, call AI, emit or subscribe,
register another callback, alter event declarations or scripts, mutate blocks or built-in fields,
draw RNG, call `say`, `sound`, or `particles`, or otherwise turn teardown into more gameplay. A
finalizer is instruction-bounded, and teardown still destroys the old environment after failure. A
failure on a still-current unload is recorded as `script.faulted`; a stale callback being replaced
cannot overwrite the replacement script's diagnostic.

## 8. Lua API reference

Every module/handler script is compiled inside a wrapper: a module gets `local self, world,
player = ...` bound; a handler gets `local self, world, player, ev = ...`
(`Sources/ElysiumCore/Scripting/ScriptRuntime.swift:338,468-470`). `self` is the object the script
is attached to; `world`/`player` are always the world and your local player, whichever object owns
the script.

### Globals

All of these are built by `ScriptRuntime.buildHostBindings()`
(`Sources/ElysiumCore/Scripting/ScriptRuntimeAPI.swift:62-87`) — this is the **complete** list; a
name not below does not exist as a script global (notably no `players()`, `world.spawn`, or
entity/mob verbs like `damage`/`heal`/`moveTo` beyond what's listed). `say(text)` is the way to
produce visible output — see the note right after the table on `log`/`print`, which are not it.

| Call | Does |
|---|---|
| `on(event, fn)` / `on(event, opts, fn)` | compatibility helper that subscribes on `self`, or on `opts.target` when that is a handle. The only option fields are `target`, `attr`, and `name`; `opts.attr` narrows `attribute.changed`, while `opts.name = "foo"` also registers `fn` under that valid handler name (equivalent to calling `register("foo", fn)`). Non-table options, unknown fields, wrong value types, unavailable events, and incompatible event/target/filter shapes are errors. Check/dry-run performs the same validation without retaining the closure |
| `subscribe(target, event[, opts], fn)` | subscribe anywhere; the optional table accepts only string `opts.attr`, which may narrow `attribute.changed`. Non-table options, unknown fields, wrong value types, unavailable events, and incompatible target/event/filter shapes are errors in both Check/dry-run and live execution |
| `every(n, handlerOrName)` / `after(n, handlerOrName)` | schedule after `n` ticks (§9). A **string** name schedules a durable, persisted timer that survives reload — only `every` with a name truly repeats. A **function** schedules a live, one-shot run — `every(n, fn)` behaves exactly like `after(n, fn)`, once only, not repeating (documented simplification; `ScriptRuntimeAPI.swift:429-436`) |
| `wait(n)` | yield the current handler for `n` ticks |
| `emit(name[, payload][, target])` | emit a custom event with exactly 1–3 arguments; default target is `self`, and an explicit target must be an object handle (a string/ref-shaped table is an error, never a silent fallback to `self`). A declaration on the target strictly validates the payload; otherwise valid custom names remain open. Engine-produced built-ins are rejected |
| `tick()` | the current world tick |
| `rng()` / `rng(n)` / `rng(a,b)` | this script's own deterministic `RandomX` stream: `[0,1)`, `[1,n]`, or `[a,b]` |
| `say(text)` | a chat line from this object — the way to produce visible output; host-only, rate-limited, text-hygiene filtered |
| `sound(...)` / `particles(...)` | accepted (arguments loosely checked) but currently no-ops — not wired to audio/renderer yet |
| `dim(name)` | `"overworld"`/`"nether"`/`"end"` → that dimension's handle |
| `register(name, fn)` | name a function so `/on`, a durable `after`/`every`, or another `on(event, {name=...})` call can find it later. The reserved name `unload` installs the separate synchronous finalizer above; it is not an EventBus handler |
| `objects.get(ref)` | a handle, or `nil`. Accepts a handle, a canonical ref string, or the aliases `"player"` (the local/host player), `"self"` (the calling script's owner), and `"world"` |
| `objects.find{kind=, type=, near=, radius=, limit=}` | handles sorted by distance then ref; `near` defaults to `self`'s position, `radius` defaults to 16, `limit` to 32 |
| `objects.block(dim, x, y, z)` | a block handle at that position (bounds-checked) |
| `ai.ask(prompt[, opts])` → `requestId` | fire-and-forget; reply arrives as an `ai.replied` event on `world` |
| `local text, err = ai.await(prompt[, opts])` | yields the handler until the reply (or `"timeout"`/`"budget"`). `opts` is accepted for forward compatibility but not currently read by either call — no field in it (e.g. a max-length hint) changes behavior today |

There is no bare `log(...)` global — calling it errors ("attempt to call a nil value"). There *is* a
`print(...)`, but it is not a player-facing print: it's wired to the sandbox's own log sink, which
writes to the host application's own console/stdout only (`[script] <line>`), never to chat, and
there is currently no `/script log` command to read it back in-game (`Sources/CLua/elysium_sandbox.c`'s
per-environment `print` closure and `ScriptRuntime.swift`'s `ScriptRuntimeLogSink`). Use `say(text)`
for anything a player should actually see.

### Handle properties and methods

Every object (`self`, `world`, `player`, anything from `objects.get`/`.find`/`.block`, or `ev.subject`/`ev.by`) is a handle:

| | |
|---|---|
| `h.ref`, `h.kind`, `h.name` | canonical ref text, kind string, display name |
| `h:exists()` | whether it currently resolves live |
| `h.<builtIn>` / `h.<builtIn> = v` | read/write a built-in field by dot-sugar; unknown/inapplicable reads as `nil`, an unknown write errors with a did-you-mean. Built-ins are matched snake_case-first, camelCase retried on a miss (`ev.subject.maxHealth` and `ev.subject.max_health` both work) |
| `h:get(name)` / `h:set(name, value)` | same read/write, by call instead of dot-sugar — works for both built-ins and custom attributes. `h:set` requires exactly two arguments; Check validates the same liveness, protected-name, applicability, mutability, value, collision, and storage-cap rules as live execution without writing |
| `h.attrs.<name>` / `h.attrs.<name> = v` | a custom attribute directly; `= nil` removes it. **`pairs(h.attrs)` is not supported** (no iteration hook) — read/write named custom attributes individually with `:get`/`:set`/`h.attrs.<name>` |
| `h:define(name, value[, opts])` | declare a custom attribute with an initial value; later writes may change its supported value type. The optional table accepts only boolean `readonly` and `force` fields. Non-table options, unknown fields/typos, wrong types, and extra arguments are errors. Check also runs the same liveness, protected-name, value, script-collision, readonly/force, revision, and storage-cap admission as live execution without writing |
| `h:events()` | list the custom event declarations owned by `h` as `{name, fields, summary, author, createdTick}` records; each field has `name`, canonical `type`, and `nullable`. The call takes no arguments |
| `h:declareEvent(name[, fields][, summary])` | declare or replace `h`'s custom event contract with exactly 1–3 arguments. `fields` is a string-keyed table of type tokens, for example `{item="string", count="integer", actor="object?"}`, and `summary` must be a string. Identical redeclarations are no-ops |
| `h:undeclareEvent(name)` | remove `h`'s custom event declaration and return whether one existed; it requires exactly one valid event-name string. The open event name and existing subscriptions remain valid |
| `h:on(event[, opts], fn)` | subscribe this module's closure to `event` on exactly `h`, with exactly 2–3 arguments. The optional table accepts only `attr` (a string filter valid for `attribute.changed`) and `name` (a valid handler name); `target` is not accepted because the receiver fixes it. Non-table options, unknown fields/typos, wrong types/names, unavailable built-ins, and incompatible target/event/filter shapes are errors in both Check and live execution |
| `h:onAttribute(name, fn)` | subscribe to `attribute.changed` on exactly `h`, filtered to the canonical built-in or normalized custom attribute name |
| `h:emit(name[, payload])` | emit a custom event with exactly 1–2 arguments whose subject is fixed to `h`, validating against `h`'s declaration when present; engine-produced built-ins cannot be emitted manually |
| `h:attach(name, source[, opts])` | attach a script. Omitting `opts` or passing `{}` attaches module mode. A nonempty options table attaches handler mode and must contain a valid `opts.on = "<event>"`; its only other fields are `opts.attr` and `opts.target`. `opts.attr` is a string filter valid only for `attribute.changed`. `opts.target` must be a *handle value* (for example `player`, not a ref string) and defaults to `h` when omitted. Unknown fields (including `opts.mode`), malformed values, unavailable built-ins, and incompatible event/target/filter combinations are errors. Grammatically valid undeclared custom events remain legal under the open custom-event contract. Check/dry-run validates this same complete shape plus the nested source without attaching anything (`ScriptRuntimeAPI.swift` and `ScriptMarshaling.swift`) |
| `h:detach(name)` | remove a script; requires exactly one argument |
| `h:scripts()` | `{name, mode, author, enabled, lastError}` for each script on `h` |
| `furnace:setFurnaceOutput(item)` | on the attached script's own loaded furnace, blast furnace, or smoker, replace the existing output-slot stack on the next furnace tick and redirect future matched-recipe output to a registered item while that script remains live. `"default"` clears the caller's registration. The recipe still consumes its original input and credits its original XP. Check performs the same target/item/stack-limit validation without registering; Run Once and unload refuse this lifecycle capability; another current script cannot silently take control |
| `block:setBlock(name[, opts])` | replace the block; extra `opts` keys (besides the accepted-but-unused `notify`) are planned in deterministic key order as built-in attribute writes, e.g. `{facing="north"}`. The block name and complete options table are preflighted for field name, applicability, mutability, value type/enum, and range before any cell changes. CamelCase built-ins are canonicalized, and the first invalid option is reported with the original block left byte-for-byte unchanged. A valid plan is then committed with no fallible validation remaining; Check/dry-run runs the same preflight without committing it |
| `block:breakBlock()` | break it naturally (drops items); takes no arguments |

Script-created lifecycle churn is bounded as well as validated: one originating script may perform
at most 2 combined `h:attach`/`h:detach` operations per simulation tick, and all scripts together may
perform at most 32 across the world in that tick. A refused operation returns the ordinary Lua error
instead of partially changing the target; both allowances reset on the next tick.

An attribute filter is legal only on `attribute.changed`. New handler records are refused if their
event/target/filter combination is impossible; when an existing editor document changes to another
event, its old attribute filter is cleared. This keeps Save-time validation, persisted records, and
runtime registration in the same state rather than storing a handler that can only fault at load.

Every mutating call above (attribute and declaration writes, `attach`/`detach`,
`setBlock`/`breakBlock`, `emit`, timers) is a no-op during a read-only Check/AI dry run — never
during ordinary attached execution. Declaration creation/removal is also unavailable in an
ephemeral Run Once because it is durable authoring state, not a one-off world verb.

`setFurnaceOutput` is intentionally an attached-lifecycle registration rather than a persisted
block-entity attribute. Put it in a Module script on the furnace itself. Disabling scripts with
either execution gate, editing/disabling/detaching/faulting the controlling script, unloading the
furnace chunk, or ending the world session stops future conversion. Items already converted are
ordinary output and are not rolled back. Clearing the override while a converted stack remains can
therefore block a different recipe output until that stack is extracted. Each completed operation
raises the engine-produced `furnace.smeltCompleted` event on that exact block with `input`, `recipeOutput`,
`output`, `count`, `xp`, and `furnaceKind` fields:

```lua
self:setFurnaceOutput("iron_ingot")
self:declareEvent("furnace.output_converted", {
  item = "string",
  recipe_item = "string",
  count = "integer",
}, "This furnace converted one recipe output")
self:on("furnace.smeltCompleted", function(ev)
  self:emit("furnace.output_converted", {
    item = ev.output,
    recipe_item = ev.recipeOutput,
    count = ev.count,
  })
end)
```

Changing `ev.output`, emitting an item name, writing read-only `be.items[2]`, or using `setBlock`
as an inventory API does not mutate furnace output. `h`, `block`, and `furnace` in generic API
signatures are documentation receiver placeholders, not globals; the current target is `self`.

Object-first handlers and declarations make cross-object behaviour explicit and readable:

```lua
local sensor = objects.get("block:overworld:10,64,3")
local lamp = objects.get("block:overworld:12,64,3")

sensor:declareEvent("sensor.threshold", {
  value = "number",
  unit = "string?",
}, "The sensor crossed its configured threshold")

sensor:on("sensor.threshold", function(ev)
  lamp.attrs.last_value = ev.value
  lamp:setBlock("glowstone")
end)

sensor:emit("sensor.threshold", {value = 12.5, unit = "C"})
```

The script may own neither `sensor` nor `lamp`; resolving live handles is enough. The declaration is
stored on `sensor`, the handler observes `sensor`, and `sensor` is the emitted event subject.

### `math`

The full kept/wrapped/removed table is in `SECURITY.md`'s "Embedded Lua script runtime" row and
design.md §8.3; in short: `abs ceil floor fmod huge maxinteger mininteger modf sqrt tointeger type
ult min max pi` are the native library untouched, and every transcendental routes through Elysium's
deterministic `DetMath` port so results are bit-identical across machines/runs — no libm fallback
anywhere:

```
sin cos tan asin acos atan exp log log2 log10 pow(^)
```

(`Sources/ElysiumCore/Scripting/ScriptHostBindings.swift:54-66`, `Sources/ElysiumScript/ScriptMath.swift`).
`math.log(x)` is natural log; `math.log(x, b)` is `log(x)/log(b)` for any base — `log2`/`log10` are
separate, additive entries, not derived from that form. `math.random`/`randomseed` are wired to this
script's own per-script `RandomX` stream (the same one `rng()` above draws from), not a shared
world generator. `table`/`string`/`utf8` keep most of their standard library too (sizes/steps
bounded); there is no `os`, `io`, `debug`, `package`, `load`, `require`, or `coroutine`.

## 9. Named durable timers

`after(n, "name")` and `every(n, "name")` register a **durable** timer — persisted in the world (up
to 256 per world, `Sources/ElysiumCore/Scripting/ScriptTimers.swift:48`), surviving unload/reload
and app restarts, firing the named handler (found via `register`, same as `/on`) at the due tick, or
in the first phase after its owner next loads if it was overdue while the object was unloaded.
`every` with a name is the *only* form that truly repeats — a durable timer's interval reschedules
it every time it fires (`ScriptRuntimeAPI.swift:409-440`). A closure form (`after(n, fn)` /
`every(n, fn)`) is live-only and always one-shot regardless of which of the two you call — it dies
with the script's own unload and does not survive a save/reload.

```lua
-- module-mode: register the handler, then schedule it
register("open_at_dawn", function(ev)
  self:setBlock("oak_door", {open = true})
end)
after(200, "open_at_dawn")   -- fires once, 200 ticks (10s) from now
every(24000, "open_at_dawn") -- fires every in-game day from then on
```

## 10. The AI workflow

`/ai <request>` sends your text, plus current game context (world seed, your position/state,
inventory, nearby state, saved template names), to the configured local Ollama model. `/ai cancel`
stops a request still in flight. A request whose text mentions scripting vocabulary (`script`,
`attach`, `attribute`, `event`, `subscribe`, `trigger`, `handler`, `emit`, `inspect`, `object
graph`, `lua`, `unsubscribe`, `journal`, `undo` — case-insensitive substring match,
`AIToolLoop.isScriptingRequest`, `Sources/ElysiumCore/Scripting/AI/AIToolLoop.swift:129-136`) is
routed to the bounded object-graph tool loop instead of the ordinary single-action world lane: up
to **4 mutations** per request, **8 turns**, **3 retries** per tool, a **90 s** wall-clock deadline
(`AIToolLoop.swift:94-96`, `Sources/Elysium/OllamaAgent.swift:174`). Every mutation tool
(`set_attribute`, `define_attribute`, `remove_attribute`, `attach_script`, `detach_script`,
`enable_script`, `subscribe`, `unsubscribe`, `emit_event`, `run_script`) runs through the exact same
executors as the matching command; `attach_script` additionally runs a dry run first (compiles and
executes the candidate once against a real handle with every mutating verb turned into a no-op,
reporting anything that looks wrong as a warning before it's ever saved for real). The fixed
20-tool budget is preserved by giving `emit_event` an `action` of `emit`, `declare`, or `remove`;
all three actions apply only to custom events, and `emit` cannot forge a built-in engine event.
Declaration fields are passed as a JSON object of the same type tokens documented in §7.

The tool-loop system prompt includes `ScriptAIAuthoringGuide`'s compact, explicitly maintained Lua
rules. Its built-in event section alone is generated from `EventDescriptorRegistry.available`, so
currently produced payload names do not come from a manually copied event list. The remaining
module-vs-handler, object-method, and declaration guidance is not generated from
`ScriptLanguageSchema`; it stays aligned through implementation review and focused contract tests.
`describe_events` accepts an optional object `ref`; with one it filters built-ins to that object's
kind and includes that object's custom declarations. `get_object` includes declaration metadata too.

For script creation, the built-in AI receives an additional app-owned system protocol with this
required order:

1. Resolve the requested owner to an exact ref already observed in the snapshot or a query result,
   then call `get_object`. Before replacing a named script, call `list_scripts` with that exact ref
   and name so existing behavior is not silently discarded.
2. Call `describe_events(ref)` before using an event and copy only its exact event name and payload
   fields. Call `describe_attributes(ref)` before using built-ins, and `search_registry` before using
   any item, block, entity, or effect id the model has not already established.
3. Choose exactly one source shape. A Module is the complete top-level chunk, may initialize state
   and register callbacks, and has no top-level `ev`. A Handler is only the selected callback body;
   `ev` is implicit and the source must not add `function(ev)`, `on`, `self:on`, or `subscribe`.
4. A draft or explanation returns text without a mutation tool. A request to create, add, install,
   fix, or replace must call `attach_script`, then read the full result and report every warning or
   refusal instead of merely printing code or claiming success.

The exact mutation argument shapes are:

```json
{"ref":"player","name":"quest_tracker","source":"<complete Lua chunk>","mode":"module"}
```

```json
{"ref":"block:overworld:10,64,3","name":"used_handler","source":"<Lua callback body using implicit ev>","mode":"handler","triggers":"[{\"event\":\"block.used\"}]"}
```

`triggers` is itself a JSON **string** containing the trigger array; it is not an array-valued tool
argument. An attribute-filtered Handler uses, for example,
`"triggers":"[{\"event\":\"attribute.changed\",\"attr\":\"state\"}]"`. Script names must match
`[a-z][a-z0-9_]{0,31}`. This is the AI tool shape, not the Lua
`self:attach(name, source[, opts])` shape: the Lua method has no `mode` option and creates a Handler
only through `opts.on`. A successful result with `loaded:"pending"` means the record was accepted
for the next script phase; it does not prove that the script is currently running or that an event
has fired, and world trust plus `doScripts` still control execution.

The initial world snapshot and every subsequent tool result use separate random nonce fences.
Object names, attributes, existing script source, event summaries, errors, and any instruction-like
text within those values remain untrusted data. Prompt guidance is defense in depth: tool argument
decoders, compiler/lint/reference checks, the mutation-free dry run, normal mutation executors,
world trust, and `doScripts` are still authoritative.

Every successful AI mutation is journaled with `.ai(model)` provenance:

```
/script journal 5
req#7 entry#12 t9041 attach_script block:overworld:10,64,3 lamp [script] (llama3.1)
```

`/script undo-ai [n]` reverts the `n` most recent requests' worth, most recent first — an attribute
goes back to its previous value (or disappears if the AI created it), an attached script is
detached or restored — refusing instead of clobbering if you've edited that script yourself since.

Inside a script, `ai.ask`/`ai.await` (§8) reach the same local model, text-only, no tools. Prompts are
capped at 4,096 characters; decoded replies are truncated on a complete character boundary to at most
4,096 UTF-8 bytes so both `ai.await` resume values and `ai.replied.text` always fit the Lua value
boundary. The encoded HTTP response is rejected while streaming past 64 KiB. Requests are capped at
2 in flight and 30 per world per minute; over budget, `ai.ask` fires an
`ai.replied{error="budget"}` event immediately (no request is made) and `ai.await` returns
`nil, "budget"` the same way — never silently queued.

```lua
-- a gatekeeper golem, on entity-interact, asking the AI whether to let a player through
on("entity.interacted", function(ev)
  if ev.by.kind ~= "player" then return end
  local text, err = ai.await(("A player with %d health asks to pass. Answer YES or NO.")
                              :format(math.floor(ev.by.health)))
  if not err and text:upper():find("YES", 1, true) then
    objects.get(self.attrs.doorRef):set("open", true)
    say("Pass, friend.")
  else
    say("Not today.")
  end
end)
```

## 11. LAN guest scripting

A guest is refused every scripting command outright until the host runs `/script trust <guestName>`
(scripting) and/or `/script trust <guestName> ai` (AI, a separate grant — neither implies the
other); `off` on either revokes it (`Sources/Elysium/LANTransport.swift:709-730`,
`grantPeerScript`). Once granted, `attr {set,define,remove}`, `script {attach,detach,run}`, `on`,
`unsubscribe`, `events {define,remove,emit}`, and `/ai`/`/agent` are sent as a `scriptIntent` message instead of
running locally — the guest never runs Lua themselves, ever
(`Sources/ElysiumCore/Scripting/ScriptingCommands.swift:118-137`, `lanForwardableCommand`); the host
re-validates the exact same predicate plus the peer's grant before dispatching through its own
`AttributeStore`/`ScriptStore`/`CustomEventStore`/`EventBus`, recording `Provenance.Author.lan(peer:)` instead of
`.player` so the write's origin stays distinguishable. Everything read-only (`inspect`, `objects`,
`events recent|list`) and every world-level `/script` subcommand (`trust`/`off`/`on`/`journal`/`undo-ai`/
`list`/`show`) stays host-only regardless of any grant — a guest reads only the host's replicated
attribute/script/event-declaration mirror (`/inspector`, editor, F3), never a live query. Custom
event metadata contains only the name, fields, and summary: no script source, declaration provenance,
or authority crosses to the guest. `/events list` remains a host-side live query, while the guest
editor uses the mirrored target catalog. That mirror is paged on the host's roughly one-second
metadata cadence: a rotating cursor eventually covers every loaded scripted object even when more
than 64 exist, and an explicit tombstone removes a guest entry after its last attribute, script, or
custom event declaration is deleted. Tombstone-bearing pages are not dropped as stale background
traffic and are requeued if a broadcast cannot be encoded or has no recipient; ordinary live
metadata pages remain low-priority and rotate back around after backpressure clears.
Wire revisions remain monotonic even if an object's final metadata is deleted and recreated at the
same canonical ref between censuses, so a guest cannot retain the old higher-revision mirror forever.
`self` in a guest's own forwarded command resolves to their
own `player:lan:<peerID>`, never the host's `player`. `/ai` forwarding
never lets a guest talk to Ollama directly: their prompt is relayed to the host's own tool loop,
sharing its one-in-flight-per-world gate, and only the final text comes back.

## 12. Worked examples

The first, second, and fourth scripts below are the exact Lua source (byte-for-byte, modulo
formatting whitespace) exercised by the elysmoke `scripting` golden suite
(`Sources/elysmoke/ScriptingSuiteSmoke.swift`), so the mechanics they show — subscribe-by-kind,
`h.attrs` read/write, `ai.await`, `emit`, a script attaching a script — are proven to actually run,
not just parse. The third is corrected relative to both the golden suite's harness and the original
design sketch it was drawn from; see the note under it for exactly what changed and why.

### A beacon that tracks a player's health (handler mode)

```lua
-- /script attach block:overworld:2,65,2 pulse handler attribute.changed <this body>
local low = ev.new / ev.subject.maxHealth < 0.3
self:setBlock(low and "glowstone" or "sea_lantern")
self.attrs.lastHealth = ev.new
```

Attached this way, the trigger fires on `attribute.changed` for the block itself, which isn't what
you want (a lamp doesn't change its own health) — this exact behavior needs the trigger aimed at
the *player*, which is only possible via `h:attach`'s own `opts.target`, from a small module wrapper
(the design this script was drawn from shows exactly this — `Sources/elysmoke/ScriptingSuiteSmoke.swift:105-153`
attaches it directly with `ScriptStore.attach(..., triggers: [Trigger(event: .attributeChanged,
attribute: "health", target: .object(.player))], ...)`, i.e. "watch the player's `health`, not the
lamp's own"). From chat, get the same result with `subscribe` in module mode instead:

```lua
-- /script attach <lamp> brain module <this body> — proven at ScriptingSuiteSmoke.swift:157-185
subscribe(player, "attribute.changed", {attr = "health"}, function(ev)
  self:setBlock(ev.new / player.maxHealth < 0.3 and "glowstone" or "sea_lantern")
end)
```

### The AI gatekeeper

The full `ai.await` script from §10 above — proven at `ScriptingSuiteSmoke.swift:187-245`, attached
to an entity as a module script (`on("entity.interacted", ...)`), with `self.attrs.doorRef` set
beforehand (via `/attr define <golem> door_ref ref:block:overworld:4,65,4` or an `h:define` call) to
point at the door it guards.

### Counting broken logs and publishing a typed milestone

```lua
-- /script attach world lumber module <this body>
world:declareEvent("lumber.milestone", {
  count = "integer",
  blockName = "string",
}, "The world-wide broken-log count reached a milestone")

subscribe({kind = "block"}, "block.broken", {}, function(ev)
  if not ev.blockName:find("_log", 1, true) then return end
  world.attrs.logs_broken = (world.attrs.logs_broken or 0) + 1
  if world.attrs.logs_broken % 64 == 0 then
    world:emit("lumber.milestone", {
      count = world.attrs.logs_broken,
      blockName = ev.blockName,
    })
  end
end)

world:on("lumber.milestone", function(ev)
  say(("Milestone: %d logs (last: %s)"):format(ev.count, ev.blockName))
end)
```

`block.broken.blockName` is the pre-removal registered block name, so the filter no longer needs to
guess from an air subject or rely on `block.changed.oldName`. The declaration makes the milestone
payload discoverable and strict; the handler can therefore complete and validate `ev.count` and
`ev.blockName` from the same contract.

### Scripts attaching scripts

```lua
-- /script attach player equip module <this body> — proven by ScriptingSuiteSmoke.swift
for _, b in ipairs(objects.find{kind = "block", type = "oak_sign", near = self, radius = 8, limit = 8}) do
  local has_greeter = false
  for _, attached in ipairs(b:scripts()) do
    if attached.name == "greeter" then has_greeter = true; break end
  end
  if not has_greeter then
    b:define("owner", self.ref, {readonly = true})
    b:attach("greeter", [[ say("Hello, " .. ev.by.name) ]], {on = "block.used"})
  end
end
```

`h.attrs` exposes custom attribute values, not attached script records. Use `h:scripts()` when the
decision depends on whether a script name is already attached; this keeps module reloads idempotent.
`h:attach`'s `source` argument is a normal Lua *string value* here (not a one-line chat command), so
it's written with Lua's `[[ ... ]]` long-bracket syntax — no escaping needed, and no chat-tokenizer
quoting rules apply once you're inside another script's own source (or the in-game editor).
