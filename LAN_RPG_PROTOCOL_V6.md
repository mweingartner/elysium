# RPG LAN Protocol v6 Build Contract

Status: nineteenth amended security-review candidate; implementation is blocked pending a fresh
Security #19 PASS. This document is the written implementation contract for
host-authoritative RPG character state, actions, progression, and lifecycle behavior over LAN.
Protocol v5 wire compatibility is intentionally not retained; persisted v5 guest rows have an
explicit, host-approved migration path.

## Fixed limits

| Contract | Limit |
| --- | ---: |
| Protocol version | 6 |
| RPG intent / owner manifest / owner chunk / client ready kinds | 26 / 27 / 28 / 29 |
| Global frame payload | 1,048,576 bytes |
| Non-replication frame payload | 65,536 bytes |
| Canonical private owner snapshot | 524,288 bytes |
| Raw owner chunk | 45,000 bytes |
| Owner chunk count | 1...12 |
| Per-peer send ledger | 2,097,184 framed bytes and 32 frames |
| Replay FIFO | 32 entries |
| Applied owner-bundle FIFO | 32 records, 24 MiB total per client process |
| Host replay memory | 24 MiB per authenticated peer (maximum 8), 192 MiB globally |
| Resume token / stored SHA-256 hash | 32 bytes / 32 bytes |
| Session epoch / handshake ID | 16 bytes / 16 bytes |
| Deferred RPG request | one, at most 65,536 raw bytes |
| Persisted host authority row / credential row | 786,432 / 65,536 bytes before decode |
| Strict LAN permission rows | 256 guest plus 1 host-local; 4,096 bytes each / 1,052,672 aggregate |
| Host-local owner checkpoint row | exactly one per hosted world; 786,432 bytes before decode |
| Persistent resumable identities per world | 256 rows and 268,435,456 encoded bytes |
| Credential token indexes per world | 512 rows and 2,097,152 encoded bytes |
| Quarantined imported identities per world | 128 rows and 67,108,864 encoded bytes |
| Copy/import entity namespace rewrite | 1,048,576 entity/projectile records and 2,147,483,648 encoded bytes |
| Namespace rewrite VCK2 row | 4,096 entity/projectile records plus 32,768 block entities / 67,108,864 encoded bytes; one row per transaction |
| Namespace/VCK2 streaming heap | two blob windows 131,072; raw record 1,048,576; decoded arena 2,097,152; canonical record 1,048,576; merge buffers 2,097,152; index run 1,048,576; parser/hash 262,144; SQLite cache 4,194,304; statement/VM 1,048,576; allocator reserve 1,310,720; 14,286,848 total |
| Namespace/VCK2 temporary disk | six 67,108,864-byte regions for source, canonical spool, merge A, merge B, output zeroblob and WAL/rollback; index/cursor 33,554,432; slack 50,331,648; 486,539,264 total |
| Existing-world baseline manifest | 1,048,576 chunk rows / 268,435,456 encoded bytes; 512-row / 1,048,576-byte page |
| Existing-world planning heap | two blob windows 131,072; raw tail 1,048,576; decoded entity 2,097,152; canonical scratch 1,048,576; manifest/relation/index pages 1,048,576 each; parser/hash 262,144; SQLite cache 4,194,304; statement/VM 1,048,576; allocator reserve 1,310,720; 14,286,848 total |
| Existing-world planning temporary disk | manifest 268,435,456; relation index 268,435,456; source spool 67,108,864; key map 134,217,728; WAL/rollback 268,435,456; phase/cursor 33,554,432; 1,040,187,392 total |
| Immutable generation-contract rows | 256 per world; 1,048,576 bytes each / 268,435,456 aggregate bytes |
| Persistent relation index | 64 edges per entity record; 16,384 per chunk; 1,048,576 per world; 256 bytes per edge / 268,435,456 aggregate bytes |
| Relation checkpoint segment | 512 edge/index deltas; 64 distinct entity records plus 9 owner records and at most 128 total references; 8,388,608 incremental index/tombstone bytes |
| Relation cleanup | 4,096 inbound edges per target; 128 pending target tombstones per world; 64 edges/source records and 8,388,608 bytes per batch |
| Mob simulation phase | 32 configured goals; 8 active goals; 256 path nodes; 16 references; 65,536 encoded bytes per mob |
| Pinned deferred loot / pending barter | 512 encoded bytes each |
| Fishing session descriptors | one per owner; 9 per hosted world; 4,096 bytes each / 36,864 aggregate bytes |
| Durable world RNG streams | exactly 9 streams; 64 bytes each / 576 bytes per world |
| Scheduled lightning descriptors | 128 per hosted world; 2,048 bytes each / 262,144 aggregate bytes |
| Scheduled evoker-fang descriptors | 512 per hosted world; 2,048 bytes each / 1,048,576 aggregate bytes |
| Durable scheduled block tasks | 131,072 rows / 33,554,432 encoded bytes per world; 512 deltas / 131,072 bytes per checkpoint |
| Durable raid state | 256 rows / 1,048,576 encoded bytes per world; 64 deltas / 262,144 bytes per checkpoint |
| Blaze scheduled volleys | 3 shots per Blaze; 4,096 shots / 8,388,608 encoded bytes per world |
| Area-effect-cloud affected set | 256 target/tick entries / 32,768 encoded bytes per cloud |
| Warden anger | 64 target entries / 16,384 encoded bytes per Warden |
| Retired identity audit / identity-list page | 1,024 rows and 1,048,576 bytes / 50 rows |
| Persisted client owner-checkpoint row | 786,432 bytes before decode |
| Persisted client credential row / pending-disposition row | 65,536 / 131,072 bytes before decode |
| Durable client notification inbox | 256 rows and 1,048,576 encoded bytes per host/world |
| Status effects | 32 |
| Inventory / ender chest / armor / offhand | exactly 36 / exactly 27 / exactly 4 / zero or one |
| Carried container contents | depth one, at most 27 slots |
| Cleanup tombstones | 96 per peer, 768 globally |
| Cleanup tombstone encoded bytes | 1,024 each; 98,304 per peer; 786,432 globally |
| Temporary-effect descriptors | 2 per owner/kind, 32 per world, 96 globally; 4,096 bytes each |
| Delayed causal descriptors | 32 per owner, 256 per world, 512 globally; 4,096 bytes each |
| Delayed payload / fanout | 2,048 bytes / 32 target descriptors per source action |
| Delayed descriptor aggregate bytes | 131,072 per owner, 1,048,576 per world, 2,097,152 globally |
| Reducer event queues | 128 / 262,144 bytes per peer; 1,024 / 2,097,152 bytes per world; 2,048 / 4,194,304 bytes globally |
| Reducer event encoded bytes | 2,048 each |
| Pending legacy claims | 8, socket-independent, expiring after 120 seconds |
| TCP sockets / authenticated peers / handshake sockets | 16 / 8 / 8 |
| Pending-only provisional identities | 8 |
| Pending credential rotation expiry | 120 seconds, refreshed only by a valid pending-token resume |
| Handshake / deferred-work progress deadline | 10 seconds |
| Incomplete owner bundle deadline | 5 seconds |
| Movement admission / over-rate tolerance | 10 tokens at 40/second / 8 strikes at 1/2 seconds |
| Direct invite | 1,024 ASCII bytes total; host 253 bytes; port 1...65,535 |
| Host checkpoint staging | one in-flight plus one coalesced pending per world; 167,772,160 bytes each / 335,544,320 combined |
| Checkpoint owners / RPG-causal chunk deltas | 8 guest plus 1 host-local / 128; 7,077,888 / 67,108,864 aggregate bytes |
| RPG-causal chunk-delta record | 524,288 bytes each |
| Checkpoint primary persistent-entity records | 64 deltas; 1,048,576 canonical bytes plus 4,096 key/envelope/digest/row/index bytes each / 67,371,008 aggregate bytes |
| Live primary-entity journal retention | 128 generation-scoped rows / 134,742,016 encoded-accounted bytes across durable + reserved + in-flight + pending references |
| Canonical full-base VCK2 row | 67,108,864 encoded bytes; 4,096 persistent entity/projectile records plus 32,768 block entities |
| RPG-coupled block-entity deltas | 512; 65,536 bytes each / 8,388,608 aggregate bytes |
| Persistent entity-key binding delta | 128-byte key / 2,048-byte row; 512 rows / 1,048,576 bytes per checkpoint |
| Checkpoint metadata / descriptors+tombstones | 1,048,576 / 4,325,376 aggregate bytes |
| Compactor canonical-base output | one separately reserved 67,108,864-byte VCK2 row |
| Live unwatermarked journal | durable + reserved + in-flight + pending: 128 delta rows / 67,108,864 encoded bytes total |
| Journal hydration window | at most the same 128 rows / 67,108,864 bytes; one window at a time |
| Simulation tick snapshot | owners 9; persistent entities 262,144; descriptor continuations 32,768; block entities 65,536; world/system tasks 163,831; exactly 524,288 total; 256 bytes/entry / 134,217,728 encoded bytes |
| Simulation snapshot working reserve | 4,194,304 sort + 65,536 active mask + 65,536 digest + 16,777,216 query scratch; 155,320,320 bytes including entries |
| Owner timed-state sync cadence | at most once per 20 ticks; checkpoint by 200 changing ticks |

Only frame payload length, aggregate owner-snapshot length, and persisted-row byte length can be
checked before decoding. Nested IDs, strings, arrays, and numeric domains are decoded only after
their enclosing aggregate has passed its byte cap, then strictly validated before normalization,
mutation, request consumption, or nested work. After that cap and before `JSONDecoder`, a mandatory
bounded duplicate-preserving JSON structural scanner validates syntax, object key uniqueness and
the exact key sets required by strict v6 DTOs; this is what makes duplicate/mixed hello rejection
real. A fully streaming allocation parser is additionally required only if profiling shows bounded
aggregate scanning/decode itself is unsafe. Nothing is silently clamped or truncated, and the
contract must never describe numeric/registry validation as "pre-JSON" unless a custom parser
actually performs it.

### Exact v6 value domains

- Client request IDs are `1...1_000_000_000`; request ID zero is reserved exclusively for host
  private sync. `nextExpectedRequestID` is `1...1_000_000_001`. Processing request
  `1_000_000_000` returns terminal `requestExhausted`, enters the authority lifecycle
  `requestCounterExhausted`, cancels deferred/prepared work, and closes its socket; only a new host
  session epoch may reset the scalar request counter. There is no connected-but-frozen authority,
  wrap, or clamp.
- Credential generation remains scalar `1...1_000_000_000` and follows the terminal no-transfer
  policy below. `joinedOrdinal` remains scalar under its terminal allocator policy. Durable gameplay
  counters use the versioned policy below rather than a bare bounded integer.
- Broad `ownerRevision` is private/public synchronization metadata only. RPG request conflicts use
  the discrete `RPGCharacterState.authorityRevision`; only operations named by the closed revision
  policy also compare `inventoryRevision`. No request carries or is rejected by an expected broad
  owner revision.
- `joinedOrdinal` is `1...1_000_000_000`; the allocator's stored next value may be
  `1_000_000_001` only as the terminal exhausted sentinel. Exhaustion rejects new identities and
  never recycles an ordinal.
- RPG/path/branch/skill/spell/effect/enchantment/potion/trim/sherd IDs are nonempty and at most 64
  UTF-8 bytes, then must match the relevant closed registry. Authority IDs are exactly
  `lan:<joinedOrdinal>`. Item labels are at most 256 UTF-8 bytes. Display names are 1...32 Unicode
  scalars and at most 128 UTF-8 bytes after single-line sanitation.
- Host installation ID, world LAN ID, world storage ID, mutation lineage ID, session epoch, handshake ID, snapshot ID, and delayed-effect
  descriptor ID are exactly 16
  bytes represented as 22-character
  unpadded base64url. Resume tokens are exactly 32 bytes represented as 43-character unpadded
  base64url. SHA-256 digests are exactly 32 bytes represented as 64 lowercase hexadecimal
  characters.
- Ack reason text is at most 256 UTF-8 bytes; user-facing ack message is at most 512 UTF-8 bytes.
  A legacy hint is either absent or one canonical 36-character UUID. A legacy claim nonce is
  exactly 16 CSPRNG bytes, stored only as its 32-byte SHA-256 hash. Its six-character uppercase
  ASCII display code is a lookup convenience, never an authenticator.
- A join code is exactly 4...8 bytes matching `[A-Z0-9]{4,8}` with no Unicode normalization,
  whitespace, punctuation, lowercase folding, or prefix match. Production generates the configured
  length (six by default) from alphabet `ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789` with
  `SecRandomCopyBytes` rejection
  sampling: accept a random byte only when it is below 252, then select `alphabet[byte % 36]`.
  Modulo bias and noncryptographic randomness are forbidden.
- Effects are at most 32 entries; duration is exactly `-1` (infinite) or
  `1...1_200_000`, amplifier is `0...255`, and effect
  IDs are unique. Enchantments are at most 32 entries; IDs are unique and levels are
  `1...255`. Sherds are at most four registered 64-byte IDs. Lodestone is exactly four integers
  `[x,y,z,dimension]`, with coordinates in `-30_000_000...30_000_000` and dimension in the closed
  `Dim` registry. Carried contents are exactly 0...27 optional child slots and children cannot
  themselves contain contents.
- A stack count is `1...min(127,item.maxStack)`; damage is zero for nondurable items and
  `0..<item.toolOrArmorDurability` otherwise. A value equal to durability is already broken and
  cannot cross a durable owner boundary. Prior work and repair units are
  `0...1_000_000_000`; firework flight is `0...255`. Owner coordinates are finite within
  `-30_000_000...30_000_000`, velocity components are finite within `-64...64`, health/max health
  and absorption are finite `0...2048`, hunger is `0...20`, and selected slot is `0...8`.
- Canonical snapshot length is `1...524_288`; chunk count is exactly
  `ceil(snapshotLength / 45_000)` in `1...12`; chunk index is `0..<chunkCount`; and every nonfinal
  raw chunk is exactly 45,000 bytes. These values reject rather than normalize.

### Closed lifecycle for every advancing counter

`LANVersionedCounterV1` is the strict two-key object `{generation,value}`. Each component is an
exact integer `0...1_000_000_000`; generation `1_000_000_000` is reserved for a persisted terminal
marker and is never a live generation. Ordering and equality are lexicographic over both fields.
For a live generation below `999_999_999`, checked successor increments `value`, or changes
`{generation,1_000_000_000}` to `{generation+1,0}` in the same prepared checkpoint. A successor of
`{999_999_999,1_000_000_000}` instead atomically writes terminal
`{1_000_000_000,0}`, enters `counterExhausted`, cancels prepared/deferred work, and closes the
affected authority or the whole hosted-world authority as scoped below. It never publishes an
unrepresentable value, clamps, freezes a live counter, or silently resets.

The following closed manifest is normative; every wire, replay, checkpoint, comparison, expected
revision, tick stamp, and deadline that names one of these fields carries the complete pair even
where prose uses the short field name:

| Counter scope | Exact fields | Exhaustion scope |
| --- | --- | --- |
| Hosted world | `globalTick`, `checkpointGeneration`, world-scoped `captureSequence`, per-chunk `worldMutationVersion`, and all nine `worldRNGDrawCount` fields | terminal hosted world before the tick/mutation/draw; retain staged dirty state and close all peers |
| Guest or host-local owner | broad `ownerRevision`, `inventoryRevision`, RPG `authorityRevision`, RPG `actionSequence`, `reducerEventSequence`, `effectOwnerSequence` | terminal owner; host-local terminal also stops hosted-world authority |
| Permission row | `permissionRevision` | terminal subject row; revoke it and terminate that authority before another permission mutation |
| Persistent entity allocator | `entityIdentitySequence` | version rebase produces a new key generation; terminal hosted world only at the reserved outer marker |
| Persistent entity age family | keyed `persistentEntityAge(LANPersistentEntityKeyV1)` for every canonical persistent entity/projectile record, including every AreaEffectCloud | terminal hosted world before that entity's tick; retain the exact entity/relations and all staged dirty state |
| Persistent entity RNG family | keyed `entitySimulationRNGDrawCount(LANPersistentEntityKeyV1)` for every `requiredSimulationRNG` entity/projectile | terminal hosted world before the draw; retain the exact entity RNG words/count, record, relations and staged dirty state |
| Fishing-session age family | keyed `fishingSessionAge(ownerAuthority,descriptorID)` for every `LANFishingSessionV1` | terminal session before that session tick; DB-first atomic cancellation clears descriptor/projection/hook/owner binding with zero catch, XP, rod durability or RNG draw, then the owner/world continue |
| Fishing-session RNG family | keyed `fishingSimulationRNGDrawCount(ownerAuthority,descriptorID)` for every `LANFishingSessionV1` | terminal session before the draw; perform the same DB-first zero-outcome cancellation while retaining the old words/count until COMMIT |
| Fishing-reel reservation family | keyed `fishingReelReservationSequence(ownerAuthority,descriptorID)` for every `LANFishingSessionV1` | terminal session before reservation; one DB-first atomic cancellation clears descriptor/projection/relations/owner binding with zero catch, XP, durability, key allocation or RNG transition |
| Persistent continuation | Blaze `volleySequence`, Piglin `barterReservationSequence`, zombification `attempt`, world `lightningSequence` and Evoker `fangCastSequence` | terminal hosted world before scheduling/reservation/retry; retain the exact continuation record |
| Cumulative owner state | `entityAge`, `arrowsShot`, `blocksPlaced`, `blocksMined`, `toolTuneCounter`, `salvageCounter` | terminal owner before the overflowing event |

Every absolute gameplay tick stored in cooldown/upkeep, descriptor creation/next/expiry, melee,
fatigue-restore, checkpoint, or sync state is `LANVersionedCounterV1` and uses checked distance/add
that crosses a value rebase at most once because every permitted duration is below one billion.
The bounded phase fields `fireTicks`, `airSupply`, `invulnTicks`, `freezeTicks`, `portalCooldown`,
`portalTime`, `hurtTime`, `deathTime`, `lastHurtByPlayerTime`, `noJumpDelay`, `foodTickTimer`,
`sleepTicks`, `attackStrengthTicker`, `useItemTicks`, `portalTicks`, and remaining cooldown/upkeep
durations are reset/decremented only by their closed gameplay transition and are not identity
counters. If a rule would advance one beyond its domain without executing a defined reset/end
transition, the prepared tick enters `counterInvariantFailure` before publication.

`LANAutomaticCounterCase: CaseIterable` contains exactly the scalar fields and five keyed families in
this manifest plus scalar `requestID`, credential generation, joined ordinal, frame sequence and
socket generation. `LANAutomaticCounterID` is the closed sum
`scalar(LANAutomaticCounterCase) | persistentEntityAge(LANPersistentEntityKeyV1) |
entitySimulationRNGDrawCount(LANPersistentEntityKeyV1) |
fishingSessionAge(LANOwnerAuthorityRefV1,descriptorID) |
fishingSimulationRNGDrawCount(LANOwnerAuthorityRefV1,descriptorID) |
fishingReelReservationSequence(LANOwnerAuthorityRefV1,descriptorID)`; the keyed cases use canonical key bytes and
cannot be represented without their key. A source audit enumerates every live keyed instance and
fails when persisted/wire/session state performs checked add/increment without one manifest entry,
one stable key and one lifecycle policy. Frame sequence exhausts by closing before another frame and
resets only under a fresh connection ID; socket generation exhausts by stopping the host and resets
only under a fresh session epoch. Credential/ordinal policies remain the explicit terminals above.
Tests force max-1, max, rebase, reserved terminal, restart, replay, stale generation and stale value
comparisons for every scalar case and keyed family instance and prove exactly old or complete new
state, never wrap/clamp/freeze.

The RNG family is exhaustive, not one generic untracked counter: `LANAutomaticCounterID` has exact
cases `rngEntitySpawnDrawCount`, `rngWorldTickDrawCount`, `rngRedstoneDrawCount`,
`rngFarmingDrawCount`, `rngInteractionDrawCount`, `rngRaidDrawCount`, `rngBlockEntityDrawCount`,
`rngExplosionDrawCount` and `rngWorldLootDrawCount`, mapped one-to-one to
`LANWorldRNGStreamIDV1`. Preparation checks the complete full-pair successor for every planned draw
before the first RNG word advances. Rebase commits words plus the rebased draw-count pair atomically;
an outer terminal stops hosted-world authority with zero draws or gameplay mutation. Tests exercise
max-1/max/rebase/outer-terminal and stale generation/value independently for all nine cases and for
multi-stream prepared mutations.
The scalar branch also has exact `blazeVolleySequence`,
`piglinBarterReservationSequence`, `zombificationAttempt`, `lightningSequence` and
`evokerFangCastSequence` cases. Their full-pair successors and
embedded absolute ticks obey the same pre-mutation rebase/outer-terminal rule; no scalar sequence or
tick exists in a continuation DTO.

Before any persistent-entity or fishing-session simulation, its complete keyed age pair and, when
applicable, keyed RNG draw-count pair are read from the tick-start snapshot. Scratch execution uses
the immutable input RNG row and checked-successors its draw count once per raw `UInt32` transition;
rejection sampling therefore charges every rejected word. The complete age successor, exact number
of draw-count successors, result RNG words and every effect are reserved in the same prepared
checkpoint. Rebase changes words/count and record/session atomically; an outer terminal performs the
exact manifest disposition before any live RNG draw, query or mutation. An
`LANAreaEffectCloudAffectedEntryV1.lastAppliedEntityAge` always stores a complete pair from the same
generation as that cloud's keyed `persistentEntityAge`; comparison across different generations uses
checked full-pair distance and never a scalar value or inferred wrap.

### Durable deterministic world RNG streams

`LANWorldRNGStreamIDV1: CaseIterable` has exactly nine per-world streams in this order:
`entitySpawn`, `worldTick`, `redstone`, `farming`, `interaction`, `raid`, `blockEntity`, `explosion`
and `worldLoot`. Each durable `LANWorldRNGStreamStateV1` is exactly
`{schema:1,id,a:UInt32,b:UInt32,c:UInt32,d:UInt32,drawCount:LANVersionedCounterV1}` and occupies at
most 64 bytes; all nine rows total 576 bytes. The former process-global `gameRng`, `World.rng` and
random closures in those subsystems become typed accessors to the named stream. Source audit rejects
an unclassified draw, native random API or cross-stream substitution.

Fresh-world creation and existing-world v6 enrollment use one byte-exact initializer. Stream tags
are `0x01...0x09` in the order above. With `worldSeed` encoded as signed two's-complement
`Int64BE`, `generationSettingsDigest` as 32 raw bytes and `worldLANID` as 16 raw bytes, compute:

```text
root = SHA256(UTF8("Pebble-LAN-v6-world-rng-root\0") ||
              Int64BE(worldSeed) || generationSettingsDigest || worldLANID)
streamDigest(id) = SHA256(UTF8("Pebble-LAN-v6-world-rng-stream\0") ||
                          root || id.tag:UInt8 || 0x00 || 0x00 || 0x00)
```

The first 16 digest bytes become `a,b,c,d` as four consecutive `UInt32BE` words and
`drawCount` starts at `{generation:0,value:0}`. If all four words are zero, only `d` is replaced by
one, the required nonzero-state escape. There is no native-endian conversion, text seed, optional
salt, timestamp, process randomness or host-specific fallback. The transaction that first installs
world LAN/storage/lineage IDs and the generation-settings digest must insert all nine strict stream
rows and all initial world counters; a uniqueness conflict, short set, digest mismatch or crash rolls
back that whole transaction. World construction, first host tick and advertisement are blocked until
the nine-row set validates.

Copy/save-as/import creates an independent RNG lineage after the source coherent checkpoint is
closed. `sourceRNGBytes` is the concatenation in stream-tag order of each strict binary row
`schema:UInt16BE=1, tag:UInt8, zero:UInt8, a/b/c/d:UInt32BE,
drawCount.generation/value:UInt32BE`. Compute
`copyRoot = SHA256(UTF8("Pebble-LAN-v6-world-rng-copy\0") || sourceRNGBytes ||
newWorldLANID || newWorldStorageID || newMutationLineageID)` and derive every destination stream with
`SHA256(UTF8("Pebble-LAN-v6-world-rng-copy-stream\0") || copyRoot || tag || 0x000000)`, the same
first-16-byte/nonzero rule and a reset `{0,0}` draw count. Destination rows are inserted atomically
with the new namespace metadata; no source row or draw count is copied. An explicit proven Move
preserves all nine rows and draw-count pairs byte-for-byte. Checked-in fixed vectors cover both
signed seed extremes, zero, every digest/ID byte position, all nine tags, the all-zero escape via an
injected SHA fixture, fresh versus existing enrollment, copy divergence and Move identity; crash
tests cut every row insert and prove exactly no initialization or one complete nine-row set.

Entity-local simulation RNG and canonical owner RNG remain their separate authorities. Every world-
mutation preparation snapshots the exact named stream words/count, performs all draws in scratch,
and includes expected/result states in its guard. The coherent world/checkpoint transaction commits
changed stream rows with the world/entity/BE/loot/redstone/farming/interact/raid result before memory
publication; failure leaves words and draw count unchanged. Stream draws execute in the stable
simulation/mutation order below, never task-completion or dictionary order. Restart/fuzz tests cover
each stream alone and interleaved, max/rebase/terminal draw counts, save/rollback/crash cuts and
byte-identical continuous-versus-restart traces. The initializer and copy split are independent test
oracles, not calls back into the production implementation.

## Wire admission and state machines

`LANMultiplayerFrameCodec.frame` becomes throwing and chooses the cap from the message kind. Direct
decode requires the exact declared frame length. Streaming decode validates the 16-byte header,
version, kind, direction, connection state, and declared length before buffering the payload or
calling `JSONDecoder`. A connection buffer may never exceed the header plus the global frame cap.
Decoded frames retain their exact `rawPayload` for replay identity.

Every connection has independent inbound and outbound `UInt32` frame sequences beginning at one.
Zero, duplicate, regressed, skipped, or wrapping sequences close the connection. V6 handshake,
RPG, manifest, and chunk decoders throw on invalid IDs, revisions, ticks, strings, collections, or
finite-number violations. Repeated hello and wrong-direction messages are protocol violations.

`LANClientHelloV6` is a closed sum, not one bag of optional fields. Its top-level JSON keys are
exactly common `{pv,hid,wid,lk,playerName}` plus `admission`; `pv` is exactly 6, the public IDs/digest
match the advertised host/world tuple, and `playerName` satisfies the display-name domain. The
nested `admission` object must be exactly one of:

```text
joinNew      {kind:"joinNew",      joinCode}
resume       {kind:"resume",       rawToken}
legacyClaim  {kind:"legacyClaim",  joinCode, legacyHint, rawClaimNonce}
legacyConsume{kind:"legacyConsume",rawClaimNonce}
```

The exact key set for the selected variant is checked before typed decode. Missing, duplicate,
unknown, mixed-variant, or extra fields; a token and nonce together; multiple tokens/nonces; wrong
secret length/encoding; or a noncanonical join code closes with no lookup, mutation, allocation, or
fallback. Across variants there is at most one raw credential/claim secret (`rawToken` or
`rawClaimNonce`); `joinCode` is an admission gate, not an identity locator. The host constant-time
compares a strictly decoded join code of the same length. No variant carries authority, ordinal,
generation, active/pending choice, player ID, owner state, or permission. A failed `resume` or
`legacyConsume` never becomes `joinNew`, and a failed `legacyClaim` never allocates an identity.
The client may try its retained active token only on a new connection as a new one-secret `resume`
after the pending-token resume receives the same generic failure; the host performs no fallback.

Host connection states:

```text
awaitingHello
  joinNew -> allocate pending identity -> awaitingClientReady
  resume -> indexed secret lookup + rotation/resume -> awaitingClientReady
  legacyClaim -> persist detached claim + nonce index -> closing
  legacyConsume -> indexed approved claim consume + pending identity -> awaitingClientReady
awaitingClientReady
  clientReady -> readyAwaitingOwnerBudget
readyAwaitingOwnerBudget
  reserve + promote + enqueue request-0 owner bundle -> authenticated
authenticated
  documented client-origin messages only
closing
  no further authority work
```

Client states:

```text
connecting -> awaitingServerAccept
awaitingServerAccept
  serverAccept -> persist/update pending credential -> clientReady -> awaitingInitialOwner
  serverReject -> rejected
awaitingInitialOwner
  complete request-0 owner bundle -> connected
connected
  documented server-origin messages only
```

No peer may wait indefinitely in a nonterminal protocol state. One global admission lock accounts
for at most 16 TCP sockets, eight authority-keyed authenticated peer slots, eight handshake slots,
and eight persisted pending-only new identities. Total sockets include awaiting hello/ready,
authenticated, superseded, and closing sockets until their close completion callback releases the
reservation. Accepting TCP atomically reserves one total plus one handshake slot before reading;
failure closes without parsing. Promotion atomically transfers that connection's handshake slot to
an available authenticated authority slot only after the complete initial-bundle/send/checkpoint
reservations succeed and immediately before credential promotion. If eight authenticated slots are
occupied, promotion returns bounded busy, leaves the pending credential resumable/unpromoted, and
closes by the ten-second deadline without evicting anyone.

An authenticated supersession transfers the **same authority slot** from old to new while marking
the old socket closing under admission then authority locks; it never briefly creates a ninth peer.
Both sockets still count against the 16 TCP total until close. Every failure/drop releases each
reservation exactly once; no state reads separate counters and then increments later. Invariants are
`authenticatedAuthorities <= 8`, `handshakeSockets <= 8`, and `allOpenOrClosingSockets <= 16`, not
an ambiguous shared “client” count. Race tests fill every 8/8/16 boundary, concurrently accept/
promote/supersede/close, inject completion reordering, and prove no ninth authority or seventeenth
socket and continued progress for an existing peer.

Per-endpoint and global token buckets cover hello attempts in addition to the
existing per-message buckets. A socket that makes no outbound-send progress for ten seconds while
handshaking or waiting for capacity is closed. Deferred authority work has the same ten-second
deadline; expiry drops the deferred request without consuming it and guarantees that its prepared
work can never commit later. Disconnect also drops deferred work. If work already committed, no
deadline may discard its replay representation; send failure/reconnect must retain it. A
pending-only new row expires by its persisted expiry even when no creating socket remains; the row
is deleted but its ordinal remains burned.
These progress deadlines apply on both host and client state machines. Tests must saturate every
pre-authentication limit and prove an honest authenticated peer continues to make progress during
the flood.

### Total lock and publication order

Every path uses this one acquisition/happens-before order; omitted domains are skipped, never
reordered:

1. `LANWorldIdentityRegistryV1` lock (offline open/copy/import/move only);
2. global admission lock;
3. normalized source-bucket shard locks in ascending shard/source key;
4. legacy claim locks in ascending claim ID;
5. authority locks in stable `(joinedOrdinal,authority)` order, with `host:local` assigned ordering
   ordinal zero only for locking; deduplicate subjects and hold at most nine;
6. permission-subject locks in the same stable subject order;
7. `LANWorldMutationCoordinatorV1` chunk gates in stable `(dimension,chunkZ,chunkX)` order;
8. `LANRPGJournalBudgetV1` actor;
9. `LANAuthorityCheckpointStager` actor;
10. `LANRPGJournalCompactor` plus its canonical-output-reserve actor;
11. ordinary save-queue actor, ordered by world capture sequence;
12. the sole SaveDB executor and then `BEGIN IMMEDIATE` transaction context;
13. activation of logical `publicationPending` world/authority leases in stable key order;
14. after COMMIT/ROLLBACK and release of every physical lock/actor turn, asynchronous nonreentrant MainActor
   publication.

Read-only secret/index discovery may use the SaveDB executor before this chain only if it releases
the executor completely before taking a claim/authority lock. Main scratch capture likewise releases
MainActor isolation before a path waits on domain/DB locks; no synchronous callback from SaveDB or a
domain lock may wait for main. Authority-to-admission acquisition is forbidden. Stop, supersession,
counter exhaustion and permission-triggered teardown release their subject lock and re-enter through
admission before taking sorted authorities; claim consumption that creates an authority starts from
admission then claim then authority. No callback/destructor may acquire an earlier rank. Cross-actor
operations send immutable asynchronous requests and release the current actor turn before awaiting a
higher rank; stop, compaction and ordinary save are never waited on while holding an earlier rank.

The LAN dispatch queue performs socket I/O and immutable message forwarding only. `queue.sync`,
`main.sync`, nested synchronous dispatch and DB/gen/mesh work on that queue are forbidden; generation
and meshing never touch SaveDB. After a transaction, SaveDB releases its physical executor/locks
before delivering an immutable publication receipt. Capacity for the receipt is reserved at its
origin actor, but the logical `publicationPending` lease activates only after DB release; it then
defers later mutation until the asynchronous MainActor receipt publishes or
fails; publication never calls back into DB or a ranked lock.

Debug lock-rank assertions and deterministic contention tests cover stopHost versus eight-authority
commit/cleanup, credential and counter exhaustion, source flood plus claim approval/consume,
permission CAS versus prepared harm, registry rewrite versus host start, multi-authority PvP in both
argument orders, journal hard-cap compaction versus checkpoint/ordinary save, output-reserve failure,
async stop at every actor rank, DB failure and MainActor publication. Tests prove progress and identical results
without inversion, starvation or authority-to-admission recursion. Source audits reject sync
dispatch and non-I/O LAN-queue work; tests reorder publication receipts and prove the pending lease
prevents later work from overtaking durable state.

### Stable pre-hello host/world binding and cryptography

Credential lookup never uses service name, mutable endpoint, display world name, seed, or the
legacy `worldID#seed` resume key. Installation creates one public 128-bit CSPRNG
`hostInstallationID` in protected app support; each world creates one public 128-bit CSPRNG
`worldLANID` in world metadata. The stable credential key is
`SHA256("Pebble-LAN-v6" || hostInstallationID || worldLANID)` and the client credential row is keyed
and uniquely constrained by the exact `(hostInstallationID,worldLANID,lookupDigest)` tuple.
Production obtains host/world LAN/storage and mutation-lineage IDs, every session epoch, handshake ID, snapshot ID, delayed-effect
descriptor ID, resume token, legacy nonce, join code, and other security/replay nonce from
`SecRandomCopyBytes`; UUID APIs,
timestamps, counters, gameplay RNG, and deterministic/test entropy are forbidden for them.

The installation maintains a protected `LANWorldIdentityRegistryV1` with unique
`(hostInstallationID,worldLANID)` and unique `worldStorageID` constraints plus the canonical world
location. World open/import/copy/save-as obtains the registry lock before LAN state is enabled. If a
second storage object on the same installation presents a registered `worldLANID` or
`worldStorageID`, it is a **copy**, not another valid instance: before it may advertise or host, a
crash-recoverable import transaction generates a fresh `worldLANID`, recomputes `lk`, moves all
copied credential tuples/token indexes/pending rotations/legacy nonce indexes into nonauthenticating
quarantine, marks copied peer-authority rows quarantined, and registers the new tuple. No copied raw
or hashed credential can authenticate in the new namespace.

