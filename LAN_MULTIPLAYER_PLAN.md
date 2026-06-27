# Pebble LAN Multiplayer Plan

Status: implemented baseline plus remaining gameplay-replication plan. Pebble
1.1.0 now ships the local-network session layer: Multiplayer/Open to LAN UI,
Bonjour browse/advertise for `_pebble-lan._tcp`, Direct Connect by
host/port/join-code, bounded `PBLN` protocol frames, join-code handshakes,
peer status, LAN chat, source/binary security allowlists, and Info.plist
local-network privacy declarations. The deeper host-authoritative gameplay
replication work below remains the contract for turning accepted LAN peers into
fully synchronized remote players.

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
- Shared chat, then host-authoritative world state, mobs, block changes,
  inventories, crafting, containers, commands, object-template placement, and
  map state as the remaining replication phases land.
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
  pong, and disconnect reasons.

Remaining core replication files:

- `Sources/PebbleCore/Net/MultiplayerHostSession.swift`: authoritative tick
  integration around a host `GameCore`.
- `Sources/PebbleCore/Net/MultiplayerClientSession.swift`: client-side
  interpolation, pending input tracking, and server-state application.
- `Sources/PebbleCore/Net/Replication.swift`: interest management, chunk
  streaming queues, entity snapshots, block diffs, inventory diffs, and event
  queues.

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
   session/chat state, and can send typed intent messages. Applying those
   intents to synchronized remote players remains in the replication plan.

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
- Maximum chunk payload per frame: one section or one small section batch.
- Maximum clients: 8.

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
- Inventory contents as truth.
- Template records to store directly.
- Save data.
- Arbitrary command execution.

The host validates every intent using the same interaction, crafting, template,
AI, and command systems that singleplayer already uses. Failed intents return a
small rejection event and do not mutate world state.

### Simulation And Replication

Host tick:

1. Read bounded intent queues from all clients.
2. Apply player inputs in stable player-slot order.
3. Tick `GameCore` once at 20 Hz.
4. Collect block/entity/inventory/UI/sound/particle/chat deltas.
5. Send deltas to each client based on interest sets.

Client frame:

1. Apply latest authoritative snapshot/deltas.
2. Predict only local player camera/input for responsiveness.
3. Interpolate remote players and mobs.
4. Render loaded chunks and entities from replicated state.
5. Roll back local prediction only for the local player, never for world state.

Chunk streaming:

- Host generates and saves chunks.
- Clients request chunks around their replicated player position.
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

- `NetCodecTests`: round-trip every message type.
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
