# Pebble LAN Multiplayer Plan

Status: implemented LAN baseline, the first host-authoritative replication
layer, and the core remote-player gameplay orchestration layer. Pebble 1.1.0
now ships Multiplayer/Open to LAN UI, Bonjour browse/advertise for
`_pebble-lan._tcp`, one-button Join World UX with manual Direct Connect
fallback by host/port/join-code, bounded `PBLN`
protocol frames, join-code handshakes, peer status, LAN chat, source/binary
security allowlists, Info.plist local-network privacy declarations, core
replication batches for host world time/weather state, player state, chunk
sections, block deltas, complete host-owned entity snapshots, player inventory
snapshots, and item-bearing block-entity snapshots for containers and crafting
stations, plus permission-gated host orchestration for remote player entities,
container/crafting/template/command/AI permissions, dimensions, deaths, respawns,
openable doors/trapdoors/fence gates, and reconnect records. Crafting tables now
use a shared `crafting` block entity for the 3x3 station grid, so the grid can
replicate like any other item-bearing container. Transient LAN client worlds
suppress local chunk
generation and locally generated/saved entity authority, keep joining players at
their last locally saved position for the same host world id/seed when available
or at the host-advertised spawn height otherwise until authoritative chunks
arrive, request center-first host chunk-section snapshots for missing visible
neighborhoods, and purge client-only spawned entities, so mobs, drops, XP,
plants, and block simulation are visible only when the host publishes them. LAN
clients can inspect host-published container/crafting contents through read-only
mirrored screens and can send typed host-authoritative use intents for openable
block mechanisms.
Remaining release hardening is two-Mac installed-app soak and richer client
interaction UI for authoritative remote container/crafting edits.

Two-Mac installed-app soak is now scripted through
`scripts/live-lan-test.sh`. The harness launches the local `/Applications/Pebble.app`
as a host, launches Neo's `/Applications/Pebble.app` as a title-screen Direct
Connect client through `PEBBLE_LAN_AUTOJOIN`, builds a deterministic spawn rig
through `PEBBLE_LAN_PROBE=host-rig`, drives the Neo client's normal
right-click path against an oak door through `PEBBLE_LAN_PROBE=client-door`,
and asserts from both app logs that the host accepted the remote use intent,
the client received the door delta, and a chest item snapshot reached the
client mirror.

## Sources

- Apple Network framework documentation:
  <https://developer.apple.com/documentation/network>
- Apple `NWBrowser` documentation:
  <https://developer.apple.com/documentation/network/nwbrowser>
- Apple `NWListener.Service` documentation:
  <https://developer.apple.com/documentation/network/nwlistener/service>
- Apple `NSLocalNetworkUsageDescription` Info.plist key:
  <https://developer.apple.com/documentation/bundleresources/information_property_list/nslocalnetworkusagedescription>
- Apple `NSBonjourServices` Info.plist key:
  <https://developer.apple.com/documentation/bundleresources/information_property_list/nsbonjourservices>

## Product Intent

Support Mac-to-Mac multiplayer on the same local network without accounts,
internet relay, telemetry, NAT traversal, or cloud services. The first shipped
release makes it possible for one player to host a LAN session and for other
local players to discover it or Direct Connect to it from Pebble's title-screen
Multiplayer UI or `/lan ...` command line.

Initial target:

- 2-8 players on one LAN.
- One host-owned world; the host remains the authority for all simulation and
  persistence.
- Bonjour discovery using a Pebble-specific TCP service type.
- Join-code approval before a client can enter the world.
- Shared chat and host-authoritative state replication for chunk sections,
  block changes, player state, complete loaded-entity snapshots, dropped-item
  and XP payloads, player inventory snapshots, and item-bearing block entities
  such as chests, hoppers, furnaces, brewing stands, shelves, campfires, and
  crafting-table grids.
- Host-authoritative openable block use for non-iron doors, non-iron trapdoors,
  and fence gates.
- Host-authoritative permission gates for crafting, containers, commands,
  object-template copy/place/undo, AI requests, creative privileges, dimension
  changes, deaths, respawns, and reconnect records layered on top of the
  replication primitives.
- Client disconnect/reconnect without corrupting host saves.

Non-goals for the first LAN release:

- Public internet multiplayer.
- Dedicated headless server binary.
- Cross-platform clients.
- Account identity, cloud saves, or global moderation.
- NAT traversal, UPnP, relay servers, or public IP direct-connect UI.
- Peer-to-peer lockstep authority.

## Current Architecture Constraints

PebbleCore is deterministic and headless. It owns `GameCore`, `GameWorld`,
entity simulation, interaction systems, saves, templates, crafting, and command
execution. The app target owns AppKit, Metal, UI, audio, and the only current
network surface: loopback-only Ollama.

LAN multiplayer must preserve this split:

- `PebbleCore` may define protocol data, message validation, replication state,
  and deterministic host/client session logic.
- `PebbleCore` must not import AppKit, Network.framework, or socket APIs.
- `Sources/Pebble` owns Bonjour discovery, `NWListener`, `NWBrowser`, and
  `NWConnection`.
- The host's `GameCore` remains the only process that mutates world state.
- Clients send intents, never authoritative block/entity/world writes.

## Architecture

### Modules

Added core-only networking model files:

- `Sources/PebbleCore/Net/LANMultiplayer.swift`: protocol version, service
  type, message type ids, caps, frame codec, malformed-frame errors, sanitized
  inputs, and `Codable` payload models for hello, accept/reject, player state,
  player input, block/container/template intents, chat, world summaries, ping,
  pong, disconnect reasons, chunk requests, replication acknowledgments, and
  replication batches. Player state now carries bounded dimension/death
  metadata with legacy decode defaults, and gameplay events carry permission,
  death/respawn, dimension, and reconnect notifications.
- `Sources/PebbleCore/Net/LANReplication.swift`: host-authoritative peer
  session state, reconnect-preserved peer records, deterministic block-change
  log, permission-gated host block/container/crafting/template/command/AI
  validation, object-template copy/place/undo execution, chunk-section
  snapshot encode/apply helpers, world-state snapshots, entity snapshots, player
  inventory snapshots, item-bearing block-entity snapshots, client-side
  replicated mirror state, and bounded apply reports.
- `Sources/PebbleCore/Net/LANGameplayOrchestration.swift`: transient remote
  player entities, remote-player apply/remove helpers, remote player yaw
  conversion, transient LAN client entity-authority cleanup, permission result
  types, reconnect disposition records, and host gameplay authorization result
  types for tests and transport.

Remaining gameplay hardening:

- Client interaction UI for simultaneous remote container/crafting edits beyond
  the current host-published item snapshots, read-only mirrored screens, and
  typed-intent authorization layer.
- Two-Mac installed-app soak covering template placement, death/respawn, and
  reconnect persistence against real Network.framework connections.

Added app transport/UI files:

- `Sources/Pebble/LANTransport.swift`: Network.framework adapter for listener,
  browser, Direct Connect, connections, send queues, receive loops, handshake,
  LAN chat, status, and connection lifecycle.
- `Sources/Pebble/LANLobbyScreen.swift`: host/join screen, join code, player
  name, service list, direct host/port fields, errors, and connection status.
- `Sources/Pebble/MenusM.swift`: title-screen Multiplayer and pause-menu
  Open to LAN entry points.
- `packaging/Info.plist`: local-network privacy text and Bonjour service type.
- `scripts/security-scan.sh` and `scripts/security-check-binary.sh`: explicit
  LAN allowlist for Network.framework use and no external URL literals.

### Discovery And Session Establishment

Use Bonjour service discovery with service type `_pebble-lan._tcp`.

Implemented host flow:

1. Player opens a world and chooses "Open to LAN".
2. App creates an `NWListener` using TCP parameters.
3. Listener advertises `_pebble-lan._tcp` with the sanitized world display
   name. TXT metadata is intentionally deferred until the browser can consume
   and test it without trusting unvalidated strings.
4. Host UI displays a short join code generated for this session.
5. New client connections enter handshake state, not gameplay state.

Implemented client flow:

1. Player opens "Join LAN".
2. App uses `NWBrowser` for `_pebble-lan._tcp`.
3. UI lists discovered worlds with their sanitized Bonjour service names.
4. Client enters join code and display name.
5. Client sends `ClientHello`.
6. Host replies with `ServerAccept` or `ServerReject`.
7. Accepted client receives the host's `LANWorldSummary`, enters connected
   session/chat state, opens a transient LAN client world when joining from the
   title screen without snapping to an empty local `surfaceY`, and receives an
   initial replication batch centered on the host world's spawn neighborhood.