The sole possible exception is an explicit **Move World** implemented through
`LANWorldMoveCoordinatorV1`; no preserving Move UI/API may ship until that coordinator exists. It
requires both worlds closed/flushed, exact expected registry row/path/worldStorageID/fingerprint,
proof the registered source path is absent after the filesystem move, and a location CAS that changes
exactly that one registry row. Any mismatch or crash leaves a journaled unavailable move for recovery,
not a copied identity. A rename, copy followed by deleting source, or ordinary import is never
retroactively inferred as a move. An import from another installation likewise quarantines rows
whose stored `hostInstallationID` differs. A journaled `namespaceRewritePending` state survives
crash and prohibits Bonjour/startHost until the world DB rewrite and registry commit both verify.
If the registry is unavailable, locked inconsistently, duplicate, or cannot prove safe uniqueness,
LAN hosting refuses with a local repair error; it never advertises both copies or guesses. Tests
cover same-install file copies, save-as, imports, explicit moves, concurrent opens, stale paths,
registry loss/corruption, crash at every rewrite/move statement, and proof that only the explicit
move preserves credentials.

Because `LANPersistentEntityKeyV1` embeds `wid`, copy/save-as/import performs a bounded namespace
transition, not only a credential rewrite. `LANEntityNamespaceRewriteV1` persists exactly
`{schema,oldWid,newWid,oldStorageID,newStorageID,oldLineageID,newLineageID,phase,dimension,chunkZ,chunkX,
entityIndex,recordCount,encodedBytes,rollingDigest}`
with phases `planned -> compactJournal -> rewriteEntities -> cancelDelayed -> cancelFishing -> verify -> registryCommit -> complete`.
Copy/import generates all three new IDs before scanning; explicit proven Move World preserves all three IDs
and all keys byte-for-byte and never enters this state machine.

Before rekeying, `compactJournal` runs the normative base-plus-journal hydration below against the
closed coherent source snapshot and atomically compacts every committed journal row/manifest into
its full base. Any gap/failure quarantines the import. The rewrite never translates journal deltas;
registry commit therefore requires the destination journal and manifest tables to be empty.

The offline rewrite advances its exact persisted `(dimension,chunkZ,chunkX,entityIndex)` cursor over
loaded and unloaded rows in deterministic order. It copies one legacy blob on disk to a rowid-backed
VCK2 staging row; one transaction rekeys every persistent entity/projectile and embedded key from old to new `wid` while
preserving `{generation,value}`; it rewrites every canonical envelope/storage key, world/checkpoint
metadata reference and binding/index key. Rekeying changes canonical entity/reference bytes, so the
rewriter recomputes the complete `LANCanonicalChunkMeasureV1`: every affected 4-KiB leaf, section
root, content root, content digest, VCK2 header digest, canonical envelope digest and complete
`LANCanonicalChunkCASV1`, plus every entity-record, relationship, binding and namespace rolling
digest. No source content/root/digest is asserted byte-equal after rekey. It advances cursor and the
new-namespace rolling digest only with that complete row transaction.
Descriptor-owned projectiles are terminally removed; every copied delayed harm/XP descriptor and
temporary-effect descriptor is deterministically cancelled with zero harm/XP, using the persisted
base's guarded original for cleanup. No causal descriptor is translated to the new namespace.

`cancelFishing` keyset-scans the at-most-nine fishing descriptors in canonical owner/descriptor-ID
order. For each source session it verifies the matching owner `fishingSessionID`, optional
`fishingHook` edge/index entry, projection disposition and any `reelPending` reservation, then one
rewrite transaction deletes the descriptor/hook/index state, clears the owner binding and records
the complete post-owner digest with zero catch, XP, rod durability, loot draw or target transfer.
Reserved output entity keys are rekeyed only into the destination allocator's burned high-water: the
new allocator is advanced strictly beyond the greatest cancelled reserved full-pair sequence and no
cancelled key may later allocate or publish. No fishing descriptor, simulation RNG or pending outcome
is translated. The cursor/rolling digest includes the source descriptor ID, source row digest,
post-owner digest, removed relation digest and burned allocator pair, making retry idempotent.
Explicit proven Move instead preserves every fishing descriptor, owner binding, `fishingHook` edge,
reel reservation, reserved key, simulation RNG and counter pair byte-for-byte.

Preflight rejects more than 1,048,576 entity/projectile records or 2,147,483,648 encoded bytes.
Each VCK2 row is at most 4,096 entity/projectile records, 32,768 block entities and 67,108,864 bytes,
one row per transaction, through `LANStreamingVCKNamespaceRewriterV1`. It uses `sqlite3_blob_open`
with 65,536-byte windows, a strict incremental duplicate/depth/string-bounded tokenizer, one strict
record at a time, and a temporary SQLite stable-key sort table. A two-pass emitter computes exact
size/digest then streams to `zeroblob`; it never materializes the full input, graph or output. Exact
simultaneous heap is the itemized 14,286,848-byte cap: two blob windows, raw/decoded/canonical
records, merge buffers, one index run, parser/hash state, SQLite cache, statement/VM state and the
allocator reserve are all charged. Temporary disk is the itemized 486,539,264-byte cap: six
67,108,864-byte source/spool/merge-A/merge-B/output/WAL-or-rollback regions plus the index/cursor and
slack regions. SQLite page-count plus
filesystem free-space checks reserve every arena before phase start and fail closed before allocation.
Limits count records currently verifying/
cancelling and never truncate. The world remains quarantined: no World/Entity publication, normal
open, Bonjour, Direct Connect, or hosting occurs in any non-complete phase. `verify` keyset-scans
world/checkpoint metadata, canonical envelopes, records, bindings, projectiles, descriptors,
tombstones, fishing sessions/hooks/reel reservations/burned-key high-water, owner/checkpoint rows,
journal rows/payloads/manifests, quarantine and indexes; it checks the rolling digest/count/bytes,
proves the entity allocator is at least the maximum rewritten sequence, and proves there is no old
source `wid`, storage ID or lineage, duplicate new key or live copied descriptor before one registry transaction publishes the new
tuple/lineage. Crash recovery resumes the persisted phase/cursor idempotently; inconsistent cursor/digest,
an old-key alias, collision or over-cap input refuses the import without exposing either namespace.
Tests cover empty and maximum imports, one-over every row/record/aggregate/scratch allocation,
adversarial token boundaries, loaded/unloaded mixes, pre-import journal compaction, cross-references,
descriptor/projectile/fishing cancellation, explicit move preservation, concurrent opens, every statement/
phase crash edge including cuts after each leaf/root/content/header/envelope/CAS/record/binding/
rolling-digest write and every fishing owner-clear/hook-delete/reservation-burn write, repeated
recovery, final verification failure, and proof that no source ID/
lineage or source-derived digest remains in any typed table, key, envelope, payload, digest binding
or manifest. The fishing matrix covers cast/bite/hooked/reelPending, absent/present target, every
owner kind, zero/one/maximum reserved outputs, and proves Copy always cancels while Move alone
preserves a restart-equivalent session.

### Existing-world v6 baseline lifecycle

An existing world cannot advertise/host from ad hoc defaults. `LANWorldV6BaselineV1` persists phases
`absent -> planning -> identityCommitted -> manifestCommitted`; eager conversion continues
`migrating -> verified -> ready`, while a fully verified bounded lazy manifest enters `readyLazy`
and reaches `ready` when its last membership is removed.
Under the registry lock, one baseline transaction creates/registers fresh `worldLANID`,
`worldStorageID` and `mutationLineageID`; initializes versioned global/checkpoint/capture/entity
counters and all nine byte-exact `LANWorldRNGStreamStateV1` rows from the initializer above; pins
the exact currently shipped legacy generator implementation/version, immutable
14-section registry-baseline ID/digest and generation-settings digest; writes strict host-local
permission and owner checkpoint rows from a fully validated local Player; installs v6 schema/legacy-
quarantine markers; and records the expected old world fingerprint. The pinned implementation and
baseline are immutable migration inputs, not aliases for "current" on a later launch. Partial
identity/host/RNG rows never become hostable. The fresh-world creation transaction has the identical
all-or-nothing requirement; only its already-selected world IDs, seed and generation digest differ.

Planning keyset-scans at most 1,048,576 chunk rows/268,435,456 manifest bytes in 512-row/1,048,576-
byte pages and commits a canonical manifest of every absent/entity-only/VCK1/VCK2 row
`{dimension,chunkZ,chunkX,migrationState,format,encodedBytes,rowSHA256,entityCount,
reservedKeyStart,reservedKeyCount,relationCount,relationDispositionDigest}` plus count/bytes/SHA-256.
The migration state is exactly `absent`, `entityOnly`, `legacyFull`, `vck2PendingVerify` or
`vck2Verified`. Planning stream-validates every legacy entity tail in stable
`(dimension,chunkZ,chunkX,sourceEntityOrdinal)` order without constructing entities or drawing RNG.
It assigns each row a disjoint consecutive `LANPersistentEntityKeyV1` range, translates all legacy
cross-row references into the bounded persistent-relation index or records the relation's explicit
clear/reject migration disposition, and hashes that closed disposition set into the row. A range may
not cross a versioned-counter rebase; exhaustion blocks enrollment rather than wrapping.

Planning is streaming and pre-reserved. Simultaneous heap is exactly the itemized 14,286,848-byte
cap: two blob windows, raw tail, decoded entity, canonical scratch, one manifest page, one relation
page, one key-map/index page, parser/hash state, SQLite cache, statement/VM state and allocator
reserve. Temporary disk is exactly 1,040,187,392 bytes: 268,435,456 each for manifest staging,
relation-index staging and WAL/rollback, 67,108,864 source spool, 134,217,728 key map and 33,554,432
phase/cursor. SQLite page-count, cache and free-space checks reserve the projected arenas before the
first scan page; cap or disk failure leaves the world nonhosting before allocation.

Manifest, relation and key-map staging tables are generation-keyed and invisible to world open.
Each at-most-512-row/1,048,576-byte page transaction writes its exact cursor, counts, byte totals and
rolling digest, so restart resumes at the first uncommitted page without rescanning committed tails.
After all pages verify, one small final transaction compares the staged roots/counts/bytes, advances
allocator high-water, publishes the staging-generation IDs and flips `manifestCommitted`; it never
copies/re-hashes the 268-MiB tables inside the publish transaction. Crash before that commit leaves
old roots invisible; crash after exposes the complete set.

The same transaction that publishes `manifestCommitted` advances the world entity-key allocator
high-water beyond every reserved range and persists the complete relation index before `readyLazy`.
Thus reverse chunk visitation, concurrent lazy migration and restart cannot allocate a key promised
to an unvisited tail. A row migrator may consume only its preassigned range and must reproduce its
entity/relation counts and disposition digest exactly. The implementation
may convert all rows offline before `ready`, or commit this bounded lazy manifest before hosting.
Only `ready` or `readyLazy` may host. Under lazy migration, each listed row must validate its manifest membership and migrate through the
exact pinned generator/strict VCK2 path before that chunk/entity can publish: a legacy full row
strict-converts without generation, while an absent/entity-only row runs the pinned implementation,
merges its strict saved entity tail and writes a complete VCK2 base. Completion atomically verifies
the full VCK2 row and removes its membership. An unavailable/mutated pinned implementation,
unknown/unmanifested legacy row, an over-cap manifest or failed row
keeps the world nonhosting. No RPG journal exists until a migrated full-base barrier is durable.

Startup resumes the first incomplete phase idempotently and verifies registry tuple, fingerprint,
lineage, counters/high-water, reserved ranges, relation index, host rows, manifest digest and absence of untracked legacy authority before
`ready`. Tests crash before/after every baseline/manifest/row statement, race two opens, migrate
empty/max/over-cap and mixed entity-only/full worlds in forward/reverse/concurrent visitation order,
restart before/after range reservation and each cross-row relation resolution, corrupt each identity/
counter/range/relation/manifest field, hit heap/temp-disk/WAL/page/cache cap-1/cap/cap+1 and crash
every staged page/final-root statement, and prove no key collision, dangling relation or advertisement/
publication precedes readiness. Installed upgrade proof
opens a real pre-v6 world, hosts it, migrates a visited and unvisited chunk, restarts, and verifies
the same v6 IDs, host state and canonical bytes.

V6 Bonjour advertisement must publish a bounded TXT record with exactly `pv=6`, 22-character
base64url `hid`, 22-character base64url `wid`, and 64-lowercase-hex `lk`. The client validates that
`lk` recomputes from `hid/wid` **before opening the socket**, selects only the credential for that
tuple, and includes all three values in `clientHello`. `serverAccept` echoes them and the host
rejects any value not equal to its currently opened world before inspecting a token. A v6 service
with missing/malformed/inconsistent TXT is not eligible through Bonjour and is shown as
incompatible; Direct Connect requires the closed invite below, never an endpoint-only fallback.
Bonjour renames and address changes do
not change the key. Duplicate advertisements for one tuple are deduplicated as one multi-address
host; the user chooses explicitly between different tuples with the same display name.

### Bounded Direct Connect invite

`LANDirectInviteV6` is the only Direct Connect input. Its canonical ASCII serialization is exactly
`pebble-lan-v6://<host>:<port>?hid=<hid>&wid=<wid>&lk=<lk>&code=<joinCode>` in that query order,
with no userinfo, password, path, fragment, percent escapes, duplicate/unknown query keys, omitted
field, whitespace, control character, or trailing data. Total length is `1...1_024` bytes. Port is
decimal canonical `1...65_535` with no sign/leading zero. Host is exactly one canonical dotted IPv4,
bracketed IPv6 accepted by Network.framework and reserialized byte-identically, or lowercase ASCII
DNS name `1...253` bytes whose labels are `1...63`, match `[a-z0-9](?:[a-z0-9-]*[a-z0-9])?`, and
have no empty label/trailing dot. `hid`, `wid`, `lk`, and join code use their exact domains, and `lk`
must recompute from `hid/wid` before DNS or TCP work.

The invite binds the first hello and echoed accept to one host/world identity. DNS may try resolved
addresses in deterministic Network.framework order only after transport failure; any framed
protocol response, ID/digest mismatch, alternate world, malformed accept, or duplicate advertised
identity terminates the invite with `directIdentityMismatch` and never falls through to another
address, Bonjour record, endpoint credential, or Join as New. This prevents ambiguity/accidental
cross-world disclosure; the plaintext-LAN spoofing risk remains documented. Invite values, including
the join code, are sensitive and never enter ordinary logs/history/probes.

Human-visible contract: hosting shows a **Copy Direct Invite** action beside the join code with a
trusted-LAN warning; joining replaces naked manual host/port fields with one **Direct Invite** paste
field, inline exact validation, disabled Connect while invalid, and redacted identity prefixes after
parse. `/lan direct <invite>` accepts exactly one bounded no-whitespace URI argument. Automation sets
`PEBBLE_LAN_AUTOJOIN` to the exact invite only and puts the separately validated display name in
`PEBBLE_LAN_AUTOJOIN_NAME`; legacy `<host> <port> <code> [name]` parsing is removed and rejected.
Environment values containing NUL/newline, over 1,024 bytes, missing names, or mixed legacy tokens
fail before network work.

Builder updates the real surfaces, not only a DTO: `Sources/Pebble/LANTransport.swift`,
`Sources/Pebble/LANLobbyScreen.swift`, command routing in `main.swift`, README/ARCHITECTURE/SECURITY,
and `scripts/live-lan-test.sh`. The installed probe obtains the host-generated invite through a
dedicated `PEBBLE_LAN_PROBE_INVITE_FILE` created mode 0600, passes it unchanged to Neo via
`PEBBLE_LAN_AUTOJOIN`, supplies `PEBBLE_LAN_AUTOJOIN_NAME`, then deletes the file. Tests cover every
byte/host/port/query boundary, UI/CLI/env equivalence, IPv4/IPv6/DNS, spoofed/mismatched tuples,
multi-address ambiguity, redaction, old-format rejection, and installed Neo join plus resume.

V6 requires Apple CryptoKit `SHA256` and Security.framework `SecRandomCopyBytes` on the supported
macOS target. There is no noncryptographic, UUID, `SystemRandomNumberGenerator`, or home-grown hash
fallback. Build configuration links both frameworks; startup runs a known-answer SHA-256 test and
checks every CSPRNG status. Any unavailability or random-generation failure disables hosting and
identity/legacy admission with an explicit local error before a socket/token is exposed. Tests may
inject deterministic entropy only through an internal test-only provider that cannot be selected
in production builds. Digest comparison uses the fixed 32-byte XOR-accumulation helper.

Hello rate limits are exact monotonic token buckets. Each fully framed `clientHello` attempt costs
one token from both a global bucket (capacity 32, refill 4 tokens/second) and a normalized-source
bucket (capacity 4, refill 1 token/5 seconds; exact IPv4 address or IPv6 /64). Buckets start full,
refill continuously but never above capacity, and denial closes before JSON semantic work,
identity lookup, hashing, allocation, or claim insertion. At most 256 source buckets exist; entries
idle for 10 minutes are evicted in stable least-recently-used order, and a new source while all are
non-evictable uses one shared overflow bucket with the same 4-token/5-second parameters. Rejected,
malformed-after-header, ordinary, resume, and legacy hellos all consume; TCP connects that never
produce a complete bounded hello remain governed by the socket/deadline caps. Host restart starts
empty runtime accounting with full buckets. Seeded-clock tests cover exact refill boundaries,
IPv4/IPv6 normalization, source churn/overflow, restart, legacy flood, and honest-peer progress.

## Host-issued identity and resume tokens

The client never asserts an authoritative player ID. The host transactionally allocates an
immutable, never-reused `joinedOrdinal` starting at one; the RPG authority is exactly
`lan:<joinedOrdinal>`. Add strict v6 identity metadata and peer storage with a unique world/ordinal
constraint. A committed provisional ordinal is burned even if its handshake never completes.

The host stores only the SHA-256 hash of a 256-bit CSPRNG resume token and compares all 32 bytes by
XOR accumulation. The client stores only the raw token in its local credential row. Persisted and
runtime identity state are deliberately disjoint:

- `LANPeerCredentialTupleV6`, the **only** SQL CAS subject, is
  `{hostInstallationID, worldLANID, authority, activeHash?, activeGeneration, pendingHash?, pendingGeneration?,
  pendingHandshakeID?, pendingExpiry?}`. The optional pending fields are either all present or all
  absent. The row contains no session epoch, connection ID, socket generation, socket reference,
  monotonic deadline, or authenticated flag. `pendingExpiry` is an absolute persisted instant set
  to admission time plus exactly 120 seconds; a value expired or more than 120 seconds in the future
  at read/resume is conservatively expired, covering host-clock rollback.
- `LANRuntimeAuthorityLeaseV6` is memory-only
  `{sessionEpoch, connectionID, socketGeneration, handshakeID, monotonicDeadline, phase}`. The
  16-byte epoch changes on every `startHost`; connection IDs are fresh and nonreused within that
  epoch; socket generations increase without wrap per authority. None is encoded into SaveDB.
- Every admission, resume, promotion, supersession, deferred reserve, prepared commit, expiry, and
  teardown transition takes the same per-authority lock. While holding it, code first validates the
  exact runtime lease and then, when persistence changes, performs a SaveDB compare-and-swap from
  one complete persisted tuple to another. SQL never pretends to compare runtime epoch/socket data.

Secret discovery is index-only and precedes the authority lock. `lan_peer_token_index_v6` has the
unique indexed key `(hostInstallationID,worldLANID,tokenHash)` and value
`{authority,role:active|pending,generation}`; `lan_legacy_nonce_index_v6` has the unique indexed key
`(hostInstallationID,worldLANID,nonceHash)` and value `{claimID,status}`. A `resume` hashes its sole
raw token, performs one equality-index lookup without scanning peer rows, releases the DB executor,
then takes only the returned authority lock and revalidates index plus complete credential tuple in
the mutation transaction. `legacyConsume` follows the same nonce-index -> claim lock -> transactional
revalidation order. No hello-provided authority or generation participates in lookup.

Credential creation, pending replacement, pending resume metadata update, promotion, expiry,
retirement, and legacy consume atomically update the complete credential tuple and every affected
token/nonce index row in the same SQL transaction. Promotion changes the pending index role to
active while deleting the prior active index; rollback restores both tuple and indexes. Unique-index
collision, no row, stale role/generation, orphan index, expiry, token/nonce mismatch, join-code
failure, or CAS failure rolls back and sends only the same bounded `serverReject("admissionFailed")`,
then closes. It reveals no authority/role/existence detail, scans no identities, allocates no fallback
identity, and never converts the hello variant. Index consistency is verified at startup before
advertising; inconsistency disables admission until repaired offline.

Physical persistence is separated by responsibility. `lan_peer_identity_v6` stores immutable
host/world/ordinal/authority and quarantine/lifecycle linkage;
`lan_peer_credentials_v6` plus `lan_peer_token_index_v6` store only credential CAS columns;
`lan_peer_permissions_v6` stores the strict permission row described below; and
`lan_peer_authority_checkpoint_v6` stores only checkpoint generation, canonical owner bytes,
owner/inventory revisions, melee/tick state, and checkpoint linkage. Legacy claims/nonces have their
own tables. No gameplay checkpoint blob, row replacement, migration helper, or `INSERT OR REPLACE`
can address credential/index columns.

### Closed permission payload and host-local equivalent

`LANPeerPermissionsV1` is a strict DTO with exactly the following ten Boolean keys. Unknown,
missing, duplicate, integer/string-as-Bool, or variant keys reject before admission or mutation.
`lan_peer_permissions_v6` stores one row per live resumable/provisional guest identity as
`{hostInstallationID,worldLANID,authority,permissionRevision,payload}`;
`lan_host_local_permissions_v6` stores the identical payload under literal authority `host:local`.
Both use `INTEGER NOT NULL CHECK(value IN (0,1))` physical columns rather than a permissive JSON
blob. A row is at most 4,096 accounted bytes, computed as the actual canonical key/column bytes plus
512 bytes row/index overhead; 256 guest rows plus the one host row are at most 1,052,672 bytes.

| Exact key | New guest default | Valid nine-field pre-v6 migration | Host-local default | Intents/guards requiring current true value |
| --- | --- | --- | --- | --- |
| `canBuild` | true | preserve | true | place, break, and remote block-use mutations |
| `canUseContainers` | true | preserve | true | open/edit/transfer for container state |
| `canCraft` | true | preserve | true | remote crafting transforms |
| `canUseTemplates` | true | preserve | true | template place and undo |
| `canUseCommands` | false | preserve | true | typed command intent |
| `canUseAI` | false | preserve | true | typed AI intent |
| `canChangeDimensions` | false | preserve | true | dimension-change intent |
| `canRespawn` | true | preserve | true | respawn intent |
| `canUseCreative` | false | preserve | true | creative-mode transition or creative-only mutation |
| `canPVP` | false | set false | false | melee and every immediate/delayed Player-harm resolution, for both attacker and target |

Allocation writes those guest defaults exactly. Migration accepts only the already validated
nine-key legacy payload, preserves each of its nine values, adds `canPVP=false`, and commits the new
row atomically; any other missing/extra/malformed legacy field quarantines the identity rather than
defaulting it. The first v6 host baseline transaction creates the explicit host-local row with the
host defaults above; no operator-status, socket role, local-player special case, or absent row can
stand in for it. World copy/move and retirement follow the identity rules and never import a host
row from a different `(hostInstallationID,worldLANID)`.

Every typed intent has a closed required-permission mask derived only from the operation/action
registry. Preparation captures the complete row and `permissionRevision`; immediately before the
first live write, commit re-reads the same host/world/authority row and requires byte-equal revision
plus every mask bit still true. A permission change causes the ordinary cached semantic rejection
with no mutation. Template preparation revalidates immediately before atomic job admission and its
first live slice; later slices are continuation of that one admitted intent, not new authorization.
Delayed Player harm independently
re-reads both current `canPVP` rows and the current world rule at actual resolution. One-field
sentinel tests flip each of all ten fields alone and prove only its mapped intent/guard changes;
restart/migration tests preserve all ten values, and prepare/change/commit plus template-admission and
delayed-harm races prove stale permission rows cannot authorize work.

### Trusted permission mutation

Permission mutation is local-host control-plane work only. The sole entry point is
`LANHostPermissionController.setPermissions(subject:expectedPermissionRevision:payload:)`, reached
only from the hosting lobby's guest/host-local permission editor, the local
`/lan permission <authority> <key> on|off` command, or an internal host API carrying the same trusted local
capability. Protocol v6 defines no client permission frame or intent; any remote message kind/key
that attempts to set a permission is malformed and closes without touching a row or revision.

The controller strictly decodes all ten and only ten Boolean fields before taking the subject lock
(`lan:<ordinal>` or `host:local`). Under that lock it reads the complete SQL row, requires the exact
expected `LANVersionedCounterV1 permissionRevision`, computes its checked successor, and CASes from
the complete old ten-column row/revision to the complete new ten-column row/revision using
`BEGIN IMMEDIATE; UPDATE` of all ten physical columns plus the pair with the exact old pair/row in
the `WHERE`; `changes == 1; COMMIT` is required. Insert/replace is forbidden. An identical payload is
an explicit `noChange` and does not advance revision. Missing
subject, stale revision, lifecycle/outer-counter terminal, SQL/disk error or CAS loss leaves both
database and memory byte-identical. Only after COMMIT may main publish the new row, refresh the UI,
or let later intent preparation observe it; no optimistic toggle or row-wide replacement exists.
A terminal guest transition first commits all ten false and then terminates that subject; a terminal
host-local permission revision stops hosting through the ranked lock path.

Tests concurrently edit different and identical fields, race stale host controllers, permission
checks and peer teardown, inject failure/crash before and after every read/CAS/COMMIT/publication,
restart guest and host-local rows, exhaust/rebase permission revision, and send every plausible
remote mutation attempt. Installed-app proof edits all ten fields for a guest and host-local row,
restarts, verifies persistence, then demonstrates the world `pvp` rule plus both explicit `canPVP`
controls allow and deny melee without exposing a network mutation surface.

### Bounded persistent identity storage and retirement

Per hosted world, live resumable/provisional identity storage is capped at 256 rows and
268,435,456 encoded bytes across identity, permission, credential, owner-authority and row-overhead
accounting. Token indexes are separately capped at 512 rows/2,097,152 bytes. Each accounted row is
`SQLite length(all text/blob columns) + 512` bytes; counts and sums are obtained with indexed SQL,
never by loading every blob. Quarantined imports are capped at 128 rows/67,108,864 bytes, and the
retired audit ring at 1,024 rows/1,048,576 bytes. No decoder, UI, or command loads an unbounded list.

`joinNew` and `legacyConsume` encode the exact projected default/migrated owner and all physical
rows/indexes, reserve count and byte capacity transactionally, and only then allocate/burn an
ordinal or generate a pending credential. Capacity failure rolls back with generic admission
failure and leaves allocator high-water unchanged. Import/copy computes its whole quarantine size
before mutation; overflow refuses the whole import rather than truncating or authenticating a
subset. UI and `/lan identities` use stable keyset pagination by `(joinedOrdinal,rowID)`, limit
`1...50`, with an opaque 128-byte cursor bound to host/world/filter; invalid/stale cursors fail.

Manual retirement is a destructive, host-approved UI/`/lan retire <authority>` operation with
confirmation. It first refuses `identityInUse` without mutation if any authenticated/rotation lease,
open/closing socket, deferred/prepared request, or checkpoint-owned reference is live; the host must
kick and complete centralized cleanup first. Retirement then blocks new admission, revokes active/
pending token indexes and credentials atomically, resolves or tombstones all temporary/delayed/
proxy references through a coherent checkpoint, removes the resumable owner/permission rows, and
appends a bounded audit record. Failure at any step leaves a nonauthenticating `retiring` state that
restart completes before hosting. The monotonic ordinal allocator is never decremented or reused,
so deleting a retired live row preserves the burned ordinal. Audit-ring overflow deterministically
folds the oldest acknowledged page into one bounded nonauthenticating count/range summary before
append; it never resurrects identity data. Tests cover every count/byte boundary, cap-before-ordinal,
concurrent joins/retirements, live-lease refusal, reference cleanup/tombstones, import atomicity,
pagination/cursor abuse, crash recovery, and proof retired tokens/ordinals never authenticate/reuse.

Token rotation is two phase:

1. A new identity persists pending generation one. An active-token match may CAS a new pending
   generation `active + 1` only when the authority lock proves there is no live rotation lease. A
   concurrent active-token socket is rejected and cannot replace pending state or evict the
   authenticated socket.
2. If an active rotation lease terminates or expires, its pending tuple remains resumable until its
   persisted expiry. Replacement from the active token uses a CAS over the complete old persisted
   tuple and installs a fresh pending hash, generation, handshake ID, and expiry. Generation
   exhaustion follows the terminal policy below; it never allocates a replacement here.
3. A token matching `pendingHash` resumes that same pending generation. Under the authority lock,
   the host first CAS-replaces `pendingHandshakeID` and `pendingExpiry` with a fresh CSPRNG
   handshake ID and fresh exactly-120-second expiry, then creates a fresh memory-only connection ID,
   socket-generation lease, epoch binding, and monotonic deadline. The prior pending handshake and
   every prior runtime lease become invalid. This works after host restart even though every
   runtime lease was lost. The host does **not** resend the raw pending token because the client
   necessarily already has it.
4. For a newly generated pending credential, the host persists its complete pending tuple before
   sending `serverAccept(..., rawPendingToken, generation, handshakeID, opaqueSocketGeneration,
   epoch, ...)`. The client durably stores pending token plus its prior active fallback before
   proceeding. A pending resume sends the same accept shape but omits the raw token.
5. `clientReady` resends the pending raw token and echoes authority, generations, epoch,
   handshake ID, and opaque socket generation. Under the authority lock the host revalidates the
   exact memory-only lease, hashes and constant-time compares the token, verifies the persisted
   tuple and expiry, then reserves the complete request-zero bundle.
6. Promotion holds the authority lock across runtime validation and a SQL CAS from the exact tuple
   `{old active, matching pending}` to `{active = pending, pending = absent}`. It revalidates the
   same memory-only epoch, connection ID, socket generation, handshake ID, phase, and deadline
   immediately before and after the SQL call. Only then may the runtime lease become authenticated
   and an older authenticated socket be superseded. Every later reserve and commit revalidates
   epoch, connection ID, socket generation, and phase under that lock.
7. The host enqueues request-zero. The client promotes its local pending credential only after the
   complete private bundle and its local checkpoint apply. On reconnect the client tries pending
   first, then its retained active fallback; it never sends multiple credentials in one hello.

Lost accept leaves the old credential/socket valid. Lost ready leaves the pending token resumable.
Lost request-zero is recoverable because the locally pending token now matches active. A
pending-only new row whose accept is permanently lost is deleted at expiry while its ordinal stays
burned. A claimed public authority, concurrent socket, expired lease, or stale `clientReady` never
evicts a live connection. `stopHost` first marks the runtime registry stopped under all authority
locks, invalidates every epoch/connection/socket lease and deferred/prepared reference, then closes
sockets; no old callback can promote or commit after stop. A later start always has a new epoch.

### Terminal credential-generation exhaustion: fresh identity, no transfer

The final permitted rotation is `999_999_999 -> 1_000_000_000`; a pending generation at the maximum
may resume and promote without increment. The next operation requiring `active + 1` enters one
closed terminal flow—there is no wrap, same-generation token, owner transfer, credential reset, or
automatic new authority:

1. Under admission then authority locks in ranked order, revalidate the matching max-generation token, atomically set
   lifecycle `generationExhausted`, and delete active/pending token indexes and credential secrets.
   Concurrent resumes lose the CAS; all old tokens immediately become nonauthenticating.
2. Block all new authority work, cancel deferred/prepared requests, send the bounded terminal reason
   when the socket is usable, then forcibly run centralized terminate/cleanup and invalidate/close
   every lease/socket. This system terminal path intentionally does not use manual retirement's
   live-lease refusal.
3. Resolve/remove proxies and every delayed/temporary causal reference; unloaded guarded effects
   become cleanup-only tombstones bearing the old authority and can restore blocks but never act,
   award XP, or bind a new owner. Commit that cleanup coherently, remove resumable owner/permission
   rows, append the retired audit, and finish lifecycle `retiredGenerationExhausted`.
4. No owner, inventory, RPG state, permissions, replay/request sequence, ordinal, token, legacy
   mapping, descriptor credit, or tombstone ownership transfers. The allocator high-water preserves
   the old ordinal. There is never more than one live authority for those data.
5. Only after terminal cleanup succeeds may the host explicitly choose **Allow Fresh Join** /
   `/lan allow-new <oldAuthority>`, which records the local approval and rotates/displays a new join
   code. The client must submit ordinary `joinNew` with that code and receives a blank, unrelated
   host-issued authority/ordinal. Without this host action, resume remains terminal and no new row is
   allocated.

The crash-recoverable lifecycle is `generationExhausted -> cleanupPending -> cleanupCheckpointed ->
retiredGenerationExhausted`; startup disables admission for that authority and resumes the first
unfinished step. If cleanup checkpointing fails, LAN authority stops and peers close under the
checkpoint-failure rule. Tests cover max-1/max boundaries, pending-max resume, concurrent terminal
attempts, active sockets, every crash edge, old-token rejection, host approval absence/presence,
blank new identity, no transfer, cleanup/tombstones, allocator monotonicity, and one-authority proof.

Host persistence contains the physically separated tables above; none contains raw tokens or live
epochs. Transactions use the SaveDB serial executor, strict pre-decode byte caps, exact column
lists, foreign/unique constraints, and failure-reporting writes. Gameplay owner/world/temporary/
delayed-descriptor/tombstone durability occurs only through the coherent checkpoint transaction
defined below, whose captured input contains no credential or secret-index value; failed
checkpoints retain the whole generation for retry. Identity allocation/token/index CAS remains its
own admission-critical transaction because it precedes gameplay authority. Graceful stop makes a
synchronous coherent final gameplay-checkpoint attempt without rewriting credential tables.

## Explicit legacy migration

V5 `lan_players` rows are quarantined and never seeded as authenticated identities. Ordinary
**Join as New** uses only `joinNew` and immediately allocates a new ordinal after the join-code
gate. **Resume legacy guest** first uses `legacyClaim`; its old local v5 ID is only the untrusted
`legacyHint` and is never accepted in any other hello variant.

V6 migration renames/seals that table as `lan_players_legacy_quarantine_v5` and permanently removes
`putLANPlayer`, `getLANPlayer`, `listLANPlayers`, `deleteLANPlayer` and raw JSON test insertion from
all production authority paths. No missing/newer/malformed legacy JSON can default into, override,
or be compared as v6 owner, permission, credential or checkpoint state. The only reader is the typed
`LANLegacyClaimStore.readQuarantinedProjection` used after an approved `legacyClaim`; it applies the
bounded legacy validator and returns an inert migration candidate, never a live owner.

The v6 SaveDB facade exposes no generic handle to the quarantine table. A debug/test SQLite
authorizer rejects every statement naming it except the typed claim reader; writes/deletes are
always denied, with claim status/mapping stored in separate v6 tables. A durable schema marker makes
older code refuse LAN authority rather than downgrade to `lan_players`. Missing table/row, malicious
future fields, duplicate IDs, corrupt/oversize JSON and forced downgrade all fail closed and leave
Join as New available. Tests enumerate every SaveDB helper/SQL statement, inject legacy rows with
newer revisions/permissions/credentials, remove/rename tables, restart and attempt downgrade, proving
only approved `legacyClaim -> legacyConsume` can read a bounded inert projection.

