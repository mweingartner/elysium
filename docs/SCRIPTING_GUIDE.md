# Scripting Guide

Elysium's object graph, event bus, embedded Lua runtime, and AI tool loop let you (and the local
AI) attach small pieces of behavior to blocks, entities, players, dimensions, and the world itself.
This guide covers both halves: driving scripting from chat/the in-game editor, and writing the Lua
scripts themselves. It assumes you've read the "Scripting, attributes, events, and AI" section of
[PLAYER_GUIDE.md](../PLAYER_GUIDE.md) for the first-run picture; this document is the full
reference.

Every command and API call below is verified against the shipped source, cited by file. If a shown
example's exact byte-for-byte source is exercised by an automated test, that's noted too.

## 1. Overview and trust model

Every mutation — an attribute write, a script attach, a subscription, an emitted event — runs
through the same three executors regardless of who initiated it (you, another script, or the AI):
`AttributeStore`, `ScriptStore`, and `EventBus`. Two independent gates govern script execution,
re-checked every phase, never cached:

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
local-editor **Run Once** may execute only the visible draft once while the world is untrusted; it
does not save or attach that draft, trust the world, or load other scripts, but its permitted
live-world mutations may persist. It still refuses when `doScripts` is off. If no local runtime
exists, Check, Save, and Run Once are unavailable because authoritative validation cannot be
performed. Attached scripts, `/script run`, AI `run_script`, and LAN-forwarded runs remain fully
gated. The editor never auto-trusts a world.

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
  that grammar (say, AI- or script-supplied camelCase like `doorRef`) is silently normalized —
  lowercased, invalid bytes folded to `_` — rather than refused
  (`normalizedAttributeNameHint`, same file; `ScriptRuntimeAPI.normalizedCustomAttributeName`
  extends this leniency to every custom attribute write a script makes, not only the AI's).
  A custom attribute can be declared `readonly` (locked against a plain `/attr set` /
  `h:set`, only a `--force`d `/attr define` or `h:define(..., {force=true})` can overwrite it).
- **Up to 8 attached scripts** — Lua chunks in **module** or **handler** mode (§4). Source is
  capped at 16 KiB (`Sources/ElysiumCore/Scripting/ScriptStore.swift:31-32,97`).

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
  fixing its type at this initial value; `readonly` locks it, `--force` overwrites an existing
  readonly one. Trailing `readonly`/`--force` tokens are stripped from the end before the value is
  parsed — only `define` does this; `set`/`remove` don't strip anything, so an extra token there
  becomes part of the value (or is simply not accepted by `remove`, which takes no value). *(yes)*
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

### `/events recent [limit] | emit <target> <event>` — `Usage: /events recent [limit] | emit <target> <event>`

`recent` lists the most recent events the bus has seen. `emit` raises one by hand — any valid event
name, catalog or custom — payload-free. *(emit only, yes)*

### `/script ...` — `Usage: /script list [target] | show <target> <name> | attach <target> <name> module <source...> | attach <target> <name> handler <event> <source...> | detach <target> <name> | run <target> <source...> | journal | undo-ai [n] | trust | off | on`

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
- `journal [limit]` (default 32) — what `/ai` has done to this world, most recent first: request,
  entry, tick, tool, object, name, kind of change, model. Only AI mutations appear here. *(no)*
- `undo-ai [n]` (default 1) — reverts the `n` most recent `/ai` requests' worth of mutations, most
  recent first; refuses (rather than clobber) a script edited since the AI touched it. *(no)*
- `trust` — trusts the *current world* (§1). *(no)*
- `off` / `on` — the kill switch (§1). *(no)*
- `trust <peer> [ai] [off]` — **host-only, LAN**: grants/revokes a connected guest's scripting
  and/or AI permission (§10). Intercepted at the app layer before reaching this Core command set
  (`Sources/Elysium/CommandsM.swift:70-91`) — a different thing from the bare `/script trust` above.

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
dormant. The explicit editor Run Once executes only the visible draft once without saving or
attaching that draft. It can do that while the world remains untrusted, but it is not read-only and
its permitted one-off verbs can change live game state; those changes may persist with the world. It
still refuses when `doScripts` is off. If no local runtime exists, Check, Save, and Run Once are
unavailable because authoritative validation cannot be performed; the draft remains available to
copy. Run is synchronous, so the editor highlights
`wait`/`ai.await` and directs you to Save the script for attached, yieldable execution. Check uses a
throwaway coroutine and treats its first legal yield as a successful validation boundary without
scheduling it or contacting AI. The runtime validator remains authoritative and reports the
offending line. In handler mode, Check supplies the selected built-in event kind and deterministic,
non-null representative values for its registry-documented payload fields. A valid custom event has
no authoritative payload schema, so Check reports compile-only success and deliberately does not
execute that handler.

When attached execution is paused, the editor's persistent status banner offers the applicable
**Trust World**, **Turn On Scripts**, or **Trust & Turn On** action. Its confirmation warns that all
enabled scripts already attached across the world may start running. Confirming changes only the
named gate or gates; opening the editor, saving, checking, or running a draft never grants trust or
turns on the kill switch implicitly. The Run exception is deliberately local: ordinary
`/script run`, AI `run_script`, attached/background execution, and every guest-forwarded run
continue to require both gates.

The editor's local language service adds semantic styling, receiver-correct completion and
documentation, signature help, diagnostics, validated snippets, and a searchable **World Objects**
browser. Typing `.` or `:` opens the member list immediately; Control-Space requests completion
elsewhere. `self.attrs.` includes the current object's live custom attributes, while `objects.`,
`ai.`, `ev.`, the sandbox libraries, and locally inferred Lua tables each receive their own factual
members. These features never execute Lua and do not require Ollama.

Ollama editor proposals are optional and separate from factual completion. **Manual** is the
default: Option-Command-/ requests one insertion from the exact selected local model, Tab accepts,
and Escape dismisses/cancels. **Off** prevents editor requests, while **On Idle** is an explicit
opt-in that persists across application sessions. The editor provider is text-only and receives no world-mutation tools; Save/Check/Run are
still required to validate or execute accepted text. See [`LUA_EDITOR.md`](LUA_EDITOR.md) for the
complete UI, key, data-sharing, accessibility, and cancellation contract.

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
carries (`Sources/ElysiumCore/Scripting/ScriptRuntime.swift:347-360`, `eventValue`).

The v1 catalog (`Sources/ElysiumCore/Scripting/EventKind.swift:83-133`):

```
attribute.changed
block.placed  block.broken  block.replaced  block.changed  block.used
block.neighborChanged  block.scheduledTick
entity.spawned  entity.removed  entity.damaged  entity.died  entity.healed
entity.interacted  entity.targetChanged
player.joined  player.left  player.respawned  player.dimensionChanged
player.pickedUp  player.dropped  player.attacked  player.slept
player.leveled  player.advancement
dim.dayPhaseChanged  dim.weatherChanged
world.gameruleChanged  world.difficultyChanged
explosion
load  unload
timer.fired  ai.replied
script.faulted  script.attached  script.overBudget
```

Custom names (`emit("lumber.milestone", ...)`) share the exact same grammar: 1-4 dot-separated
segments, each `[a-z][a-z0-9_]{0,31}`, ≤ 64 bytes total (`EventKind.parse`). `attribute.changed`
and `block.changed` require a narrower subscription than `any`/a bare kind (a specific ref or a
type filter) — every other kind accepts a wildcard.

Payloads for events raised by the engine itself are fixed by their call site — a few verified ones:

| Event | Payload |
|---|---|
| `attribute.changed` | `key`, `old`, `new` (`GameCore+Scripting.swift`, `ScriptRuntime.swift:244-259`) |
| `block.broken` | `by` (ref), `item` (string or null) — **not** the broken block's name (`Sources/ElysiumCore/Systems/Interact.swift:1586-1588`) |
| `block.changed` | `oldName`, `newName`, `oldMeta`, `newMeta` — raised for *every* non-silent block write (placement, breaking, redstone, growth, …), not only player-initiated breaks, and only delivered when the cell already carries custom data or some subscription filters by that exact type name (`Sources/ElysiumCore/Scripting/EventBus.swift:403-419`) |
| `block.used` | `by` (ref), `item` (string or null) (`Sources/ElysiumCore/Game/GameCore.swift:5049-5057`) |
| `entity.interacted` | `by` (ref), `item` (string or null) (`GameCore.swift:5030-5039`) |

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
  ```
  `subscribe`'s target is the same shape `/on` and a script's `h:attach{target=...}` opt use: a
  handle, a canonical ref string, `{kind=..., type=...}`, or `"any"`
  (`Sources/ElysiumCore/Scripting/ScriptRuntimeAPI.swift:393-404`).

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
| `on(event, fn)` / `on(event, opts, fn)` | subscribe on `self`. `opts.attr`, `opts.target` narrow it; `opts.name = "foo"` also registers `fn` under that name (equivalent to calling `register("foo", fn)`) |
| `subscribe(target, event[, opts], fn)` | subscribe anywhere; `opts.attr` narrows |
| `every(n, handlerOrName)` / `after(n, handlerOrName)` | schedule after `n` ticks (§9). A **string** name schedules a durable, persisted timer that survives reload — only `every` with a name truly repeats. A **function** schedules a live, one-shot run — `every(n, fn)` behaves exactly like `after(n, fn)`, once only, not repeating (documented simplification; `ScriptRuntimeAPI.swift:429-436`) |
| `wait(n)` | yield the current handler for `n` ticks |
| `emit(name[, payload][, target])` | raise a custom event; default target is `self` |
| `tick()` | the current world tick |
| `rng()` / `rng(n)` / `rng(a,b)` | this script's own deterministic `RandomX` stream: `[0,1)`, `[1,n]`, or `[a,b]` |
| `say(text)` | a chat line from this object — the way to produce visible output; host-only, rate-limited, text-hygiene filtered |
| `sound(...)` / `particles(...)` | accepted (arguments loosely checked) but currently no-ops — not wired to audio/renderer yet |
| `dim(name)` | `"overworld"`/`"nether"`/`"end"` → that dimension's handle |
| `register(name, fn)` | name a function so `/on`, a durable `after`/`every`, or another `on(event, {name=...})` call can find it later |
| `objects.get(ref)` | a handle, or `nil`. Accepts a handle, a canonical ref string, or the aliases `"player"`/`"self"` (**both** resolve to your player — `objects.get("self")` is *not* the calling script's own object; use the `self` local for that) / `"world"` |
| `objects.find{kind=, type=, near=, radius=, limit=}` | handles sorted by distance then ref; `near` defaults to `self`'s position, `radius` defaults to 16, `limit` to 32 |
| `objects.block(dim, x, y, z)` | a block handle at that position (bounds-checked) |
| `ai.ask(prompt[, opts])` → `requestId` | fire-and-forget; reply arrives as an `ai.replied` event on `world` |
| `local text, err = ai.await(prompt[, opts])` | yields the handler until the reply (or `"timeout"`/`"budget"`). `opts` is accepted for forward compatibility but not currently read by either call — no field in it (e.g. a max-length hint) changes behavior today |

There is no bare `log(...)` global — calling it errors ("attempt to call a nil value"). There *is* a
`print(...)`, but it is not a player-facing print: it's wired to the sandbox's own log sink, which
writes to the host application's own console/stdout only (`[script] <line>`), never to chat, and
there is currently no `/script log` command to read it back in-game (`Sources/CLua/elysium_sandbox.c`,
the per-environment `print` closure; `Sources/ElysiumCore/Scripting/ScriptRuntime.swift:868-875`,
`ScriptRuntimeLogSink`). Use `say(text)` for anything a player should actually see.

### Handle properties and methods

Every object (`self`, `world`, `player`, anything from `objects.get`/`.find`/`.block`, or `ev.subject`/`ev.by`) is a handle:

| | |
|---|---|
| `h.ref`, `h.kind`, `h.name` | canonical ref text, kind string, display name |
| `h:exists()` | whether it currently resolves live |
| `h.<builtIn>` / `h.<builtIn> = v` | read/write a built-in field by dot-sugar; unknown/inapplicable reads as `nil`, an unknown write errors with a did-you-mean. Built-ins are matched snake_case-first, camelCase retried on a miss (`ev.subject.maxHealth` and `ev.subject.max_health` both work) |
| `h:get(name)` / `h:set(name, value)` | same read/write, by call instead of dot-sugar — works for both built-ins and custom attributes |
| `h.attrs.<name>` / `h.attrs.<name> = v` | a custom attribute directly; `= nil` removes it. **`pairs(h.attrs)` is not supported** (no iteration hook) — read/write named custom attributes individually with `:get`/`:set`/`h.attrs.<name>` |
| `h:define(name, value[, opts])` | declare a custom attribute; `opts = {readonly=true, force=true}` |
| `h:attach(name, source[, opts])` | attach a script. **No `opts.mode` field exists** — omitting `opts`, or omitting `opts.on`, always attaches module mode; supplying `opts.on = "<event>"` (plus optional `opts.attr`, and `opts.target = <a handle>` — a *handle value*, e.g. `player`, not a string; a plain string there is silently ignored) attaches handler mode, triggered on `opts.target` or `h` itself if omitted (`ScriptRuntimeAPI.swift:215-261`, `ScriptMarshaling.swift:114-118` for why it must be a handle) |
| `h:detach(name)` | remove a script |
| `h:scripts()` | `{name, mode, author, enabled, lastError}` for each script on `h` |
| `block:setBlock(name[, opts])` | replace the block; extra `opts` keys (besides the accepted-but-unused `notify`) are applied as built-in attribute writes, e.g. `{facing="north"}` |
| `block:breakBlock()` | break it naturally (drops items) |

Every mutating call above (attribute writes, `attach`/`detach`, `setBlock`/`breakBlock`, `emit`,
timers) is a no-op during the AI's dry-run validation pass (§9) — never during ordinary play.

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
reporting anything that looks wrong as a warning before it's ever saved for real).

Every successful AI mutation is journaled with `.ai(model)` provenance:

```
/script journal 5
req#7 entry#12 t9041 attach_script block:overworld:10,64,3 lamp [script] (llama3.1)
```

`/script undo-ai [n]` reverts the `n` most recent requests' worth, most recent first — an attribute
goes back to its previous value (or disappears if the AI created it), an attached script is
detached or restored — refusing instead of clobbering if you've edited that script yourself since.

Inside a script, `ai.ask`/`ai.await` (§8) reach the same local model, text-only, no tools, capped at
2 requests in flight and 30 per world per minute; over budget, `ai.ask` fires an
`ai.replied{error="budget"}` event immediately (no request is made) and `ai.await` returns
`nil, "budget"` the same way — never silently queued.

```lua
-- a gatekeeper golem, on entity-interact, asking the AI whether to let a player through
on("entity.interacted", function(ev)
  if ev.by.kind ~= "player" then return end
  local text, err = ai.await(("A player with %d health asks to pass. Answer YES or NO.")
                              :format(math.floor(ev.by.health)), {maxChars = 8})
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
`unsubscribe`, `events emit`, and `/ai`/`/agent` are sent as a `scriptIntent` message instead of
running locally — the guest never runs Lua themselves, ever
(`Sources/ElysiumCore/Scripting/ScriptingCommands.swift:118-137`, `lanForwardableCommand`); the host
re-validates the exact same predicate plus the peer's grant before dispatching through its own
`AttributeStore`/`ScriptStore`/`EventBus`, recording `Provenance.Author.lan(peer:)` instead of
`.player` so the write's origin stays distinguishable. Everything read-only (`inspect`, `objects`,
`events recent`) and every world-level `/script` subcommand (`trust`/`off`/`on`/`journal`/`undo-ai`/
`list`/`show`) stays host-only regardless of any grant — a guest reads only the host's replicated
attribute/script mirror (`/inspector`, F3), never a live query. `self` in a guest's own forwarded
command resolves to their own `player:lan:<peerID>`, never the host's `player`. `/ai` forwarding
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
beforehand (via `/attr define <golem> doorRef ref:block:overworld:4,65,4` or an `h:define` call) to
point at the door it guards.

### Counting broken blocks world-wide

```lua
-- /script attach world lumber module <this body> — proven at ScriptingSuiteSmoke.swift:249-293
subscribe({kind = "block"}, "block.broken", {}, function(ev)
  world.attrs.blocksBroken = (world.attrs.blocksBroken or 0) + 1
  if world.attrs.blocksBroken % 64 == 0 then
    emit("lumber.milestone", {count = world.attrs.blocksBroken})
  end
end)
```

**A deviation from the original design sketch, verified and corrected here:** the design document
this script was drawn from (and the golden-suite test that proves the mechanics above) filters on
`ev.oldName:find("_log", 1, true)` to count specifically broken logs. That relies on `block.broken`
carrying an `oldName` field — it doesn't, in the shipped game: the event's real payload is `{by,
item}` (§7's table), and by the time any handler observes `ev.subject`, the block has already been
replaced with air, so there is currently no reliable way for a `block.broken` handler alone to learn
what type the broken block *was*. The script above is corrected to count every broken block instead
of only logs, which the shipped payload genuinely supports; a script wanting to react to one
specific block type should filter at the *subscription* level today (`{kind="block", type="oak_log"}`
in `subscribe`/`objects.find`), not by reading a name field off `ev` for `block.broken`.

### Scripts attaching scripts

```lua
-- /script attach player equip module <this body> — proven at ScriptingSuiteSmoke.swift:297-330
for _, b in ipairs(objects.find{kind = "block", type = "oak_sign", near = self, radius = 8, limit = 8}) do
  if not b.attrs.greeter then
    b:define("owner", self.ref, {readonly = true})
    b:attach("greeter", [[ say("Hello, " .. ev.by.name) ]], {on = "block.used"})
  end
end
```

`h:attach`'s `source` argument is a normal Lua *string value* here (not a one-line chat command), so
it's written with Lua's `[[ ... ]]` long-bracket syntax — no escaping needed, and no chat-tokenizer
quoting rules apply once you're inside another script's own source (or the in-game editor).