8. Host publishes periodic bounded replication batches from the main game
   thread. World/player/entity state publishes at 20 Hz, host runtime block
   mutations are captured through the coalescing block-change log, and full
   chunk-section refreshes publish once per second. Clients acknowledge and apply
   batches to a client mirror; if a matching world is already loaded, world
   state, block deltas, and chunk sections are applied through the normal world
   dirty-section path.
9. Transient LAN client worlds request missing chunks from the host with
   `LANChunkRequest` and do not generate local seed chunks for shared play.
   New clients include the current view Y and request a bounded 3x3 visible
   neighborhood; hosts answer with capped current-height and surface sections so
   meshing has neighboring chunks and the minimap has useful height data quickly.

### Protocol

Use one reliable ordered stream per client for the first release. A later
release can add UDP for high-frequency cosmetic traffic after the authoritative
state model is proven.

Frame format:

- Magic: `PBLN`
- Protocol version: `UInt16`
- Message type: `UInt16`
- Sequence: `UInt32`
- Payload byte count: `UInt32`
- Payload: bounded binary `Codable` encoding

Hard caps:

- Maximum frame size: 1 MiB.
- Maximum chat message: 512 bytes after UTF-8 validation.
- Maximum player name: 32 visible characters.
- Maximum queued outbound frames per client: fixed back-pressure cap.
- Maximum chunk payload per frame: one bounded visible-neighborhood section
  batch.
- Maximum clients: 8.
- Maximum replication block changes per batch: 4096.
- Maximum chunk sections per replication batch: 32.
- Maximum entity snapshots per replication batch: 512.
- Maximum player/inventory snapshots per batch: 9.
- Maximum replicated inventory slots per player: 64.
- Maximum block-entity snapshots per replication batch: 64.
- Maximum replicated block-entity slots per snapshot: 64.

Every decoder must fail closed before allocation if lengths exceed caps.

### Authority Model

The host is authoritative.

Clients may send:

- Movement inputs: axes, jump, sneak, sprint, fly controls, yaw, pitch.
- Use/break/place intents against client-visible targets.
- Selected hotbar slot and inventory UI actions.
- Crafting, container, template, command, and chat intents.
- Acknowledge snapshot/chunk sequence numbers.

Clients may not send:

- Raw block arrays.
- Entity positions as truth.
- Inventory or container contents as truth.
- Template records to store directly.
- Save data.
- Arbitrary command execution.

The host validates every intent using the same interaction, crafting, template,
AI, and command systems that singleplayer already uses. Failed intents return a
small rejection event and do not mutate world state.

### Simulation And Replication

Implemented host replication tick:

1. App frame advances the single host `GameCore` on the main thread.
2. `LANTransport` snapshots local host player state, accepted peer states,
   nearby chunk sections, a complete capped loaded-entity listing, host
   inventory, item-bearing block entities, and drained block changes. Direct
   chunk-request replies are center-first and include current-height plus
   surface sections and a small block-entity item snapshot set across the
   requested visible neighborhood, not full-height chunks for every neighbor.
3. The host sends a `LANReplicationBatch` at a bounded cadence, with larger
   full snapshots every few seconds and delta batches between them.
4. Client block intents are accepted only from joined peers, validated against
   the last peer state/reach and registry-valid cells, then applied to the host
   world on the main thread.

Implemented client replication apply:

1. Client decodes `LANReplicationBatch` frames under the same 1 MiB PBLN cap.
2. The client mirror stores world summary, players, chunk sections, block cells,
   entity snapshots, inventory snapshots, and block-entity item snapshots,
   dropping malformed sections, invalid cells, unknown entity types, invalid
   dropped-item ids/counts, invalid block-entity slots/items, and invalid XP
   payloads.
3. If the local game has a loaded matching world, chunk sections, block deltas,
   and compatible block-entity item snapshots apply to `World` on the main
   thread; chunk-section application notifies dirty-section hooks for remeshing.