Client-side v6 likewise renames/seals `lan_player_resume` as
`lan_player_resume_v5_quarantine` and removes `getLANClientResume`, `putLANClientResume`, every
`INSERT OR REPLACE`, `worldID#seed` lookup and pre-v6 Player hydration from connect/open paths. The
typed `LANLegacyClientResumeMigrationStore` may keyset-list bounded raw row hashes for quarantine
UI/export/delete only; it cannot return a Player/owner DTO or write v6 checkpoint tables. Its table
has the same typed-facade/authorizer/source-audit isolation as host legacy rows.

A v6 client has no authoritative owner before a complete request-zero owner bundle validates and
`commitLANClientAuthorityCheckpoint` commits under the exact `(hid,wid,lookupDigest)` key. Pending
credentials may exist, but UI/render state stays explicitly ownerless/loading; neither a missing v6
row nor any legacy/newer/malicious resume JSON supplies position, inventory, RPG, revisions or quick
slots. Tests cover old `worldID#seed` collisions, missing/newer/corrupt rows, forced SQL bridge/
downgrade/`INSERT OR REPLACE`, crash before/after request-zero COMMIT and source enumeration proving
only the v6 client checkpoint can end ownerless state.

A valid `legacyClaim` contains a fresh 128-bit CSPRNG nonce generated by the client and the strict
join code. After the normal
hello byte/rate limits, the host transactionally inserts one detached claim
`{hostInstallationID,worldLANID,legacySourceID,requestedDisplayName,SHA256(nonce),displayCode,
createdAt,expiresAt,status}` plus its unique nonce-index row,
bounded by the eight-claim/120-second limits, and immediately closes the socket without issuing a
token, owner data, ordinal, or provisional identity. The raw nonce is never persisted or logged.
The six-character display code may collide and therefore only filters UI candidates; it is not an
authenticator and approval by code alone never creates a resumable identity.

The LAN host screen lists display code, old and requested display names, reason, and expiry with
Approve/Reject buttons; chat announces it. `/lan identities`, `/lan approve <code>`, and
`/lan reject <code>` are accessible selection equivalents, but approval only changes the detached
claim to `approved` after a unique claim is selected. Approval allocates no ordinal, copies no
state, binds no socket, and sends no credential.

The client must reconnect with the closed `legacyConsume` variant and its sole original raw nonce.
The host finds the claim only through `(hid,wid,SHA256(nonce))`, then under the returned claim lock
constant-time compares all 32 bytes, verifies approved/unexpired/unconsumed status, and
in one SQL transaction CAS-marks the nonce consumed, allocates the fresh ordinal, copies only
validated legacy position/inventory projection/permissions/repaired RPG state, strips quick slots,
records the unique legacy mapping, and creates the normal pending credential tuple. Only that
complete reconnect transaction enters ordinary token admission. Exactly one of simultaneous
reconnects can consume the nonce; losers close without identity state. Rejection, expiry,
corruption, oversize, nonce mismatch, display-code collision, approval race, or host restart never
authenticates a socket and leaves the quarantined v5 row untouched. Expired/consumed claims are
pruned deterministically; Join as New is never blocked by legacy rows.

## Lossless private owner bundle

`LANOwnerSnapshotV1` is the sole authoritative guest owner representation. Its strict decoder
requires every nonoptional field exactly once, rejects unknown keys, duplicate collection IDs,
nonfinite or negative-zero floating values, and cross-field inconsistencies, and performs no
repair/clamping. “Lossless” means equality after each
`live capture -> DTO -> canonical bytes -> DTO -> temporary Player -> DTO` phase, not merely enough
fields to render a plausible avatar. The schema is exhaustive:

| Group | Exact fields | Strict domain and cross-field rule |
| --- | --- | --- |
| Envelope | `schema`, `authority`, `ownerRevision`, `inventoryRevision`, `globalTick`, `dimension` | schema exactly 1; authority `lan:<ordinal>`; revisions/tick strict `LANVersionedCounterV1`; closed dimension registry |
| Pose | `x/y/z`, `prevX/prevY/prevZ`, `yaw/pitch`, `prevYaw/prevPitch` | every value finite; positions `-30_000_000...30_000_000`; y also within that bound; yaw values `-1_000_000...1_000_000` radians; pitch values `-pi/2...pi/2` |
| Motion/shape | `vx/vy/vz`, `width`, `height`, `stepHeight`, `gravityScale`, `fallDistance` | finite; velocity `-64...64`; width/height/step `0...8`; gravity `-8...8`; fall `0...1_000_000`; Player width/step and standing/sneaking height must equal engine constants |
| Riding graph | optional `vehicleRef`, sorted `passengerRefs` | closed persistent subjects/relation classes below; Player vehicle is an entity key, a chunk entity may name this owner authority as passenger; reciprocal edge/index equality, one vehicle, uniqueness and acyclic same-dimension graph are mandatory |
| Base flags | `onGround`, `horizontalCollision`, `dead`, `inWater`, `inLava`, `underwater`, `inPowderSnow`, `noGravity`, `noClip`, `persistent` | exact Booleans; hosted Player `persistent` must be true; no truthy integer/string decoding |
| Base timers | `entityAge`, `fireTicks`, `airSupply`, `invulnTicks`, `freezeTicks`, `portalCooldown`, `portalTime` | `entityAge` is strict `LANVersionedCounterV1`; all others `0...1_200_000`; values preserve their exact phase and are not reset during hydration |
| Vital | `health`, `maxHealth`, `absorption`, `hurtTime`, `deathTime`, `catalystBloomPending`, `lastHurtByPlayerTime` | finite vital values `0...2048`, `health <= maxHealth`; timers `0...1_200_000`; exact Boolean; `dead`/death fields pass closed semantic validation |
| Attributes | `attackCooldown`, `speed`, `kbResist`, `jumpPower` | finite `attackCooldown 0...1_000_000_000`, speed/jump `0...8`, resistance `0...1` |
| Movement/input phase | `moveForward`, `moveStrafe`, `jumping`, `sprinting`, `sneaking`, `limbSwing`, `limbAmp`, `attackAnim`, `headYaw`, `bodyYaw`, `noJumpDelay` | axes finite `-1...1`; all presentation values finite `-1_000_000...1_000_000`; exact Booleans; `noJumpDelay 0...1_200_000` |
| Food | `hunger`, `saturation`, `exhaustion`, `foodTickTimer` | hunger `0...20`; finite saturation `0...20`; finite exhaustion `0...1_000_000_000`; `foodTickTimer 0...1_200_000`; no timer reset at decode/apply |
| Vanilla XP | `xp`, `xpLevel`, `xpProgress` | xp `0...1_000_000_000`, level `0...100_000`, finite progress `0...1`; tuple must satisfy the engine XP invariant |
| Mode/selection/flight | `gameMode`, `selectedSlot`, `flying`, `elytraFlying`, `creativeDoubleJumpWindowRemainingMs`, `creativeFlightLaunchTicks`, `flyingWandFlightActive`, `flyingWandFallLocked`, `flyingWandFallDamageMultiplier` | mode exactly survival/creative; selected slot exactly `0...8`; exact flags; window `nil` or finite `0...280`; launch `0...1_200_000`; multiplier `nil` or finite `0...1`; illegal mode/equipment/flight combinations reject |
| Sleep/spawn | `sleepTicks`, `bedPos`, `spawnPoint`, `spawnDimension`, `spawnForced` | ticks `0...1_200_000`; optional positions are exact integer triples in coordinate bounds; closed dimension; exact Boolean |
| Mining/use | `breakingX/Y/Z`, `breakingProgress`, `attackStrengthTicker`, `usingItem`, `useItemTicks`, `useItemHand`, `useItemSlot`, `useItemItemID`, `fishingSessionID` | coordinates bounded; progress exactly `-1` or finite `0...1`; ticker finite `0...1_000_000_000`; use ticks `0...1_200_000`; hand `main/off`; slot `-1...35`; item `-1` or registered numeric ID; session is nil or one exact descriptor ID owned by this authority; inactive use requires ticks 0, slot/item -1 |
| Portal phase | `portalTicks`, `insidePortalKind` | ticks `0...1_200_000`; kind `nil/nether/end`; phase combination validated exactly |
| Player entity data | `playerEntityData.deathCause`, `playerEntityData.deathAttacker` | closed `LANPlayerEntityDataV1` with exactly these two optional keys; cause is nil or one registered damage-source ID up to 64 UTF-8 bytes; attacker is nil or a sanitized single-line authority/display value of 1...128 UTF-8 bytes; every other `EntityData` field must be nil and makes the owner unrepresentable if populated |
| Status effects | ordered `effects` | at most 32 unique registered IDs; duration exactly `-1` or `1...1_200_000`; amplifier `0...255`; `ambient` and `showParticles` each preserve all three states `nil/false/true` |
| Equipment/storage | `inventory`, `enderChest`, `armor`, `offHand` | exactly 36/27/4/optional `LANItemStackV1` slots in order; selected main hand is derived from inventory and never encoded twice |
| Deterministic owner RNG | `ownerRNG.a/b/c/d` | four exact `UInt32` words; implementation adds bounded snapshot/restore accessors and never reseeds on hydration |
| RPG identity/progression | `RPGAuthoritativeStateV1` | every `RPGCharacterState` field except `actionQuickSlots`: version exactly current v2 and exact `created`; closed path, starter, branch with the uncreated/created cross-field rules; five attributes `6...18`; xp through level-20 cap and level `0...20`; closed rank map up to 54 entries with rank `1...3`; ordered unique prepared skills `0...4`, known spells `0...17`, prepared spells `0...6`; optional selected prepared spell/action; finite fatigue `0...derived max`; action sequence and authority revision are strict `LANVersionedCounterV1`; kit grant version `0...RPG_STARTER_KIT_VERSION` and closed optional kit ID; up to 32 unique cooldowns and 16 unique upkeeps with scalar remaining ticks `1...1_200_000`; exact bounded XP-ledger counts, keys, masks, and milestone words |
| Closed player stats | `arrowsShot`, `blocksPlaced`, `blocksMined`, `fatigueRestoreHarvestTick`, `fatigueRestoreHarvestAmount`, `fatigueRestoreHerbalLoreTick`, `fatigueRestoreHerbalLoreAmount`, `toolTuneCounter`, `salvageCounter` | all nine keys are explicit; five cumulative counters and both absolute tick fields are strict versioned counters even though the live bag currently uses `Double`; amounts are finite `0...1_000_000_000`; fractional/nonfinite values and unknown/missing/duplicate keys reject rather than cross as an arbitrary dictionary |

New Player initialization and the one-time pre-v6 legacy repair seed exactly these nine stat keys to
zero, using `{generation:0,value:0}` for versioned fields; after admission, missing/extra keys are
invariant failures and are never silently repaired by capture/decode.

Fields intentionally absent are also closed: runtime object references (`world`,
`lastAttacker`, `lastHurtTarget`, bobber object, socket, ghost/proxy pointers), local
input wall-clock timestamps, entity allocation ID, LAN mirror metadata, and derived values
(`mainHand`, `wearingPumpkin`, authority from the envelope). They are rebound or recomputed only
after the complete temporary owner validates. Apart from the two `LANPlayerEntityDataV1` fields,
every `Entity.data` option must be nil. Player invariants not carried as data are `xpReward == 5`,
`breathesWater == false`, and
`breathesWaterOnly == false`; any contrary hosted Player is not representable and authority work
fails before consumption. Process-local weak attacker/Arcanist/mitigation/Mender object pointers
are never encoded and are reset before descriptor rebinding. Every numeric injury generation,
nonce, credit, expiry, and other causal value that can mint delayed XP lives only in the applicable
closed host-checkpoint descriptor and is hydrated; no unrepresented value may survive restart.
No other mutable Player/Entity/Living field may be added without updating this table, its strict
DTO, canonical equality oracle, and every phase test first.

`LANOwnerFieldMapperV1` is the single bidirectional capture/hydrate implementation. Its independent
oracle is a closed `LANOwnerFieldID: CaseIterable` manifest assigning every stored property declared
by `Entity`, `LivingEntity`, and `Player` exactly one disposition: encoded field, derived invariant,
runtime-only reset/rebind, or forbidden-for-hosted-owner. A pipeline source audit enumerates those
stored declarations and fails when the source set and disposition manifest differ. White-box tests
mutate each encoded field independently to a unique in-domain sentinel and assert the mapper changes
exactly that `LANOwnerFieldID`, survives every canonical phase, and hydrates the same value; each
derived/reset/forbidden field has its inverse invariant test. Thus adding, omitting, aliasing, or
accidentally mapping a field—including selected slot, the nine stats, or either death field—fails
without relying on a hand-picked round-trip fixture.

Fishing uses no process `fishingBobberID`. `LANFishingSessionV1` is one owner-linked persistent
descriptor, at most one per owner/nine per world and 4,096 bytes each, exactly
`{schema:1,descriptorID,ownerAuthority,dimension,x,y,z,vx,vy,vz,yaw,pitch,onGround,
horizontalCollision,fallDistance,fireTicks,airSupply,invulnTicks,freezeTicks,portalCooldown,
entityAge,biteTime,nibbling,hookedTarget,simulationRNG:{a,b,c,d,drawCount},rodSlot,
rodItemDigest,rngGenesis,lifecycle,reelReservationSequence,reelReservation}`. Descriptor ID is 16 CSPRNG bytes; finite pose/motion,
angles and fall distance use the entity bounds; age and RNG draw count are independent complete
versioned pairs; bounded timers use their ordinary scalar domains. Width, height, gravity and fluid
flags are type-derived or rebuilt from the validated canonical cells before the first callback.
Slot is `0...35`; the digest binds the complete canonical rod stack and its lure/luck values.
Lifecycle is the closed sum `cast | nibbling | bite | hooked | reelPending`: cast has both timers
zero and no hook; nibbling has `1...1_200_000` nibbling and zero bite; bite has `1...1_200_000`
bite and zero nibbling; hooked has exactly one living target and zero timers; reelPending has exactly
one strict reservation. Acquiring a hook atomically clears both timers. Other combinations reject.
`reelReservationSequence` starts at `{0,0}` and remains in every lifecycle; only the checked
successor used to enter `reelPending` may change it, and the reservation must carry that exact result.
The runtime `FishingBobber` remains a forbidden transient projection recreated RNG-free only after
the descriptor, owner binding and complete relation index validate.

`LANFishingSessionRNGGenesisV1` is the immutable cast proof
`{domain:4,ordinal:0,ownerEffectSequence,contextDigest,interactionRNGExpected,
interactionRNGResult,childRNG}`. Both interaction rows are complete
`{id:.interaction,a,b,c,d,drawCount}` values; `ownerEffectSequence` is the checked successor used as
the split sequence; `contextDigest` is the exact domain-4 digest below; and `childRNG` is the exact
split child with draw count `{0,0}`. The descriptor's initial `simulationRNG` must equal `childRNG`
byte-for-byte. The proof never changes while later session ticks advance only `simulationRNG`.

`LANFishingReelReservationV1` is exactly `{reservationSequence,expectedOwnerDigest,
expectedRodDigest,interactionRNGExpected,interactionRNGResult,catchRNG,outcome,
primaryEntityRecordRefs,ownerDeltaDigest,chunkCASExpectedResult}`. The expected/result interaction
rows are complete `{id:.interaction,a,b,c,d,drawCount}` values and `catchRNG` is the exact domain-3
child `{a,b,c,d,drawCount:{0,0}}`. `outcome` is the closed sum
`hookedImpulse(targetRef,resultRecordRef) |
loot(contractDigest,itemEntityRefs,xpEntityRef,xpAmount,durabilityDamage) | empty`; there are at most
eight generation-scoped primary-record references, each naming an exact key/checkpoint generation/
record digest rather than embedding a record. XP is `1...6`, durability damage is the exact checked
rod delta, and all item/XP keys, poses, velocities, loot bytes and RNG results already exist in the
referenced primary segment. A reservation is immutable: retry reuses it and never rerolls, redraws,
reallocates a key or rereads a mutable loot table.

Cast preparation generates the descriptor ID, validates the rod, reads the owner's exact
`effectOwnerSequence` and durable world `interaction` stream row, checks both successors, and runs
domain 4/ordinal 0 with the owner/descriptor/rod/dimension context. Before any live change it reserves
the descriptor, parent result, owner row, required `fishingOwner` edge, explicit absent
`fishingHook`, relation indexes, replay/send and checkpoint bytes. One DB-first checkpoint atomically
commits the owner-sequence successor, full interaction expected/result CAS, descriptor with immutable
genesis proof/child RNG, owner session/rod binding, required owner edge and absent hook state. Only
its receipt may publish the transient projection. Failure or CAS loss leaves owner, parent RNG,
descriptor, relations and projection absent; exact retry reuses the staged bytes and never splits
again. Parent draw-count outer terminal stops hosted authority with zero cast state; owner-sequence
terminal performs the owner terminal policy with zero parent transition/allocation. Fixed host-local
and guest vectors cover retry before/after COMMIT, restart before first session tick, context changes,
draw-count rebase/terminal and child/result nonzero escapes.

Each tick advances its saved RNG
words/draw count, timers, physics fields and optional hook relation through prepared world state.
Reel requires the same authority/slot/rod digest. Scratch preparation reads the descriptor's exact
reel-sequence pair and the durable world `interaction` RNG row, checks the sequence successor and RNG
draw-count successor before allocating anything, derives the domain-3 child/result below, and
pre-reserves every primary key/row, owner/world delta, relation, journal and checkpoint byte. The
reservation DB-first checkpoint atomically installs the sequence successor, full immutable
reservation, interaction result row and `reelPending`; no sequence or parent RNG state may publish
alone. A later coherent DB-first resolution checkpoint applies its referenced target/loot/XP/durability
result, clears descriptor/session plus `fishingOwner`/`fishingHook`, burns every reserved key and
removes the projection. Missing rod, disconnect, owner retirement or dimension transfer uses the
explicit atomic-clear lifecycle with zero outcome; failure retains the exact old descriptor,
relations, reservation and rod state. Tests cover every lifecycle and cross-field combination,
physics/timer/RNG sentinels, hooked unloaded/retired targets, all reservation refs, restart, rod
swap/break, reel/cancel crash cuts and proof runtime entity-ID reuse cannot steal or duplicate a
session.

`LANItemStackV1` losslessly represents every current `ItemStack` field: ID/count/damage/label,
enchantments, potion, trim, sherds, charged/prior-work/repair data, lodestone, flight, and carried
contents. Validation rejects unregistered IDs, illegal counts, durable damage outside
`0..<item.toolOrArmorDurability` (or any nonzero damage for nondurable items), duplicate or
excessive enchantments, unknown effects, nonfinite fields, unbounded strings, contents deeper than
one or over 27 slots, incorrect array sizes, and snapshots over 524,288 bytes. One shared deep-copy
routine must copy nested stacks; `ItemStack.copy()` is not sufficient.

Canonical encoding is sorted-key JSON. SHA-256 covers the uncompressed canonical bytes. Kind 27
is a lean `LANRPGOwnerAck` manifest containing epoch, request ID, status/reason/message, owner and
inventory revisions, next expected request ID, simulation tick, credential generation, snapshot
ID/bytes/chunk count/digest. Kind 28 repeats epoch/request/snapshot/length/count/digest and adds an
index plus at most 45,000 raw bytes. Every encoded payload is rechecked against 65,536 bytes.

The client accepts one active bundle: manifest first, then exact chunk indexes `0..<count`. An
exact duplicate active manifest is idempotent and does not reset received chunks or its five-second
deadline. A duplicate already-received chunk is ignored only when epoch, request, snapshot ID,
total length, index/count, digest, and raw bytes all match. A conflicting duplicate or a chunk with
an index greater than the next required index aborts; a future index is never buffered. Mixed,
missing, over-total, wrong-length, wrong-digest, or a second unrelated manifest likewise aborts
with no mutation.

The client retains a FIFO of at most 32 full `AppliedOwnerBundleRecord` values, with a hard
24-MiB aggregate accounting cap over record overhead plus every stored byte. A record contains the
exact raw manifest payload, exact canonical owner bytes, and every binding needed to prove identity:
`{hostInstallationID, worldLANID, sessionEpoch, requestID, status, reason, message, ownerRevision, inventoryRevision,
nextExpectedRequestID, simulationTick, credentialGeneration, snapshotID, snapshotLength,
chunkCount, snapshotSHA256, manifestRawPayload, canonicalOwnerBytes,
chunks[{index,rawOffset,rawLength,rawSHA256}]}`. Chunk bindings must form the exact canonical byte
partition, in order, and their hashes and ranges must match both received raw chunks and the stored
canonical bytes. Before admission the client computes and reserves the exact post-insert accounting
and a deterministic oldest-first eviction plan, but does not mutate the FIFO. If one complete record
cannot fit after permitted eviction, the connection closes before DB/owner/inbox mutation. For a
first delivery, planned evictions and record insertion occur only after the complete client
authority checkpoint commits; failure leaves the prior FIFO byte-for-byte unchanged.

Record lookup uses exactly `(hostInstallationID,worldLANID,sessionEpoch,requestID,snapshotID)`;
digest/status/revisions/generation are comparison data, not part of the lookup key, so mutating one
cannot evade same-key collision handling.

An incoming replay is drained through the normal manifest/chunk state machine. Only after all exact
raw manifest fields, exact manifest payload bytes, all chunk bindings, all raw chunk bytes, and the
complete canonical owner bytes equal one stored record is it ignored without owner mutation,
pending mutation, or user notice. Equality of only epoch/request/snapshot/digest is insufficient.
Any same-key mutation in status/reason/message/revisions/generation/length/count, manifest bytes,
chunk boundary/index/hash/bytes, or canonical owner bytes is a protocol violation. An incomplete
bundle has a five-second monotonic deadline. Timeout closes the connection and preserves the
pending request for reconnect/retry. Tests suppress zero, some, and all chunks; replay
manifests/chunks before and after completion; mutate every record and binding field one at a time;
inject conflicting and future chunks; expire partial bundles; exhaust the 32-record/24-MiB cap; and
prove only byte-exact applied replays are idempotent.

The complete DTO is strictly decoded into a temporary owner and atomically applied only after
validation. Deep copy, host persistence, ghost hydration, prepared previews, client apply, and
request-zero convergence must preserve every table field exactly. Boundary and phase-oracle tests
compare canonical bytes after capture, host checkpoint, restart hydration, ghost hydration,
prepared preview, committed live owner, client decode, client durable checkpoint, and client apply.

## Private/public separation and dimension routing

V6 public player state, batches, restore, grants, events, chat/status, probes, and other-peer
messages never contain authoritative RPG state, quick-slot tokens, resume secrets, hashes, or
owner payloads. Generic player state has no encoded RPG field. Only the addressed owner socket
receives kinds 27/28. Host guest quick slots are always empty. Owner apply preserves client-local
slots, then normalizes only tokens no longer naming an acknowledged prepared action.

Public replication is grouped by recorded viewer dimension. Initial state/chunks use the owner's
restored dimension, not the host's current world. Block changes retain their dimension and go only
to viewers there. Proxies are updated in every loaded world. Every replication/RPG envelope uses
`GameCore.rpgSimulationTick`; per-dimension `world.time` appears only in world-state DTOs.

### Client movement is input, never pose authority

V6 makes kind 5 `playerState` host-to-client only. A client-origin kind 5 frame is a protocol
violation; the client can never submit position, previous position, velocity, health, hunger,
effects, inventory, game mode, dimension, dead state, owner revision, or RPG state. Kind 10 carries
only a strict `LANInputIntentV1`: finite `forward/strafe` in `-1...1`; exact Boolean
`jump/sneak/sprint/flyingUp/flyingDown`; finite yaw in `-1_000_000...1_000_000` radians; finite
pitch in `-pi/2...pi/2`; and selected hotbar slot `0...8`. Missing/unknown fields, nonfinite values,
out-of-range numbers, type coercion, and contradictory flying flags reject rather than clamp.
The frame sequence and authenticated socket determine the owner; any encoded client player ID is
removed from v6 rather than trusted.

The host applies at most one ordered intent per guest per global tick and runs the normal Player
movement/collision/fluid/fall/portal/dimension simulation in the guest's recorded world. A bounded
single pending intent may replace an older not-yet-applied analog intent, but a jump edge is latched
for at most one tick; there is no unbounded movement queue. The per-peer movement bucket has
capacity 10 and refills continuously at 40 intents/second. After full frame/sequence/direction and
strict `LANInputIntentV1` validation, an admitted intent consumes one movement token. A valid intent
with no movement token consumes one token from a separate tolerance bucket (capacity eight,
continuous refill one token per two seconds) and is dropped without updating analog input, jump
edge, or selected slot; when the tolerance bucket has less than one token, that next over-rate frame
closes the connection. Thus eight consecutive over-rate frames are tolerated and the ninth closes
at a no-refill boundary. Both buckets are memory-only per authority/session epoch, survive socket
reconnect/supersession in that epoch, start full on host start, and use the injected monotonic clock.

Malformed input never uses the over-rate tolerance: bad header/length/sequence/direction, client
kind 5, invalid JSON/key set/type, missing/extra field, nonfinite/out-of-domain number, or
contradictory flags closes immediately with no latch or owner mutation. A well-formed dropped frame
still consumes its frame sequence, so retrying it is a duplicate violation. Exact tests cover token
values just below/at/above one, simultaneous refill and arrival, eight/ninth strikes, two-second
refill boundaries, reconnect preservation, host restart, malformed frames while empty/full, and
proof that no drop changes input. Position,
velocity, damage, teleport, dimension, and death are therefore host outcomes. Client camera/motion
prediction is presentation-only and reconciles from host kind-5 replication/private checkpoints;
it is never read by RPG validation or persisted as authority. Tests inject extreme/NaN pose and
intent fields, wall/floor/portal cheats, flight without permission, flood/coalescing/jump edges, and
prove the host simulation alone determines the owner snapshot.

The closed permission table above persists `canPVP`, default false for guest/host-local allocation
and legacy migration, alongside the closed host game rule `pvp`, default false in every new and
migrated world when absent. An
owner-targeting melee, projectile, skill, spell, delayed effect, or area effect may harm another
Player only when the host rule is true **and** both attacker and target peer permissions are true;
host/local players use an explicit equivalent permission rather than implicit operator status.
These gates are revalidated in `RPGPreparedCommit` immediately before commit. Friendly buffs may
use their own metadata but cannot bypass damage gates through a secondary effect. Tests cover every
attacker/target/rule truth-table combination and rule/permission changes between prepare and commit.

### One canonical physical owner and normative tick order

`LANHostedOwnerAggregateV1` on main is the sole canonical writable representation for every host
guest field in `LANOwnerSnapshotV1`. The mapping is normative:

| Domain | Sole canonical storage/writer | Noncanonical projections |
| --- | --- | --- |
| Pose, motion, collision/fluid, fall/fire/air/freeze/portal, physical flags/timers, health/absorption/effects, food, mode/flight, mining/use and vanilla XP | `LANHostedOwnerAggregateV1`, replaced only by `LANHostedOwnerReducer` | `LANRemotePlayerEntity`, generic public state and render prediction are scratch/output only |
| Inventory, ender chest, equipment, selected slot, RNG, RPG state, closed stats and player death data | same aggregate/reducer, with prepared-commit deltas | ghost/UI/request previews cannot write directly |
| Client quick slots | client checkpoint only | never a host owner field |

The ghost is an RPG targeting identity and the proxy is a world simulation/damage surface; neither
is an alternate owner store. Engine code may mutate an isolated working Player/proxy during one
reducer pass, but no caller reads that scratch as committed authority and no callback writes the
aggregate directly. Damage hooks, item use, environment, proxy collisions, delayed progression, and
network input enqueue bounded typed events; only the reducer projects them. All persistence,
private bundles, public replication, action guards, and replay bytes derive from the same aggregate.

`LANOwnerReducerEventV1` is a closed sum of `damage`, `status`, `hungerExhaustion`, `environment`,
`itemUse`, `proxyProjection`, `delayedCausal`, and `lifecycle`; input uses the separately bounded
single latch. Each encoded event is at most 2,048 bytes. Counts/encoded bytes include reserved,
queued, and the event currently executing: 128/262,144 per peer, 1,024/2,097,152 per world, and
2,048/4,194,304 globally. Eight peer slots and 64 world slots are permanently reserved for
lifecycle/cleanup, leaving 120/960 for ordinary work; ordinary events cannot consume emergency
capacity. Event sequence uses the versioned counter lifecycle and queues are stable-sorted by the order
below, never Dictionary/Set iteration.

A source action computes its entire delayed/area fanout (at most 32 target descriptors/events),
strictly encodes it, and reserves descriptor, reducer-event, checkpoint, replay and send budgets
before prepared commit. Partial fanout is forbidden. Capacity failure for a request defers without
consumption; an already-durable descriptor that cannot reserve its resolution event remains
unchanged for deterministic retry and cannot award/apply/remove until the event and checkpoint
deletion commit together. A nonrequest physical/lifecycle source that exhausts even reserved
capacity stops LAN authority and closes peers rather than dropping authoritative state. Tests fill
each ordinary/emergency/count/byte/fanout boundary and prove no partial effect, lost cleanup, or
unbacked callback.

For each global tick, `LANHostedTickPreparedCommitV1` first computes the checked prospective tick
from the durable current tick and owns scratch copies of world metadata, every touched dimension,
the host-local owner when involved, and guests in stable `(ordinal,authority)` order. No World,
WorldRecord, owner aggregate, descriptor registry, RNG, or visible tick field changes while these
phases run exactly once against those copies:

1. preflight and reserve the one immutable bounded tick snapshot/query arenas defined below;
2. consume/latch the at-most-one admitted input intent;
3. materialize from the canonical aggregate and run host physical movement/collision/fluid/fall/
   portal simulation in the recorded dimension;
4. apply queued damage, status effects, hunger/exhaustion, environment and item-use events in stable
   `(eventTick,eventSequence,sourceAuthority)` order;
5. project the complete proxy physical result back through `LANOwnerFieldMapperV1` into the working
   owner—never only health/position;
6. advance pure RPG/melee timed state, drain delayed causal/progression events in stable order, then
   prepare/revalidate/commit at most the one queued exact-next RPG/melee request against this
   **post-projection** owner;
7. execute every remaining `LANWorldScheduleV1` phase `0x02...0x0F` exactly once on the
   same scratch snapshot; callbacks may enqueue only bounded reducer events/deltas and never mutate
   live authority. Phase `0x0E` drains the resulting owner post-world events into that same scratch;
8. canonical-encode before/after owner/world/entity/descriptor snapshots and compute the complete diff;
9. if any authoritative field differs, update only the scratch aggregate, mark its prospective
   dirty set, and advance `ownerRevision` exactly once for that peer/tick; advance
   `inventoryRevision` once iff its closed inventory/equipment/vanilla-XP domain changed. A request
   does not add a second revision to an already-changing tick;
10. canonical-encode and reserve the prospective global-tick metadata, all owner/host-local rows,
   touched-dimension RPG-causal deltas, entity bindings, descriptors/tombstones, checkpoint arenas,
   replay and send bytes; any failure discards all scratch and leaves the current tick/state exact;
11. perform one nonthrowing main-thread publication that swaps the prospective tick into WorldRecord
   and every dimension view, swaps all scratch reducer outputs, activates the pre-encoded checkpoint
   segments, then enqueues private/replay and public projections from that same final state.

The ordinary/template world-mutation slice is exclusively phase `0x0F`, once per fixed gameplay tick
rather than per render callback and in stable job/guest ordinal order. It obtains later prospective
chunk capture sequences inside the same scratch transaction and cannot leak a partial dimension copy
or publish independently of the prepared tick. Tests fail reservation/encoding at every phase with
host menus open and work in multiple dimensions, then restart and prove either no tick/dimension/
owner changed or all changed together.

Ordinary walking, yaw, age, fire/air/freeze, fall, hunger, status-duration, invulnerability, portal,
item-use, selected-slot, or proxy damage changes are dirty/revision-worthy even when no RPG XP or
notice occurs. A semantic rejection adds no mutation, but its fallback reflects physical changes
already coalesced that tick. Terminal cleanup that cannot wait creates one reducer boundary and uses
`lastOwnerRevisionTick` to preserve the one-revision-per-global-tick rule. No action preparation may
run from a pre-projection ghost/proxy snapshot. Tests independently change every physical group with
zero XP; combine movement, damage, delayed XP and an action in one tick; permute callbacks; unload/
reload proxies; and assert one aggregate, one canonical diff, one revision, exact checkpoint ->
private -> public ordering, and byte-identical consumers.

## One host authority transaction

Move pure authority work to `LANRPGAuthority`. V6 operations are exact, never toggles:

```text
createCharacter(draft)
learnSkill(skillID)
prepareSkill(skillID)
unprepareSkill(skillID)
spendAttribute(attribute)
prepareSpell(spellID)
unprepareSpell(spellID)
selectAction(kind,id)
executeAction(kind,id)
```

`LANRPGIntentV6` carries `expectedAuthorityRevision` for every operation and never carries an
expected broad `ownerRevision`. The server compares it to the current post-projection
`RPGCharacterState.authorityRevision` in reducer phase five. Continuous fatigue/cooldown/upkeep
ticks and all ordinary physical owner changes remain revision-free in that discrete RPG field, so
they cannot create false conflicts. Delayed XP/progression, selection/preparation, character
creation, learning, attribute spending, action execution, and terminal RPG cleanup are real
discrete mutations and do change it.

Inventory conflict fields follow one server-owned closed `LANRPGOperationRevisionPolicy`:

| Operation | Required request revision fields |
| --- | --- |
| `createCharacter`, guest melee | authority + inventory |
| `learnSkill`, `prepareSkill`, `unprepareSkill`, `spendAttribute`, `prepareSpell`, `unprepareSpell`, `selectAction` | authority only; an inventory field is forbidden |
| `executeAction(kind,id)` | authority + inventory iff the audited registry entry reads/writes inventory, main/offhand, armor, durability, material, container-carried contents, or vanilla XP; otherwise authority only |

Every one of the 19 active-skill and 17 spell registry entries has an explicit immutable policy bit;
there is no client-supplied choice or default. The strict intent key set requires
`expectedInventoryRevision` exactly for `.authorityAndInventory` and rejects it as an extra field for
`.authorityOnly`. The comparison occurs against current post-projection semantics: pose, selected
slot, health, effects and world state may legitimately change before evaluation and are validated
as current semantic gates, not optimistic-lock conflicts. A true discrete authority mismatch returns
cached `staleAuthorityRevision`; a required inventory mismatch returns cached
`staleInventoryRevision`; neither mutates. Tests submit at tick zero and evaluate after exactly
1/19/20/200 physical-only ticks (including owner syncs) and must accept when current semantics allow;
then independently change discrete RPG state or required inventory and must reject, while
inventory-independent operations ignore inventory churn.

Quick-slot assignment and clearing remain client-local and are never sent or translated into
`selectAction`; only explicit character-screen selection may mutate authoritative selected action.

The implementation must first add a required core primitive, `RPGPreparedCommit`; it is not
permitted to approximate post-state by independently projecting current mutating routines.
Preparation captures complete owner, inventory/equipment, RPG, world, entity, block, container,
temporary-reservation, credential/socket-generation, global-tick, and gameplay-RNG guards. The RNG
checkpoint includes every generator the operation can read: global gameplay RNG, relevant world
RNG, owner RNG, target RNG, and loot/container RNG state. Preparation executes all chance draws on
copies and precomputes exact durability/unbreaking/tool preservation, lethal damage and kill
progression, loot materialization, entity outcomes, temporary-effect outcomes, owner fields, and
post-operation RNG states.

