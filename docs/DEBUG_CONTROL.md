# Elysium Interactive Debug Control

Elysium's interactive control plane is a development-only way to inspect and drive a real
running game. It can create and load isolated debug worlds, control the player and simulation,
exercise production interaction/UI paths, manipulate bounded world regions, manage object
templates and RPG characters, and capture the rendered frame. It is not a general remote shell
and it is not present in the production `Elysium.app` executable.

The implementation source of truth is:

- [`DebugControlServer.swift`](../Sources/Elysium/DebugControlServer.swift) for listener,
  discovery, authentication, framing, and connection lifecycle.
- [`DebugControlRuntime.swift`](../Sources/Elysium/DebugControlRuntime.swift) for the operation
  allowlist, bounds, authority checks, snapshots, and capture coordination.
- [`DebugScreenSemantics.swift`](../Sources/Elysium/DebugScreenSemantics.swift) for stable
  screen/slot/action adapters over the real UI.
- [`ElysiumDebugProtocol`](../Sources/ElysiumDebugProtocol/) for manifest validation, handshake
  messages, authenticated frames, request/response models, and error codes.
- [`elydebug`](../Sources/elydebug/) for the supported command-line client.
- [`package-debug-app.sh`](../scripts/package-debug-app.sh) for the separate debug package.

## Security and trust model

The controller is intentionally a high-authority same-user development capability. A process that
can read the owner-only session manifest can mutate or delete data in the debug profile, drive the
game, capture its window, and quit it. The boundary protects against LAN peers, accidental HTTP
traffic, stale manifests, frame corruption/replay, and other local users. It is not intended to
protect the debug session from malicious software already running as the same macOS user or from a
privileged process.

The concrete controls are:

- The listener exists only in a build compiled with `ELYSIUM_DEBUG_CONTROL`, and starts only when
  that executable is launched with `--debug-control`.
- The listener binds an ephemeral TCP port on `127.0.0.1`; it is not advertised with Bonjour and
  cannot be configured to accept a non-loopback host.
- Discovery is through
  `~/Library/Caches/Elysium Debug/Control/session.json`. The control directory is mode `0700`; the
  regular, single-link manifest is mode `0600` and contains a random 256-bit session token.
- The CLI validates the manifest's ownership, permissions, size, process start time, executable
  path/device/inode, and executable SHA-256 before connecting. The server uses the same secure
  validator when deciding whether an existing manifest is live and when revoking its own manifest.
  A live manifest prevents a second debug session from replacing it.
- Every connection receives a fresh 32-byte server challenge. HKDF-SHA256 binds the manifest token,
  challenge, session UUID, and executable build identifier into a per-connection key.
- Frames have directional keys, HMAC-SHA256 authentication, transcript chaining, and exact
  monotonically increasing sequence numbers beginning at 1. Replayed, skipped, reordered,
  malformed, oversized, or unauthenticated frames close the connection.
- The wire is authenticated but not encrypted. This is acceptable only because the endpoint and
  credential are confined to the local same-user development boundary.
- Incoming JSON is preflighted before `Codable` decoding: depth, object members, array elements,
  strings, and total frame size are bounded. Request payloads are limited to 64 KiB.
- There is one active controller and at most one pending handshake. A newly authenticated pending
  controller replaces the previous active connection. Handshake timeout is 3 seconds, idle timeout
  is 300 seconds, and the server accepts at most 256 requests per second. Requests are serialized;
  clients must wait for each response before sending the next request.
- All game and UI operations cross onto the main actor. Direct mutation is bounded and registry
  checked; semantic operations call the same placement, interaction, screen, template, and RPG
  entry points used by the game.
- There is no operation for shell execution, process launch, arbitrary SQL, arbitrary file access,
  dynamic code loading, or unrestricted network access.

Do not share `session.json`, paste it into logs, or commit it. The token is a live credential. The
CLI deliberately never prints it.

## Production separation and isolated data

The production package and debug package are separate capabilities:

| Property | Production app | Debug app |
|---|---|---|
| Bundle | `Elysium.app` | `Elysium Debug.app` |
| Bundle identifier | `com.briangao.elysium` | `com.briangao.elysium.debug` |
| Main executable | `Elysium` | `ElysiumDebug` |
| Debug marker and protocol module | Forbidden by the production binary scan | Required in the debug executable |
| Control listener | Not compiled into the executable | Compiled, but opt-in with `--debug-control` |
| Application Support | `~/Library/Application Support/Elysium/` | `~/Library/Application Support/Elysium Debug/` |
| Package command | `bash scripts/package-app.sh ...` through the release workflow | `bash scripts/package-debug-app.sh` |

The debug build uses the isolated Application Support directory whether or not the listener is
requested. Its worlds, player state, settings, templates, resource-pack copies, and database do not
reuse or migrate the production profile. The normal release pipeline still packages and installs
only `/Applications/Elysium.app`; it does not package or install the debug app.