4. Complete entity batches materialize non-persistent client-side mirror
   entities for dropped items, XP orbs, and registered entity types, update them
   from host snapshots, skip their normal local simulation ticks, and remove
   stale mirrors only when the batch explicitly marks the entity list complete.
5. Remote player snapshots spawn/update/remove transient player entities, and
   first-person rendering hides only the local player so peers remain visible.

Remaining client gameplay work:

1. Predict only local player camera/input for responsiveness.
2. Smooth/interpolate remote player and mirrored entity movement between
   snapshots.
3. Roll back local prediction only for the local player, never for world state.

Chunk streaming:

- Host generates and saves chunks.
- Clients request chunks around their replicated player position, marking the
  3x3 requested neighborhood in flight so one request replaces overlapping
  one-chunk round trips.
- Host sends section data plus light/biome data in bounded frames.
- Clients cache runtime chunks in memory only; persisted chunks remain host-owned.

Player data:

- Host assigns a stable multiplayer player id.
- Client identity is a random local UUID stored in Pebble settings, not a
  credential.
- Host stores per-client player inventory, location, dimension, health, hunger,
  advancements, and permissions in the host world database.

### Gameplay Surface Requirements

- Containers: host serializes opens/moves/crafts so two players cannot duplicate
  items.
- Crafting: host plans and consumes resources; clients see staged grids and
  outputs as replicated UI state.
- Creative mode: host controls whether a client may use creative inventory,
  flight, no-damage, and non-consuming placement.
- Object templates: host validates template names, copies, placements,
  obstruction clearing, support fills, and undo snapshots.
- `/ai`: host-only by default. A client may request an AI action only if the host
  grants operator permission.
- Commands: split into chat, harmless client-local commands, and host-only
  world mutation commands.
- Sleeping/time/weather: first release should disable sleep-skips unless all
  players are sleeping or host uses a command.
- Pause: opening menus must not pause host simulation while clients are joined.
- Disconnect: player entity is removed after a timeout and saved safely.
- Reconnect: client resumes the saved multiplayer player record.

## Security Plan

The security posture changes from "no external network access" to "no external
network access except explicit local-network LAN multiplayer." That requires a
full-tier security review before any implementation ships.

Required controls:

- Use Bonjour and Network.framework for local discovery/connections.
- Add `NSLocalNetworkUsageDescription` explaining local multiplayer.
- Add `NSBonjourServices` with `_pebble-lan._tcp`.
- Do not add cloud endpoints, update checks, telemetry, analytics, relay
  servers, NAT traversal, or hard-coded public URLs.
- Keep the existing Ollama loopback path separate from LAN multiplayer.
- Reject mismatched protocol versions before sending world data.
- Require a host-visible join code for every connection.
- Rate-limit handshake, chat, input, and chunk requests.
- Treat all client payloads as untrusted structured input.
- Cap every length before allocation.
- Keep all host save writes on the existing save queue.
- Never deserialize remote data into block/entity/item ids without registry
  bounds checks.
- Never let a remote client name or world name become a filesystem path.
- Add kick/ban for the current hosted session.
- Log network errors without dumping private chat or full payloads.

Scripts must change deliberately:

- `scripts/security-scan.sh` allows Network.framework symbols only in
  `Sources/Pebble/LANTransport.swift` and continues failing other unapproved
  network references.
- `scripts/security-check-binary.sh` distinguishes approved Network.framework
  symbols from unapproved low-level socket symbols and URL strings. It still
  rejects non-local URL literals and requires the LAN Info.plist declarations
  before accepting Network.framework symbols.

## Test Plan

Core unit tests:

- `LANMultiplayerTests`: round-trip every message type, stream partial frames,
  reject bad magic/version/type/oversized frames, validate sanitizers, verify
  Info.plist LAN declarations, and preserve same-version block-intent
  compatibility when older peers omit the optional placement cell.
- `LANReplicationTests`: prove deterministic block-change coalescing/drain
  order, host break/place validation, out-of-reach and invalid-cell rejection,
  chunk-section snapshot apply/remesh hooks, client mirror apply with malformed
  section/invalid-cell drops, and batch caps.
- `NetCodecTests`: keep fuzz/property coverage for malformed future protocol
  variants.
- `NetCodecFuzzTests`: seeded malformed lengths, truncated frames, unknown
  message types, invalid UTF-8, and over-cap payloads.