`RPGPreparedCommit` exposes the exact complete post-owner preview and exact post-RNG checkpoint.
Commit revalidates credential generation, socket generation, tick, all RNG checkpoints, owner,
items/equipment, entities, blocks, containers, and temporary reservations. After the first write it
may perform only nonthrowing precomputed assignments. It must not call `hurt`, `damageHeld`,
`resolveLoot`, random APIs, callbacks that can branch, or any other fallible/recomputing gameplay
routine. Local and LAN wrappers use the same prepare/commit primitive, so there is one semantics
source. Preview canonical bytes must equal actual canonical owner bytes after commit for every RPG
action and melee case, including unbreaking, loot, temporary effects, and lethal XP/progression.

The network handler structurally admits and queues at most one request; semantic preparation runs
only in phase five of the normative tick, after proxy projection and delayed drain. For every
incoming RPG request, order is mandatory:

1. Validate frame structure, connection ownership, credential and socket generation, epoch,
   collision/replay identity, and exact-next request ID. Malformed, wrong-epoch, colliding, evicted,
   or future requests follow their structural rules before semantic gameplay is inspected.
2. For a structurally valid exact-next request, encode the complete current-owner fallback bundle
   and reserve enough replay memory, send-ledger capacity, and prospective checkpoint staging for
   the bounded fallback or success response. Capacity failure defers without consuming the ID. An identical deferred retry is a
   no-op; different bytes collide; disconnect/ten-second expiry drops the defer permanently.
3. Only after reservation validate semantic lifecycle, RPG rule, the exact revision policy above, strict owner
   representability, permission, recorded dimension/world requirements, focus/equipment,
   target/range/LOS/PvP, material, and operation-specific gates against the post-projection aggregate.
4. Deep-copy the full owner candidate. Build authorization from `lan:<ordinal>`, the ghost's real
   entity ID, and persisted `canBuild`/`canUseContainers`; use core metadata including
   `buildOnlyForBlockTarget`.
5. Creation uses the shared prepared-commit creation path, including all six starter kits and
   one-time grant. Executable actions and melee create exactly one `RPGPreparedCommit`.
6. Encode and validate the exact post-success owner preview, response, and all affected checkpoint
   segments within the existing reservations. Revalidate the complete prepared guard set
   immediately before commit.
7. Commit once through nonthrowing precomputed assignments into the tick's working aggregate. The
   normative canonical diff then increments `ownerRevision` at most once for the entire peer/tick
   and `inventoryRevision` at most once iff its closed domain changed; an accepted request never
   creates a second revision after an ordinary physical change. These remain distinct from RPG
   internal revision.
8. Cache the exact raw request plus bounded replay representation, consume exact-next for every
   structurally valid semantic accept or reject, activate the pre-encoded coherent checkpoint, enqueue the
   reserved private atomic response, then public projection, and perform only infallible
   publication/dirty marking afterwards.

Every structurally valid exact-next semantic rejection uses the reserved post-projection owner
fallback, is cached, and advances request ID without adding an owner/world mutation; ordinary
same-tick physical changes retain their one revision. Malformed, collision,
wrong epoch, future ID, or capacity defer does not consume. No prepared/deferred object may survive
disconnect or its progress deadline.

## Replay and send bounds

Live-epoch state retains `nextExpectedRequestID` and FIFO 32 entries. Each entry stores the exact
raw request; the exact bounded manifest fields and manifest payload; canonical owner bytes, digest,
snapshot ID, and fixed chunk parameters; retained byte count; owner revision; and simulation tick.
It does not retain twelve redundant chunk payload copies. Replay deterministically regenerates the
same 45,000-byte chunk boundaries and kind-28 payload bytes from canonical owner bytes. Tests fill
all 32 entries with maximum-sized owner snapshots under the 24 MiB authenticated-peer cap and all
eight authenticated peers under the derived 192 MiB global cap, and prove regenerated payload bytes
are identical to the originals. Ack reason and message remain
bounded to 256 and 512 UTF-8 bytes respectively.

- Exact next processes once.
- Cached identical bytes resend exact cached output with no reapply.
- Cached different bytes close as collision without overwriting cache.
- An evicted older ID gets an `outcomeEvicted` current-owner sync without replay insertion.
- A future ID is a protocol violation.
- Accepted and semantic-rejected exact-next requests advance.
- Same-epoch reconnect preserves replay; host restart rotates epoch, resets next to one, sends
  request-zero, and makes the client discard old-epoch pending work.
- Request-zero never advances exact-next. Same-epoch pending reconciliation follows the exact
  state machine below; it is not a blanket retain or clear operation.
- IDs and revisions never wrap.

Same-epoch request-zero reconciliation is exact:

- `nextExpectedRequestID == pending.requestID`: apply a nonregressing sync, retain the pending
  request, and retry its exact raw payload.
- `nextExpectedRequestID > pending.requestID`: after the complete request-zero owner and client
  checkpoint apply, atomically change that pending row from `awaitingState` to
  `dispositionOnly(requestZeroSnapshotID,requestZeroOwnerRevision,requestZeroInventoryRevision,
  requestZeroCredentialGeneration)`, then retry the exact raw request once. This mode is durable
  across reconnect and process restart.
- A response for a `dispositionOnly` pending request still traverses full frame sequencing,
  connection/epoch/request binding, exact cached-request identity, manifest/chunk assembly, byte
  caps, digest, strict owner DTO decode, semantic status, and canonical re-encode validation. It
  **never** installs or updates owner fields, inventory/equipment, RPG state, global tick,
  owner/inventory revisions, credential generation, selected action, or slots from that cached
  bundle. This is unconditional when the cached tuple is lower than, equal to, or higher than the
  installed request-zero owner revision, inventory revision, simulation tick, or credential
  generation; those relationships are tested but never used to reopen state installation.
- If a matching `AppliedOwnerBundleRecord` already exists, all manifest/chunk bytes and bindings are
  drained and compared to that complete record. Exact equality suppresses replay with no DB change,
  pending change, inbox insertion, owner mutation, or render; any same-key mismatch closes. This is
  the only fast replay path.
- On the **first** valid disposition delivery, no applied record exists. The client performs every
  full validation above, constructs but does not install the candidate record, then calls
  `commitLANClientAuthorityCheckpoint` with owner/slots/credentials unchanged, matching pending
  cleared, and one unique durable notification-inbox row containing the exact terminal fields plus
  its audit digest. Only after SQLite COMMIT may it insert the in-memory
  `AppliedOwnerBundleRecord`; inbox rendering is a later idempotent-by-ID step. Commit failure leaves
  pending and FIFO unchanged and closes for retry.
- After a crash between durable commit and in-memory record insertion, the durable inbox preserves
  the outcome but is **not** a hash-only substitute for a full applied record. A disposition bundle
  arriving with neither matching pending nor full `AppliedOwnerBundleRecord` (including after FIFO
  eviction/restart) is unsolicited and closes even if its digest matches the inbox audit digest. It
  can never apply owner state or insert a second notification.
- A matching `outcomeEvicted` while `dispositionOnly` is authenticated and drained by the same full
  first-delivery/replay paths, clears pending and durably records outcome unavailable without
  installing its current-owner payload or replaying a success notification.
- `nextExpectedRequestID < pending.requestID` in the same epoch is a protocol violation; close,
  mark the local pending row protocol-blocked, and do not automatically resend it again in that
  epoch. Only a new epoch or explicit local discard can clear that blocked state.
- A new session epoch atomically discards the old pending request before applying request-zero.

Tests cover accepted and rejected responses lost before any bytes, after the manifest, and after a
partial bundle; crash immediately before/after durable `dispositionOnly`; cached accepted,
rejected, and evicted dispositions whose owner/inventory/tick/credential tuple is independently
lower/equal/higher than request-zero; every malformed cached field; cleanup revision bumps before
reconnect; no-record first delivery; existing-record exact replay/mismatch; crash after inbox commit
before record insertion; unsolicited replay after FIFO eviction/restart; inbox idempotence; and proof that
no disposition-only bundle can mutate owner state.

The pure send ledger's total is exactly `reserved + encodedQueued + encodedInFlight` for both framed
bytes and frame count, including the one frame currently handed to the socket. Moving a frame from
reservation to queue or queue to in-flight transfers its accounting rather than adding or releasing
it; only completion/drop releases it. Owner manifest plus chunks is one non-skippable atomic group,
ordered before skippable deltas with no interleaving. Capacity is reserved before authority
mutation. Send completion releases queue bytes, not replay memory. Send failure preserves cache and
enters centralized cleanup. Server accept uses the same ledger; pre-auth sockets receive no deltas,
and token promotion waits until the full initial bundle fits. Tests assert the 2,097,184-byte/
32-frame boundary in every reserved/queued/in-flight permutation and during partial socket writes.

## Global clock, lifecycle, and melee

`GameCore.lanHostRPGTickHandler(currentTick:)` runs once to prepare, not publish, the checked
prospective global tick and invokes the normative scratch reducer. Only the phase-nine atomic
publication above changes the persisted WorldRecord or any dimension's visible tick; it does not
mutate a ghost/proxy beside that reducer. The host prepares connected guests in stable
`(ordinal, authority)` order and records prospective `lastProcessedRPGTick`. Pure RPG state advances
exactly once for every connected peer on every successfully published global tick regardless of
whether its recorded dimension or player chunk is loaded. This includes
fatigue regeneration, cooldown decrement, upkeep duration and periodic cost, exact upkeep expiry,
and melee `attackStrengthTicker`. `lastProcessedRPGTick` always advances; missed callbacks are not
caught up later and duplicate callbacks are no-ops.

Only world-coupled upkeep pulses, entity changes, and guarded-block work require a loaded matching
world/chunk. Pure upkeep expiry happens immediately even while unloaded. Its world cleanup happens
in loaded worlds or is converted to a cleanup tombstone for later resolution. Ghost hydration never
recharges melee or rewinds pure tick state. Host pause/menu state must not freeze the authoritative
global clock or this guest callback; the host menu proof explicitly measures continued guest
fatigue/cooldown/upkeep advancement.

A pure timed change marks the owner dirty every changing tick. Private timed-state sync is
coalesced to at most one owner bundle per 20 ticks, is immediate at a discrete boundary (cooldown
ready, upkeep expiry, insufficient-fatigue cancellation, death/dimension/rule transition) or after
delayed progression, and must send a drift checkpoint at least once per 200 changing ticks even if
ordinary cadence sends were backpressured. If the host cannot reserve that checkpoint by the
200-tick boundary, it closes the connection and retains dirty owner state for request-zero on
reconnect rather than silently exceeding the bound. LAN clients never run authoritative RPG tick
locally; a bounded pure presentation projection may cover at most 1,200 ticks before requesting a
fresh private sync. Read-only client validation may display predicted fatigue/cooldown, but it may
never reject an otherwise well-formed request solely because that prediction looks stale; the host
owns the semantic decision.

One idempotent `terminatePeerRPG(authority,reason,oldDimension)` handles disconnect, death,
dimension change, RPG-rule disable, kick, host stop/shutdown, malformed frames, and send failure.
Successful authenticated socket supersession is the sole no-cleanup exception. Cleanup blocks new
authority work, cancels only that owner in all loaded worlds, clears terminal upkeeps, removes
ghosts/proxies, bumps owner revision once if needed, persists before dropping the socket, and sends
request-zero when the connection remains usable.

Unavailable guarded blocks become bounded tombstones containing authority/dimension/position,
expected temporary cell, original cell, and created tick. Tombstone capacity is reserved before a
guarded action. Chunk adoption resolves them before publication in stable order and restores only
when the current cell still equals the expected temporary value. Natural expiry, fatigue-driven
upkeep end, explicit unprepare, death/disconnect/dimension lifecycle, and RPG-rule disable all use
the same effect-end conversion routine. A reservation is released exactly once when an effect ends
while loaded, a tombstone successfully restores, or a loaded mismatch is deliberately discarded.
It remains held while a tombstone is unresolved/never loaded and becomes reusable immediately
after resolution. Tombstone creation and removal are part of the coherent authoritative checkpoint,
not independent best-effort peer writes. Cleanup and resolution are idempotent. Tests cover loaded
end, successful restore, mismatch-discard, repeated resolution, never-loaded persistence across
restart, every end trigger, cap exhaustion, and reservation reuse.

### Durable temporary-effect descriptors

Temporary effects are not reconstructed from upkeeps or live entities. Every active effect is a
strict `LANRPGTemporaryEffectV1` stored in the same coherent generation as its owner cost, world
mutation, and original block/entity information:

| Field | Domain |
| --- | --- |
| `schema`, `kind` | schema exactly 1; one of the ten closed `RPGTemporaryEffectKind` cases |
| `ownerAuthority`, `ownerSequence` | canonical `lan:<ordinal>` or literal `host:local`; sequence is strict `LANVersionedCounterV1` and scalar form rejects |
| `dimension`, `center` | closed dimension; bounded integer xyz |
| `createdTick`, `expiryTick` | each strict `LANVersionedCounterV1`; scalar form rejects; checked lexicographic distance is `1...1_200_000` across at most one value rebase |
| `radius`, `remainingCharges`, `magnitude` | finite radius `0...32`; charges `0...64`; finite magnitude `-2048...2048` |
| `guardedBlock` | optional exact `{position, originalCell, temporaryCell}`; bounded position; each cell `UInt16`; original and temporary differ |
| `temporaryEntity` | optional closed `{kind, spawnPosition, yaw, health, maxHealth, effectStableID}` sufficient to recreate the effect-owned entity; finite/bounded values; no process-local entity ID |

There are at most 32 active descriptors per world and 96 per process; the two-per-owner/kind cap applies.
Keys `(ownerAuthority,ownerSequence,kind)` are unique across active descriptors and tombstones.
Kind-specific validation requires exactly the guarded block and/or temporary entity shape used by
that kind; irrelevant optional data rejects. Saved chunks contain the guarded `originalCell`, never
only the temporary overlay. Effect-owned entities are excluded from ordinary entity persistence;
their complete bounded `temporaryEntity` descriptor is the sole recreation source.

A `host:local` effect is owned by `LANHostLocalOwnerCheckpointV1`, uses the explicit host-local
permission row, and commits its cost, owner sequence, RPG/RNG change, world delta and descriptor in
that same host-local coherent generation. It never borrows a guest row or implicit operator status.
The successful host baseline binds the live Player to literal `host:local` and validates both rows
before the first hosted simulation tick; missing/mismatched rows on hydration fail hosting. That
binding is cleared only after the coherent final stop checkpoint commits.
All ten effect kinds accept both owner forms through one closed validator. Tests create every kind
for the host and all eight guests in 90 isolated reset scenarios, then separately fill 32 mixed-owner
descriptors and reject the 33rd; restart before/after create/pulse/cleanup, cross a
counter value rebase, and prove exact host/guest ownership, checked expiry distance, centralized
cleanup and rejection of every scalar sequence/tick encoding.

Restart reads and strictly validates world metadata, owners, chunks, active descriptors, and
tombstones as one checkpoint before any chunk, proxy, effect, or player is published. For each
descriptor it reserves its capacity/key first, materializes a temporary world from the persisted
original cells, reapplies the guarded temporary cell, recreates and rebinds any temporary entity by
stable effect ID, and only then publishes the complete world. No pulse or expiry callback can run
during hydration. A still-active descriptor whose original cell/entity can be recreated becomes
active with its original `createdTick`/`expiryTick`; elapsed time is never reset.

An expired, semantically invalid, conflicting, cap-exceeding, or unrecreatable descriptor cannot be
silently dropped or partially installed. Recovery stages one atomic terminal transition: remove
the descriptor/entity, retain/restore the persisted original cell when available, or create the
already-reserved tombstone when the currently loaded cell is still the expected temporary value;
release the reservation exactly once, and synchronously commit that repaired coherent generation
before publication. If neither a safe restore nor a valid tombstone transition can be proven, load
fails closed and the prior database generation remains authoritative. Runtime termination uses the
same descriptor-to-restored-or-tombstoned transaction. No checkpoint may contain both active and
terminal records for one key, neither record after an unresolved temporary cell, a temporary cell
without its original, or an active temporary entity without its descriptor.

Failure injection cuts before and after every descriptor/chunk/owner/tombstone statement and at
every hydration phase. Tests cover every effect kind; active and expired restart; loaded and
unloaded guards; original/temporary/mismatched cells; entity recreation failure; duplicate keys;
all caps; crash during create, pulse, expiry, explicit cancel, lifecycle cleanup, tombstone
conversion/restoration, and repaired-generation commit; repeated restart; and proof that the
published state is always exactly the old coherent generation or the complete new one.

### World-scoped persistent entity and projectile identity

No delayed descriptor, save record, or checkpoint may use process-local `Entity.id` as durable
identity. `LANPersistentEntityKeyV1` is the strict three-key object
`{schema:1,wid,sequence:{generation,value}}`: `wid` is the exact 22-character world LAN ID and
`sequence` is the world's `entityIdentitySequence`, with live generation `0...999_999_999` and
allocated value `1...1_000_000_000`. Canonical encoding is at most 128 bytes. The complete tuple is
the key; dimension, chunk, entity kind, spawn coordinates, or a runtime ID never substitutes for or
changes it.

World metadata owns the prospective allocator. Before constructing a persistent entity or
projectile, preparation advances a scratch copy of `entityIdentitySequence`, reserves the entity
record, key-binding row, descriptor/event, and checkpoint bytes, then publishes the key only with
the prepared commit. Rebase follows the closed counter lifecycle. The SaveDB unique index is
`(worldStorageID,generation,value)` and its row is the strict
`{key,registeredKind,dimension,chunkX,chunkZ,worldMutationVersion,entityRecordDigest,lifecycle}`.
The public `wid` must equal the storage registry's current world LAN ID. A unique-index collision,
allocator regression, duplicate key in loaded or unloaded saves, or mismatched world/kind/digest is
corruption: fail the whole load/commit and stop LAN authority; never retry with the next value.

Every persistent entity/projectile save record embeds the exact key. Creation inserts the entity
record and binding in the same coherent transaction; dimension/chunk movement CAS-updates both;
unload writes both at one `worldMutationVersion`; load validates the binding and digest before
publishing the entity. Despawn atomically removes the active binding with the saved entity, but the
monotone versioned allocator means its key is forever burned and cannot be rebound. A descriptor
whose key is absent after committed despawn cancels without effect/XP; it may not bind a later entity
at the same coordinates or runtime ID. Pre-v6 persisted entities receive keys in deterministic
`(dimension,chunkZ,chunkX,saveRecordIndex,digest)` order in a committed migration before publication;
unloaded legacy chunks migrate on first load before any descriptor can target them.

Each key-binding row is at most 2,048 encoded bytes; one RPG checkpoint may change at most 512 rows
and 1,048,576 aggregate bytes. Counts include reserved/created/moved/despawned bindings. Capacity
failure defers a request without consumption; nonrequest overflow stops authority before mutation.
Tests cover allocation and rebase boundaries, injected collisions, duplicate imported rows, world
copy/move, dimension transfer, unload/reload/restart, despawn then runtime-ID reuse, projectile
impact/despawn races, stale descriptor cancellation, entity-record/binding crash cuts and digests,
and every per-row/count/aggregate boundary.

### Delayed ghost/proxy causality and progression

`LANHostedOwnerAggregateV1` remains the authority; a LAN ghost supplies stable targeting identity
and an in-world `LANRemotePlayerEntity` is scratch projection/damage surface. Delayed ownership
cannot be copied loosely between them. Self Interpose mitigation is moved between projections, not
duplicated. Ordered mitigation/provenance layers retain canonical attacker authority, owner
sequence, remaining credit, and causal XP attribution. Damage applied through a proxy reaches the
aggregate only in the normative proxy-projection/reducer phase before any private sync.

`LANDelayedCausalDescriptorV1` is a durable closed sum. Common fields are schema 1, CSPRNG
descriptor ID, owner/attacker authority, strict versioned owner sequence, closed dimension, strict
versioned created/next/expiry ticks, and a closed stable target key (`lan:<ordinal>`, `host:local`,
or bounded persistent entity key). Every sequence/tick field is `LANVersionedCounterV1`; scalar form
rejects, ordering is lexicographic, and every lifetime/pulse distance uses checked counter distance.
Its only shipped variants and exact variant payloads are:

| Variant | Complete causal payload |
| --- | --- |
| `wardenMitigation` | target key, remaining mitigation, hostile absorbed, ordered layer index |
| `wardenRescue` | target key, remaining rescue credit and triggering injury generation |
| `arcanistPeriodicFire` | target key, next pulse, remaining pulses and bounded harm payload |
| `arcanistStormPulse` | bounded center/radius, next pulse, remaining pulses and bounded harm payload |
| `rangerProjectile` | persistent projectile key, bounded kinematics, optional target key and harm payload |
| `menderSupportWindow` | injured target key, injury generation/nonce, expiry and remaining effective-health credit |

Every descriptor is at most 4,096 encoded bytes and its nested payload at most 2,048. Limits are 32
descriptors/131,072 bytes per owner, 256/1,048,576 per world, and 512/2,097,152 globally. A single
source action may reserve at most 32 target descriptors. Counts include reserved, active and
currently resolving records. Duplicate `(descriptorID,variant)` or reused owner-sequence bindings
reject; fields irrelevant to the selected variant are forbidden. Temporary-effect descriptors keep
their separate 2-per-owner/kind, 32/world, 96/global, 4,096-byte limits; cleanup tombstones keep
their count and byte limits. All are reserved with reducer/checkpoint capacity before commit.

These six variants cover every currently shipped delayed XP/causal path; none is reset merely
because its weak object reference or process restarts. Checkpoint hydration restores numeric causal
state first, then rebinds a live target/proxy by stable key before publication. Missing, dead,
quarantined or mismatched targets atomically cancel the descriptor without XP. A future delayed XP
source is blocked from shipping until this sum, bounds, persistence/hydration, cleanup and tests are
extended. Descriptor removal and resulting harm/support/XP commit in one coherent checkpoint, so a
crash replays the descriptor or the complete result, never both/neither.

Every projectile, periodic fire/storm pulse, trap, aura, area spell, reflected hit, or other delayed
operation capable of harming a Player embeds a closed `LANDelayedHarmDescriptorV1` binding in its
causal descriptor; it is part of that record/payload and does not consume a second descriptor slot:

| Field | Strict domain |
| --- | --- |
| `schema`, `descriptorID`, `sourceKind`, `sourceID` | schema 1; fresh 16-byte production CSPRNG ID; closed kind and registered 64-byte action/effect ID |
| `attackerAuthority`, `attackerOwnerSequence` | one canonical `lan:<ordinal>` or literal `host:local`, plus strict `LANVersionedCounterV1`; scalar rejects; never only entity ID/pointer |
| `targetAuthority` | canonical `lan:<ordinal>` or `host:local` required before Player harm; nil only while an untargeted projectile/area descriptor awaits collision or for a non-Player guarded by its separate stable entity key |
| `dimension`, `createdTick`, `resolveNotBeforeTick`, `expiryTick` | closed dimension; every tick strict `LANVersionedCounterV1`; scalar rejects; checked lexicographic order and lifetime distance `1...1_200_000` |
| `payload`, `remainingCredit` | one closed bounded damage/status/knockback payload; finite nonnegative credit `0...2048` |

Any descriptor surviving its creation tick is stored in the same coherent checkpoint as owner and
world state. Creation performs the ordinary PvP checks, but that never authorizes future harm. At
**actual resolution**, immediately before applying damage, status, knockback, secondary area harm,
or XP, an untargeted descriptor first specializes to one bounded target descriptor, then the host
resolves `attackerAuthority` and the required current Player target authority through canonical peer
rows and re-reads the target world's current `pvp` rule plus both current `canPVP` permissions. A
missing/quarantined/retired authority, changed target, stale sequence, false rule, either false
permission, dimension mismatch, or lookup failure atomically cancels that Player-harm descriptor
with no harm, status, knockback, resource credit, or XP. Area operations create/check one bounded
target descriptor per Player; indirect/secondary callbacks cannot inherit a prior allow result.
Non-Player harm follows its independent permission/guard rules. Resolution itself uses a prepared
commit so a rule/permission change between recheck and write also fails closed.

Every delayed XP path has one owner-dirty callback keyed by authority: Warden mitigation and rescue,
Arcanist delayed fire/storm effects, Ranger projectile effects, Mender support causality, and any
later delayed class source. The stable per-tick `(ordinal,authority)` coalesced drain captures both
ghost RPG state and proxy physical state, participates in the reducer's one canonical diff/revision
for that tick, marks persistence dirty, and schedules immediate request-zero sync for a progression or
discrete boundary. It must not issue one revision per callback. Lifecycle cleanup removes all
ghost/proxy causal layers and callbacks for that authority; successful socket supersession alone
preserves them. Tests cover self Interpose no-double-credit, ordered multiple layers, proxy damage
projection, delayed Arcanist/Ranger/Warden/Mender XP, one coalesced revision, disconnect cleanup,
and supersession preservation. Delayed-harm tests flip the rule and each permission after projectile/
effect creation and again between resolution prepare/commit; remove/change attacker and target;
exercise area/secondary harm and restart; and prove every failed revalidation causes zero harm/XP.

Guest melee uses shared combat prepare/commit primitives, the recorded dimension, loaded attacker
and target chunks, live target, normal 3-block reach, eye-to-AABB LOS, persisted attack cooldown,
default-false `pvp`, and both attacker/target default-false `canPVP`. It never uses the host's current world or hydration
full-charge reset. Complete durability, vanilla/RPG XP, status, velocity, equipment, and cooldown
converge through a private request-zero owner bundle.

## Client no-optimism

The client persists at most one pending canonical request: epoch, request ID, expected discrete RPG
authority revision, policy-required optional inventory revision, exact payload, operation, and send
state. It never snapshots broad physical owner revision as a request precondition. Retry resends the exact bytes. Every GameCore
authoritative RPG API does read-only local validation and submits without changing RPG, items,
selection, fatigue, cooldowns, world, or effects. A second request returns “Waiting for host”.

Local quick-slot assign/clear remains available while pending. Assignment, clearing, and
normalization mutate only the nine local slot tokens: they never call `selectAction`, never alter
`selectedPreparedSpellID`/`selectedPreparedActionID`, and never create an authoritative request.
Quick-slot use sends its explicit kind/ID without changing authoritative selection. Bundle apply
validates and materializes the whole owner, captures local slots, commits the complete client
checkpoint below, then atomically installs all owner fields under a reentrancy guard,
restores/normalizes slots, updates tick/revisions, and clears/transitions only the matching pending
request. A matching terminal outcome is inserted into the durable notification inbox in that same
commit; bundle handling never fires an ephemeral notice inline. Replays and request-zero insert no
notification.
The same-epoch pending reconciliation table in Replay and send bounds is normative: a newer
request-zero can make an older cached snapshot noninstallable without hiding its matching terminal
outcome. Read-only predicted fatigue/cooldown may inform copy but never locally reject submission
solely due to prediction drift. Malformed/incomplete/stale/regressed bundles cause no partial
mutation; incomplete timeout preserves pending for reconnect.

## Coherent crash-consistent checkpoints

### Bounded pre-reserved host checkpoint staging

One `LANAuthorityCheckpointStager` covers a hosted world and all dimensions. It owns exactly one
immutable SQLite **in-flight** checkpoint and one segmented **coalesced pending** full checkpoint;
there is no third queue, unbounded dirty-copy list, or per-peer checkpoint backlog. Each entry is at
most 167,772,160 accounted bytes and both arenas together at most 335,544,320. Accounting is the
actual encoded/bound `Data` length plus 512 bytes per SQL row/map node, not a Swift capacity estimate.

Each full checkpoint is also bounded to: one metadata row/1,048,576 bytes; eight guest authority
owners plus exactly one `LANHostLocalOwnerCheckpointV1`, 786,432 bytes each and 7,077,888 aggregate;
128 RPG-causal chunk-delta records, 524,288 each and 67,108,864 aggregate; 512 RPG-coupled block-
entity deltas, 65,536 each and 8,388,608 aggregate; 512 persistent entity-binding deltas, 2,048 each
and 1,048,576 aggregate; 64 primary persistent-entity record deltas in one
`LANPrimaryPersistentEntityCheckpointSegmentV1`, each at most 1,048,576 canonical bytes plus 4,096
bytes for key/envelope/digest/SQL-row/index accounting and 67,371,008 aggregate; and all delayed/
temporary/general-cleanup-tombstone records within both their own limits and a combined 3,014,656
bytes. One optional `LANRelationCheckpointSegmentV1` adds at most 512 edge/index deltas, references
at most 64 distinct entity records plus all 9 owner records and 128 total references, and contributes
at most 8,388,608 incremental relation-index/tombstone bytes. The relation segment carries only
stable keys/digests: each entity reference must resolve to the primary entity segment and each owner
reference to the owner segment, so no canonical record is copied or charged twice.

Every full checkpoint also contains one `LANWorldRNGCheckpointSegmentV1` with exactly all nine
strict stream rows in tag order, 64 bytes each/576 bytes aggregate, and one
`LANFishingSessionCheckpointSegmentV1` with at most one active-row-or-deletion-tombstone per owner,
9 rows at 4,096 bytes/36,864 bytes aggregate; one `LANScheduledEffectCheckpointSegmentV1` with at
most 128 lightning rows/262,144 bytes plus 512 fang rows/1,048,576 bytes; and one
`LANWorldTaskCheckpointSegmentV1` with at most 512 scheduled-block deltas/131,072 bytes plus 64 raid
deltas/262,144 bytes. There is no RNG, fishing, scheduled-effect, world-task, relation or primary-
entity checkpoint writer outside this stager and
`commitLANAuthorityCheckpoint`.

The component payload maxima are therefore exactly 165,188,160 bytes:
`1,048,576 + 7,077,888 + 67,108,864 + 8,388,608 + 1,048,576 + 67,371,008 +
3,014,656 + 8,388,608 + 576 + 36,864 + 262,144 + 1,048,576 + 131,072 +
262,144`. This leaves 2,584,000 bytes before row/map overhead. The
maximum separately charged overhead is exactly 4,092 nodes times 512 = 2,095,104 bytes: 1 metadata,
9 owners, 128 chunk deltas, 512 block-entity deltas, 512 bindings, 32 temporary descriptors, 256
delayed descriptors, 768 general cleanup tombstones, 512 relation deltas, 128 relation-cleanup
tombstones, 9 RNG rows, 9 fishing rows, 128 lightning rows, 512 fang rows, 512 scheduled-block deltas
and 64 raid deltas. Primary entity-record row/index overhead is already inside
its 4,096-byte-per-record component and is not charged again. At all maxima the 167,772,160-byte
arena retains exactly 488,896 bytes of residual reserve. Actual accounted bytes still decide
admission; failure of any component/count/aggregate, cross-reference, overhead or total rejects the
candidate, and limits never truncate.

`LANHostLocalOwnerCheckpointV1` uses the same exhaustive owner mapper and strict field domains as a
guest with authority fixed to `host:local`. It contains the host's physical state, inventory/
equipment/vanilla XP, RPG state, owner RNG, closed stats, broad owner revision, inventory revision,
RPG revisions/sequences, and logical tick; host-local quick slots remain a local preference outside
causal authority. `commitLANAuthorityCheckpoint` writes it to
`lan_host_local_authority_checkpoint_v6` in the same generation as every guest cost, harm,
progression, entity/world delta, descriptor, and tombstone. While hosting, this row is authoritative
and the legacy `player` JSON is only a post-checkpoint projection; independent player writes are
disabled. Host start atomically seeds the first row from a fully validated local Player, restart
hydrates it before delayed descriptors, and clean stop projects the final committed row back to the
ordinary player save. There is never a guest-only checkpoint when `host:local` can pay, receive
harm, kill, die, gain XP, or advance RPG state.

Pending is a full recovery superset relative to the last durable generation, including all keys in
in-flight plus newer changes. Pure owner changes replace that guest/host-local pending canonical row
with the latest version. Closed RPG-causal world deltas enter this stager: cell, block-entity,
primary persistent-entity record, entity-binding, descriptor and tombstone mutations caused by the
prepared RPG/melee/reducer/simulation tick. The complete nine-row world-RNG result set and complete
at-most-nine fishing-session active/tombstone result map enter the same pending checkpoint even when
only one keyed row changed. The complete bounded lightning/fang result maps and every changed
scheduled-block/raid row or tombstone enter their dedicated segments.
Every relationship mutation also enters as the sole `LANRelationCheckpointSegmentV1`; there is no
relation queue, transaction or stager outside this actor. Ordinary simulation and template place/
undo chunk captures never enter unless they change a relationship.

Coalescing is one deterministic keyed compare-and-swap union. Owner and primary entity records keep
the latest canonical result bytes while retaining the earliest expected digest, keyed respectively
by owner authority and `LANPersistentEntityKeyV1`; an entity key/generation can never alias another
record. Binding and relation-index deltas compose earliest expected to latest result by stable key;
reciprocal edges must coalesce together; cleanup tombstones retain their earliest target digest and
latest monotonic cursor/remaining state. The relation segment's owner/entity/descriptor/binding references must
resolve byte-for-byte to payloads in the corresponding primary checkpoint segments.

World RNG rows key only by `LANWorldRNGStreamIDV1`: all nine expected/result word-plus-full-draw-count
pairs are present, and consecutive changes compose only when the prior result equals the next
expected pair byte-for-byte. Fishing rows key by `(ownerAuthority,descriptorID)` and carry expected
row digest-or-nil, result row-or-deletion-tombstone and the matching expected/result owner
`fishingSessionID`; a descriptor cannot change owner and an owner cannot acquire a second active
session. A fishing create/update/delete composes only when both prior descriptor result and owner-
binding result equal the next expected values. Create-then-delete may cancel only before either state
entered in-flight; otherwise the deletion tombstone remains through the next durable generation.
Scheduled-effect and world-task rows compose by the same earliest-expected/latest-result digest rule;
due-tick, sequence, lifecycle and table-root transitions cannot be skipped. The same rule applies to
entity/relation transitions. Any CAS gap, conflicting precondition,
nonmonotonic cleanup cursor, missing one of nine RNG rows, fishing owner/session mismatch or cap
failure rejects the prospective union. RPG deltas likewise form a deterministic union by stable
dimension/chunk/cell/entity key and compose in capture-sequence order. A two-pass canonical
encoder first computes exact sizes, then encodes changed records into scratch charged inside the one
pending arena; no temporary full checkpoint escapes the two-arena cap. Commit swaps those segments
and releases replaced bytes.

Before any prepared RPG/melee/reducer commit, the pure preparation result is merged into a
prospective pending view, the global metadata plus every affected guest/host-local owner, RPG-causal
cell/block-entity/primary-entity/entity binding, descriptor/tombstone, all nine world RNG rows and
the complete fishing-session and scheduled-effect maps plus changed world-task rows are canonically
encoded, cross-checked and reserved alongside
replay/send capacity. Only then may
`RPGPreparedCommit` write live state and atomically publish the pre-encoded staged segments. If
staging cannot reserve, an incoming request is deferred without consumption or semantic result;
different retry bytes still collide. Reducer-only physical/timed work is likewise computed on
scratch first; inability to stage it enters checkpoint failure before canonical publication rather
than creating untracked authority.