The source security scan requires all three app-side control files to remain wholly inside the
compile-time guard. The ordinary package graph omits `ElysiumDebugProtocol` from the app target;
the production binary scan rejects both that module and the exported
`elysium_debug_control_build_marker_v1` marker. The isolated debug packager explicitly opts into
the dependency and compile definition, requires the marker in the debug app, and forbids it in the
`elydebug` helper.

## Build, launch, and connect

From the repository root, build the warning-free optimized debug package:

```bash
bash scripts/package-debug-app.sh
```

This creates and signs `dist/Elysium Debug.app` using a dedicated `.build/debug-app` scratch tree.
The command ends with `install=not_performed`; packaging is not deployment.

Launch the packaged app with the endpoint explicitly enabled:

```bash
open -na "$PWD/dist/Elysium Debug.app" --args --debug-control
```

Wait for the window title `Elysium Debug — CONTROL ACTIVE`, the HUD readiness notice, or the
`[debug-control] ready` log line. Then use the helper bundled with that same package:

```bash
"$PWD/dist/Elysium Debug.app/Contents/Helpers/elydebug" status
"$PWD/dist/Elysium Debug.app/Contents/Helpers/elydebug" capabilities
"$PWD/dist/Elysium Debug.app/Contents/Helpers/elydebug" snapshot
```

The helper defaults to the standard manifest path. `--manifest PATH` selects an explicit manifest,
and `--timeout SECONDS` sets a 0.1 through 300 second connect/request timeout (10 seconds by
default). Global options precede the command.

### Installing the debug bundle

There is intentionally no repository script that installs the privileged control build. To place a
debug candidate in Applications, first quit Elysium Debug and move any existing
`/Applications/Elysium Debug.app` out of the way as a whole bundle; do not overlay a new package on
an old one. Then copy and verify the candidate:

```bash
/usr/bin/ditto "$PWD/dist/Elysium Debug.app" "/Applications/Elysium Debug.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "/Applications/Elysium Debug.app"
open -na "/Applications/Elysium Debug.app" --args --debug-control
"/Applications/Elysium Debug.app/Contents/Helpers/elydebug" status
```

That is a debug deployment only. It says nothing about `/Applications/Elysium.app`, the production
release pipeline, Git state, GitHub state, or visual approval.

## `elydebug` commands

```text
elydebug [--manifest PATH] [--timeout SECONDS] COMMAND

status                         session.status
snapshot [JSON_OBJECT]         state.snapshot
capabilities                   session.capabilities
request OP [JSON_OBJECT]       one allowlisted runtime operation
scenario JSONL_PATH            multiple request envelopes on one connection
stream                         incremental JSONL from stdin on one connection
help                           usage
```

Inline JSON must be a JSON object and is limited to 64 KiB. Output is sorted JSON. Exit statuses are
`0` success, `2` usage error, `3` manifest error, `4` transport error, `5` protocol error, and `6`
for a typed remote failure.

`scenario` preloads and validates a regular UTF-8 JSONL file before connecting. It allows at most
8 MiB, 4,096 nonblank steps, and 64 KiB per line. Each line may contain only
`protocolVersion`, `id`, `operation`, `arguments`, `expectedEpoch`, `expectedRevision`, and
`deadlineUptimeNanoseconds`. Missing protocol version, UUID, arguments, or deadline receive safe
defaults. The scenario stops after the first remote failure and prints one response per attempted
line.

`stream` is the real-time agent path. It reads at most 64 KiB per line and sends each request as
soon as the newline arrives without preloading stdin. It retains one authenticated connection,
flushes one response per request, stops on the first remote failure, and requires reconnecting after
4,096 requests. On another Mac, invoke the helper there through the node's pinned SSH session; do
not copy that node's manifest or session token to the controller.

Example scenario:

```jsonl
{"operation":"world.create","arguments":{"name":"Control Lab","seed":"24680","mode":1,"difficulty":2,"preset":"minecraft:flat","biome":"plains","dungeonDensity":1,"rpgClassesEnabled":true}}
{"operation":"simulation.pause"}
{"operation":"interaction.action","arguments":{"action":{"action":"give_item","item":"diamond","count":16}}}
{"operation":"interaction.action","arguments":{"action":{"action":"set_gamemode","mode":"survival"}}}
{"operation":"simulation.step","arguments":{"ticks":1}}
{"operation":"state.snapshot","arguments":{"scopes":["world","player","inventory","screen"]}}
{"operation":"render.capture","arguments":{"includeUI":true}}
```

Run it with:

```bash
"$PWD/dist/Elysium Debug.app/Contents/Helpers/elydebug" scenario /absolute/path/to/scenario.jsonl
```

## Discovery, handshake, and frames

The manifest is bounded JSON with manifest/protocol versions, session UUID, PID and process start
identity, canonical executable identity, ephemeral port, executable SHA-256/build identifier,
creation time, and token. The CLI opens and validates it without following symlinks, connects only
to `127.0.0.1:<manifest port>`, and verifies the live process before using the credential.

Connection sequence:

```text
server -> client: 32-byte random challenge
client/server:     derive connection key from token + challenge + session + build
client -> server: authenticated clientHello frame (session + build identity)
server -> client: authenticated serverHello frame (session + capabilities + limits)
client -> server: authenticated request frames
server -> client: authenticated response frames
```

Protocol version 1 uses a 20-byte big-endian header followed by payload and a 32-byte HMAC tag:

| Header field | Width | Contract |
|---|---:|---|
| Magic | 4 bytes | ASCII `ELYD` (`0x454c5944`) |
| Protocol version | 2 bytes | `1` |
| Frame kind | 2 bytes | client hello `1`, server hello `2`, request `3`, response `4`, event `5`, close `6` |
| Sequence | 8 bytes | Exact next sequence for that direction, starting at `1` |
| Payload length | 4 bytes | Bounded before allocation/JSON decode |

The frame codec's absolute payload ceiling is 1 MiB. The negotiated request limit is 64 KiB;
snapshots/responses may use the 1 MiB ceiling. Each directional transcript includes all prior
authenticated frames, so a valid frame cannot be transplanted into a different position or
direction.

The request JSON model is:

```json
{
  "protocolVersion": 1,
  "id": "7b5d1b61-3111-4da3-bd44-7eacfb8a276c",
  "operation": "state.snapshot",
  "arguments": {"scopes": ["player", "target"]},
  "expectedEpoch": 2,
  "expectedRevision": 9,
  "deadlineUptimeNanoseconds": 123456789000
}
```

`expectedEpoch` protects a request from crossing a world create/load/exit/delete/dimension boundary,
including a transition made outside the control port once the runtime observes it.
`expectedRevision` is optimistic concurrency for control-plane mutations only; ordinary player
input, realtime simulation, renderer progress, and LAN replication are observed by taking a fresh
snapshot and are not revision sources. The deadline is an absolute value from the local monotonic
uptime clock, not wall-clock time. All three fields are optional when using the generic request
command; the CLI supplies a deadline.

The runtime caches up to 512 request UUIDs within an 8 MiB encoded-response budget. Retrying an
identical request UUID and body returns the cached response rather than performing the mutation
twice. Reusing that UUID with different content is rejected. A duplicate asynchronous capture while
the first request is still running returns retryable `busy`; retrying after completion returns the
cache. Any response that would exceed 1 MiB becomes a typed `boundedLimit` response rather than a
transport disconnect. Responses contain exactly one of `result` or `error`, plus the current epoch,
revision, and event sequence when available.

The runtime retains the most recent 4,096 events. The negotiated capability and request operation
are both `events.replay`; use it to poll by sequence. The server does not currently push unsolicited
event frames and there is no subscribe/watch CLI command. This replay is an audit of accepted
control-port mutations and world-boundary commands, not a general engine event bus; observe human
input, ordinary simulation, workstation progress, renderer state, and LAN replication by polling
bounded snapshots.

## Operation catalog

The following is the complete top-level operation allowlist implemented by the runtime. The JSON in
the last column is the argument object passed to `elydebug request`; `...` and angle-bracket values
mean “substitute a value discovered from the corresponding registry or snapshot.” Empty `{}` may be
omitted from the CLI.

Context labels used below:

- **Any**: no world is required.
- **World**: a loaded world is required; local view/input may be used in a LAN client world.
- **Authority**: a loaded local world or LAN host is required; a LAN client receives
  `forbiddenInLANClient`.
- **No world**: the operation requires the title/no-active-world state.
- **Screen**: a compatible live screen is required and may independently be read-only.

### Session, registries, state, and events

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `session.capabilities` | Any | `{}` | Negotiated capability families and payload/replay limits. |
| `session.status` | Any | `{}` | Session, epoch, revision, event sequence, world-loaded flag, and `isolated-debug` profile. |
| `registry.items` | Any | `{}` | Every registered item's numeric id, name, display name, and maximum stack. |
| `registry.blocks` | Any | `{}` | Every registered block's numeric id, name, and display name. |
| `registry.entities` | Any | `{}` | Sorted spawnable entity names. |
| `registry.world_presets` | Any | `{}` | Accepted world-preset ids and display names. |
| `registry.biomes` | Any | `{}` | Accepted biome names, numeric ids, and display names. |
| `registry.dungeon_densities` | Any | `{}` | Accepted integer density ids and display names. |
| `registry.rpg` | Any | `{}` | Paths, branches/subclasses, starting-skill pools, skills, and spells. |
| `state.snapshot` | Any | `{"scopes":["app","world","player","target","inventory","rpg","screen","entities","region","renderer","network"],"limit":256,"radius":2,"x":0,"y":64,"z":0}` | Identity-stamped bounded state sections. Unknown well-formed scope names return `null`. |
| `events.replay` | Any | `{"after":120,"limit":256}` | Retained events with sequence greater than `after`; limit clamps to `1...4096`. |