- `MultiplayerHostSessionTests`: two synthetic clients moving, breaking,
  placing, crafting, fighting, changing dimensions, and disconnecting.
- `ReplicationTests`: interest-set chunk streaming, block diffs, inventory
  diffs, entity spawn/despawn, and sequence acknowledgments.
- `PermissionTests`: survival vs creative vs operator actions.

Integration tests:

- In-memory transport simulation with host plus two clients for at least 2,000
  ticks.
- Packet delay/reorder/drop simulation at the transport boundary.
- Disconnect/reconnect and host-save round trip.
- Container contention and item duplication probes.
- Template placement and undo with two clients observing the same mutation.

Security tests:

- Info.plist has local network usage text and only the Pebble Bonjour service.
- Source scan allows only the LAN transport network surface.
- Binary scan still rejects public URL literals.
- Oversized frames and chat floods fail closed.
- Malicious client ids, item ids, block ids, template names, and command payloads
  cannot mutate host state.

Manual installed-app smoke:

- Host a world on one Mac, discover it from another Mac on the same LAN, join
  with code, move both players, chat, place/break blocks, use a chest, craft,
  fight a mob, disconnect/reconnect, and verify host save persistence.
- Repeat with Local Network permission denied, host canceled, wrong join code,
  version mismatch, host quit, client quit, and Wi-Fi temporarily disabled.
- The local Neo client helper is `scripts/deploy-lan-client.sh`. It defaults to
  `neo.localdomain`, runs `./pebble install` locally, copies the resulting
  `/Applications/Pebble.app` to `/Applications/Pebble.app` on Neo over SSH, and
  opens it there. Use `scripts/deploy-lan-client.sh --check` after enabling
  Remote Login on Neo, and `scripts/deploy-lan-client.sh --no-build` after a
  pipeline run that already refreshed the local installed app.

Release gate:

- `swift build -c release`
- `swift test`
- `swift run -c release pebsmoke`
- `bash scripts/security-scan.sh`
- `bash scripts/pipeline.sh`
- Installed-app two-Mac LAN smoke before marking the feature done.

## Implementation Phases

1. Protocol and codecs only.
   - Add bounded message model and tests.
   - No Network.framework use yet.
   - No gameplay behavior change.

2. Host/client session model with in-memory transport.
   - Host authoritative tick order.
   - Synthetic two-client tests.
   - Basic movement, chat, block place/break.

3. Replication layer.
   - Chunk streaming, entity snapshots, inventory diffs, events.
   - Prediction/interpolation for clients.
   - Golden-safe deterministic host behavior.

4. App LAN transport and lobby UI.
   - Bonjour advertise/browse.
   - Join code.
   - Info.plist privacy keys.
   - Source/binary security scripts updated with narrow allowlists.

5. Gameplay completion.
   - Containers, crafting, creative permissions, templates, commands, `/ai`
     host permissions, dimensions, deaths, respawns, and disconnect/reconnect.

6. Hardening and release.
   - Fuzz/property tests.
   - Soak tests.
   - Two-Mac installed-app smoke.
   - Documentation updates across README, ARCHITECTURE, SECURITY, and
     CONTRIBUTING.

## Conditions For Builder

- No client-authoritative world mutations.
- No public internet, relay, NAT traversal, telemetry, analytics, or update
  network code.
- All remote data is length-capped, versioned, registry-validated, and decoded
  before use.
- Host simulation remains deterministic with stable player-slot intent order.
- Existing singleplayer behavior and `pebsmoke` goldens remain unchanged unless
  a deliberate multiplayer-only test path is being exercised.
- Security scripts fail closed on network surfaces outside the approved LAN
  transport and Ollama loopback client.
- Multiplayer cannot ship without installed-app LAN smoke on two Macs.

## Open Decisions

- Maximum players: assume 8 until performance testing proves a different cap.
- Transport: TCP-only first release, or add UDP after protocol stabilization.
- World ownership UX: whether "Open to LAN" is available from pause menu only,
  title screen only, or both.
- Operator model: whether host can grant creative/command permissions per
  client during a session.
- Compatibility: whether patch-version mismatch is allowed when protocol
  version matches.
- Persistence: whether disconnected players leave ghost entities for a timeout
  or disappear immediately.