Relationship, fishing-session, scheduled-effect and world-task operations are stricter DB-first
publications. Mount/dismount/unload/transfer/disconnect/cleanup/cast/tick/hook/reel/cancel/schedule/
resolve/reschedule remains scratch under
`publicationPending` until this same stager promotes its
full checkpoint and `commitLANAuthorityCheckpoint` commits. Only the immutable DB receipt may install
owner/entity pointers, bindings, index edges, tombstone lifecycle, RNG words/counts, fishing rows,
owner session IDs or bobber projections on MainActor and release the lease; ack/UI publication
follows that install. Rollback leaves the complete old memory graph/RNG/session state and pending
candidate for retry. Unrelated RPG commits may retain their existing replayable live-session
semantics, but they cannot overtake a pending relation/fishing/RNG lease on an affected subject or
stream.

While SQLite is stalled, new work may only replace/union into the single pending full checkpoint.
If a new world-dirty key or encoded growth would exceed any bound, authority stops before that
mutation, cancels prepared/deferred work, and closes all LAN peers; dirty canonical/staged state is
retained for recovery. On SQLite BEGIN/statement/COMMIT failure, the stager becomes `failed`, admits
no hello/promotion/request/tick mutation, closes peers, and never releases dirty bytes. A failed
in-flight entry is reclassified as pending if no newer superset exists; otherwise the already-full
pending superset remains. Recovery retries that full checkpoint from the last durable generation;
LAN hosting can restart only after successful commit and a request-zero from the recovered state.

Tests block the DB before/after dequeue and every SQL statement; run 1/19/20/200 physical ticks;
replace all eight guest owners plus the host-local owner at maximum size; union repeated/new causal
chunk, block-entity, 1,048,576-byte primary entity, entity-binding, descriptor, delete and relation
owner/entity/binding/index/tombstone deltas; independently change/rebase/terminal each of nine RNG
rows; and exercise cast/bite/hooked/reelPending/cancel transitions for all nine fishing slots. They
also fill/change/delete all 128 lightning, 512 fang, 512 scheduled-block-delta and 64 raid-delta
slots, including whole-cast and due-task ordering. They
verify the exact 165,188,160 component sum, 4,092-node/2,095,104 overhead charge, 488,896 residual
reserve and 335,544,320 two-arena cap; permute primary-entity/relation/RNG/fishing/scheduled-task
coalescing, CAS
conflicts and DB-first receipts;
hit every per-component/aggregate byte and count boundary; race encode/commit/completion; inject
disk-full/corruption; and prove at most two arenas, no request consumption on capacity defer, no
post-failure authority, exact dirty retention, deterministic recovery, and no stale host/guest/world
mix. Maximum relation tests use 64 distinct 1,048,576-byte canonical entity records plus nine owners,
128 total references and 512 edge/index deltas, then test each cap+1 independently; no relation may
hide a full record inside the 524,288-byte RPG chunk-delta cap. Crash cuts before/after every RNG/
fishing/entity SQL statement and COMMIT prove exactly the complete old checkpoint or complete new
checkpoint, including owner session ID, hook/index, reserved reel keys and RNG parent/result, never a
mixed generation. Host-local lethal harm/kill/XP tests cover every cut with eight guests concurrently
active.

### Canonical chunk state and pre-first-delta base barrier

`LANCanonicalChunkStateV1` is exactly
`{envelope: LANCanonicalChunkEnvelopeV1, content: LANCanonicalChunkContentV1}`. Content bytes/digest
are independent of the versioned envelope; neither is allowed to alias the other. Their strict field
manifests are exhaustive:

| Group | Exact canonical fields/disposition |
| --- | --- |
| Envelope identity | schema 1, `wid`, `worldStorageID`, `mutationLineageID`, closed dimension, exact `cx/cz/minY/height`; coordinates and dimension height must agree |
| Envelope versions | full-pair `captureSequence`, `worldMutationVersion`, `rpgCheckpointWatermark`, `includedCheckpointGeneration`, plus `contentDigest`; all share the opened world lineage |
| Content contract | `generationSettingsDigest`, `chunkDomainDigest` |
| Cells | exactly `16 * 16 * height` registered `UInt16` block/meta cells in `(y,z,x)` index order |
| Biomes | exactly `4 * 4 * ceil(height/4)` registered biome IDs in quart `(y,z,x)` order |
| Block entities | complete strict `BlockEntityData` records sorted by unique cell index; position, block compatibility, inventories and every kind-specific field validate without repair |
| Persistent entities/projectiles | complete strict save records sorted by `LANPersistentEntityKeyV1` then registered kind; keys, bindings and record digests agree |
| Derived runtime state | `skyLight`, `blockLight`, `heightmap`, `portalBlocks`, `sculkSensors` are deterministically rebuilt from canonical cells/metadata; never encoded or digested independently |
| Runtime bookkeeping | `dirty`, renderer `version`, `status`, `modified` are reset/recomputed publication state and never authority |
| Temporary overlays | a live guarded cell must equal the descriptor's temporary value, then capture reverses it to the guarded original; mismatch rejects; effect-owned entities are excluded; overlays are reapplied only after base/journal validation |

Blocks/biomes/block-entity items/entity kinds must already exist in their closed registries. Unknown
IDs, malformed metadata, nonfinite values, duplicate keys or incompatible records reject; v6 never
uses the legacy VCK clamp/repair path. `LANCanonicalChunkFieldID: CaseIterable` assigns every stored
`Chunk`/`ChunkRecord` field exactly one row above, and a source audit fails additions/omissions.
Canonical content bytes are the four exact VCK2 section byte streams in the order above; their
lengths/counts live in the header and in the measure below. The two content-contract digests are
separate digest inputs. `generationSettingsDigest` and `chunkDomainDigest` use the one byte-exact
`LANGenerationContractCanonicalBytesV1` serialization and formulas below. No field-list prose,
registry hash or alternate concatenation is a second serialization.

`LANCanonicalChunkMeasureV1` is the only capacity/digest measure. It is exactly
`{blockCount,biomeCount,blockEntityCount,entityCount,blockBytes,biomeBytes,blockEntityBytes,
entityBytes,totalContentBytes,rowBytes,blockRoot,biomeRoot,blockEntityRoot,entityRoot,contentRoot,
contentDigest}` and is produced by the same canonical field/record emitters as VCK2. Each section is
partitioned into consecutive 4,096-byte leaves. A leaf is
`SHA256("Pebble-LAN-v6-merkle-leaf\0" || sectionTag || UInt64BE(index) || UInt32BE(actualBytes) ||
leafBytes)`; an empty section is `SHA256("Pebble-LAN-v6-merkle-empty\0" || sectionTag)`. At level
zero and above, adjacent hashes form
`SHA256("Pebble-LAN-v6-merkle-node\0" || sectionTag || UInt32BE(level) || left || right)`; an odd
last hash is promoted as `SHA256("Pebble-LAN-v6-merkle-promote\0" || sectionTag || UInt32BE(level)
|| hash)`, never duplicated. The content root is
`SHA256("Pebble-LAN-v6-merkle-content\0" || each ordered sectionTag/count/byteCount/root)`.
Merkle `sectionTag` is one byte (`0x01` blocks, `0x02` biomes, `0x03` block entities, `0x04`
entities); leaf indexes are `UInt64BE`, actual lengths/levels/counts are `UInt32BE`, section byte
counts are `UInt64BE`, and roots are exactly 32 raw bytes. The content-root tuple order is those four
tags, each followed by count, byte count and root. Domain strings are the shown ASCII bytes including
their terminating NUL; no platform string encoding or native-endian integer is accepted.
`contentDigest = SHA256("Pebble-LAN-v6-chunk-content\0" || generationSettingsDigest ||
chunkDomainDigest || UInt64BE(totalContentBytes) || contentRoot)`. The canonical envelope separately
hashes `SHA256("Pebble-LAN-v6-chunk-envelope\0" || all length-prefixed envelope fields including
contentDigest)`. Lineage, coordinates, capture/mutation versions and watermarks never enter the
content digest. No generic VCK/JSON digest substitutes. Measurement and final encoding compare the
complete measure plus roots, so preparation never needs a second 64-MiB in-memory copy or an
unbounded rehash.

Every base-row conditional update uses the closed `LANCanonicalChunkCASV1` and no shorter
"canonical digest" shorthand: `{mutationLineageID,captureSequence,worldMutationVersion,
rpgCheckpointWatermark,includedCheckpointGeneration,contentDigest,envelopeDigest}`. Its
`envelopeDigest` is the canonical-envelope hash above, not the VCK2 header-integrity digest. A
proposed CAS repeats all seven fields after their normative transition; identity/coordinates remain
part of the row key and envelope validation. Idempotence requires byte equality of the complete
proposed CAS and canonical content bytes.

`LANRPGWorldDeltaV1` is a closed sum whose variant declares its only affected canonical fields:
`upgradeGenerationContract(expectedContractDigest,resultContractDigest,changedSections)` -> content
contract;
`setCell(index,expected,new)` -> cells; `setBiome(index,expected,new)` -> biomes;
`putBlockEntity(index,expectedDigest,newRecord)` / `removeBlockEntity(index,expectedDigest)` -> block
entities; `putEntity(key,expectedDigest,primaryRecordRef)` / `removeEntity(key,expectedDigest)` -> persistent
entities; and `createTemporaryOverlay` / `removeTemporaryOverlay` -> descriptor/live overlay only,
with canonical guarded-original cells unchanged. Irrelevant keys reject. Every canonical-changing
variant carries exact before/after envelopes and content digests; applying it must change only its
declared `LANCanonicalChunkFieldID` set.

There is one `LANRPGWorldDeltaV1` shape in scratch, checkpoint, journal, replay and compaction—no
larger logical `putEntity(newRecord)` variant. `primaryRecordRef` is exactly
`LANPrimaryEntityJournalReferenceV1`; its key must equal the operation key and its checkpoint
generation/record/row digests must resolve to the separately encoded primary segment in the same
prepared checkpoint. Preparation returns `{delta,primaryRows}` as distinct typed outputs. Every
delta encoder rejects inline entity bytes or a reference without its charged/reserved primary row;
the 524,288-byte delta cap and 1,048,576-byte primary-record cap are therefore unambiguous at every
layer.

Metadata transitions are normative. A full-base barrier commits envelope `E0 =
{capture:S, worldMutation:M, watermark:W, included:W, contentDigest:D0}`. The next canonical-changing
delta reserves checked successors and commits journal transition `E0 -> E1 = {capture:S+1,
worldMutation:M+1, watermark:W, included:W, contentDigest:D1}`; world metadata publishes `S+1` with
the mutation. Each later delta chains from the exact preceding envelope. Descriptor-only temporary
overlay variants do not change chunk content/envelope and live solely in descriptor checkpoint rows.
Compaction through checkpoint `G` writes the same final content `D1` with envelope
`{capture:S+1, worldMutation:M+1, watermark:G, included:G, contentDigest:D1}` and deletes only rows
covered through `G`. Every pair uses checked versioned successor/rebase. Tests sentinel every
envelope field, value and generation rebase, before/after CAS, descriptor-only no-op, multi-delta
chain and compaction transition.

Every `RPGPreparedCommit` obtains the complete prospective post-delta
`LANCanonicalChunkMeasureV1` before
any owner, RNG, checkpoint or world mutation: exact content/VCK2 bytes, block/biome counts, unique
block entities, persistent entities/projectiles, every length-prefixed record and all index/row
overhead. It must fit the exact dimension counts, 32,768 block entities, 4,096 persistent entity/
projectile records, each per-record cap, and the 67,108,864-byte VCK2 row cap; multi-chunk work
reserves every post-state independently plus aggregate staging. Failure or max+1 defers/rejects with
zero owner cost/request consumption and no checkpoint reservation publication. Boundary tests build
real max/max+1 post-states for every delta variant and fanout, verifying every count/byte value,
4-KiB leaf boundary, section/content root and digest equals the eventual byte encoder exactly.

### Bound generation and append-compatible registry contract

Every canonical base carries strict `LANGenerationContractV1 {schema:1,generatorVersion,
generationSettingsDigest,registryBaselineID,registryManifestVersion,prefixes}`. `generatorVersion`
and manifest version are exact `UInt32`; the baseline ID and digest name immutable rows, never a
mutable "current" alias. `prefixes` has exactly these 14 ordered sections: block, item, biome,
entity kind, block-entity kind, enchantment, potion, status effect, trim pattern, trim material,
villager profession, damage source, generator/entity/block-entity specification and loot-table
definition. Each section is `{kind,prefixCount:UInt32,prefixSHA256}` and each entry hash covers stable
numeric tag, canonical ID and closed DTO schema/bounds; item entries additionally cover max stack/
durability and block entries cover their metadata schema. Closures, localized/display text and
runtime callbacks are excluded. The generator/specification section covers every shipped immutable
generator version plus the exact VCK2 entity and block-entity manifest digests. Each loot-table
entry covers its ordered pools, roll/bonus-roll ranges, ordered entry tags, weights, min/max counts,
enchant/potion references and exact RNG-draw algorithm. The `chunkDomainDigest` binds this complete
ordered 14-section contract.

`LANGenerationContractCanonicalBytesV1` is the sole serialization. It is, in order:
`stateSchema:UInt16BE=1`; `generatorVersion:UInt32BE`;
`generationSettingsLength:UInt32BE` plus exact schema-manifest generation-settings bytes;
`generationSettingsDigest:32 raw bytes`; `registryBaselineID:32 raw bytes`;
`registryManifestVersion:UInt32BE`; `dimension:UInt8` plus three zero bytes;
`minY:Int32BE`; `height:UInt32BE`; `sectionCount:UInt16BE=14` plus two zero bytes; then exactly 14
section records in fixed tag order. A section record is `sectionTag:UInt8`, three zero bytes,
`prefixCount:UInt32BE`, `prefixSHA256:32 raw bytes`, `definitionLength:UInt32BE`, and the exact
append-order definition bytes specified by that section's checked-in schema manifest. Lengths count
bytes following their own field only; no optional field, native padding, JSON, locale or dictionary
order exists. The formulas are exclusively
`generationSettingsDigest = SHA256("Pebble-LAN-v6-generation\0" ||
UInt32BE(generationSettingsLength) || generationSettingsBytes)` and
`chunkDomainDigest = SHA256("Pebble-LAN-v6-chunk-domain\0" ||
UInt64BE(canonicalPayload.count) || canonicalPayload)`.

`Tests/PebbleCoreTests/Fixtures/LANGenerationContractDigestVectors.json` contains independent fixed
canonical-payload hex and intermediate/final hashes for the minimum contract, every dimension, a
definition at its byte cap and a compatible append. Both the contract-table writer and VCK2 encoder
must match those vectors; changing a byte requires a deliberate schema/baseline version change.

The contract is recoverable data, not a bare hash. `lan_generation_contract_v1` stores immutable
content-addressed rows keyed by `chunkDomainDigest`; each canonical row is at most 1,048,576 bytes
and contains the complete `LANGenerationContractV1`, canonical generation settings, dimension
geometry, all 14 section prefix manifests and every referenced generator/schema/loot-definition
payload. At most 256 rows/268,435,456 bytes exist per world. The key is exactly the sole
`chunkDomainDigest` formula above.
Every VCK2 header's `chunkDomainDigest` is a foreign key to one byte-equal row; insert-on-conflict
compares all bytes and a same-digest/different-payload collision terminally quarantines the world.
Checkpoint/base/journal rows retain all referenced contracts; pruning occurs only after no base,
journal, baseline manifest or prepared commit references one. Copy/import carries and revalidates
the immutable rows. Missing rows, cap overflow or a hash/payload mismatch block decode before chunk
or entity allocation; mixed-version chunks are valid only when each resolves its own exact row.

Registry evolution is append-only compatible only when every stored section exists, every stored
prefix count is no greater than the current count and the current prefix digest is byte-equal.
Reorder, removal, tag/schema/bounds mutation or digest mismatch fails hosting. Checked-in baseline
rows are content-addressed and immutable; updating an old row is forbidden.

Contract evolution is an explicit canonical mutation owned by one generic primitive, not an RPG-
only helper. `LANWorldMutationSourceV1` is exactly `rpgAction`, `ordinarySimulation`,
`objectTemplate`, `naturalSpawn`, or `baseCapture`. Every one of those paths must call
`LANWorldMutationCoordinatorV1.prepareContractBoundMutation`; direct block/biome/BE/entity writes or
numeric-registry lookups outside it fail source audit.

The primitive accepts exact `{source,chunkKey,expectedCAS,expectedContractDigest,
resultContractDigest,canonicalMutation}`. It validates both immutable contract rows, proves every
pre-existing ID under the expected contract and every prospective new ID under the result contract,
computes the complete prospective measure, and pre-reserves contract row, transition, journal/full-
save, checkpoint and publication capacity. `expectedCAS/expectedContractDigest` may be absent only
for a genuinely absent base capture; that path stamps the result contract before any entity/cell
publication.

When digests differ, the first logical mutation is `LANGenerationContractUpgradeDeltaV1`, exactly
`{expectedContractDigest,resultContractDigest,expectedGenerationSettingsDigest,
resultGenerationSettingsDigest,expectedRegistryBaselineID,resultRegistryBaselineID,changedSections,
fieldMask}`. Both rows exist, `changedSections` is sorted/unique and `fieldMask` is exactly
`contentContract`. It has exact before/after envelopes, measure roots, content digests and CAS values;
section bytes/roots remain equal while contract/content/envelope digests change. It consumes its own
checked capture/mutation successor. The new-ID mutation consumes the next successor, expects the
result contract and is encoded under it.

One SaveDB transaction inserts/verifies the result contract, CASes the expected transition, writes
the transition plus source-appropriate RPG journal or ordinary/template/natural/base save, and
commits the final CAS/content. Only its immutable receipt may publish new IDs on MainActor. Thus
upgrade and new-ID mutation are all-or-nothing and durable before visibility for every source;
neither logical half can publish alone. Tests exercise all five sources with absent/same/upgraded
contracts and crash before/after contract insert, each successor/CAS, journal/full-save statement,
COMMIT and publication receipt. Implicit prefix replacement, current-registry lookup, stale CAS or
code paths that bypass the primitive reject with zero live mutation.

Entity-only/absent regeneration dispatches by the exact stored `generatorVersion` and settings
digest. Supported historical generators remain read-only deterministic implementations; migration
runs that exact generator, merges the strict saved entity tail and writes a full current VCK2 base
before publication. If the required generator is unavailable or its output/domain digest differs,
hosting remains blocked. A strict full legacy base can migrate without regeneration only when its
registry prefix contract validates. Deferred/unmaterialized loot stores exact
`{chunkDomainDigest,lootTableTag,RNGCheckpoint}` and resolves only the pinned immutable definition;
it never looks up a mutable current table by name. Tests load pre-upgrade entity-only and full bases
across generator changes, compatible appends in each of all 14 sections and hostile reorder/removal/
schema/bounds/loot-definition changes; they verify historical byte identity, immutable baseline/
contract lookup, missing/collision/cap/FK behavior, mixed-version chunks, explicit two-delta contract
upgrades, deferred-loot identity and deterministic refusal.

### Byte-exact VCK2 and closed record manifests

VCK2 is one 296-byte fixed header followed by four contiguous sections; all integers are little-
endian, all reserved bits/bytes are zero, and trailing bytes reject:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII `VCK2` |
| 4 | 2 | state schema `1` (`VCK2` is the container-format magic, not the state-schema value) |
| 6 | 2 | flags exactly zero |
| 8 | 1 + 7 | dimension `UInt8`, then zero padding |
| 16 | 16 | `cx:Int32`, `cz:Int32`, `minY:Int32`, `height:UInt32` |
| 32 | 16 | raw `worldLANID` |
| 48 | 16 | raw `worldStorageID` |
| 64 | 16 | raw `mutationLineageID` |
| 80 | 32 | generation-settings SHA-256 digest |
| 112 | 32 | chunk-domain SHA-256 digest |
| 144 | 32 | four `LANVersionedCounterV1` pairs in capture/mutation/watermark/included order, each `UInt32 generation, UInt32 value` |
| 176 | 16 | blocks, biomes, block-entity and entity counts as `UInt32` |
| 192 | 40 | the four section byte lengths plus total content length as `UInt64` |
| 232 | 32 | content digest |
| 264 | 32 | `SHA256("Pebble-LAN-v6-vck2-header\0" || UInt32BE(264) || bytes[0..<264])` |

Sections are: (1) exactly `blocksCount` registered `UInt16` cells; (2) exactly `biomeCount`
registered `UInt16` IDs; (3) cell-index-sorted block-entity records; (4) persistent-key-sorted entity/
projectile records. Each record is `UInt32 recordLength, UInt16 kindTag, UInt16 recordSchema, UInt16
fieldCount, UInt16 reserved=0`, followed by strictly ascending fields
`{UInt16 fieldTag, UInt8 wireType, UInt8 reserved=0, UInt32 payloadLength, payload}`. Closed wire
types are exact Boolean byte `0|1`, fixed-width signed/unsigned integer, IEEE-754 binary64 raw bits,
UTF-8, bytes, optional and count-prefixed array/record. Integers use two's-complement little-endian;
floats must be finite and canonical positive zero (negative zero/NaN/Infinity reject); UTF-8 must be
shortest-form valid with no normalization or replacement. Unknown/duplicate/out-of-order tags,
length/count overflow and nonzero reserved values reject.

`recordLength` is exactly the number of bytes after its own four-byte prefix: the eight-byte
`kindTag/recordSchema/fieldCount/reserved` header plus `sum(8 + payloadLength)` for all fields. Thus
one record occupies exactly `4 + recordLength` bytes and must have `recordLength >= 8`; the
1,048,576 encoded-record cap counts the four-byte prefix. Optional values are encoded only by field
absence when the concrete kind mask marks that tag optional; a present optional wrapper, null tag or
zero-length stand-in rejects. The exact row formula is
`296 + blocksCount*2 + biomesCount*2 + sumBE(4+recordLength) +
sumEntity(4+recordLength)`. It must equal `296 + totalContentLength`, every declared section length,
the actual SQLite blob length and the at-most-67,108,864-byte row cap without overflow.

The canonical per-record digest is exactly
`SHA256("Pebble-LAN-v6-vck2-record\0" || sectionTag:UInt8 ||
UInt32BE(4+recordLength) || exactRecordBytes)`, where `exactRecordBytes` starts with the little-
endian `recordLength` prefix and includes every little-endian header/tag/length plus payload byte in
wire order. The relationship digest is
`SHA256("Pebble-LAN-v6-vck2-relation\0" || UInt32BE(canonicalReferenceBytes.count) ||
canonicalReferenceBytes)`; the binding and namespace rolling digests use distinct literal domains
and length-prefix each exact key/digest tuple in stable key order. No digest hashes a Swift value,
JSON object or host-endian struct.

`LANVCK2SchemaManifestV1` is a checked-in, generated, append-only table containing the header
state-schema value, every numeric width/signedness/endian, every section/count formula, kind and
field tag, record schema, wire type, required/optional mask, nested bound and record/row cap. Its
digest is in the generator/specification registry section. Decode dispatches only when header schema,
record schema and stored manifest digest all match; no `V1` DTO is accepted under a schema-2 header,
and no unknown schema falls through to a current decoder.
`Tests/PebbleCoreTests/Fixtures/LANVCK2DigestVectors.json` is a checked-in independent oracle with
hex header/record/reference bytes and every intermediate leaf/node/section/content/record/header
digest for empty sections, one BE, one entity, and 4,095/4,096/4,097-byte leaf boundaries. Tests
recompute it through both the streaming encoder and a separately implemented reference hasher; a
fixture update requires an intentional state-schema/registry-baseline change.

Every record is at most 1,048,576 encoded bytes, 2,097,152 decoded-accounted bytes, 1,048,576
canonical bytes, 128 fields and nesting depth 16; every string is at most 65,536 bytes unless a
smaller domain elsewhere applies, and every collection is at most 4,096 entries unless its closed
field manifest is smaller. `LANBlockEntityStoredFieldDispositionV1: CaseIterable` has exactly 54
canonical rows: all 52 stored `BlockEntityData` properties plus record bindings `cellIndex` and
`expectedBlockCell`. Each row fixes tag, wire type, bounds and its exact subtype masks; source audit
fails unless all 52 properties and both bindings occur exactly once. `type` is derived from the kind
tag, and `x/y/z` must equal the bound cell index; neither can disagree with the record. This is not a
property bag.

`LANBlockEntityKindManifestV1` assigns these exact closed variants: container has block-derived
9-or-27-slot `items`, optional paired `lootTable/lootSeed`, optional `rpgGeneratedContainerKey`,
optional `name`; hopper has five-slot `items`, `cooldown`, optional `name`; furnace has
`kind` in furnace/blast/smoker, three-slot `items`, `burnTime,burnTotal,cookTime,cookTotal,xpBank`
and optional `name`; brewing has five-slot `items,brewTime,fuel` and optional `name`; crafting has
nine-slot `items` and optional `name`; sign has four `lines,glowing,color`; spawner has `mob,delay`;
jukebox has optional `disc` and `startedTick`; beacon has optional `primary,secondary` and `levels`;
beehive has `bees,honey`; shelf has six-slot `items,lastSlot`; pot has four `sherds`; campfire has
four-slot `items` and four `times`; brushable has paired `lootTable/lootSeed`, optional `item` and
`dusted`; comparator has `output`; note has `note`; piston has
`movedCell,facing,extending,progress,isSourceHead`; conduit has `active` and optional stable
`eyeTarget` entity reference; end gateway has `exitX,exitY,exitZ,exactTeleport`; shrieker has
`canSummon,shrieking`; lectern/potted has `plant`. Every nested item is exact
`LANItemStackV1`. A nonlisted field, wrong slot count, unpaired option, process-local eye ID or field
from another variant rejects.

The source `BlockEntityData.viewers` is exclusively runtime open-container occupancy: its disposition
is `runtimeRebuilt`, it is omitted from every VCK2 variant, and hydration initializes it to zero/nil
before redstone queries. Shrieker gameplay uses `shrieking`; if a distinct persistent listener count
is ever required, it must add a new named source property/tag/schema row rather than reuse `viewers`.
Restart tests open/close containers around save cuts and prove no persisted phantom viewer produces
comparator power or other ghost redstone.

`LANEntityKindManifestV1` likewise assigns all 100 entries returned by `entityTypes()` an append-
only tag, a closed persistence class, concrete type, schema and exact required field mask. The
persistence class is exactly `chunkPersistent`, `separateAuthority` or `forbiddenTransient`.
`player` is `separateAuthority` and may exist only in the canonical owner checkpoint. LAN remote
players/ghost actors, `lanReplicatedMirror` instances, runtime lightning presentation bolts,
`fishing_bobber`, evoker-fang visuals and every descriptor-owned temporary entity/projectile are
`forbiddenTransient`; they can never be emitted, accepted or allocated from a VCK2 chunk. Every
authoritative lightning strike and fang bite instead lives in the strict scheduled-effect segment
below. `effect_cloud` is not silently treated as temporary: an
ordinary persistent cloud uses the strict fields below, while a descriptor-owned cloud remains
forbidden. Every other registered kind has one explicit manifest row; there is no default entity
row, reflection fallback, arbitrary dictionary or legacy `[String:Any]` decoder in VCK2.

`LANEntityStoredFieldDispositionV1: CaseIterable` is the source-of-truth census, with one row
`{declaringType,sourceProperty,applicableKindTags,disposition,fieldTag,wireType,required,domain}` for
every stored property declared anywhere in the transitive superclass chain from each registered
factory's concrete type through every intermediate abstract/open superclass to `Entity`, plus every
reachable nested persistent state type and stored property introduced by an extension. The union is
computed independently for all 100 factories; an inherited property is audited for each applicable
kind even when its declaring type has no `save()`/`load(_:)` override. `disposition` is exactly one of
`encoded`, `typeDerived`, `runtimeRebuilt`, `separateAuthority`, or `forbiddenTransient`; a source
property appears exactly once per applicable concrete kind. Computed projections alias their
single backing-field row and may not create a second authority. Build tooling parses the declarations
and the complete override/super-call graph of all entity persistence methods. It fails when a
registered factory cannot resolve a unique concrete type, a superclass/extension/nested declaration
is skipped, an override neither calls nor explicitly supersedes its parent's disposition, or a stored property,
registered kind or persistence read/write lacks exactly one matching disposition. The checked-in
v6 census baseline is exactly 100 registered kinds, 15 `save()` implementations and 16 `load(_:)`
implementations; changing any count or source-property set without changing the manifests fails the
build and registry-prefix digest. The census deliberately covers much more than the existing save
overrides, which are incomplete and are migration input only.

The common encoded record is exactly `persistentKey,x,y,z,vx,vy,vz,yaw,pitch,age,fireTicks,
airSupply,invulnTicks,fallDistance,freezeTicks,noGravity,gravityScale,onGround,
horizontalCollision,portalCooldown,portalTime,persistent,vehicleRef,passengerRefs,data`. The closed
`EntityData` subrecord is exactly `variant,color,size,pattern,puffed,swelling,grazing,stingTimer,
buckTimer,loveCauseRef,baby,brown,sheared,charged,captain,cold,hanging,aiming,airborne,crossed,
leatherBoots,persistent,open,gene,deathCause,deathAttacker,swimTarget`, with bounded strings and an
exact three-finite-value swim target. `prevX/prevY/prevZ`, `prevYaw/prevPitch`, renderer fields and
`noClip` are `runtimeRebuilt` only when the manifest names their pure rebuild function;
`inWater/inLava/underwater/inPowderSnow` rebuild from canonical cells/position before the first tick. `dead` is
`forbiddenTransient` because dead entities never enter VCK2. Type dimensions/step height and
immutable attributes are `typeDerived`. Source `Entity.type` is not encoded: the record `kindTag`
maps one-to-one to the exact registered type through `LANEntityKindManifestV1`, and a constructor/
legacy type mismatch rejects before allocation. LAN source
IDs/mirror flags are `forbiddenTransient`.

`LANEntityRNGDispositionV1: CaseIterable` has one row for every registered kind: exactly
`noSimulationRNG` or `requiredSimulationRNG`. A required record contains
`simulationRNG.a/b/c/d` as four `UInt32` plus
`simulationRNG.drawCount:LANVersionedCounterV1`; a no-RNG kind rejects the whole row. The count is
authoritative state, not test-only instrumentation: every raw state transition, including a rejected
bounded-integer sample, advances it once, and the named split operation advances it once. Source audit follows every
tick/hurt/interact/goal/callback reachable after publication and rejects `gameRng`, `Double.random`,
`Int.random`, freshly seeded local RNG or another nondeterministic source. Every consuming path uses
the entity's encoded simulation RNG. This includes Living/Mob kinds and non-Living Arrow/Egg/
Firework/TNT-minecart behavior plus every analogous registered kind found by the audit. Spawn-time
world randomness is allowed only inside a prepared world mutation whose resulting fields and initial
entity RNG are encoded before publication. Hydration restores words and the complete count without a
draw.

Entity RNG genesis has no constructor-order or process-random fallback. A fresh admitted entity
reserves four raw words from the durable `entitySpawn` world stream in its prepared mutation, stores
them as `a/b/c/d`, applies the all-zero `d = 1` escape, and starts its entity-local draw count at
`{0,0}`; the four world-stream draws and entity row publish atomically. A legacy VCK1 entity instead
uses the stable baseline key assigned before construction and computes
`SHA256("Pebble-LAN-v6-legacy-entity-rng-genesis\0" || worldStorageID || mutationLineageID ||
dimensionTag:UInt8 || Int32BE(chunkZ) || Int32BE(chunkX) || UInt32BE(sourceEntityOrdinal) ||
persistentKeyCanonicalBytes || UInt16BE(kindTag) || canonicalLegacyTypedRecordDigest)`.
The first 16 digest bytes are four `UInt32BE` words with the same nonzero escape and draw count
`{0,0}`. The legacy typed digest is produced only after duplicate-preserving strict decode and is
independent of JSON key order. Copy/import derives each destination entity row from the complete
source RNG row by one byte-exact function. `sourceEntityRNGBytes` is exactly 32 bytes:
`schema:UInt16BE=1`, `flags:UInt16BE=0`, `a/b/c/d:UInt32BE`,
`drawCount.generation/value:UInt32BE`, and `reserved:UInt32BE=0`. Source and destination persistent
keys are each exactly 24 bytes, raw 16-byte wid followed by generation/value `UInt32BE`. The exact
132-byte `copyInput` is `sourceEntityRNGBytes || sourcePersistentKeyBytes || newWorldLANID ||
newWorldStorageID || newMutationLineageID || newPersistentKeyBytes || kindTag:UInt16BE ||
zero:UInt16BE`. Compute
`copyDigest = SHA256("Pebble-LAN-v6-copy-entity-rng\0" || UInt16BE(132) || copyInput)`.
Digest bytes `0..<16` become destination `a/b/c/d` as four consecutive `UInt32BE`; if all four are
zero, only `d` becomes one. Destination draw count is exactly `{0,0}`; digest bytes `16..<32` are
unused and no source count is numerically carried forward. The destination RNG row, rekeyed entity,
bindings and namespace manifest commit atomically. Explicit Move instead preserves the exact 32-byte
source row and key without hashing.

`LANEntityRNGCopyVectors.json` contains source rows at zero/max words and draw-count rebase edges,
every source/destination key and ID byte position, each kind-tag byte, exact 132-byte input and
digest, first-half extraction, injected all-zero escape, Copy divergence, reversed migration order
and Move byte identity. Encoder and independent reference hasher must match every intermediate byte;
native endian, JSON/text rows, omitted IDs, last-half extraction and preserved source draw count all
fail.

The Living/Mob encoded family is exactly `health,maxHealth,absorption,effects,armor,mainHand,offHand,
hurtTime,deathTime,catalystBloomPending,attackCooldown,lastAttackerRef,lastHurtTargetRef,
lastHurtByPlayerTime,speed,kbResist,jumpPower,xpReward,ambientSoundTimer,baby,growUpAge,loveTicks,
breedCooldown,sitting,ownerRef,leashRef,leashFence,combatTargetRef,
mobSimulationPhase`. Equipment/effect DTOs reuse the strict owner
item/effect schemas and smaller caps. Per-instance attributes are encoded—including randomized
Horse speed—and never re-derived on load. Immutable kind attributes such as category, attack damage,
follow range, sunlight behavior and water breathing are
`typeDerived` only while source audit proves they cannot mutate after construction. Presentation-only
animation may be `runtimeRebuilt`; every AI goal/navigation/look/target state, cooldown, timer, flag,
RNG word or pointer that can change the next authoritative tick is encoded in the closed simulation
phase/reference fields. Session-only RPG mitigation/injury/fire-owner state is `separateAuthority`
only when its complete causal value lives in the coherent descriptor checkpoint, never implicitly
omitted.

`LANMobSimulationPhaseV1` is a versioned closed sum:
`quiescent(schema:1,movement)` or
`active(schema:1,movement,behaviorActive,targetActive,goalStates,navigation,look,combatTarget,
ambientSoundTimer)`. `movement` is exactly
`{moveForward:Float64BE,moveStrafe:Float64BE,jumping:Bool,sprinting:Bool,sneaking:Bool}`; axes must be
finite `-1...1` and flags are exact bytes `0|1`. They are authoritative next-tick inputs, never
animation scratch or hydration defaults. A mob's immutable configured goal graph is derived only from its exact
kind/specification contract and is capped at 32 goals; closures/filters are never serialized.
`behaviorActive` and `targetActive` each preserve `GoalSelector.active` order as at most eight unique
goal keys. A key is exact `{selector:UInt8,goalKind:UInt16,priority:Int16,insertionOrdinal:UInt16,
flags:UInt8}` and must name the derived configured graph; selector order is behavior then target,
and within each array active ordinal is authoritative.