`state.snapshot` defaults to all implemented scopes except `region`. `limit` clamps to `1...1024`.
The `region` radius clamps to `0...8`, defaults to the player's block position, returns non-air
blocks only with raw `cell`, orientation/state `meta`, registry id/name, and block-entity type, and
reports truncation in `truncatedScopes`. Player/inventory/screen projections include bounded status
effects, enchantments, potion/trim/item metadata, and furnace/brewing progress where applicable.
Snapshot identity includes session,
epoch, revision, event sequence, simulation tick, dimension, screen generation, and registry
generation.

### LAN lifecycle and status

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `lan.status` | Any | `{}` | Redacted state, role, protocol version, client counts, discovery count, listening port, and explicit transport-security classification. Never returns join codes, peer IDs, addresses, or raw status lines. |
| `lan.host` | Authority | `{"joinCode":"A1B2C3D4","port":41337}` | Starts protocol-5 hosting for the active authoritative debug world. The join code is required but is not returned. |
| `lan.direct_connect` | No world | `{"host":"10.0.10.153","port":41337,"joinCode":"A1B2C3D4","playerName":"Neo Probe"}` | Starts a direct client connection; poll `lan.status` until connected or failed. |
| `lan.stop` | Any | `{}` | Stops browsing/hosting/client transport and clears replication hooks. |

These operations configure the real LAN manager; they do not proxy game traffic through the debug
protocol. Protocol 5 remains explicitly reported as `trusted-lan-plaintext`, so this is a private
test-LAN capability, not an internet-facing security boundary.

### World lifecycle, simulation, player, and inventory

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `world.list` | Any | `{"offset":0,"limit":128}` | Saved worlds in the isolated debug profile, paged at no more than 256 records with `total` and `nextOffset`. |
| `world.create` | Not LAN client | `{"name":"Control Lab","seed":"24680","mode":1,"difficulty":2,"preset":"minecraft:normal","biome":"plains","dungeonDensity":2,"rpgClassesEnabled":true}` | Exits an active world, creates and enters a new one, then advances epoch/revision. Mode is `0` survival or `1` creative; difficulty is `0...3`. Use the registries for preset/biome/density values. |
| `world.load` | Not LAN client | `{"id":"<id from world.list>"}` | Exits an active world, loads the selected debug-profile world, and advances epoch/revision. |
| `world.save` | Authority | `{}` | Safely closes transient screens and synchronously verifies world, player, advancements, and chunk persistence. |
| `world.exit` | World | `{}` | Returns to title and advances epoch/revision. This is allowed for a LAN client because it exits rather than mutates host state. |
| `world.delete` | No world | `{"id":"<id from world.list>"}` | Deletes the named isolated-profile world and advances epoch/revision. |
| `simulation.pause` | Authority | `{}` | Enables the manual simulation clock. Rendering/streaming remains live. |
| `simulation.resume` | Authority | `{}` | Restores the ordinary simulation clock. |
| `simulation.step` | Authority | `{"ticks":1}` | Enables the manual clock and advances `1...20` ticks deterministically. |
| `player.teleport` | Authority | `{"x":10.5,"y":72,"z":-4.5}` | Teleports, clears velocity/fall distance; X/Z are within the 30-million world bound and Y must be in the dimension. |
| `player.look` | World | `{"yaw":1.57,"pitch":0}` | Sets finite yaw/pitch in radians; yaw is normalized to one turn and pitch must be within `-pi/2...pi/2`. |
| `player.flying` | Authority | `{"enabled":true}` | Changes flight; enabling requires creative mode. |
| `inventory.select` | Authority | `{"slot":0}` | Selects hotbar slot `0...8`. |

### Scripting