`LANGoalPhaseV1` is the closed tagged sum of the 27 shipped cases: float, panic, stroll,
lookAtPlayer, randomLook, meleeAttack, nearestTarget, hurtByTarget, avoidEntity, tempt, breed,
followParent, followOwner, sitWhenOrdered, rangedAttack, moveToBlock, randomSwim, eatGrass,
ownerHurtTarget, pollinate, returnToHive, ram, sniffDig, allayCollect, swell, findWorkstation and
snowballAttack. Cases with no mutable state carry no payload; the only mutable payload fields are
`lookTime,targetRef,time,attackCooldown,scanCooldown,fleeingRef,playerRef,partnerRef,parentRef,
cooldown,targetPos,tries,eatTimer,pollinating,ramTargetRef,charging,digging,targetItemRef` as allowed
by that exact case. Pollinate and find-workstation include their inherited move-to-block fields.
Every reference uses the relation schema; timers are `0...1_200_000`, positions are bounded integer
triples, and no generic payload/map or unknown goal tag is accepted.

`navigation` is exactly `{path[0...256] of Int32 x/y/z,pathIndex,repathCooldown,targetX/Y/Z,
speedMod,stuckTicks,nodeTicks,lastX,lastZ,avoidWater}` with finite coordinates/speed, index
`0...path.count`, timers `0...1_200_000` and exact Boolean. `look` is exact optional finite `lookX`
plus finite `lookY/lookZ`; `combatTarget` is an optional closed living/owner reference and the whole
phase has at most 16 references and 65,536 encoded bytes. Goal states are sorted by goal key;
duplicates, state for an unconfigured goal, active/state disagreement or cap+1 rejects.

The source audit covers `GoalSelector`, `Navigation` and every Goal subclass field. A field omitted
from this sum needs the same per-field next-trace rebuild proof; otherwise it must be added with a
schema/registry change. Legacy VCK1 missing phase may migrate only to the documented quiescent phase
under the pinned historical kind graph (or capture a provenance-verified loaded phase), then writes
strict VCK2; VCK2 never defaults. Tests sentinel every case/payload, active ordering, path/ref cap,
legacy migration and 1,200-tick continuous-versus-restart traces for each mob kind.
Movement tests independently sentinel both axes at `-1/0/1` and every flag combination through
capture, restart and the first post-load travel tick. A non-Mob Living subtype must encode the same
five fields in its closed subtype simulation phase; it may not inherit a Mob goal payload.

Subtype masks are closed compositions of the common families plus these exact field families:

- animals/tames: `foods,saddled,boostTime,sheared,color,eatGrassTimer,eggTime,tamed,angry,hasNectar,
  hasStung,hivePos,hiveScanCooldown,playDead,ramCooldown,hanging,dashCooldown,digCooldown,likedItem,heldItems,bucketItem,
  puffed`;
- monsters/raiders: `conversionTime,hasTrident,curing,swellTicks,charged,size,jumpDelay,drinkTime,
  carrying,lifeTicks,circlePos,attackPhase,laserTargetRef,laserTime,peekAmount,isCaptain,castCooldown,
  roarCooldown,ghastShootCooldown,zombifiedAngerTime,blazeVolleys,admiring,admiredItem,zombifyPhase`;
- villagers/golems/mounts: `profession,tradeLevel,tradeXP,offers,restockTimer,workstation,homeBed,
  despawnTimer,playerMade,tamed,saddled,temper,jumpStrength,spitCooldown`;
- bosses: `angerByRef,sonicCharge,sniffCooldown,diggingOut,emerging,phase,phaseTime,pathAngle,
  pathRadius,pathHeight,deathAnimTime,breathTime,chargeTime,shootCooldowns`;
- item/misc: `stack,pickupDelay,lifeTime,amount,blockCell,fuse,power,controlledChargeAuthority,
  showBottom,beamTarget,radius,duration,effectID,amplifier,reapplyDelay,affectedEntries,particleType,
  followTargetRef,targetX,targetZ,life,surviveChance`;
- projectiles: common `ownerRef,gravity,drag,stuck` plus arrow
  `damage,critical,pickupable,punchLevel,flame,potionID,spectral,stuckTime,fromCrossbow,piercingLeft`,
  thrown-potion `potionID,lingering`, fireball `power,small`, wither-skull `blue`, shulker-bullet
  `targetRef`, trident `stack,loyalty,returning,dealtDamage`, firework
  `life,lifeTotal,attachedToRef,flightDuration`, and every remaining registered projectile's
  corresponding owner, lifetime and subtype state row;
- vehicles: boat `wood,hasChest,chestItems,paddleAnim` and minecart
  `variant,chestItems,fuel,tntFuse`.

Every field in those families is either required for each applicable VCK2 kind or absent because
the concrete kind mask excludes it; VCK2 never supplies a default. A value that is semantically
constant for a kind is `typeDerived`, not an optional encoded field. Legacy missing-field defaults
exist only inside the explicit versioned VCK1/entity-tail migrator; that migrator must materialize a
complete VCK2 record and then prove it passes the strict VCK2 decoder before publication.

Bee `hiveScanCooldown` is a required `UInt8` in `0...40`; it preserves whether the next
`locateHive` call scans or decrements. Only the explicit VCK1 migrator may materialize missing state
as zero, then writes strict VCK2. Tests restart at 0/1/40 and prove identical scan tick, selected hive
and subsequent movement trace.

Continuation RNG uses the single named `LANContinuationRNGSplitV1` algorithm. Its exact 72-byte
input is `schema:UInt16BE=1`, `parentAuthorityTag:UInt8`, `domain:UInt8`, parent
`a/b/c/d:UInt32BE`, parent `drawCount.generation/value:UInt32BE`,
`sequence.generation/value:UInt32BE`, `ordinal:UInt8` plus three zero bytes, and a 32-byte
`contextDigest`. Allowed authority/domain pairs are exactly entity simulation RNG (`tag 1`) with
Blaze shot (`domain 1`) or Piglin barter (`domain 2`), and the durable world `interaction` stream
(`tag 2`) with fishing reel (`domain 3`) or fishing-session genesis (`domain 4`); every other pair
rejects before hashing. Domain 3 requires `ordinal == UInt8(0)` exactly; ordinal 1...255 rejects
before hashing, counter advance or allocation. Domain 4 also uses ordinal zero; domains 1/2 retain
their separately bounded shot/output ordinals.

Context digests are exact: domain 1 hashes
`"Pebble-LAN-v6-blaze-rng-context\0" || sourcePersistentKeyBytes || reservedProjectileKeyBytes`;
domain 2 hashes `"Pebble-LAN-v6-barter-rng-context\0" || sourcePersistentKeyBytes ||
chunkDomainDigest`; domain 3 hashes `"Pebble-LAN-v6-fishing-rng-context\0" ||
UInt16BE(ownerAuthorityBytes.count) || ownerAuthorityBytes || descriptorID || rodItemDigest`;
domain 4 hashes `"Pebble-LAN-v6-fishing-session-rng-context\0" ||
UInt16BE(ownerAuthorityBytes.count) || ownerAuthorityBytes || descriptorID || rodItemDigest ||
dimensionTag:UInt8 || 0x00 || 0x00 || 0x00`.
Compute `SHA256("Pebble-LAN-v6-continuation-rng-split\0" || UInt16BE(72) || input)`. Digest bytes
`0..<16`, read as four `UInt32BE`, are the child words; bytes `16..<32` are the result parent words.
Each half independently applies the all-zero escape by replacing only `d` with one. Child draw count
is `{0,0}` and result parent draw count is the checked successor of the complete expected parent
count. Scheduling/reservation atomically installs result words/count once and persists the child;
retry reuses the same expected/result/child bytes and never splits again.

For domain 3, the parent authority is always `LANWorldRNGStreamStateV1(id:.interaction)` from the
same hosted-world checkpoint—never owner RNG, fishing-session RNG or a process global. The
reservation stores the full expected/result stream rows and its keyed reel-sequence successor; a
CAS mismatch defers unchanged. `LANContinuationRNGSplitVectors.json` fixes the complete input,
digest, child and result for host-local and guest fishing contexts, same-byte retry, different owner/
descriptor/rod contexts, zero/max words, draw-count rebase/outer terminal and every allowed domain.
Domain-3 vectors include ordinal 0 success plus ordinal 1 and 255 pre-hash rejection.
Host endian, seed constructors and native random APIs are forbidden substitutes.

Blaze volleys are not closures or process-global timeouts. A Blaze record contains at most three
`LANBlazeScheduledShotV1` values. Its canonical wire bytes are exactly `schema:UInt16BE=1`,
`volleySequence.generation/value:UInt32BE`, `shotOrdinal:UInt8` plus three zero bytes,
`dueWorldTick.generation/value:UInt32BE`, source key as raw wid plus generation/value `UInt32BE`,
`targetLength:UInt16BE` plus canonical target-reference bytes, `resultContractDigest:32 raw bytes`,
reserved projectile key in the same 24-byte form, and `shotRNG.a/b/c/d:UInt32BE` plus
`shotRNG.drawCount.generation/value:UInt32BE`. Records sort by
`(dueWorldTick,volleySequence,shotOrdinal)` and reject unknown schema, padding or trailing bytes.
Scheduling all three pre-reserves their keys, RNG, contract and world-mutation capacity; the world
cap is 4,096 shots/8,388,608 bytes. Resolution uses the generic contract-bound coordinator, validates
source/target, atomically deletes that shot and spawns the fireball under its pinned contract/key/RNG,
or applies the declared target-gone cancellation. Death/import cancels remaining shots; explicit Move
preserves them. Tests unload/reload dimensions, restart between all three shots, change contracts,
kill source/target, exhaust capacity, rebase/terminal volley and due-tick pairs, match the split
oracle, and prove no closure survives or shot duplicates.

Lightning and evoker fangs are scheduled authority, never process queues or VCK2 entities.
`LANScheduledLightningV1` is at most 2,048 bytes and exactly
`{schema:1,descriptorID,dimension,x,y,z,dueWorldTick,lightningSequence,sourceKind,sourceRef,
resultContractDigest,lifecycle}`. IDs are 16 CSPRNG bytes; position is finite/in bounds; both tick and
sequence are complete versioned pairs. `sourceKind` is the closed sum `weather | channeling |
rpgAction | trustedSystem`; weather forbids a source and every other kind requires an exact
entity/owner causal reference. Lifecycle is exactly `scheduled`; there is no persisted resolving/
pending variant. At most 128 rows/
262,144 encoded bytes exist per world. Creating a runtime `LightningBolt` with authoritative
callbacks is forbidden; an optional six-tick bolt projection is presentation-only and appears only
after the descriptor's durable creation receipt.

At the due phase, lightning preparation uses the tick-start task/query snapshot, chooses the
canonical ground/fire cell, and stable-orders all living targets within four blocks. Its closed
authoritative fanout is the first 32 targets; target 33 and later are deliberately outside the
strike contract, never chosen by container order. It pre-reserves fire, five damage, 160 fire ticks,
every applicable registered conversion, causal credit, entity keys, RNG-stream results, primary
records, relations, journal and checkpoint bytes without changing durable state. One DB-first
transaction CAS-deletes the expected scheduled row and atomically commits every world/entity result,
relation update and deletion tombstone; after COMMIT hydration can observe only all-old or all-new and
can never strike twice. A missing retained causal source removes credit but does not cancel a
previously scheduled strike. `doFireTick`, PvP and both owner permissions are revalidated at actual
resolution. Sound pitch/particles are nonauthoritative and may use presentation randomness only.

`LANScheduledEvokerFangV1` is at most 2,048 bytes and exactly
`{schema:1,descriptorID,dimension,x,y,z,dueWorldTick,fangCastSequence,fangOrdinal,ownerRef,
resultContractDigest,lifecycle}`. Ordinal is `1...16`; owner is one stable living-entity reference;
lifecycle is exactly `scheduled`; rows sort by
`(dueWorldTick,fangCastSequence,fangOrdinal,descriptorID)`. A cast reserves all 16 descriptors,
their IDs, due ticks `castTick + 2*ordinal`, relation/index rows, damage fanout, journal and checkpoint
capacity before consuming its RNG draw or changing cooldown; partial casts are forbidden. The world
cap is 512 rows/1,048,576 encoded bytes. Resolution searches exactly four cells downward in fixed
Y order, queries the immutable tick snapshot, excludes the owner, and applies magic damage to the
first 32 stable-order living targets. It retains stable causal credit if the owner unloads/dies, but
owner-key corruption rejects the descriptor. One DB-first transaction CAS-deletes the expected
scheduled row and commits the complete damage/causal/relation results plus deletion tombstone,
making each bite exactly once without a persisted intermediate. Import/copy cancels and burns reserved IDs;
explicit Move preserves rows byte-for-byte. Tests restart/crash at every one of 16 due boundaries,
reverse insertion, unload/retire the owner, exercise 0/1/32/33 targets, cap 511/512/513, full-pair
rebase/terminal, whole-cast reservation failure and all-old/all-new resolution.

`LANScheduledEffectCheckpointSegmentV1` is the sole writer for both descriptor families. It carries
the complete stable-key result map of at most 128 lightning and 512 fang active rows or deletion
tombstones, 1,310,720 payload bytes total, and participates in the coherent checkpoint/component
manifest. There is no `fangQueue`, delayed closure, standalone descriptor save, or post-COMMIT
authoritative callback. `LANPersistentRelationSourceV1` adds
`scheduledEffect(descriptorID)` only for the required `lightningSource`/`fangOwner` causal rows;
their lifecycle is `retain-causal-credit-on-target-gone`, which preserves immutable attribution but
never binds a stale runtime pointer.

Ghast `shootCooldown` and Zombified Piglin `angerTime` are required `0...1_200_000` fields; the anger
target is a stable relation and clearing at zero is part of the same record transition. Horse speed
is a required finite per-instance field, not `typeDerived`. `XPOrb.followTarget` is encoded as an
optional owner/entity reference with clear-on-target-gone lifecycle; nearest-player reacquisition is
stable subject order and happens only after the persisted reference clears.

`LANAreaEffectCloudAffectedEntryV1` is exactly
`{target:LANPersistentSubjectV1,lastAppliedEntityAge:LANVersionedCounterV1}`. Entries are sorted/unique
by target, share the cloud-age generation, and are capped at 256/32,768 bytes. Before a five-tick
application pass, gone targets and entries whose reapply delay has elapsed are deterministically
pruned, then the complete prospective target/update set is measured in stable subject order; cap+1
defers the whole cloud mutation with no partial effects. Process IDs and an unbounded dictionary are
forbidden. Tests cover target unload/retirement, reapply boundaries, 255/256/257 targets and restart.

Warden anger is a sorted array of at most 64
`{target:living-or-owner-reference,anger:1...1_000_000,lastUpdatedTick}` records. Existing-target
increments are checked. At full capacity, a new target may replace only the deterministic minimum
`(anger,lastUpdatedTick,targetCanonicalBytes)` entry and only when its proposed anger is greater;
otherwise admission rejects that vibration before mutation. Eviction atomically clears/reselects
combat target as needed. Tests cover stable ties, 63/64/65 entries, max anger, target cleanup and
restart; raw numeric-ID maps are forbidden.

Authoritative simulation uses one total cross-category key and one closed phase schedule, never
separate container orders. `LANSimulationOrderKeyV1` canonical bytes are `phaseTag:UInt8`,
`dimensionTag:UInt8`, `subjectKind:UInt8`, one zero byte, `subjectLength:UInt16BE`, canonical subject
bytes, and `tieBreak:UInt32BE`. Owner subjects encode host as `UInt32BE(0)` and guests by joined
ordinal; persistent entities encode raw wid plus key generation/value `UInt32BE`; descriptors use
16 raw ID bytes; BE subjects encode x/y/z as sign-biased `UInt32BE` plus kind tag; world/system tasks
encode their closed task tag, stable cell/chunk/descriptor key and versioned schedule sequence.
`tieBreak` is zero unless the phase manifest names a unique subrecord ordinal. Lexicographic key
order is the one total order within each phase; no two live tasks may share a key.

`LANWorldScheduleV1: CaseIterable` fixes this complete global-tick order:

| Tag | Exact authoritative phase |
| ---: | --- |
| `0x01` | owner input, physical movement/collision/fluid/fall/portal staging, queued reducer events, complete proxy projection, pure timed state, delayed progression and at-most-one exact-next action |
| `0x02` | per-dimension world/global clock, daylight and weather-state transition |
| `0x03` | due scheduled block/fluid ticks in `(dueTick,priority,stableScheduleSequence,cell)` order |
| `0x04` | random block-tick candidates precomputed from the tick-start loaded-chunk set and `worldTick`/`farming` RNG rows |
| `0x05` | block entities in canonical `(dimension,z,y,x,kindTag)` order |
| `0x06` | persistent entities/projectiles in persistent-key order |
| `0x07` | entity/redstone trigger tasks |
| `0x08` | descriptor continuations: fishing, Blaze shots, lightning, evoker fangs, delayed/temporary effects and timeout tombstones |
| `0x09` | natural-spawn attempt tasks |
| `0x0A` | durable raid-state advance/wave tasks |
| `0x0B` | patrol attempt tasks |
| `0x0C` | raid-admission tasks after patrol publication in scratch |
| `0x0D` | weather strike and snow/ice/fire-damp world-mutation tasks; particles are excluded presentation |
| `0x0E` | owner post-world portal/use/mining completion and resulting reducer events |
| `0x0F` | at-most-one bounded template-job step per stable job ordinal |

`LANWorldScheduleRNGUseV1: CaseIterable` maps every reachable draw callsite exactly once: `0x01`
uses owner RNG and the `interaction` stream; `0x02` uses `worldTick`; each `0x03` handler is declared
`noRNG | redstone | farming | blockEntity | explosion`; `0x04` candidate selection uses `worldTick`
and its handler uses the same closed declaration; `0x05` uses `blockEntity`; `0x06` uses only the
subject entity RNG plus contract-declared `entitySpawn`/`worldLoot`; `0x07` uses `redstone`; `0x08`
uses the descriptor's saved child/entity RNG plus contract-declared `entitySpawn`, `worldLoot` or
`explosion`; `0x09` uses `entitySpawn`; `0x0A...0x0C` use `raid`; `0x0D` uses `worldTick`, `farming`
and `entitySpawn`; `0x0E` uses owner RNG/`interaction`; and `0x0F` is `noRNG`. Source audit fails an
unmapped call, cross-stream substitution, native authority randomness, or RNG access outside its
declared phase. Scratch expected/result words and draw counts are committed with that phase's exact
mutation.

Scheduled block and raid work is durable input to this schedule. `LANScheduledBlockTaskV1` is the
strict row `{schema:1,dimension,x,y,z,blockTag,dueWorldTick,priority,scheduleSequence,
handlerContractDigest}` at most 256 bytes, unique by `(dimension,x,y,z,blockTag)`, with 131,072 rows/
33,554,432 bytes per world. Each tick takes at most the first 512 due rows by
`(dueWorldTick,priority,scheduleSequence,dimension,z,y,x,blockTag)`; excess due rows remain unchanged
for the next tick. `LANDurableRaidStateV1` is at most 4,096 bytes and replaces process-global raid
objects/IDs with `{raidID,dimension,center,wave,totalWaves,raiderRefs,phase,cooldown,health,
raidRNGReservation}`; at most 256 rows/1,048,576 bytes exist, and at most 64 rows change in one tick.
Raider references are stable keys, never runtime IDs.

The coherent checkpoint carries one `LANWorldTaskCheckpointSegmentV1` with at most 512 scheduled-
task deltas/131,072 bytes plus 64 raid deltas/262,144 bytes. Each delta has earliest expected and
latest result row digest or deletion tombstone; metadata stores complete table count/root. Schedule,
dedupe, reschedule, due-pop, raid create/wave/victory/defeat/prune and their world/entity results
commit atomically. Hydration validates both tables/root before snapshot capture. Random-tick,
natural-spawn, patrol, weather and raid-admission attempts are regenerated task entries from the
immutable tick-start world/chunk/owner state and saved RNG rows; they are not hidden process queues.

No authoritative callback exists outside this table. Light/mesh flush, sounds, particles, ambience,
view bob, boss-bar rendering, toast rendering and save scheduling are derived/presentation or
persistence consumers after the prepared publication; they cannot mutate canonical authority.
Adding/reordering a phase or task kind changes the manifest/registry digest and its trace fixtures.

Each global tick constructs exactly one immutable `LANSimulationTickSnapshotV1` after applying all
eligible prior DB publication receipts and before `0x01`. It contains the prospective full-pair
global tick, every scheduled task key for all phases in one phase/key-sorted array, each subject's
stable generation/dimension binding, the immutable tick-start loaded-chunk membership, and SHA-256
over canonical length-prefixed entries. Exact category maxima are 9 owners + 262,144 persistent
entities + 32,768 descriptor continuations + 65,536 block entities + 163,831 world/system tasks =
524,288 entries. Each entry is at most 256 bytes, so entries occupy at most 134,217,728 bytes.
Construction first count/scans the bounded indexes, rejects count/byte cap+1 before allocating or
drawing RNG, reserves the exact array and working arenas, then fills/sorts once. Every phase and
authoritative query uses this snapshot ID/array; no phase rebuilds a list or discovers membership
from a live container.

A subject removed, retired, transferred or cancelled during the tick is marked inactive in the
snapshot and receives no later callback, but its removal neither shifts nor reorders any other entry.
Any owner/entity/projectile/fishing projection/descriptor continuation/block entity/scheduled task
created, loaded, recreated or rekeyed after snapshot capture is absent from all remaining
phases and spatial queries and becomes eligible only in the next global tick—never a later phase of
the current tick. Dimension transfer retires the old entry and admits the destination entry next
tick. There is no mid-tick resnapshot, per-chunk refresh or exception for a category whose phase has
not started.

Debug/test `LANSimulationPhaseSentinelV1` values at tick start, before/after each exact phase tag and
tick end carry `{tick,snapshotDigest,phaseTag,lastVisitedKey,activeMaskDigest,createdKeyDigest}`.
Sentinels assert an unchanged snapshot digest, monotonic inactive mask, strictly increasing visits,
and that each start member is either visited exactly once or became inactive before its turn, while
every created key remains unvisited. Tests create/delete/rekey/transfer one member during every phase
including the first and last entry, create a BE and fishing projection before their otherwise-later
phases, reverse all chunk/container insertion orders, restart at tick boundaries, and require
byte-identical visit/query/RNG/mutation traces with admission only on the following tick.

The simultaneous working maximum is exact: one `UInt64` sort index per entry is 4,194,304 bytes;
the 524,288-bit active mask is 65,536; digest/phase frontier storage is 65,536; and one query page is
65,536 entries at 256 bytes/16,777,216. Including entries, the cap is therefore 155,320,320 bytes.
Only one page may exist. Queries scan the already ordered snapshot and may stream successive pages;
they never allocate a whole-result array, and a bounded consumer stops at its separately declared
fanout while preserving order. A page, entry, category or aggregate cap failure occurs before the
tick/RNG/mutation; autonomous failure stops hosted authority with staged state intact, while an
exact request remains unconsumed/deferred.

Every authoritative spatial/query API—including nearby-entity, ray/collision candidate, target,
pickup, area effect, passenger, block-neighbor and BE/scheduled-tick queries—returns results ordered
by this key before filtering, `first`, RNG or mutation. A query with a semantic primary metric (for
example distance) orders by the exact canonical metric then uses this key as tie-break. Spatial hash,
chunk load, entity-ID map, BE update array, `Dictionary` and `Set` iteration order are never visible.
Source audit enforces the shared sorter. Reversed chunk load/insertion/index permutations exercise
XPOrb follow, Piglin pickup, Warden anger, Blaze targeting, cloud effects, collisions, passengers and
redstone/BE interactions, every phase in the table, lightning and fangs; all must yield identical
result order, draw counts, mutations and VCK2 bytes.

Piglin/PiglinBrute barter state is one optional, at-most-512-byte `LANPiglinPendingBarterV1`, exactly
the canonical bytes `schema:UInt16BE=1`, `phase:UInt8` (`1` admiring, `2` payoutPending),
`remainingTicks:UInt8` (`1...120` only for admiring, zero only for pending),
`admiredItemTag:UInt32BE`, `count:UInt8=1` plus three zero bytes, `chunkDomainDigest:32 raw bytes`,
`lootTableTag:UInt16BE` plus two zero bytes, `barterRNG.a/b/c/d:UInt32BE`,
`barterRNG.drawCount.generation/value:UInt32BE`, and
`reservationSequence.generation/value:UInt32BE`; trailing bytes reject. The item tag is exactly the
registered gold
ingot; the contract row and table tag must resolve the immutable `piglin_bartering` definition.
There is no separate encoded `admiring`/`admiredItem` authority: live fields map bijectively to this
DTO, and phase `payoutPending` represents live countdown zero with the item still owned.

Gold consumption runs through the contract-bound coordinator and atomically decrements/removes the
ItemEntity, reserves a dedicated barter RNG substream from the Piglin simulation RNG, advances the
main RNG to its exact post-reservation words and persists the pending DTO. Countdown and movement
preserve its pinned contract. Payout always rolls the saved substream/definition, pre-reserves all
output entities, and in one prepared mutation inserts output and clears the pending record; failure
leaves `payoutPending` and its original RNG unchanged, so retry never rerolls. PiglinBrute inherits
the same reachable state/handler and may not forbid a valid pending barter merely because its normal
AI does not initiate one. Contract upgrade or chunk movement keeps the old row retained; world copy/
import carries and revalidates it, explicit Move preserves it, and entity/template cloning rejects a
pending barter to prevent loot duplication. Pruning cannot remove its contract row.

Zombification canonical bytes are `schema:UInt16BE=1`, tag `UInt8` (`0` inactive, `1` countdown,
`2` conversionPending), one zero byte, `countdown:UInt16BE`, two zero bytes,
`attempt.generation/value:UInt32BE`, and `nextRetryTick.generation/value:UInt32BE`. Inactive requires
all payload zero; countdown requires `1...300` and zero attempt/tick; pending requires countdown zero
and valid full-pair attempt/tick. Reaching zero atomically enters
`conversionPending`; values never decrement negative. Replacement spawn/removal uses the generic
contract-bound coordinator. Spawn/cap failure leaves the pending phase and schedules its exact next
retry without removing the Piglin; success atomically publishes the replacement, removes the source
and, if a barter is pending, returns its admired gold rather than minting barter loot. Legacy positive
values map to countdown, zero/negative map to conversionPending without clamp, and an entity in a
non-converting dimension maps to inactive; VCK2 never defaults.

Tests cut before/after gold removal, RNG reservation, every countdown, payout roll/output/clear,
movement, contract upgrade/retention/prune, copy/move/template, restart, zero/negative zombification,
every failed/successful replacement spawn and COMMIT, counter rebase/outer terminal and split-vector
oracle. Piglin and PiglinBrute must produce exactly one
barter or one returned gold and never duplicate/lose state. The exhaustive disposition/source audit
applies the same oracle to every analogous subtype timer/flag added later.

All encoded relationships use the closed sum `LANPersistentSubjectV1 =
entity(LANPersistentEntityKeyV1) | owner(LANOwnerAuthorityRefV1)`, where the owner case is exactly
`host:local` or `lan:<joinedOrdinal>` and never a process ID, display name or guessed authority.
Relation sources use the separate closed sum `LANPersistentRelationSourceV1 =
subject(LANPersistentSubjectV1) | fishingSession(ownerAuthority,descriptorID) |
scheduledEffect(descriptorID)`; descriptor IDs are raw 16-byte IDs and must resolve to a row in the
same coherent checkpoint generation. Descriptor cases are sources only and can never be accepted as
an entity/owner target.
`LANPersistentEntityReferenceV1` is exactly
`{subject,relation,expectedTargetClass,expectedDimension,lifecycle}`. `expectedTargetClass` is the
closed set owner-authority, any-persistent-entity, living, mob, tameable, vehicle and projectile;
`lifecycle` is required, clear-on-target-gone, cancel-source-on-target-gone or reciprocal-dismount.

The relation manifest fixes allowable subject/class/lifecycle combinations: causal/projectile/tame
owner accepts a living entity or owner authority; vehicle points only to a vehicle entity; passenger
accepts a persistent entity or owner authority; leash/love-cause accept living/entity-or-owner as
their source semantics require; anger/combat/laser/projectile target and affected accept only their
declared living/owner class; attached-to accepts its subtype's exact entity/owner class. Every fishing
session has exactly one required `fishingOwner` edge to the same owner named by the descriptor with
`cancel-source-on-target-gone`, and zero or one `fishingHook` edge to a nonowner living entity with
`clear-on-target-gone`; lifecycle `hooked` requires that edge and every other lifecycle forbids it.
The descriptor's `hookedTarget`, the edge, both index directions and owner `fishingSessionID` must
agree byte-for-byte. Scheduled-effect sources may use only the `lightningSource` or `fangOwner`
rows defined above. A relation
outside that row rejects even if its key exists. Raw pointers, numeric entity/owner IDs and arbitrary
relation dictionaries are forbidden.

`LANPassengerCapacityV1` is the sole numeric capacity oracle. It counts entity and owner passengers
together and has this complete mapping for every currently registered kind that can be a vehicle or
is reachable from a riding interaction:

| Registered vehicle kind | Exact validated state | Capacity |
| --- | --- | ---: |
| `boat` | live, `hasChest == false` (all registered wood/raft variants) | 2 |
| `boat` | live, `hasChest == true` (all registered chest-boat/chest-raft variants) | 1 |
| `minecart` | live, `variant == empty` | 1 |
| `minecart` | live, `variant == chest`, `hopper`, `tnt` or `furnace` | 0 |
| `pig` | live adult with `saddled == true` | 1 |
| `pig` | baby or unsaddled | 0 |
| `strider` | live adult with `saddled == true` | 1 |
| `strider` | baby or unsaddled | 0 |
| `camel` | live adult with `saddled == true` | 2 |
| `camel` | baby or unsaddled | 0 |
| `horse`, `donkey`, `mule`, `skeleton_horse` | live adult, for every valid tamed/untamed and saddled/unsaddled combination | 1 |
| `horse`, `donkey`, `mule`, `skeleton_horse` | baby | 0 |
| `llama` and every other registered entity kind | every state | 0 |

The universal override is capacity zero for dead, removal-pending, relation-cleanup-pending,
dimension-transfer-pending or quarantined entities. Unknown boat wood, minecart variant or illegal
cross-field state rejects the entity record; it does not fall through to zero. The catch-all row is
closed over `ENTITY_FACTORIES`: a source audit requires every registered kind to map exactly once to
one explicit row or the zero-capacity remainder, and adding a riding interaction or nonzero-capacity
kind fails until this table, the oracle and tests change together. In particular, live `Llama` has no
mount interaction and remains zero; generic `Entity.mount` cannot make an arbitrary entity a vehicle.

All mount entry points, interactions, persistence decode/migration, relation coalescing and hydration
call this oracle before mutation. A state transition that reduces capacity keeps the lowest
`LANSimulationOrderKeyV1` passengers and prepares reciprocal dismounts for the highest keys in
descending order in the same primary-record/relation checkpoint; it cannot publish the new state
first. Failure to reserve every dismount, safe resulting pose, binding/index update and checkpoint
byte rejects or defers the state transition unchanged. Direct array append, raw pointer assignment
and a subtype-local capacity check are forbidden bypasses.

Each entity record has at most 64 relations, each chunk 16,384 and each world 1,048,576. The bounded
persistent relation index stores both loaded and unloaded cross-chunk edges; decode validates a
target against the binding/index without requiring a live object, and second-pass binding creates a
pointer only after the target publishes. Despawn, dimension transfer, owner retirement and chunk
migration apply the declared lifecycle under the world-mutation coordinator and atomically update
the source record/index or cancel/dismount; an unloaded stale edge cannot attach to a later key.
Copy/import rekeys both ends of entity subjects, applies clear/cancel to quarantined owner-authority
subjects, and recomputes relation digests; explicit Move preserves both. Legacy migration may emit
only relations resolved by the baseline's reserved-key/owner map or its explicit clear disposition.

Riding is fully reciprocal: every entity/owner `vehicleRef` has exactly one matching sorted unique
`passengerRef`, every passenger has at most one vehicle, both sides name the same dimension, vehicle
kinds obey the exact capacity oracle above, and the complete entity-plus-owner graph is acyclic. Unloaded
halves remain reciprocal in the index. Mount/dismount/despawn/transfer updates both canonical records
and the index in one prepared mutation; partial, duplicate-parent, wrong-class, wrong-dimension or
cyclic graphs reject before allocation. Tests reverse load order, unload either side, cross a chunk
boundary, retire an owner, copy/migrate and crash each reciprocal update. The capacity matrix tests
every listed live/baby, chest, variant, tame and saddle combination at capacity-1/capacity/capacity+1;
enumerates every registered kind through an independent oracle; exercises generic API bypasses; and
changes 2->1, 2->0 and 1->0 with both passenger insertion orders, restart and every reciprocal
dismount/COMMIT crash cut.

Every relationship mutation contributes one coherent `LANRelationCheckpointSegmentV1`, exactly
`{schema:1,checkpointGeneration,ownerRecordRefs,entityRecordRefs,descriptorRecordRefs,bindingRefs,
relationIndexDeltas,cleanupTombstones,count,encodedBytes,digest}`. Under sorted authority/world-
mutation gates it pre-reserves at most 512 edge/index deltas, references at most 128 canonical owner/
entity/descriptor records total, including at most 64 distinct entity records, all 9 owner records,
all 9 fishing rows and the scheduled-effect rows touched by that checkpoint already encoded in their
primary checkpoint segments, and adds at most 8,388,608 relation-
index/tombstone bytes. It is accepted only by the sole `LANAuthorityCheckpointStager` and written by
the sole `commitLANAuthorityCheckpoint` transaction with all referenced owner records, canonical
entity records in the dedicated 1,048,576-byte-per-record primary segment, persistent-key bindings,
both index directions, cleanup tombstones and
world/CAS metadata. Mount, dismount, unload, dimension transfer, disconnect/retirement, despawn and
migration have no standalone relation write API. Capacity failure is a pre-mutation defer; DB-first
publication and rollback behavior are normative in the checkpoint section.

Inbound fanout is independently bounded to 4,096 edges per target. Adding edge 4,097 rejects before
source mutation. Cleanup that fits one relation segment is atomic. Larger cleanup first commits through the sole stager a
`LANRelationCleanupTombstoneV1 {target,expectedInboundCount,expectedDigest,cursor,remaining}` and
marks the target `relationCleanupPending`; that target cannot bind, publish, transfer or be reused,
and a source carrying an unprocessed edge cannot publish from an unloaded chunk. Live resolution
treats the tombstoned target as unavailable immediately. Crash-recoverable batches process at most
64 stable-source-key-ordered edge/source records and 8,388,608 bytes, atomically advancing cursor,
source records, bindings and index through `commitLANAuthorityCheckpoint`. At most 128 target tombstones exist per world. The last batch
proves zero inbound edges before deleting the tombstone; mismatch/cap/disk failure retains it and
blocks affected publication. Tests cover 0/1/64/65/4,096/4,097 inbound edges, record-byte cap+1,
every batch/COMMIT crash cut, reverse reload, disconnect/transfer and proof that no stale relation or
key alias becomes observable.

VCK2 decode is transactional and allocation-free until the entire header, all records, all required
fields, numeric/registry domains, aggregate counts, digests and reference graph validate. It then
reserves all runtime IDs without advancing an allocator and constructs entities through a dedicated
RNG-free persistence initializer: no `gameRng`, global entity allocator, spawn hook, sound, particle,
loot or world mutation is reachable. Kind/variant/size, dimensions and other shape-derived
attributes apply before `maxHealth`, health, absorption, equipment or effects; motion and timers
apply next; every required simulation RNG restores before any simulation callback; stable relationships
bind in a second pass; the complete set publishes atomically last.
Any failure destroys scratch values and leaves entity allocators, gameplay RNG, world arrays,
bindings and callbacks byte-for-byte unchanged.

`runtimeRebuilt` is legal only with a named pure rebuild function from canonical world bytes and
encoded fields and a proof that rebuilding cannot change the next authoritative trace. Clearing to a
default because old saves omitted a field is not a rebuild. For every allowed kind, a restart trace-
equivalence test forks from the same canonical capture, runs one branch continuously and VCK2-
round-trips the other, then supplies identical inputs for at least 1,200 ticks. Per tick it compares
all encoded fields, per-entity RNG words/draw count, target/riding graph, damage/loot/spawn/world
mutations, descriptors and canonical bytes. Sentinel states exercise every gameplay timer/flag at
zero, one, active and terminal boundaries; any divergence makes the disposition invalid.

Both block-entity and entity manifests are `CaseIterable`, checked into the generator/registry
contract, and source-audited. Tests assert the exact 100-kind/15-save/16-load census, instantiate
every allowed kind, sentinel every `encoded` field and exercise every other disposition, then encode/
decode every tag. They permute field/record order and probe malformed masks, numeric domains, widths,
endian, lengths, UTF-8, floats, references and caps while proving zero RNG draw and zero allocator/
world change on failure. Required regressions cover Slime size-before-health, dragon phase/path/death,
ItemEntity pickup/lifetime, TNT fuse/power/causal owner, minecart variant/fuel/chest/TNT fuse,
AreaEffectCloud radius/duration/effect/reapply/affected set, and every projectile's owner/gravity/
drag/stuck/lifetime/subtype state, invulnerability windows, catalyst bloom, AI/ambient timers,
per-entity RNG and Piglin barter/zombification. Exact 4,096-record success and 4,097-record pre-allocation rejection,
legacy-default migration-only behavior, repeated restart canonical bytes and stable digests are
mandatory.

Before the first RPG delta for a chunk in a mutation lineage, a durable **full-base barrier** is
mandatory. Under the world-mutation coordinator, preparation builds the strict pre-mutation
`LANCanonicalChunkStateV1`: an absent/entity-only row regenerates deterministic cells/biomes from
the exact seed/preset and merges all strictly validated preserved block entities/entities; a saved
entity tail suppresses generated entities, and any malformed tail blocks hosting even when blocks
could be regenerated. A valid
legacy full row is strictly converted; a corrupt row may use only an already loaded canonical live
chunk with verified provenance, otherwise load fails closed. No corrupted/clamped bytes are treated
as a base. Preparation advances only `captureSequence` (the pre-mutation `worldMutationVersion`
remains unchanged), stamps current lineage and committed checkpoint watermark, reserves/encodes the
full row, and commits metadata plus base through the shared SaveDB executor. COMMIT returns a strict
`LANFullBaseBarrierTokenV1 {chunkKey,cas:LANCanonicalChunkCASV1}`.
Only after that token is durable, still matches an unchanged live mutation version, and is reserved
by the prepared commit may the RPG memory mutation and journal row publish. Concurrent ordinary/template/RPG mutation of that chunk is excluded until the barrier
finishes. Tests cover every absent/entity-only/legacy/corrupt/live provenance case, preserved entity
merge and collisions, all canonical-field sentinels/order permutations, unknown registries,
temporary overlays, digest domains, delta field masks, simultaneous first writers, and every crash
cut proving no live first delta exists without its durable full base.

### RPG journal coexistence with ordinary and maximum-template saves

The 512 block-entity limit applies only to closed RPG-causal deltas, never to a full chunk or legal
object template. `OBJECT_TEMPLATE_MAX_BLOCK_ENTITIES` remains 32,768. Template place/undo and
ordinary world mutation are forbidden inside `RPGPreparedCommit`; they continue through bounded
tick-sliced jobs and the base-chunk save path.

World metadata stores the world-scoped `captureSequence: LANVersionedCounterV1`, and
`LANAutomaticCounterID.captureSequence` is mandatory. Before any RPG, ordinary, template, natural-
spawn or base-capture chunk mutation, `LANWorldMutationCoordinatorV1` verifies the exact contract
primitive above and takes a scratch successor (consecutive successors for
multiple chunks in stable chunk-key order), encodes/reserves the mutation and save work, and only
then atomically publishes the live mutation plus prospective metadata value. Scalar sequence values
reject. Rebase/outer terminal behavior is exactly the closed counter lifecycle; outer terminal stops
authority before mutation.

Each base chunk row stores the complete canonical envelope, content, `contentDigest`,
`envelopeDigest` and `LANCanonicalChunkCASV1`. An RPG
checkpoint atomically persists the prospective world metadata counter and appends exact causal
deltas to `lan_rpg_world_mutation_v6` with their chunk sequence and generation. Ordinary/template
SaveDB writes persist metadata and chunk capture together through the same serial executor. Each
conditional update names the exact expected and proposed `LANCanonicalChunkCASV1` values;
`changes == 1` is required. A retry is idempotent only when the complete stored proposed CAS and
canonical content bytes are byte-equal. Any other stale/newer envelope, content or digest is a conflict that retains
dirty work and stops authority; it is never accepted merely because its number is newer.

If an RPG delta targets a chunk with any earlier live ordinary/template mutation not yet represented
by a durable full base, the coordinator first performs the full-base barrier above and waits for its
COMMIT. Only that durable canonical preimage may become the delta's `preStateDigest`.
A capture after an RPG mutation carries `requiresCheckpointGeneration` and the serial SaveDB
executor cannot commit it until that checkpoint commits; because the capture is later and complete,
it necessarily contains that RPG delta. The same transaction may then advance the chunk watermark
and delete journal deltas at or below it. Save-queue order is stable by capture sequence; any observed
reordering/mismatched lineage/CAS stops authority and retains both dirty capture and journal.

Restart validates that metadata is live, every chunk/journal sequence is in the same world lineage
and no greater than the durable metadata sequence, then resumes from that exact pair. Tests cover
max-1/max/rebase/outer terminal, multi-chunk prospective reservation failure, crash before/after
metadata and chunk statements, stale queued captures on both sides of rebase, concurrent chunks,
restart and lexicographic CAS; no test may observe a mutation without its allocated sequence.

Thus a template-dense chunk may encode all 32,768 legal block entities through the ordinary chunk
row without entering the 512-delta arena, while owner cost and the small causal delta remain atomic
through the journal. Template jobs step once per fixed tick only in phase `0x0F`, after all earlier
RPG/world preparation but before the one coherent publication, in stable ordinal order. Tests place
and undo a maximum 32,768-block-entity template, run eight maximum
jobs, interleave ordinary/template/RPG writes to the same chunk in every enqueue/commit order, stall
SQLite, hit the 512 causal-delta cap, inject CAS/disk failure, and prove no lost delta, stale full-
chunk overwrite, partial owner cost, or template rejection caused solely by the RPG cap.

### Bounded live journal compactor and backpressure

`LANRPGJournalBudgetV1` accounts actual encoded row/payload/manifest bytes plus 512-byte row/index
overhead across **durable unwatermarked + reserved + in-flight + pending** journal work. Under one
budget lock their sum may never exceed 128 delta rows or 67,108,864 bytes. Reservation occurs before
request consumption or tick publication and transfers, without double-counting, through those four
states. At 96 rows or 50,331,648 bytes the single serial `LANRPGJournalCompactor` starts in stable
chunk-key/watermark order; it also runs synchronously whenever a proposed reservation would exceed
the hard cap. Its dirty set is capped to the same 128 stable chunk keys. A separate pre-reserved
67,108,864-byte canonical-base output arena is never charged to journal occupancy, so compaction can
run when the journal is completely full.

An entity upsert journal operation never embeds canonical entity bytes in the 524,288-byte causal
delta. It contains exactly one
`LANPrimaryEntityJournalReferenceV1 {checkpointGeneration,persistentKey,recordDigest,
primaryRowDigest}` naming the generation-scoped row in
`LANPrimaryPersistentEntityCheckpointSegmentV1`; deletion names only key/expected digest. Each
journal delta may carry at most one such upsert reference, so a maximum 1,048,576-byte legal entity
record remains replayable without violating the causal-row cap. The referenced primary row is part
of the same checkpoint/component manifest and must validate before applying the journal delta.

`LANPrimaryEntityJournalRetentionBudgetV1` covers referenced generation-scoped primary rows across
durable + reserved + in-flight + pending work: exactly 128 rows and 134,742,016 encoded-accounted
bytes, because each row is at most 1,048,576 canonical bytes plus its already-defined 4,096 key/
envelope/digest/SQL/index charge. Reservation precedes delta reservation and transfers between the
four states without double charge. Coalescing by stable entity key may replace a pending row only
when no durable/in-flight journal entry still references the old generation; otherwise both rows
remain charged. A row is deleted only in the same transaction that removes the last manifest/
journal reference after its result is present in the canonical full base. At 96 rows or 101,056,512
bytes compaction starts; proposed cap+1 runs synchronous compaction or defers/stops under the same
policy as journal saturation. There is no inline-record fallback, dangling reference, uncharged
SQLite row or early deletion.

Cross-generation retention is closed by one
`LANPrimaryEntityRetentionManifestV1 {schema:1,mutationLineageID,entries,count,encodedBytes,root}`.
Each stable-key-sorted entry is exactly `{checkpointGeneration,persistentKey,recordDigest,
primaryRowDigest,referenceCount,referenceDigest}`. `referenceDigest` is
`SHA256("Pebble-LAN-v6-primary-retention-refs\0" ||` every canonical length-prefixed live journal
membership key `(checkpointGeneration,chunkKey,captureSequence,stableDeltaKey,rowDigest)` in sorted
order `)`. `root` is `SHA256("Pebble-LAN-v6-primary-retention-root\0" || UInt32BE(count) ||
UInt64BE(encodedBytes) ||` every length-prefixed canonical entry `)`. Count is `0...128`; encoded
bytes charge the referenced primary rows and must be `0...134,742,016`.
Each retention-entry row/index is charged inside its referenced primary row's existing 4,096-byte
key/envelope/digest/SQL/index allowance, so this manifest adds no hidden checkpoint-arena component.

The journal-manifest chain has one byte-exact codec. `LANRPGJournalManifestV1` begins with this
168-byte big-endian header, followed immediately by its ordinary membership entries and no trailing
bytes:

| Offset | Bytes | Exact field |
| ---: | ---: | --- |
| 0 | 4 | ASCII `LRJM` |
| 4 | 2 | schema `1` |
| 6 | 2 | flags/reserved `0` |
| 8 | 16 | raw `mutationLineageID` |
| 24 | 8 | checkpoint generation/value `UInt32BE` |
| 32 | 8 | previous-manifest generation/value `UInt32BE` |
| 40 | 32 | previous-manifest digest |
| 72 | 4 | ordinary membership count `UInt32BE` |
| 76 | 8 | ordinary accounted bytes `UInt64BE` |
| 84 | 32 | ordinary membership SHA-256 |
| 116 | 4 | generation-local primary count `UInt32BE` |
| 120 | 8 | generation-local primary accounted bytes `UInt64BE` |
| 128 | 32 | generation-local primary retention root |
| 160 | 8 | ordinary entries byte length `UInt64BE` |

Each sorted ordinary entry is `entryLength:UInt32BE` followed by exactly
`dimension:UInt8,zero[3],chunkX:Int32BE,chunkZ:Int32BE,captureGeneration:UInt32BE,
captureValue:UInt32BE,stableDeltaKeyLength:UInt16BE,zero:UInt16BE,stableDeltaKey,rowDigest[32]`.
The key is 1...128 bytes, `entryLength` is exactly `56 + keyLength` and excludes its four-byte
prefix, and entries sort by `(dimension,chunkZ,chunkX,captureGeneration,captureValue,
stableDeltaKeyBytes)`. `entriesByteLength` is `sum(4 + entryLength)`. Reserved/trailing bytes,
duplicate keys, scalar generations and a count/length/byte mismatch reject.

`ordinaryMembershipSHA = SHA256("Pebble-LAN-v6-journal-membership-v1\0" || UInt32BE(count) ||
UInt64BE(accountedBytes) || exactEntriesBytes)`. The manifest row's separately stored
`manifestDigest = SHA256("Pebble-LAN-v6-journal-manifest-chain-v1\0" ||
UInt32BE(168 + entriesByteLength) || exactHeaderAndEntriesBytes)`. Thus the digest binds lineage,
full generation/predecessor, ordinary membership SHA and the generation-local retention root in one
named domain; JSON, native-endian structs and a generic SHA are forbidden.

The lineage-bound empty anchor generation is exactly `{0,0}` and
`emptyAnchorDigest = SHA256("Pebble-LAN-v6-journal-chain-empty-v1\0" || mutationLineageID ||
UInt32BE(0) || UInt32BE(0))`. Fresh-world creation and existing-world baseline enrollment atomically
store the empty global retention root, anchor generation/digest and identical tip generation/digest
with the new lineage, while creating no manifest row. First append names that anchor as predecessor.
Prefix prune advances the anchor to the pruned manifest's exact generation/digest; when no live
manifest remains, tip generation/digest must equal the anchor. `LANJournalManifestChainVectors.json`
fixes every header/entry byte, membership SHA, manifest digest, global root, anchor and metadata for
fresh empty, enrolled empty, first append, second append, first-prefix prune and final prune-to-empty.

Only latest committed world/checkpoint metadata stores the current global
`{primaryRetentionCount,primaryRetentionBytes,primaryRetentionRoot}` plus
`{retentionChainAnchorGeneration,retentionChainAnchorDigest,retentionChainTipGeneration,
retentionChainTipDigest}`. Each live
`LANRPGJournalManifestV1` is immutable and stores only its generation-local primary membership
`{primaryGenerationCount,primaryGenerationBytes,primaryGenerationRoot}` plus
`{previousManifestGeneration,previousManifestDigest}`. Its generation root uses the same canonical
entry encoding/domain with only references introduced by that journal generation; its canonical
manifest digest covers those fields and all ordinary journal membership. An append never rewrites an
older manifest.

Appending generation G atomically inserts/retains its primary rows, writes journal rows and one new
immutable manifest whose previous digest is the old chain tip, recomputes the global 128-row
retention manifest/root, and CAS-updates latest metadata to the new count/bytes/root and chain tip.
Rollback leaves the old tip/global root and no G rows. To preserve an immutable verifiable chain,
retention pruning is oldest-live-generation prefix only: the compactor may prepare bases in bounded
steps, but it retains that generation's rows/manifest until every membership is proven represented
in its canonical bases. One final transaction then deletes the whole oldest manifest and all its
compaction receipts/membership rows, decrements/deletes primary rows only for references not present in later
manifests, advances the chain anchor to the deleted manifest digest, recomputes the current global
root and publishes metadata. Later manifests remain byte-for-byte unchanged. A nonprefix prune,
partial manifest rewrite or row deletion before the final prefix transaction is forbidden.

Startup first reads latest metadata, then all live manifests in generation order, all generation
memberships/global retention entries and exactly their referenced primary rows under the 128-row/
134,742,016-byte cap. The first live manifest must link to the stored anchor; each later manifest
must link to the prior canonical digest; the last must equal the tip. Startup recomputes every
generation-local root, requires every membership to resolve to exactly one live journal row or
valid result-base receipt, recomputes reference count/digest and the union's current global
root/count/bytes. Missing/extra/unreferenced rows, a chain gap/fork, mixed lineage/generation,
ref-count mismatch, divergent current root or cap+1 leaves the world unpublished. Empty live state
requires anchor digest equal tip digest and the specified empty global root.

For one reconstructed chunk, the compactor snapshot records exact capture sequence and the maximum
represented `requiresCheckpointGeneration`, waits until that generation is durable, and uses the
strict hydration algorithm below. Then one SaveDB
transaction CASes the exact old `LANCanonicalChunkCASV1` to the complete new CAS/base, including
the specified included-generation/watermark transition, and replaces each covered journal row with
one bounded immutable `LANJournalCompactionReceiptV1 {mutationLineageID,manifestGeneration,
manifestDigest,previousManifestGeneration,previousManifestDigest,chunkKey,stableDeltaKey,rowDigest,
preBaseCAS,resultBaseCAS,receiptDigest}`. `receiptDigest` is
`SHA256("Pebble-LAN-v6-journal-compaction-receipt-v1\0" ||` canonical length-prefixed preceding
fields `)`; manifest generation/digests must match the immutable chain row exactly. The per-generation
manifest/membership bytes never change. An entry resolves to
exactly one live journal row or one receipt; receipts are charged to the same row/byte journal budget
and are never replayed. Only the oldest fully receipted generation is removed by the final prefix
transaction above. Budget is released only after that COMMIT. CAS loss, disk failure or crash retains
all durable/reserved accounting and dirty work. A request blocked at the hard cap defers without
consumption; reducer/physical work remains scratch. If compaction cannot make room by the existing
progress deadline, authority stops and peers close rather than dropping or publishing unjournaled
state.

The transaction that writes a first receipt for a chunk also installs
`LANReceiptedChunkBaseFreezeV1 {chunkKey,frozenBaseCAS,oldestManifestGeneration,receiptCount,
receiptRoot}`. `frozenBaseCAS` is byte-equal to every receipt's `resultBaseCAS`; `receiptRoot` hashes
receipts sorted by `(manifestGeneration,stableDeltaKey,receiptDigest)` exactly as
`SHA256("Pebble-LAN-v6-receipted-chunk-freeze-v1\0" || UInt32BE(receiptCount) ||` each
length-prefixed canonical receipt `)`. One base-compaction transaction may create receipts for
the same chunk from multiple contiguous manifest generations when that one `resultBaseCAS` includes
all of them; `oldestManifestGeneration` is their minimum. At most 128 frozen chunks/
receipts exist because they share the journal row/count/byte budget. `LANWorldMutationCoordinatorV1`
checks this gate before reserving any ordinary, template, RPG, natural-spawn, full-base barrier,
compactor, unload or save capture touching the chunk.

While frozen, no path may write or publish a base CAS newer than `frozenBaseCAS`. A mutation may
proceed only by encoding the same closed reference-form `LANRPGWorldDeltaV1` against the frozen base
plus its stable unwatermarked journal tail, reserving the existing journal/primary-retention budgets,
and durably appending that scratch delta before live publication. Small ordinary/natural/system
mutations may route through that path only when exactly representable and within its atomic caps;
template steps, full-base barriers/captures, unload saves and over-cap mutations defer whole and
unchanged. After the freeze row exists, a later compactor may prepare but cannot install another base
or extend its receipt set for that chunk.
There is no side queue: allowed scratch shares 128 rows/67,108,864 bytes and 128 retained-primary
rows/134,742,016 bytes. A request that cannot reserve remains unconsumed; autonomous dirty work
forces progress on the oldest manifest prefix and, if it cannot advance within the progress
deadline, stops hosted authority with all state retained.

Restart loads/validates manifest ancestry, receipts and freezes before chunk hydration. Each stored
base must equal its freeze CAS; an absent, older or newer base, mismatched receipt root or unjournaled
capture rejects the world. Later allowed journal rows replay only into isolated/live state above the
frozen base and cannot trigger a repair write. The oldest-prefix prune transaction revalidates every
receipt/base/manifest digest and loads the exact expected old freeze plus the complete remaining
receipt set in the canonical order above. If receipts remain after deleting the pruned manifest, it
must CAS the full row to
`{same chunkKey,same frozenBaseCAS,oldestManifestGeneration:minRemainingGeneration,
receiptCount:remaining.count,receiptRoot:recomputedRemainingRoot}`. The `UPDATE` predicate names the
exact old chunk key, frozen CAS, oldest generation, count and root and requires `changes == 1`. If no
receipt remains, an exact-full-old-row `DELETE` with `changes == 1` is mandatory. Only in the same
transaction may it advance the chain anchor/global retention root and delete manifest/receipt/
retention rows. Any missing/extra/duplicate receipt, root/count/minimum mismatch or zero/multiple-row
CAS result rolls back every prune write. Freeze update/deletion is visible only after COMMIT;
deferred captures may allocate a later CAS on the next
coordinator turn. Every crash therefore leaves either the old manifest+receipt+frozen CAS or the new
anchor with the exact reduced freeze (or no freeze when empty) and the same exact base—never a later
base that supersedes a live receipt.

The fixed same-chunk partial-prune vector starts with receipts from G1 and G2 sharing base CAS B and
freeze `{oldest:G1,count:2,root:R12}`. Pruning G1 must produce anchor G1 plus unchanged B and freeze
`{oldest:G2,count:1,root:R2}`; restart must reproduce that row before any mutation. Pruning G2 then
deletes the freeze. Tests cut before/after the receipt select, every manifest/receipt/retention/base/
metadata/freeze statement and COMMIT in both prunes, and inject stale old rows plus missing, extra,
or duplicated receipts; reversed/permuted storage order must sort to the same R12/R2. Every cut
yields exactly the complete old or complete new tuple.

Tests fill 127/128/129 rows and dirty keys, remove/exhaust the separate output reserve, and hit every byte boundary across all four accounting states, race reserve/
checkpoint/compaction/retry, compact while template/ordinary captures target the same chunk, inject
every CAS/statement/COMMIT/crash failure, restart with a full budget, and prove deterministic
backpressure, exact release, no oversubscription and no lost journal row.

### Normative RPG-journal hydration and compaction

World load first validates the committed world/checkpoint metadata and `mutationLineageID`, then
selects exactly its latest durable checkpoint generation. That metadata contains a closed
`LANAuthorityCheckpointComponentManifestV1` with fixed-order `{count,encodedBytes,sha256}` entries
for owners, RPG chunk deltas, block-entity deltas, primary entity records, primary-retention entries,
entity bindings,
temporary/delayed/general tombstones, relation deltas/tombstones, world RNG rows and fishing-session
active/deletion rows, scheduled-lightning/fang active/deletion rows, and scheduled-block/raid task
deltas. Each digest covers canonical length-prefixed stable-key-sorted rows including
their checkpoint generation; an empty component has count/bytes zero and the specified SHA-256 of
empty input. Hydration bounded-reads exactly those rows, recomputes every entry, validates every
expected/result CAS chain from the previous durable generation and rejects a missing, extra,
duplicate, future or mixed-generation row.

The RNG component must contain exactly the nine unique stream tags and valid word/draw-count pairs.
The fishing component must contain at most one active row or deletion tombstone per owner and must
agree bidirectionally with owner `fishingSessionID`, every `fishingHook` relation/index entry and all
reserved reel keys. Primary entity rows must satisfy the 1,048,576-byte canonical-record cap and
their binding/relation digests. Every entity-upsert journal operation must resolve its exact
generation/key/record/row digest to one retained primary row; an unreferenced duplicate, missing row,
cross-generation alias or row compacted without the corresponding base result rejects load. Only
after those components and the chunk reconstruction below all
validate does hydration install RNG words/counts, owners, canonical entities, bindings, relations,
descriptors/fishing sessions and projections in the prescribed publication order. No default RNG
seed, dropped session, synthetic owner binding or relation repair is permitted; failure leaves the
entire world unpublished and retryable.

World load then
reconstructs each chunk in an isolated copy from its full canonical base plus committed
`lan_rpg_world_mutation_v6` rows strictly above that base's watermark and no later than the committed
checkpoint generation. A checkpoint has a closed `LANRPGJournalManifestV1` if and only if it commits
at least one world-delta row; an owner/descriptor-only checkpoint writes no journal manifest and
reserves zero journal rows/bytes. Its semantic fields, encoded only by the exact binary codec above,
are `{lineage,generation,entries[{chunkKey,captureSequence,stableDeltaKey,rowDigest}],count,bytes,
ordinaryMembershipSHA,
primaryGenerationCount,primaryGenerationBytes,primaryGenerationRoot,previousManifestGeneration,
previousManifestDigest}`;
`count` is `1...128`, `ordinaryMembershipSHA` uses the named formula above, and
count/bytes must equal the complete durable membership and fit the live journal cap. A durable empty
manifest, delta without a manifest or manifest without a delta rejects load. When compaction removes
the final live row it leaves the immutable manifest plus complete receipts; only the oldest fully
receipted manifest is pruned by the atomic chain-anchor transaction. Rollback retains the prior live
row/receipt state.

A journal row is the closed record `{worldStorageID,mutationLineageID,checkpointGeneration,
predecessorGeneration,captureSequence,chunkKey,stableDeltaKey,deltaOrdinal,deltaCount,preStateDigest,
postStateDigest,beforeEnvelope,afterEnvelope,payload,rowDigest}`; `preStateDigest/postStateDigest`
are the before/after content digests. Hydration selects only committed rows with exact one-to-one
manifest membership, verifies every row digest and manifest SHA-256, and applies in stable
`(dimension,chunkZ,chunkX,checkpointGeneration,captureSequence,stableDeltaKey)` order through the
bounded window. Decoding a later row cannot publish or discard the prior isolated result.
The payload closed sum's `putEntity` case contains only the retained-primary-row reference above;
hydration streams that row through the strict entity decoder. It never treats the causal payload's
524,288-byte ceiling as an entity-record ceiling.

For each chunk, a strict full-base barrier and matching lineage are mandatory. The first predecessor must equal its watermark, each later predecessor must equal
the prior applied generation, ordinals must be exactly contiguous `0..<deltaCount`, capture
sequences must increase lexicographically within the same world lineage, and the first/current
content digest must equal `preStateDigest`; applying the strict delta must produce
`postStateDigest` and the exact normative envelope transition. Duplicate keys/ordinals, gaps, conflicts, unknown payloads, scalar counters,
missing base/lineage/manifest membership, empty manifest, manifest count/byte/SHA mismatch, uncommitted/future generations, digest mismatch or an entry above durable
metadata fails the whole load closed. No entity, projectile, owner, temporary effect, delayed
descriptor, proxy or render chunk publishes until every required chunk and owner generation has
passed this reconstruction.

Before publication, each reconstructed chunk is compacted by one SaveDB transaction that CASes its
exact old `LANCanonicalChunkCASV1`, writes the complete canonical base with the exact new CAS and
`includedCheckpointGeneration`, advances `rpgCheckpointWatermark` to the last applied generation,
and replaces exactly the consumed rows with compaction receipts while leaving manifest membership
immutable. COMMIT yields new base plus receipts; rollback yields old base plus live rows. A watermark
update and deletion can never occur separately, and an ordinary/template capture may compact only
after satisfying its declared checkpoint dependency. Failure leaves the world unpublished and retryable. Tests inject every cut
across base read, window boundaries, delta apply, upsert/watermark/delete/COMMIT and publication;
permute same-chunk RPG/template captures; and cover empty chains, multiple generations, rebase,
gaps, exact/conflicting duplicates, stale/future rows, missing lineage/base/barrier, bad row/manifest/pre/post digests,
atomic compaction retry and byte-identical restart. A million consecutive owner-only changing ticks/
checkpoints must create zero journal manifests/deltas, consume zero journal-budget bytes and leave
compactor/output activity at zero; mixed owner/world ticks prove the iff transition and deterministic
empty pruning at every crash cut.

Add one SaveDB `commitLANAuthorityCheckpoint` transaction. A checkpoint has a versioned generation
and atomically writes world metadata/prospective global RPG tick, RPG-causal world-journal and
block-entity/entity-binding deltas, the primary persistent-entity record segment, all referenced
relation owner/entity records plus relation-index/tombstone deltas, exact columns in all affected
`lan_peer_authority_checkpoint_v6` rows, the `lan_host_local_authority_checkpoint_v6` row, exactly
all nine world-RNG stream rows, the complete fishing-session active/deletion map with owner bindings,
the complete scheduled-lightning/fang active/deletion map, scheduled-block/raid task deltas and
active temporary/delayed descriptors plus tombstone creations/removals. Every keyed SQL write
uses the segment's earliest expected digest/value as its `WHERE` CAS and its latest result as the
only inserted/updated/deleted state; zero or multiple affected rows rolls back the whole transaction.
The immutable input type has no credential,
token hash, pending generation, handshake, expiry, secret-index, host/world identity, or permission
field. Prepared SQL uses explicit `UPDATE`/`INSERT` column lists and never row-wide replace.

`commitLANAuthorityCheckpoint` is denied access to `lan_peer_credentials_v6`,
`lan_peer_token_index_v6`, nonce/claim indexes, identity, and permission tables; credential CAS
helpers are denied access to authority/world checkpoint tables. Enforce this with separate typed DB
APIs and a test/debug SQLite authorizer over statement preparation. A checkpoint captured before a
token rotation but executed after it therefore cannot restore the captured token tuple because it
possesses neither those columns nor table authority. Independent periodic owner writes are removed;
no owner revision may become durable without the world/chunk state it acknowledges. On main, the
stager activates only the already bounded, encoded, and reserved immutable checkpoint segments
produced before live publication; the save queue moves that input into the single in-flight arena,
then commits all-or-nothing under the database transaction lock.

An ack is memory-authoritative as soon as prepared commit succeeds and remains replayable in the
live session even before disk checkpoint completion. A crash before commit completion rolls back to
the previous coherent checkpoint; restart rotates session epoch and request-zero publishes exactly
that coherent state. It must never load a new owner revision with old world loot/blocks, or new
world mutations with an old owner cost. Graceful host stop, lifecycle cleanup, and shutdown perform
a synchronous coherent checkpoint before socket/world teardown and surface a failed final commit.

Client durability uses one `commitLANClientAuthorityCheckpoint` transaction keyed by the stable
host/world lookup key. Its input is a completely decoded and validated immutable candidate and it
updates up to three logical, separately byte-capped state rows plus an optional notification-inbox
insert, never one unbounded aggregate. A component
may be explicitly unchanged and a brand-new client may have no owner row until request-zero, but
every component changed by one protocol transition is committed in the same transaction:

1. `LANClientOwnerCheckpointRowV1` (786,432 bytes before decode) contains exact canonical owner
   bytes, the nine client-local quick slots, session epoch, snapshot ID, simulation tick,
   owner/inventory revisions, credential generation, and last applied checkpoint generation.
2. `LANClientCredentialRowV1` (65,536 bytes before decode) contains host ID, world ID, lookup key,
   active raw token/generation and optional pending raw token/generation/handshake/expiry fallback.
   It contains no socket/runtime lease.
3. `LANClientPendingDispositionRowV1` (131,072 bytes before decode) contains zero or one exact raw
   request plus epoch/request/expected authority revision/policy-required inventory revision/
   operation/send state, mode `awaitingState` or the
   full `dispositionOnly` request-zero binding.
4. `LANClientNotificationInboxV1` is a separate table bounded to 256 rows/1,048,576 encoded bytes
   per host/world. A terminal insert contains unique deterministic
   `notificationID = SHA256("Pebble-LAN-v6-notice\0" || hid[16] || wid[16] || epoch[16] ||
   UInt64BE(requestID))`, exact
   request/epoch/snapshot/status/reason/message, a digest of the fully validated bundle-record
   identity for audit/deduplication (`SHA256` over length-prefixed exact manifest payload, canonical
   owner bytes and canonical chunk-binding encoding), creation checkpoint generation, and state
   `pendingRender|acknowledged`. Unique `(hid,wid,epoch,requestID)` forbids two outcomes.

The implementation encodes and checks all three state-row caps plus the inbox row/aggregate caps,
decodes candidates back through the strict validators, then enters the client DB transaction. The transaction uses expected old checkpoint
generation as a CAS and writes owner/slots/tick/revisions, credential promotion/rotation, and
pending/disposition transition or clear plus any inbox insertion all-or-nothing. A disposition-only
outcome leaves owner-row bytes unchanged but still CAS-commits its pending clear and inbox row. Only
after a
successful SQLite COMMIT does main-thread code install the candidate owner and slots, update
in-memory epoch/tick/revisions/credentials, insert `AppliedOwnerBundleRecord`, clear/transition
pending, and wake the inbox renderer, in that order under one reentrancy guard. It does not directly
render the outcome. Memory is never acknowledged first.

Encode, validation, BEGIN, statement, CAS, disk-full, and COMMIT failure leave all live client
state, credentials, pending state, applied-record FIFO, and inbox unchanged; the active bundle is
discarded, the connection closes, and reconnect retries from durable state. There is no crash point
at which the client forgets both active and pending credentials, promotes a token without its
pending request, marks a request cleared before the matching bundle/disposition is durable, or
publishes owner state that restart cannot reproduce. Startup validates each row under its own cap
before combining only matching host/world/checkpoint generations.

Notification delivery is a durable inbox/outbox protocol. Before a terminal checkpoint insert, the
transaction prunes only acknowledged rows in stable `(ackGeneration,notificationID)` order; it
never evicts `pendingRender`. If the row/byte cap still cannot admit the new row, the entire client
checkpoint fails, pending remains, and the connection closes for retry. After commit, the main/UI
renderer reads `pendingRender` rows in creation order and calls an idempotent
`upsertProgressionNotification(notificationID,payload)`. Only after that UI-model upsert succeeds
does a separate `ackLANClientNotification(notificationID,expectedPayloadDigest)` transaction mark
the row acknowledged. Bundle/replay code cannot acknowledge or delete it.

Crash semantics are explicit: crash before the authority commit retains pending and no inbox row;
crash after commit but before render replays the inbox row on startup; crash after UI upsert but
before ack may call the same upsert again, which replaces/deduplicates by stable ID; crash after ack
does not render again. This guarantees exactly one durable terminal row and idempotent UI-model
identity, with **at-least-once visible delivery across a full process crash**—not an impossible claim
of exactly-once human perception. Existing applied-bundle replay inserts nothing. Tests cut every
boundary, force cap pressure/disk failure, restart repeatedly, and assert no lost terminal outcome,
no duplicate inbox ID, and no pending clear without its inbox row.

Host and client database work share an explicit locking contract. One queue-specific
`SaveDBExecutor` serializes all SQLite access; transaction helpers use an executor-owned
`SaveDBTransactionContext` and no public DB method synchronously re-enters the queue or starts an
implicit nested transaction. If legacy SaveDB helpers require recursive calls, they must reuse that
context (or a documented recursive lock inside the executor), never take a second independent DB
lock. Lock order is per-authority lock -> SaveDB executor -> SQLite transaction; DB callbacks never
call main/gameplay or acquire an authority lock. Debug preconditions and contention tests enforce
executor ownership, re-entry behavior, and lock order. The read-only secret-index discovery query
is the explicit exception: it runs with no authority lock, releases the executor completely, then
code acquires the discovered authority/claim lock and follows the normal lock -> executor order for
transactional revalidation. It never holds DB while acquiring a domain lock.