`script.*` calls straight into the same Core `ScriptingCommands.run(command: "script", ...)`
executors `/script` uses (`docs/scripting-and-eventing-design.md` §12) — never a second
implementation, so the validator, the 8-scripts-per-object cap, the trust gate, and the kill
switch all apply exactly as they do in chat. Every `script.*` op is **Authority**-gated (a LAN
client is refused, matching `/script` itself, which does not yet distinguish read from write —
that split is `lan-client-parity`'s job). The response always has the shape `{"ok": bool,
"lines": [string, ...]}`: `ok: false` means the *script* operation was refused (bad name, no
such script, a validation/compile error) while the request itself still succeeded — a protocol
error (missing world, wrong arguments) is a normal `error` response instead. `target` defaults
to `"looking"` (the crosshair) when omitted, matching the `/script` CLI default; `source` is
carried as one JSON string, never split, so multi-line Lua survives byte-exact.

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `script.list` | Authority | `{"target":"self"}` | `lines`: one summary per attached script (`name [mode] (disabled)? — lastError?`). |
| `script.show` | Authority | `{"target":"self","name":"greet"}` | `lines`: the full record — header, author/created/api, triggers, `lastError`, and up to 30 lines of source. |
| `script.attach` | Authority | `{"target":"self","name":"greet","mode":"module","source":"log('hi')"}` | Validates and attaches (or replaces) a script; takes effect next script phase. `mode:"handler"` additionally requires `"event":"<event name>"`. |
| `script.run` | Authority | `{"target":"self","source":"log('hi')"}` | Runs `source` once, ephemerally (never persisted, never subscribed — §9.3's capability-reduced `run_script`). |
| `script.journal` | Authority | `{"limit":32}` | `lines`: the most recent AI journal entries (`limit` `1...256`, default 32); `ok:false` with an explanatory line when no AI journal exists this session. |

### Interaction, environment, and entities

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `interaction.action` | Authority | `{"cursor":{"x":2,"y":64,"z":2,"face":1},"action":{"action":"use_block","target":"cursor"}}` | Runs a bounded `AIAgentAction` through production interaction/game routines. Omit `cursor` to use the live crosshair; face is `0...5`. See the nested action table below. |
| `interaction.bed_click` | Authority | `{"cursor":{"x":2,"y":63,"z":2,"face":1}}` | Sends one explicit validated hit through the production two-left-click bed-selection path. Call once for the head and again for an adjacent same-height foot while a bed is selected. |
| `world.set_block` | Authority | `{"x":2,"y":64,"z":2,"block":"oak_planks"}` | Direct debug setup of one registered block or `air`. |
| `world.fill` | Authority | `{"minX":0,"minY":64,"minZ":0,"maxX":3,"maxY":64,"maxZ":3,"block":"stone"}` | Preflights then fills an ordered box of at most 4,096 blocks. |
| `entity.spawn` | Authority | `{"type":"zombie","x":2,"y":65,"z":2,"count":1}` | Spawns `1...16` persistent registered mobs at a bounded loaded target. |

Direct block/fill/entity targets must be in a loaded chunk, within the current dimension's height,
and no more than 256 blocks from the player in X and Z. Those direct operations are intended for
bounded test setup. Prefer `interaction.action` when testing placement, breaking, workstation,
inventory, game-rule, or player behavior because it reuses production semantics.

`interaction.action` accepts this canonical nested action set (aliases accepted by the underlying
game code are intentionally omitted):

| Nested action | Example `action` object | Behavior and principal bound |
|---|---|---|
| `say` | `{"action":"say","message":"state inspected"}` | Sanitized message only; no mutation. |
| `give_item` | `{"action":"give_item","item":"diamond","count":16}` | Gives a registered item, capped at 640 and actual inventory capacity. |
| `place_block` | `{"action":"place_block","target":"cursor","block":"oak_planks"}` | Places through the production placement path adjacent to the supplied/live cursor. |
| `set_block_at_cursor` | `{"action":"set_block_at_cursor","target":"cursor","block":"air"}` | Replaces the cursor cell with a registered block or air. |
| `break_block` | `{"action":"break_block","target":"cursor"}` | Breaks the cursor block through the production break path. |
| `use_block` | `{"action":"use_block","target":"cursor"}` | Uses/opens the cursor block through production interaction; use this for furnaces, crafting tables, chests, brewing, enchanting, anvils, grindstones, stonecutters, smithing tables, beacons, doors, beds, and other interactable blocks. |
| `fill_hole` | `{"action":"fill_hole","target":"front","block":"dirt"}` | Bounded terrain-aware hole fill chosen in front of the player. |
| `fill_region` | `{"action":"fill_region","target":"cursor","block":"stone","radius":1}` | Cube around the placement side of the cursor; radius `0...6`, at most 4,096 blocks. |
| `rework_biome` | `{"action":"rework_biome","profile":"rolling_hills_resource_rich"}` | Reworks only the loaded contiguous current-biome patch through the sole supported profile. |
| `set_time` | `{"action":"set_time","time":"noon"}` | Sets normalized day time from a supported name/numeric string or integer `ticks`. |
| `set_weather` | `{"action":"set_weather","weather":"thunder"}` | Sets `clear`, `rain`, or `thunder`. |
| `spawn_entity` | `{"action":"spawn_entity","target":"cursor","entity":"zombie","count":2}` | Production cursor-relative spawn of a registered entity, capped at 16. |
| `remove_entities_nearby` | `{"action":"remove_entities_nearby","entity":"zombie","radius":16,"count":8}` | Removes sorted non-player entities; radius caps at 48 and count at 128. Use `all`, `item`, or `xp_orb` for supported broad filters. |
| `eat_selected_food` | `{"action":"eat_selected_food"}` | Consumes the selected food immediately through interaction logic. |
| `set_gamemode` | `{"action":"set_gamemode","mode":"creative"}` | Sets `survival` or `creative` and disables incompatible flight. |
| `heal_player` | `{"action":"heal_player"}` | Restores health, hunger, and saturation. |
| `damage_player` | `{"action":"damage_player","amount":4}` | Magic damage from `1...2048`. |
| `apply_effect` | `{"action":"apply_effect","effect":"speed","duration":30,"amplifier":1}` | Registered effect for 1...3,600 seconds, amplifier `0...4`; use `clear` to clear effects. |
| `clear_inventory` | `{"action":"clear_inventory"}` | Clears inventory, armor, and offhand. |
| `add_xp` | `{"action":"add_xp","amount":100,"levels":false}` | Adds `1...100000` XP points, or levels when `levels` is true. |
| `set_spawnpoint` | `{"action":"set_spawnpoint"}` | Saves the player's current block position and dimension as spawn. |
| `set_difficulty` | `{"action":"set_difficulty","value":"hard"}` | Sets peaceful/easy/normal/hard through the game callback. |
| `set_gamerule` | `{"action":"set_gamerule","rule":"doDaylightCycle","enabled":false}` | Updates an existing game rule only. |
| `teleport_player` | `{"action":"teleport_player","target":"surface"}` | Moves vertically to the loaded surface at the current X/Z. |

The `replace_template_blocks` and `create_template` AI-helper actions are not reachable through
`interaction.action`; use the top-level `template.*` operations instead.

### Raw input

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `input.key_down` | World | `{"key":"KeyW","command":false}` | Sends one internal key-down; `command` supplies Command/control semantics. |
| `input.key_up` | World | `{"key":"KeyW"}` | Releases one internal key. |
| `input.mouse_delta` | World | `{"dx":12,"dy":-4}` | Sends finite relative look movement bounded to `+/-10000` per axis and normalizes resulting yaw. |
| `input.mouse_down` | World | `{"button":0}` | Holds primary `0` or secondary `2`. |
| `input.mouse_up` | World | `{"button":0}` | Releases primary `0` or secondary `2`. |
| `input.wheel` | World | `{"direction":1}` | Moves the hotbar by exactly `-1` or `1`. |
| `input.clear` | Any | `{}` | Clears held input; also performed when a controller disconnects. |

Key values use Elysium's internal DOM-like names such as `KeyW`, `Digit1`, `Space`, and `Escape`.
Raw input intentionally does not advance the debug revision; follow it with a snapshot or an
explicit state precondition when observing its result.

### Screens and workstations

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `screen.snapshot` | Any | `{}` | Current screen kind/instance/read-only state, cursor stack, slots, buttons, actions, and fields. |
| `screen.open` | Authority | `{"kind":"inventory"}` | Opens exactly one of `inventory`, `creative`, `templates`, `templatesPlace`, `map`, or `rpg`. Workstations are deliberately excluded. |
| `screen.slot` | Screen | `{"id":"crafting.0","button":0,"shift":false,"instance":"<snapshot instance>"}` | Clicks a semantic slot through the real slot handler. Button is `0` or `2`. |
| `screen.transfer` | Screen | `{"from":"player.inventory.0","to":"furnace.input","instance":"<snapshot instance>"}` | Moves, merges, or swaps two distinct ordinary non-output slots through the production click path, leaving the UI cursor empty. |
| `screen.button` | Screen | `{"id":"<button id from snapshot>","instance":"<snapshot instance>"}` | Activates an enabled, visible real button. |
| `screen.action` | Screen | `{"id":"enchanting.option.0","instance":"<snapshot instance>"}` | Activates an enabled non-slot semantic/accessibility action. |
| `screen.field` | Screen | `{"id":"<field id from snapshot>","value":"new value","instance":"<snapshot instance>"}` | Replaces an enabled field with at most 4,096 UTF-8 bytes. |
| `screen.key` | Screen | `{"key":"Escape","instance":"<snapshot instance>"}` | Sends a key to the current screen's real key handler. |
| `screen.close` | Screen | `{"instance":"<snapshot instance>"}` | Closes the top screen. |

Always read `screen.snapshot`, select ids from that response, and pass its required `instance` on a
subsequent mutation. If the screen identity/presentation generation changed, the mutation fails
with `staleScreen` instead of acting on a different UI.

Stable slot prefixes exposed when applicable are:

- Inventory: `armor.head`, `armor.chest`, `armor.legs`, `armor.feet`, `offhand`,
  `crafting.0...3`, `crafting.output`.
- Crafting table: `crafting.0...8`, `crafting.output`.
- Furnace-family screen: `furnace.input`, `furnace.fuel`, `furnace.output`.
- Brewing: `brewing.bottle.0...2`, `brewing.ingredient`, `brewing.fuel`.
- Enchanting: `enchanting.item`, `enchanting.lapis`.
- Anvil: `anvil.left`, `anvil.right`, `anvil.output`.
- Grindstone: `grindstone.top`, `grindstone.bottom`, `grindstone.output`.
- Stonecutter: `stonecutter.input`, `stonecutter.output`.
- Smithing: `smithing.template`, `smithing.base`, `smithing.addition`, `smithing.output`.
- Beacon: `beacon.payment`.
- Generic/chest containers: `container.N`; player inventory: `player.inventory.N`.

Known generated actions include `enchanting.option.0...2`,
`stonecutter.recipe.0...11`, `beacon.power.speed`, `beacon.power.haste`,
`beacon.power.resistance`, `beacon.power.jump_boost`, `beacon.power.strength`, and
`beacon.confirm`. Trading and other screens may contribute additional accessibility actions.
Buttons include a dynamic index suffix. Never synthesize either kind of id; discover the live
enabled ids from `screen.snapshot`.

Prefer `screen.transfer` for a one-command ordinary-slot move or swap. Output slots are excluded
because taking one can commit crafting, XP, smelting, or trade side effects before a destination is
known; use one `screen.slot` shift-click to collect an output without leaving a cursor stack. If a
test genuinely needs a multi-click cursor gesture, put all clicks in one JSONL `scenario` so they
share one connection. Separate `elydebug request` invocations each disconnect after their response.
On disconnect, any remaining cursor stack is returned to player inventory and dropped into the
world only if the inventory is full, preventing a stranded UI-cursor item.

A workstation flow is therefore:

1. Aim at it or supply a valid cursor and call `interaction.action` with nested `use_block`.
2. Call `screen.snapshot` and retain `instance`.
3. Move ordinary items with `screen.transfer`, collect outputs with a shift-click `screen.slot`,
   choose recipes/powers/offers with `screen.action`, and edit fields or press a discovered button
   when applicable.
4. Snapshot after each material transition. Close with the last observed instance.

This route exercises the same furnace, crafting, container, brewing, enchanting, anvil,
grindstone, stonecutter, smithing, beacon, and trading screen logic as a player. It does not expose
an out-of-band “set workstation contents” shortcut.

### Object templates

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `template.list` | Any | `{"offset":0,"limit":128}` | Bounded summaries from the isolated template store, paged at no more than 256 records. |
| `template.copy` | Authority | `{"name":"test_house","x":2,"y":64,"z":2}` | Clones the connected object rooted at the target, at most 8,192 blocks and 96 cells per span, then stores it. |
| `template.generate` | Any | `{"name":"test_ship","kind":"pirate_ship","length":24,"style":"oak"}` | Generates and stores a bounded `pirate_ship`, `ship`, or `boat`. |
| `template.place` | Authority | `{"name":"test_house","x":20,"y":64,"z":20,"rotation":1,"replaceExisting":false,"prepareTerrain":false}` | Preflights and places at most 8,192 blocks, retaining one world-bound debug undo snapshot. Terrain preparation is limited to 65,536 scanned cells. |
| `template.undo` | Authority | `{}` | Restores the most recent compatible debug placement in the same world/dimension once, only while its full region is loaded. |
| `template.delete` | Any | `{"name":"test_house"}` | Deletes the normalized exact-name template from the isolated store. |

Template names follow the existing normalized template contract and are limited to 48 bytes at
the control boundary. Copy/place coordinates use the same loaded/height/256-block setup bound as
other direct targets. A world boundary clears the one-level debug undo snapshot.

### RPG character and actions

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `rpg.create` | Authority | `{"path":"<path id>","branch":"<branch id>","startingSkills":["<skill 1>","<skill 2>","<skill 3>"]}` | Requests character creation. Use `registry.rpg`; the selection must be exactly three unique skills from that path/branch's five-skill pool. |
| `rpg.learn` | Authority | `{"skill":"<registered skill id>"}` | Requests the next rank of a skill. |
| `rpg.prepare_skill` | Authority | `{"skill":"<registered active skill id>"}` | Toggles a learned active skill in the prepared set. |
| `rpg.prepare_spell` | Authority | `{"spell":"<registered known spell id>"}` | Toggles a known spell in the prepared set. |
| `rpg.select_skill` | Authority | `{"skill":"<prepared skill id>"}` | Selects a prepared active skill. |
| `rpg.select_spell` | Authority | `{"spell":"<prepared spell id>"}` | Selects a prepared spell. |
| `rpg.use_selected` | Authority | `{}` | Uses the currently selected prepared action. |
| `rpg.use_quick_slot` | Authority | `{"slot":0}` | Uses RPG quick slot `0...8`. |

These calls preserve the existing RPG validation, fatigue, cooldown, progression, and persistence
rules. The GameCore RPG methods return a human-readable `message` for accepted and rejected game
requests; a successful protocol response proves delivery, not that the gameplay request succeeded.
Inspect `message` and a follow-up `rpg` snapshot before asserting the new state.

### Capture and app lifecycle

| Operation | Context | Example arguments | Result/effect |
|---|---|---|---|
| `render.capture` | Any for UI; World for world-only | `{"includeUI":true}` | Queues one PNG capture and responds with artifact UUID, absolute path, SHA-256, byte count, dimensions, and UI flag. `includeUI:false` is rejected unless a world is loaded. |
| `app.quit` | Any | `{}` | Settles input/persistence, returns `quitting:true`, then asks AppKit to terminate after the authenticated response is processed (with a two-second fallback). |

Capture files are server-named `capture-<uuid>.png` beneath the session-specific owner-only
directory:

```text
~/Library/Caches/Elysium Debug/Control/Artifacts-<session-uuid>/
```

The caller cannot choose a path. A completed artifact is accepted only if it is at most 64 MiB;
failed captures are removed. `includeUI: false` captures the world render without the UI. Captures
are serialized with other requests, have a 15-second hard ceiling, and are cancelled/rejected if
their controller or world epoch changes before completion. A title-screen world-only request fails
promptly instead of blocking the queue. Captures may contain world names, chat, coordinates,
inventory, or other player-visible content, and the
response contains an absolute local path; review both before sharing.

The server begins only after the ordinary app UI is revealed. Clean termination synchronously
closes active/pending transport and the listener before the normal final save/database close,
revokes `session.json` only if it still belongs to that session, clears held input, and safely
returns UI-cursor and screen-local workstation stacks to inventory (dropping only any remainder
when inventory is full). Stale manifests
are removed at the next start only after secure validation cannot prove a live owning process.
Per-session artifact directories are not automatically deleted.

## LAN authority and deterministic bounds

The debug listener is separate from Elysium LAN multiplayer. It grants no host permission and does
not bypass the host-authoritative replication model.

On a LAN client, authoritative world/player/inventory/entity/template/RPG mutation returns
`forbiddenInLANClient`. Local observation, view direction, raw input, screen snapshots/close, and
exiting the client world remain available. All semantic screen mutation/open operations are denied
conservatively because some production screens directly mutate local inventory or game mode. Run
the control port on the LAN host when a test requires authoritative multiplayer mutation, then
observe client replication separately.

The renderer snapshot reports total, empty, distance-culled, frustum-culled, and visible section
counts plus the equivalent shadow-volume counters and draw-call count. Main geometry uses a reused
scratch list, radial distance rejection, conservative section-AABB frustum tests, and front/back
ordering. The shadow pass also applies a conservative light-frustum AABB test after its cheap range
check. GPU occlusion/HZB is intentionally not enabled without movement/teleport/chunk-invalidation
grace logic and measured frame-time evidence; false occlusion is a correctness failure.

Load-bearing request bounds include:

| Resource | Bound |
|---|---:|
| Request payload | 64 KiB |
| Absolute response/frame payload | 1 MiB |
| Cached idempotency responses | 512 entries / 8 MiB encoded |
| Outstanding requests per controller | 1 |
| Retained events/replay | 4,096 |
| Direct fill | 4,096 blocks |
| Direct coordinate setup radius | 256 blocks in X/Z from player |
| Template per request | 8,192 blocks |
| Template span | 96 cells per axis |
| Template terrain-preparation scan | 65,536 cells |
| Entity spawn count | 16 |
| Snapshot item limit | 1...1,024 |
| Snapshot region radius | 0...8 |
| One simulation step | 1...20 ticks |
| Screen field value | 4,096 UTF-8 bytes |

Pause/step controls use the real manual-clock hook and keep rendering and chunk/mesh work available,
which makes before/after captures possible without allowing unbounded synchronous simulation.

## Errors and recovery

Typed remote error codes are:

```text
unauthenticated, unsupportedVersion, invalidArguments, unknownOperation,
deadlineExceeded, wrongEpoch, wrongRevision, wrongState, noWorld, unloaded,
forbiddenInLANClient, notAuthoritative, busy, timeout, boundedLimit,
staleScreen, placementRejected, persistenceFailed, internalFailure
```

Retry only when `retryable` is true, or after correcting the reported state. In particular:

- Refresh status/snapshot after `wrongEpoch`, `wrongRevision`, or `staleScreen`.
- Wait for chunk streaming after retryable `unloaded`.
- Drain/retry capture after retryable `busy`.
- Move to the LAN host for `forbiddenInLANClient`.
- Do not blind-retry a mutating request with a new UUID after transport uncertainty. Reuse the exact
  original UUID and body so the idempotency cache can return the prior response.
- If the manifest fails validation, do not loosen its permissions or bypass validation. Confirm the
  debug app is still live and relaunch it to publish a fresh session.

## Verification checklist

Use checks proportional to the changed layer:

```bash
# Protocol/manifest/frame unit coverage
swift test --filter ElysiumDebugProtocolTests

# Compile-time separation, packaging contracts, and source security
bash scripts/security-scan.sh

# Warning-free optimized debug app + helper, marker checks, assets, and signatures
bash scripts/package-debug-app.sh
```

For a runtime change, launch the resulting package with `--debug-control` and verify at minimum:

```bash
"$PWD/dist/Elysium Debug.app/Contents/Helpers/elydebug" status
"$PWD/dist/Elysium Debug.app/Contents/Helpers/elydebug" capabilities
"$PWD/dist/Elysium Debug.app/Contents/Helpers/elydebug" snapshot '{"scopes":["app","world","player","screen","renderer","network"]}'
"$PWD/dist/Elysium Debug.app/Contents/Helpers/elydebug" request render.capture '{"includeUI":true}'
```

Then exercise the changed gameplay flow through the relevant production-semantic operation and
inspect both state and the captured artifact. Protocol tests alone do not prove AppKit/Metal,
workstation, placement, RPG, persistence, or LAN behavior.

For release-boundary changes, separately run the ordinary production gate required by the project.
`bash scripts/pipeline.sh` must still build, scan, test, package, install, and verify the production
`/Applications/Elysium.app` with no debug marker. Passing the debug package does not substitute for
that production proof, and passing the production pipeline does not deploy the debug package.