Failure-injection tests cut before and after every host and client checkpoint statement, simulate
process restart, and prove all-or-nothing host state, replay-until-crash semantics, new-epoch
reconciliation, graceful-stop durability, separate client row caps, CAS conflict handling,
credential/pending/disposition/inbox atomicity, no pre-COMMIT memory/inbox/render change, and exact
post-COMMIT restart reproduction. Interleaving tests capture checkpoint C, perform credential/index
CAS T, then execute C; execute C while T waits; crash before/after each T/C statement; and assert
the gameplay generation is coherent while the newest committed token tuple/index survives exactly.
Schema/authorizer tests fail any helper that names the other responsibility's table or uses
`INSERT OR REPLACE`/row-wide replacement.

## Required tests and installed proof

Focused suites must cover:

- frame and aggregate pre-decode byte boundaries, exact frame lengths, raw payloads, strict nested
  post-decode boundaries with no clamp, every exact ID/revision/ordinal/generation/string/effect/
  enchant/sherd/lodestone domain, request/credential exhaustion, strict sequences/directions/
  states, and each 786,432/65,536/131,072-byte client row boundary;
- all four `LANClientHelloV6` variants and exact common/variant key sets; every missing/extra/mixed/
  duplicate field; token+nonce/multiple-secret rejection; join-code lengths 3/4/8/9 and alphabet;
  unbiased deterministic rejection-sampling oracle; variant-preserving generic failures; and proof
  resume/legacy failure performs no scan, authority trust, fallback conversion, or allocation;
- stable host/world IDs and credential lookup across Bonjour rename/address changes; malformed or
  missing TXT; same-install copy/save-as/import versus explicit atomic move; duplicate registry,
  quarantine and crash-recovery refusal; world clone on another installation; tuple mismatch;
  production entropy for host/world/epoch/handshake/snapshot/delayed-descriptor/token/nonce/join IDs; CryptoKit known
  answer; CSPRNG failure with no fallback; constant-time comparison; exact endpoint/global hello
  bucket refill, normalization, churn, overflow, restart, and flood behavior;
- namespace rewrite of loaded/unloaded entities, bindings, projectiles and embedded keys at zero/
  maximum/one-over VCK2 record/row, 14,286,848-byte heap and 486,539,264-byte temporary-disk caps;
  pre-rewrite journal compaction; old/new world/storage/lineage and envelope/checkpoint rewrites;
  recomputed leaf/section/content/header/envelope/CAS/record/relation/binding/rolling digests with no
  source-digest equality assumption; deterministic delayed cancellation; all phase/statement
  crash cuts and idempotent resume; cast/bite/hooked/reelPending fishing cancellation with owner/hook/
  reservation cleanup and burned allocator high-water; final typed old-key-alias scan; explicit Move
  fishing/RNG/key byte preservation versus Copy RNG re-derivation; exact 32-byte source-row/
  132-byte copy-input serialization, digest extraction, nonzero escape, reset draw count and every
  `LANEntityRNGCopyVectors.json` byte; and
  proof no publication/hosting occurs before verified registry commit;
- concurrent ordinal allocation; token hashing; persisted-tuple versus runtime-lease separation;
  query-plan/index-only `(hid,wid,tokenHash|nonceHash)` discovery; atomic tuple/index creation,
  replacement, promotion, expiry and rollback; orphan/collision/generic-failure behavior;
  per-authority/SaveDB lock ordering; active/pending/socket-generation/connection/epoch lease races;
  pending-token resume without token resend; pending-first/active-fallback reconnect; lost
  accept/ready/request-zero; fresh handshake/expiry on every pending resume; host stop during every
  CAS/reserve/commit phase; CAS failures; epoch rotation; live-socket anti-eviction; terminal and
  generation/ordinal exhaustion; and pending-only expiry;
- detached legacy claim socket closure; nonce-hash storage/redaction; six-character code collision;
  approve/reject/expiry across host restart; reconnect nonce mismatch; simultaneous consume CAS;
  claim flood/caps; and proof no approval socket or display code authenticates;
- pre-authentication total/unauthenticated/pending-only caps, endpoint/global hello buckets,
  handshake and deferred progress deadlines, flood teardown, and honest-peer progress;
- strict bounded v6 persistence, Bool/type rejection, dirty checkpoint retry, coherent host/client
  crash cut points, and source/authorizer proof that neither host `lan_players` nor client
  `lan_player_resume` JSON can hydrate/write v6 authority or use `INSERT OR REPLACE`/`worldID#seed`;
- existing-world baseline zero/max/over-cap manifests, every crash/restart phase and installed
  upgrade; stable tail counts/key ranges/relation dispositions and allocator high-water under reverse/
  concurrent/restart migration; exact planning heap/temp-disk/WAL/page caps, staged-page recovery and
  small final-root publish; enrollment-pinned generator dispatch, compatible appends across all 14
  registry sections and hostile evolution; exact fresh/existing nine-stream initialization vectors,
  all-or-none first transaction and per-row crash recovery;
- exact 296-byte VCK2 header offsets, state schema, row/record-length formula, section/record widths,
  endian, tags, UTF-8, floats and optional absence; all 54 block-entity disposition rows; all 100
  entity kinds and 15-save/16-load field dispositions; transient-zero BE viewers/no ghost redstone;
  malformed zero-RNG/zero-allocation decode; exact VCK2 and generation-contract digest oracle vectors and 4-KiB measure/Merkle
  equality after insert/remove/reorder/multi-chunk changes; record/heap/temp-disk caps, disk-full and
  canonical permutation/property tests;
- immutable generation-contract row count/byte/FK/missing/collision/copy/checkpoint retention and
  mixed-version chunks; all five mutation sources through explicit contract-upgrade/save/journal/CAS
  ordering; all 14 prefix sections; pinned
  deferred-loot definitions and compatible append versus hostile loot evolution;
- every entity gameplay RNG/timer/flag sentinel, 1,200-tick restart trace equivalence, owner/entity
  relation target/lifecycle matrix, unloaded cross-chunk and reciprocal vehicle/passenger graphs,
  coherent relation checkpoints plus 4,096/4,097 inbound batch cleanup, copy/migration/crash behavior,
  every `LANPassengerCapacityV1` kind/state row and cap+1, deterministic capacity-reduction dismount;
  transitive factory-to-Entity superclass/extension/nested-state census with intermediate-class and
  inherited-override omissions; fresh/legacy/copy/Move entity-RNG genesis vectors and authoritative
  entity/fishing draw-count max/rebase/terminal/crash behavior; complete fishing physics/lifecycle/
  reel-reservation DTO plus required owner/hook relation matrix; keyed reel-reservation sequence
  max/rebase/terminal and zero-allocation exhaustion; domain-3 world-interaction expected/result/
  child bytes for host-local, guest, collision and same-byte retry vectors, exact ordinal-zero
  success and ordinal 1/255 rejection; domain-4 cast genesis expected/result/child bytes and atomic
  descriptor/owner/owner-edge/absent-hook commit across host, guest, retry, restart, rebase and
  terminal vectors; one immutable exact 524,288-entry/
  134,217,728-byte tick-start snapshot and 155,320,320-byte total working cap with category/page
  cap-1/cap/cap+1, first/last/every `LANWorldScheduleV1` phase create/delete/transfer sentinels and
  next-global-tick-only admission; keyed persistent-entity/fishing-session age full-pair
  rebase/terminal behavior including AreaEffectCloud generation agreement;
  all 27 Mob phase cases/order/path caps, per-kind RNG audit
  including non-Living kinds, all nine world RNG streams/draw counts, durable Blaze volleys, Ghast/
  Zombified timers, per-instance Horse speed, cloud target/tick pruning, XPOrb follow, Warden anger,
  durable exactly-once lightning and whole-16 evoker-fang scheduling with direct scheduled-row CAS
  delete + results, every statement/COMMIT cut and proof no resolving row exists; scheduled-block 131,072-row/
  512-delta and raid 256-row/64-delta persistence, every phase-to-RNG mapping, stable entity/BE/task
  iteration and Piglin admiration/item/zombification/barter exact-once;
- strict all-ten guest/host-local permission DTO/default/migration rows; one-field sentinels; trusted
  local UI/command/API full-row CAS, stale/concurrent/no-op/disk/crash/restart/rebase behavior; every
  remote mutation attempt; and intent/PvP permission changes across prepare/commit;
- every field/domain in the owner table at minimum/maximum/just-outside boundaries, including
  `selectedSlot`, `entityAge`, `foodTickTimer`, all nine closed stats, both closed PlayerEntityData
  death fields, every timer/flag, `-1` effects, tri-state ambient/particles, and
  durable damage immediately below/equal to durability; canonical equality through every capture/
  checkpoint/restart/ghost/preview/commit/client phase; source-declaration/field-disposition audit;
  every mapper sentinel/inverse oracle; rejection of every other EntityData/stat field;
  complete item metadata and closed stats;
  deep-copy/ghost hydration/preview independence; size/depth limits; zero/partial/all response
  suppression; duplicate active manifests/chunks; conflicts/future indexes; five-second timeout;
  exact `AppliedOwnerBundleRecord` manifest/canonical-byte/chunk-binding mutation; 32-record/24-MiB
  client FIFO; digest attacks; and durable-before-memory atomic apply;
- every RPG operation, six kits, 18 branches, all 19 active skills/17 spells permission metadata,
  and `RPGPreparedCommit` preview-bytes-equal-actual proof for every action and melee path including
  unbreaking/tool preservation, loot, temporary effects, RNG checkpoints, lethal kill, XP, and
  exactly measured/Merkle-rooted full post-chunk record/byte max/max+1 before owner/checkpoint mutation;
- structural-before-semantic ordering; cached semantic rejection; no-consume malformed/wrong-epoch/
  collision/future/defer; identical deferred no-op; differing deferred collision; disconnect/deadline
  invalidation; and no post-deadline commit;
- identical replay, collision, eviction, gap, full FIFO 32 at maximum owner size under 24 MiB per
  authenticated peer and 192 MiB across all eight authenticated peers, deterministic regenerated
  chunk bytes, reconnect, restart, send loss, accepted and
  rejected pending reconciliation after cleanup revision bumps, durable `dispositionOnly`, cached
  tuples lower/equal/higher in every revision/tick/credential dimension, outcome eviction, full
  cached-bundle authentication, and zero owner mutation from any disposition-only bundle;
- pure global guest state once per tick even while dimension/chunk unloaded; no catch-up;
  world-coupled gating/tombstones; host-menu ticking; client no-tick; 20/200-tick sync cadence;
  stale-prediction submission; every lifecycle trigger; tombstone reservation release/reuse;
  every bounded temporary descriptor kind and crash/hydration phase; active/expired/invalid restart;
  original/temporary/mismatched blocks; entity recreation; never-loaded restart; ghost/proxy
  cleanup; and idempotence;
- all ten temporary-effect kinds for `host:local` and eight guests in isolated reset scenarios, plus
  32 mixed-owner live descriptors/33rd rejection; host-local checkpoint/permission binding;
  restart/cleanup/counter-rebase; and scalar rejection for every
  owner sequence and temporary/delayed absolute tick field;
- the normative input -> physical simulation -> damage/effects/hunger -> complete proxy projection
  -> pure timed state -> delayed drain/action prepare -> canonical diff -> one revision -> checkpoint/private/public
  order; one-writer aggregate enforcement; callback permutation; post-projection guards; and ordinary
  movement/timer/hunger/effect dirtying with zero XP;
- self Interpose move/no duplicate, ordered mitigation layers, proxy physical-state projection,
  delayed Warden/Arcanist/Ranger/Mender XP, stable per-tick one-revision coalescing, disconnect
  removal, socket-supersession preservation, attacker-authority descriptor persistence, and
  current-rule/both-permission revalidation at actual delayed/area/secondary harm resolution;
- correct-dimension melee, 3-block reach, LOS/PvP, persisted cooldown, durability, XP, RNG, lethal
  progression, proxy convergence, complete private sync, and the default-false `pvp` plus both-peer
  `canPVP` truth table including prepare/commit races;
- client-origin kind-5 rejection; strict kind-10 numeric/type bounds; host-only pose/velocity/
  dimension/health authority; exact 10-at-40/s admission plus eight-strike/one-per-two-second
  tolerance including ninth-close and reconnect; immediate malformed close versus valid over-rate
  drop; coalescing/jump edge; collision/fall/portal/flight cheats; and prediction isolation;
- all GameCore APIs non-optimistic, one pending, local slot privacy/preservation, exact retry,
  request-zero `==`, `>`, and `<` pending reconciliation, matching stale cached outcome without
  state regression, no-record disposition first delivery, durable-commit-before-applied-record,
  existing-record exact replay/mismatch, malformed-bundle atomicity, durable notification unique
  insertion with pending clear, idempotent render/separate ack, cap failure, and every crash window;
- coherent checkpoint transaction of world metadata, causal journal, every affected owner, the
  64-record/67,371,008-byte primary persistent-entity segment, bindings/relations, all nine RNG rows,
  all nine fishing-session slots, 128 lightning/512 fang slots, 512 scheduled-block/64 raid deltas,
  plus delayed/temporary descriptors and tombstones;
  exact 165,188,160-byte component sum, 4,092-node/2,095,104 row/map overhead, 488,896 reserve and
  167,772,160/335,544,320 one/two-arena caps; deterministic keyed union/CAS and component-manifest
  hydration with missing/extra/mixed-generation rejection; physically separated credential/index versus
  authority tables; statement-authorizer/column isolation; stale captured checkpoint interleaved
  before/after token CAS and crash; no cross-generation peer write; crash rollback/new-epoch sync;
  synchronous graceful stop; strict serial DB executor/re-entry/lock-order contention; three separately capped client
  state rows plus bounded inbox; client CAS/disk/COMMIT failure before memory/inbox/render; and atomic owner/slots/epoch/tick/
  revisions/credentials/pending/disposition;
- world-scoped prospective `captureSequence` allocation/CAS/rebase/terminal/restart with stale
  queues and multi-chunk failures; base-plus-journal hydration above watermark with strict lineage,
  generation, sequence, ordinal, pre/post digest and gap/duplicate/conflict checks; publication only
  after stable replay; separate content/envelope barrier/delta/compaction transitions for every
  metadata field; journal-manifest iff nonempty, deterministic empty pruning and one million owner-
  only checkpoints with zero journal growth; logical four-state journal cap/backpressure; referenced
  maximum 1,048,576-byte entity upserts with the one reference-form `LANRPGWorldDeltaV1` in scratch/
  checkpoint/journal/replay and inline-record rejection; exact 128-row/134,742,016-byte retained-
  primary budget across all four states; immutable generation-local manifest roots/digest chain,
  exact 168-byte header/entry lengths/order/endian/reserved fields, ordinary-membership and manifest
  domain digests, lineage-bound empty anchor/fresh+baseline initialization, and fixed empty/append/
  prune vectors; metadata-only current global root/anchor/tip, ancestry-bound row-to-receipt
  replacement, startup chain/membership/union validation, append without old-manifest rewrite,
  oldest-prefix prune and every append/base/receipt/prune/metadata COMMIT crash cut, divergent root/
  reference rejection and early-delete rejection; receipted-chunk freeze across ordinary/template/
  RPG/natural-spawn/barrier/unload/save/capture paths, allowed journal routing, count/byte
  backpressure, restart, newer-base rejection and atomic thaw with no post-receipt base supersession;
  same-chunk G1+G2 `{G1,2,R12,B} -> {G2,1,R2,B} -> deleted` full-row CAS vector, canonical receipt
  sorting, stale/missing/extra/duplicate sets, every statement/COMMIT crash and restart boundary; and
  atomic base/watermark/primary-row/deletion compaction through every crash/interleaving;
- full ranked actor/lock contention permutations across registry/admission/source/claim/multi-owner/
  permission/world/journal/stager/compactor/save/DB/publication, including async stop and no sync wait;
- enumeration of every public host message builder proving no private RPG/slot/token content.

### Deterministic parser and state-machine property gate

Add deterministic seeded fuzz/property/metamorphic XCTest suites, not an optional manual fuzzer.
The checked-in root seed is `0x504542424C455636`; derive and run at least 10,000 cases for each of
the frame-stream decoder, closed hello sum, every v6 wire DTO, owner/item/effect DTOs, all client
state/inbox rows and physically separated host tables, credential/index/legacy/world-copy state
machines, owner reducer/tick ordering, movement/strike buckets, bundle/replay/reconciliation state
machines, and coherent checkpoint recovery model. A failure prints suite/seed/case and the minimized byte/event sequence;
rerunning that test reproduces it exactly.

Parser properties are: no trap, precondition failure, unbounded allocation, nonfinite escape, clamp,
partial mutation, request consumption, or notice on arbitrary bytes; accept implies every stated cap
and domain; canonical encode/decode/encode is byte-idempotent; valid boundary DTOs round-trip
field-equal. Streaming metamorphisms split/coalesce the same bytes at every header/payload boundary
and must produce the same frames; truncation adds no frame; one-bit/one-field/key-order/chunk-boundary
mutations either retain explicitly permitted semantic equivalence or produce the specified exact
replay collision, never a third behavior.

State-machine generators compare the implementation to a small pure reference model while
permuting duplicate/reordered frames, deadlines, socket close, restart/epoch rotation, host stop,
pending resume, legacy approve/reconnect, CAS failure, send-cap failure, request-zero reconciliation,
world copy/move/quarantine, disposition first delivery/replay, inbox render/ack, movement flood,
permission changes before delayed harm, descriptor hydration, physical callback permutations, and
every database crash cut. Metamorphic repetition of an
idempotent event cannot change state; swapping independent authorities cannot change either result;
and any accepted commit must conserve the declared owner/world/item/RNG delta. Allocation counters
assert every per-peer/global byte and count cap. These deterministic suites run under ordinary
`swift test` and the pipeline; a disabled, skipped, flaky, unreproducible, or reduced-case fuzz gate
is a release failure.

Extend the installed two-Mac probe. Before launch, SHA-256 of both installed Pebble executables
must match. Through public UI/input/transport paths, prove generated-code `joinNew`, indexed
one-token `resume`, detached `legacyClaim` socket close/approval and one-nonce `legacyConsume`; use a
bounded raw probe to prove a mixed/extra-field hello gets the generic rejection and creates no
identity; verify epoch/handshake/snapshot IDs rotate across the exercised boundaries without logging
them in full; upgrade a real pre-v6 world through baseline/manifest, visit one lazy-migrated chunk,
restart and verify stable IDs/canonical VCK2; then prove character creation and kit; local quick slots; suppressed-response retry
with one revision; local-host-only editing and restart persistence of all ten guest and host-local
permission fields; remote permission-mutation rejection; the world-rule/attacker/target `canPVP`
allow/deny matrix;
global clock/upkeep while host menus are open; guest melee in a dimension different from the host;
disconnect cleanup/tombstone/reconnect; token generation increase; quick-slot survival; host epoch
restart; and visible legacy Approve/Reject. Probe logs contain variant, indexed-lookup success/fail,
redacted ordinal/epoch prefix, request/revisions/tick/digest/status only—never join codes, tokens,
nonces, complete IDs, or payloads.

Final gates:

```bash
bash scripts/pipeline.sh
bash scripts/live-lan-test.sh --deploy --timeout 90
```

Any code change after installed proof invalidates it and requires redeploy and rerun.

## Residual plaintext-LAN risk

V6 is plaintext TCP/Bonjour: no TLS, authenticated encryption, forward secrecy, or host
certificate. A passive observer can read join codes and rotated tokens and later impersonate a
guest. An active LAN attacker can alter/drop traffic, steal credentials, or impersonate a host.
SHA-256 binds chunks against mixing/corruption but does not authenticate a malicious endpoint.
Document the feature as suitable only for a trusted LAN or separately secured tunnel, never
hostile Wi-Fi or internet exposure.

## Conditions for Builder

- Build in dependency order: production entropy, existing-world baseline, stable/unique host-world registry and bounded namespace rewrite;
  closed hello sum and strict join codes; bounded codec/state primitives and exact buckets; indexed
  secret tables plus separated credential/runtime CAS; sealed legacy quarantine; generator/registry
  contract table/upgrade and byte-exact VCK2; canonical chunk content/envelope/full-base barrier; canonical owner
  mapper/aggregate and host-only movement reducer; exhaustive item/temporary/delayed DTOs;
  transitive entity census plus RNG genesis/draw-count rows; full fishing relation/reservation DTO
  with ordinal-zero reel and cast-session interaction-stream split proofs;
  single reference-form entity delta plus cross-generation primary-retention manifest/root,
  byte-exact journal-chain codec and receipted-chunk base-freeze gate;
  durable lightning/fang/scheduled-block/raid stores; bounded tick snapshot/query and exact
  `LANWorldScheduleV1`;
  applied-bundle assembler; bounded replay/send ledger; required post-projection `RPGPreparedCommit`;
  authority transaction; client disposition/checkpoint/inbox; pure clock/world lifecycle; isolated
  coherent host checkpoints; PvP/melee; deterministic property gates; UI/probes/docs.
- Never trust a client identity, RPG state, sequence, revision, permission, dimension, target,
  item, or tick.
- `lan:<joinedOrdinal>` is immutable, host-issued, and never reused.
- `LANClientHelloV6` accepts only the four exact common-plus-variant key sets. At most one raw token/
  nonce appears; join code is strict CSPRNG `[A-Z0-9]{4,8}`; mixed/extra fields close; variant failure
  is generic and never scans, trusts authority, changes variant, or allocates fallback identity.
- Host stores no raw token. SQL CASes only the persisted credential tuple; epoch, connection ID,
  socket generation, deadline, and phase remain memory-only under one per-authority lock. Pending
  resume persists a fresh handshake/expiry and creates a fresh runtime lease; `clientReady` resends
  the token; all promotion/reserve/commit paths revalidate the exact lease. Host stop invalidates
  every lease/work item before closing. No concurrent or claimed ID displaces a live socket.
- Credential lookup is one unique `(hid,wid,secretHash)` index query before the returned domain lock;
  tuple and index updates are atomic. It uses the validated Bonjour host/world tuple, never endpoint,
  name, seed, scan, or hello authority. CryptoKit SHA-256 and `SecRandomCopyBytes` are mandatory for
  every production epoch/handshake/snapshot/credential/nonce/code with no insecure fallback.
- Local registry uniqueness is mandatory before advertisement. Same-install copy/import regenerates
  world/storage/lineage IDs, quarantines copied credentials, rekeys every persistent entity/projectile and
  cancels delayed descriptors and every fishing session/hook/reel reservation through one
  4,096-entity/32,768-block-entity/67,108,864-byte VCK2 row
  per transaction with 14,286,848 heap and 486,539,264 temporary-disk bytes. Only an explicit proven atomic
  move preserves IDs/keys. Any pending,
  ambiguous, corrupt, incomplete or old-key-bearing rewrite refuses publication and LAN hosting.
- Rekey recomputes every canonical measure leaf/root and content/header/envelope/CAS/record/relation/
  binding/rolling digest; source content/digest equality is forbidden and every digest-stage crash
  resumes idempotently before registry publication.
- Existing worlds atomically establish IDs/lineage/counters/host rows, pin the exact enrollment
  generator, all nine byte-exact initialized world RNG rows and immutable 14-section registry
  baseline, reserve stable per-tail entity-key ranges/
  relations and advance allocator high-water, and either finish VCK2
  conversion or commit the bounded verified lazy manifest before hosting. No manifested chunk
  publishes before exact pinned-generator migration; planning pre-reserves the itemized heap/disk/
  WAL/page arenas and publishes only verified staging roots in the small final transaction. Baseline
  crash recovery is idempotent.
- Every chunk-domain digest resolves through a bounded immutable content-addressed contract row.
  RPG, ordinary, template, natural-spawn and base-capture paths all use the generic coordinator;
  contract changes use the explicit expected/result upgrade transition, source-appropriate save/
  journal and CAS before any appended ID. Deferred loot resolves its pinned immutable definition,
  never mutable current state.
- Permission payloads are exactly ten strict Booleans. Only trusted local-host UI/command/API may
  mutate them, under the subject lock and complete-row/expected-version CAS; database COMMIT precedes
  memory/UI publication. V6 has no client permission frame, fallback or optimistic toggle.
- Enforce the 16-total-socket/8-handshake/8-authenticated-authority admission limits plus the
  separately bounded eight pending-only identities, exact 32-at-4/s global and 4-at-1/5s
  normalized-source hello buckets and bounded source map,
  ten-second progress deadlines, pending-only expiry, and no deferred commit after expiry/drop.
- Legacy approval is a detached hash-only 128-bit nonce claim: creating socket closes, display code
  is non-authenticating, and only one approved reconnect can CAS-consume the raw nonce.
- Host `lan_players` and client `lan_player_resume` are sealed read-only v5 quarantine only. Their
  generic JSON get/put/list/delete, `INSERT OR REPLACE`, `worldID#seed`, fallback hydration and
  downgrade paths do not exist in v6; a client stays ownerless until committed request-zero.
- No public message carries RPG state, quick slots, credentials, or private owner payload.
- Frame/snapshot/row caps are checked pre-decode; nested bounds are strict post-decode and
  pre-mutation unless a real custom parser is implemented. All exact ranges exhaust explicitly;
  nothing clamps or wraps.
- Structural admission and fallback replay/send reservation precede semantic validation. Every
  structurally valid exact-next semantic accept/reject is cached and consumed; malformed,
  collision, wrong epoch, future ID, and capacity defer are not.
- `RPGPreparedCommit` is mandatory. It captures complete gameplay RNG and all owner/world guards,
  produces exact post-owner/post-RNG preview, revalidates immediately before commit, and commits
  only nonthrowing precomputed assignments. No `hurt`, `damageHeld`, `resolveLoot`, RNG, or
  branch-capable callback occurs after the first write. Preview bytes equal actual bytes. Every
  prospective post-chunk has an exact `LANCanonicalChunkMeasureV1`/4-KiB Merkle measure and is fully reserved under all record/row caps
  before owner, RNG, request or checkpoint mutation.
- VCK2 encodes every nonderivable entity gameplay RNG word, timer and flag, including invulnerability,
  catalyst bloom and Piglin barter/zombification state. Only pure trace-equivalent scratch is rebuilt.
  The source census walks every registered concrete type's complete superclass/extension/nested-state
  closure. Every random-consuming registered kind, including non-Living kinds, has required
  simulation RNG words plus authoritative draw count; fresh, legacy, Copy and Move genesis follow the
  exact domains/vectors. The nine world RNG streams persist words/draw counts in the coherent
  checkpoint. Every tick uses one immutable exact 524,288-entry/155,320,320-working-byte snapshot,
  one 65,536-entry query page and the exact `0x01...0x0F` `LANWorldScheduleV1`; later creations wait
  until the next global tick.
  Mob goal/nav/look/
  target phase is the bounded closed sum; Blaze volleys, lightning and evoker fangs are durable
  records, not closures/process queues; fishing has the complete reciprocal owner/hook and reel-
  reservation lifecycle plus atomic domain-4 session-RNG genesis; scheduled blocks and raids are
  bounded durable task rows; Ghast and
  Zombified timers, Horse speed, cloud target/tick entries, XPOrb follow and bounded Warden anger are
  lossless. Entity/BE simulation uses stable canonical order, never insertion order.
  Persistent references use the entity-or-owner sum and closed target/lifecycle rows; vehicle/
  passenger edges live on base Entity and are reciprocal, sorted, bounded and acyclic across loaded/
  unloaded chunks, and every registered kind/state obeys the numeric passenger-capacity table.
  Relation checkpoints atomically cover owner/entity records, bindings and index;
  overlarge inbound cleanup uses bounded publication-blocking tombstone batches. BE
  `viewers` always rebuilds zero/nil and never persists comparator power.
- Exact requests and semantic rejections are replayable from exact request/manifest plus canonical
  owner bytes; fixed chunks regenerate byte-identically within FIFO 32, 24 MiB per authenticated
  peer, and 192 MiB globally across the maximum eight authenticated peers.
- Active bundle duplicate handling, full `AppliedOwnerBundleRecord` identity, client FIFO 32/
  24-MiB accounting, and five-second incomplete timeout are exact. No duplicate resets progress,
  no conflicting/future data is buffered, and no key-only replay is accepted; complete byte-exact replay
  causes neither mutation nor notice.
- Same-epoch request-zero reconciliation follows the normative `==`, `>`, and `<` table. A matching
  `>` checkpoint durably marks `dispositionOnly`; its cached bundle is fully authenticated but can
  install only terminal outcome, never owner state, for lower/equal/higher revisions/tick/generation.
  First delivery with no record fully validates, commits pending-clear plus inbox, then creates the
  record; an existing record suppresses only exact replay and mismatch closes. New epoch discards
  old pending atomically.
- Broad owner sync, inventory, discrete RPG authority, frame, and request revisions remain distinct
  and nonwrapping. Requests never compare broad owner revision; all compare current post-projection
  discrete authority revision and compare inventory revision only under the closed operation policy.
- Client RPG/pose authority is never optimistic; kind 10 is bounded input and kind 5 is host-only.
  Movement uses exact admission/tolerance buckets: valid over-rate drops consume one of eight
  refilling strikes and the ninth closes; malformed structure closes immediately, never as a drop.
  Quick slots remain local and assignment/clear never mutates authoritative selected action.
- Global ticks are strict/non-poisonable. Pure fatigue/cooldown/upkeep/melee state advances exactly
  once per connected peer per tick regardless of world loading, with no catch-up; only
  world-coupled work is load-gated. Host menus keep ticking. World clock/weather, scheduled/random
  blocks, BEs, persistent entities, triggers, descriptor continuations, spawning, raids, patrols,
  weather mutations, owner post-world work and template steps occur only in their declared phase and
  RNG mapping. All phase categories and authoritative queries consume the same immutable tick-start
  membership/order snapshot; removal only marks
  inactive and creation/recreation/transfer cannot run until the next tick. Sync obeys the 20-tick coalescing,
  immediate-boundary/delayed-progression, and 200-changing-tick checkpoint rules. Client predicted
  fatigue/cooldown cannot be the sole rejection reason.
- World metadata owns versioned `captureSequence`; every RPG/ordinary/template/natural-spawn/base-
  capture chunk mutation
  prospectively reserves its sequence and durable work before publication. Full-pair CAS, rebase,
  restart validation and outer-terminal behavior follow the automatic-counter manifest. Canonical
  content digest excludes its versioned envelope; barrier, each delta and compaction use the exact
  specified capture/mutation/watermark/included transition and bound generator/registry contract.
- Ghost/proxy causal layers retain ghost authority/sequence/credit, self Interpose moves rather than
  copies, proxy physical damage projects back, and all delayed class XP coalesces into one owner
  revision/persist/sync per tick. Every delayed Player-harm descriptor carries attacker authority and
  revalidates current `pvp` plus both current `canPVP` at actual resolution; failure causes zero harm/
  status/XP. Cleanup removes layers except on authenticated supersession.
- `LANHostedOwnerAggregateV1` is the sole canonical writer. Each tick strictly orders input,
  physical simulation, damage/effects/hunger, complete proxy projection, pure timed state, delayed
  drain and post-projection action preparation, canonical diff, one revision, checkpoint capture, private
  bundle, then public projection. Every ordinary physical diff marks dirty even without XP.
- Every terminal path uses centralized exact-owner cleanup before persistence/socket removal.
- Every guarded effect has a bounded descriptor with its original data in the coherent checkpoint,
  hydrates before publication, and ends through one atomic restore-or-tombstone path. Temporary
  owner authority is guest or `host:local`; every owner sequence/absolute tick is a strict versioned
  counter with checked distance, and host effects bind the host checkpoint/permission row.
  Reservations release on loaded end, successful restore, or mismatch discard.
- Melee uses normal reach, LOS, correct world, default-false `pvp`, both peers' default-false
  `canPVP`, complete convergence, and persisted cooldown through the same prepared-commit/RNG
  contract.
- Host durability uses one coherent checkpoint generation covering world metadata, RPG-causal
  journal/entity deltas, the dedicated 64-record/67,371,008-byte primary entity segment, all guest
  plus host-local owner state/revisions, all nine RNG rows, all fishing sessions/bindings, all 128
  lightning/512 fang slots, 512 scheduled-block/64 raid deltas, delayed/temporary descriptors,
  relations and tombstones inside the exact 165,188,160 component + 2,095,104 overhead + 488,896
  reserve = 167,772,160-byte arena.
  Hydration strictly validates the component manifest and applies base plus committed lineage-complete
  deltas above watermark before any publication, then atomically compacts base/watermark/deletions;
  ordinary/template full chunks coexist through sequence/dependency CAS and never enter the 512
  causal-delta cap. Credential,
  index, identity and permission tables are physically outside the checkpoint API/columns, so a
  captured gameplay checkpoint cannot revert a later token CAS. Independent peer writes cannot
  cross it; graceful cleanup/stop checkpoints synchronously. Client durability uses
  `commitLANClientAuthorityCheckpoint` over separately capped owner/slots, credential, and pending/
  disposition rows plus an atomic bounded inbox insert; DB commit precedes every memory mutation.
  Inbox render is idempotent by stable ID and acknowledged separately, with explicit at-least-once
  visible crash semantics. Live journal accounting includes durable/reserved/in-flight/pending work,
  hard-backpressures at 128/67,108,864 and retains a separate compactor-output reserve. Maximum-size
  entity upserts reference, rather than embed, generation-scoped primary rows; their separate four-
  state retention budget is exactly 128 rows/134,742,016 bytes. Immutable generation-local manifests
  use the 168-byte lineage-bound codec/vectors and chain from metadata's anchor to tip; metadata alone
  stores the current global root. Live rows become ancestry-bound receipts; their chunks reject every
  newer base writer and route only bounded journal deltas until atomic oldest-prefix prune releases
  the freeze. Partial prefix prune full-row-CASes any remaining same-chunk receipt set to its exact
  minimum generation/count/root with the base CAS unchanged, deleting the freeze only at zero. All SQLite
  work obeys the single serial executor/transaction-context/lock-order contract.
  A journal manifest exists iff its checkpoint has at least one delta; owner-only checkpoints create
  no manifest/budget work and compaction prunes the last membership plus manifest atomically.
- The exhaustive owner table is normative: every mutable field has an exact strict domain or an
  explicit derived/runtime exclusion, and canonical bytes are equal across every persistence,
  hydration, preview, commit, and client phase. Selected slot, nine closed stats and the two-only
  PlayerEntityData fields participate in the independent field-mapper oracle. Effect `-1`, tri-state
  flags, and damage below (not equal to) durability remain lossless.
- Send caps always include reserved + queued + in-flight bytes/frames with transfer accounting.
- Seeded fuzz/property/metamorphic parser and pure-reference state-machine suites run their full
  fixed case counts in `swift test`; skips, clamps, flaky seeds, and unreproducible failures block.
- All memory/frame/row/replay/inbox/descriptor/tombstone caps fail closed. Secrets never enter logs.
- All actors obey registry -> admission -> source -> claim -> sorted authority -> sorted permission
  -> sorted world mutation -> journal budget -> checkpoint stager -> compactor/output -> ordinary
  save -> SaveDB -> publication lease -> MainActor. Cross-actor work is asynchronous; sync dispatch,
  descending acquisition and waiting while holding an earlier rank are forbidden.
- Legacy migration is explicit and discoverable; Join as New stays immediate after a valid v6
  host/world advertisement.
- This nineteenth amended contract is submitted for a fresh independent Security #19 plan review.
  Implementation must not start until that review returns **PASS**. Independent code review, full
  pipeline, deployment, installed bundle verification, and Neo proof must all PASS before commit.
