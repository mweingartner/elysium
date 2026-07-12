# RPG Local Preferences and LAN v6 Owner Checkpoint Storage-Surface Amendment

**Gate:** Architecture
**Status:** Architecture PASS for the expected-old-player-row CAS amendment; Phase 2.0B and the implemented safe-deferral storage surface retain independent Security and Tester PASS; the prior amendment Security-plan PASS does not cover this new API delta; awaiting renewed Security plan review before implementation
**Design gates:** N/A for this isolated persistence boundary only; any visible failure copy or interaction change returns to RPG Design Review
**Depends on:** `LAN_V6_PHASE20B_ADAPTER_PLAN.md`, `LAN_V6_PHASE2_IMPLEMENTATION_PLAN.md`, `LAN_RPG_PROTOCOL_V6.md`, and `RPG_UI_IMPLEMENTATION_PLAN.md`

**Implementation note (2026-07-10):** Security code review found that the reviewed strict
`LANOwnerSnapshotV1`, `LANRPGIntentV6`, closed send-state, and disposition-binding codecs do not yet
exist in the repository. The incomplete Core client codec/candidate adapter was removed rather than
substitute opaque bounded bytes or invented tags. The storage component remains dormant behind a
test-only bootstrap and verify-only production accessor; Phase 2.5 must implement and review those
semantic prerequisites before PebbleCore gains any client checkpoint adapter or façade acquisition.
Host runtime allocation and cap matrices are likewise deferred until the reviewed host identity
parents and coherent host checkpoint façade exist; this amendment does not add a test-only host
writer to imitate that future authority boundary.

## 1. Purpose and non-authority

This amendment freezes the first post-Phase-2.0B expansion of the `PebbleStorage` API needed by the
RPG UI contract:

1. world-scoped local RPG quick-slot preferences and their one-time legacy-player migration marker;
2. the four-table client LAN-v6 authority checkpoint aggregate containing owner state, client-local
   slots, credentials, pending/disposition state, and the durable notification inbox;
3. the host guest and host-local owner checkpoint row layouts, while deliberately exposing no
   standalone host-owner writer before the complete coherent host checkpoint transaction exists.

It does not activate protocol v6, change `LAN_MULTIPLAYER_PROTOCOL_VERSION`, advertise a v6 ready
marker, rename/quarantine v5 tables, allocate identities, promote credentials, submit an RPG request,
acknowledge a notice, or publish any gameplay/UI value. The storage API moves primitive, bounded,
already-validated bytes only. PebbleCore retains registry validation, strict DTO decoding, gameplay
legality, canonical RPG repair, and candidate-before-publish orchestration.

The implemented safe-deferral portion of this amendment has independent Security code and Tester
PASS against the exact passed Phase 2.0B baseline frozen below. The new player-row CAS delta has
Architecture PASS only and is not authorized for Build until renewed Security plan review. A matching
file hash or passing source scan is not a substitute for those gates, and any further contract or
baseline drift returns to Architecture plus Security plan review.

## 2. Closed Phase 2.0B conditions retained as invariants

Phase 2.0B has independent Security code PASS and Tester PASS. The formerly blocking findings remain
listed because this amendment must preserve their remediated invariants:

- revalidate the retained persistent lock and named source/backup namespace before and after every
  classification, manifest pass, import, barrier, rename/sync/rollback, restart, equivalence pass,
  and marker operation;
- make the reopened coordinator/facade session cleanup-owning on every throwing path;
- implement cumulative token-based resident-memory reserve/release accounting, including retained
  rows, duplicate buffers, parser/hash scratch, and real peak evidence;
- validate every provenance byte, including world/chunk counts and the complete equivalence root,
  with equivalence covering world numeric columns, player rows, advancement rows, and chunks;
- classify every ambiguous rename/sync/rollback result by captured inode and prove the final named
  source/backup or temporary/final marker state before publication;
- replace the incomplete scanner/manifests with static-concatenation/interpolation/attribute-aware
  scanning and exact symbol USR, declaration/use kind, owner, access, and type/closure escape checks;
- reject wrong types for every fixed directory and grammatically exact candidate; validate optional
  player and advancement domain shapes before import;
- hold the real migration lease inside rank 10 for preflight through final handoff; and
- add the full race, cut-point, cap, fuzz, special-file, namespace, marker, restart, equivalence,
  cleanup, two-process, and rank-inversion test matrices.

This amendment consumes those remediations without weakening or duplicating them. If their final code
changes `Package.swift`, `Sources/PebbleStorage/StorageEngine.swift`, the release verifier, the
adapter ownership model, lock ranks, public symbol graph, or scanner manifest format, this plan must
be revalidated and rehashed before Security plan review.

This plan also makes one required safety correction to `RPG_UI_IMPLEMENTATION_PLAN.md`: legacy
migration omission proof binds the marker to the preference row's immutable migration-origin digest,
not forever to its mutable current payload digest. Before Build, that wording and its tests must be
reconciled in the UI plan and receive renewed Security plan review. The user-visible behavior is
unchanged, so Design Review need only confirm that successful post-migration edits remain available.

### 2.1 Final passed Phase 2.0B baseline

The baseline was captured after independent Security code PASS and Tester PASS. Focused evidence was
175/175 expanded persistence tests and 55/55 decisive adversarial tests. The amendment contract body
immediately before this metadata-only baseline update had SHA-256
`0c0566cd00b7915ba126b2274292c44c55734d2c68301681b4c404aa72449734`; no reviewed DDL, API,
transaction, cap, codec, authorizer, v5, scanner, test, gate, or Builder condition changed during
this revalidation.

| Passed baseline input | SHA-256 |
| --- | --- |
| `LAN_V6_PHASE20B_ADAPTER_PLAN.md` after status reconciliation | `86c87ae1fb2b4ba2e3c710a3ac5d97768aeef7cf7b9e2927d16d4ab86fc50589` |
| `Package.swift` | `50270ebc175f60239feba2c4f2ba0ce75ee3f26e4fd97c7af1630a0d9000710a` |
| `Sources/PebbleStorage/StorageEngine.swift` | `ae73b775aef8f7e286a47eaae4260d9f63064feb63ec16c916787f32208db5bb` |
| `Sources/PebbleCore/Game/Saves.swift` | `08db0b3290c4c1750d297934cb56d9ba5de02f2a4c841f00f38ef1e3f5a22d7a` |
| `Sources/PebbleCore/Game/LegacySaveMigration.swift` | `5a5358076905427ba4ba62fd3e1efca78a5f845333a7c2aa034aa291c5c57890` |
| `Sources/PebbleCore/Game/LockRank.swift` | `af87d214e878dfa81ffbdb56e9ea0dc0bcdeca5bced174a36b2b69591f0701a1` |
| `Sources/PebbleCore/Game/GameCore.swift` | `3e381982ebc0e782bf90ccac88fe6b35633f385dddc4e4a616d02478da26cdbd` |
| `Sources/Pebble/main.swift` | `4c0831b9a2664dfef5f2aa6c89bede21912bc79f93b15314a69eadfee045abf0` |
| `scripts/sqlite-boundary-scan.swift` | `e238953cc0e40c4de3846989eeceaa713bb023c107f82cd1b570b1bf1d1f37a5` |
| `scripts/pebble-storage-api-v1.json` | `8ab5084ce458d40d0f2c1638e0dee4cde246b5f4c8aa5978995f7cecc2d74ab8` |
| `scripts/pebble-core-storage-capability-v1.json` | `175deda4759ee301a24df4a6848d45eea305d7c5b7da1fc9a7f231cb25b08cd9` |
| `scripts/security-scan.sh` | `26ea71253b1474c6533bf047ba7c9bf2894b68b9b547ceef915044477f220a07` |
| `scripts/verify-pebble-storage-release-surface.sh` | `ca5fe73a61d812365db78e26fc627614b73e138cc50b5e1336eb7ed9e81a12bb` |
| ordered `Tests/SecurityScanFixtures` file/hash manifest | `7528e547bc0b2bd6a11a398df5beb94d2f631ce410aa964962db1f482d87e8bf` |
| `Tests/PebbleCoreTests/PersistenceTestSupport.swift` | `ed4ef97415ee2452b044233b3e631173e9a230b5739bd68dddd2ed2539dbc461` |
| `Tests/PebbleCoreTests/SaveDBLifecycleTests.swift` | `6caa772fd437337821dbfc9f7d67b3f2bb036a55bb032a808db6102023538bbb` |
| `Tests/PebbleCoreTests/LegacySaveMigrationTests.swift` | `b5341673254f9ce715f582ffb5b7bf205de0fcc9f9e00d7fd3204dec105943a4` |
| `Tests/PebbleCoreTests/LegacySaveMigrationAdversarialTests.swift` | `3b917d472c3c1f4418a66638c185fa349b8c8561f3eed49aa934f1804d5c37ac` |
| `Tests/PebbleCoreTests/PersistenceLockRankTests.swift` | `68386c36cb3e9d741240e044fc084f2148c68996b59711f4158066041084abf7` |
| `Tests/PebbleCoreTests/SaveDBTests.swift` | `6a3391b7a725c0d5563e2702d914084639974773827b8e474466380b9004f240` |
| `Tests/PebbleCoreTests/PebbleStorageExecutorTests.swift` | `8abf4699ccce64f20066e9bdd9b2d6146be45913651de3a967516e199d123381` |
| `Tests/PebbleCoreTests/PebbleStorageAdversarialTests.swift` | `d93cf4f9aa2ce8f2cdea5f8e2dd882776662685598d0166e9d2f408b83d60851` |
| `Tests/PebbleCoreTests/LANV6SchemaAuthorizerTests.swift` | `be5744cdf8dfe79c3b364b501812f63954b857bdb179d19fabe639adf2c22de7` |
| ordered compatibility-owner test file/hash manifest | `aba0b4e5f66c774a6b9d5bf547c1020d878ca54986a2aa92ffb2d8d5df9b581a` |
| ordered `ARCHITECTURE.md`/`SECURITY.md`/`CONTRIBUTING.md` file/hash manifest | `53332a64f1ae7ebc6aa54da529f06afb27bda572f327b943704653a5419f9a0f` |

The ordered fixture/aggregate hashes are SHA-256 over the exact newline-delimited `shasum -a 256`
output in lexical/file-list order. Revalidation must first reproduce the individual files and then
the aggregate; an aggregate match alone is insufficient. Drift in any row stops this amendment and
returns it to Architecture plus Security plan review.

This player-row CAS amendment deliberately does **not** replace any frozen hash in section
2.1 at plan time. Those rows remain the passed input baseline. Only after the exact implementation,
focused tests, scanner/API review, renewed Security code PASS, and Tester PASS may a separately
reviewed implementation-baseline record add the new `Saves.swift`, capability-manifest, verifier,
test, object, and executable hashes. Pre-approving anticipated hashes or silently overwriting these
inputs is forbidden.

## 3. Frozen ownership and file map

### 3.1 Files modified after Phase 2.0B PASS

1. `Sources/PebbleStorage/StorageEngine.swift`
   - Add the exact revision-1 schema below, its private schema bootstrap/verification manifest, its
     private authorizer scopes, primitive row types, and the three named façades.
   - Retain sole ownership of SQLite, DDL, SQL, statement/context/capability types, aggregate count/
     byte checks, and transaction failure injection.
2. `Sources/PebbleCore/Game/Saves.swift`
   - Obtain the new façades from the existing coordinator and expose only typed domain adapter
     methods. It remains one of exactly two permitted PebbleCore `import PebbleStorage` owners.
   - Encode/decode and validate domain bytes outside storage rank 12; invoke a façade only inside the
     existing rank-12 wrapper; publish nothing from a storage callback.
   - Add exactly the checked `getPlayerChecked` snapshot and `compareAndSwapPlayerChecked` APIs plus
     concrete digest/expectation/snapshot and closed redacted error types below. Keep compatibility
     `putPlayer(_:_:) -> Void` on its existing serialized transaction; do not add an unconditional
     throwing writer or change any other caller implicitly to CAS behavior.
3. `Sources/PebbleCore/Game/RPGLocalPreferences.swift`
   - Own exact scope validation, the quick-slot codec, canonical digests, pure reducers, and mapping
     between domain values and `SaveDB` operations. It does not import or name `PebbleStorage`.
4. `Sources/PebbleCore/Game/CharacterProgression.swift`,
   `Sources/PebbleCore/Entity/Player.swift`, and `Sources/PebbleCore/Game/GameCore.swift`
   - Retain the bounded legacy envelope, route local-world migration and writes, remove slots from
     authoritative encoding only after migration safety exists, and enforce persist-before-publish.
   - `Player` adds only the explicit pure `save(omitLegacyQuickSlots:)` candidate overload; GameCore
     owns the migration-committed/non-omittable -> checked durable row -> omittable state transition.
5. `Sources/PebbleCore/Net/LANMultiplayer.swift`
   - Remove quick slots from v5/public/owner RPG encoding after local migration is available; add no
     v5-to-v6 persistence bridge.
6. Future reviewed v6 client authority coordinator source
   - Use only the complete `SaveDB.commitLANClientAuthorityCheckpoint` adapter. It may not hold or
     receive a storage façade and may not call a slot-only persistence method.
7. Future reviewed coherent host-checkpoint source
   - Use the host owner row layouts only as components of the complete
     `commitLANAuthorityCheckpoint`; no periodic or owner-only transaction is permitted.

### 3.2 Tests and enforcement files

- Add `Tests/PebbleCoreTests/RPGLocalPreferenceStorageTests.swift`.
- Add `Tests/PebbleCoreTests/SaveDBPlayerRowCASTests.swift` for checked snapshot/CAS, rank split,
  redacted errors, injected storage failures, restart rows, and compatibility wrapper.
- Add `Tests/PebbleCoreTests/LANV6ClientAuthorityCheckpointStorageTests.swift`.
- Add `Tests/PebbleCoreTests/LANV6HostOwnerCheckpointStorageTests.swift`.
- Extend `PebbleStorageExecutorTests.swift`, `LANV6SchemaAuthorizerTests.swift`,
  `RPGLocalPreferencesTests.swift`, `RPGCharacterStateTests.swift`, `RPGCoreV2Tests.swift`,
  `RPGQuickSlotInputTests.swift`, `LANClientRoutingTests.swift`, `LANMultiplayerTests.swift`, and
  `LANReplicationTests.swift`.
- Semantically update `scripts/pebble-storage-api-v1.json` and
  `scripts/pebble-core-storage-capability-v1.json` only after reviewing the exact public/package/SPI
  symbol and use-site diff.
- Update `scripts/sqlite-boundary-scan.swift`, `scripts/verify-pebble-storage-release-surface.sh`,
  `scripts/security-scan.sh`, and `scripts/pipeline.sh` only for the new reviewed schema/API manifest
  and artifact expectations. No automatic manifest-accept/regeneration mode is allowed.
- Update `ARCHITECTURE.md`, `SECURITY.md`, `CONTRIBUTING.md`, and implementation status in the RPG
  design/UI plan only after behavior is proven.

No additional production file may import `PebbleStorage`. No façade accepts SQL, table/column names,
capabilities, closures, callbacks, protocols, generic carriers, or arbitrary error values.

## 4. Schema revision and atomic bootstrap

The extension schema revision is exactly 1. `PRAGMA user_version` is not used. Schema evolution is
three dependency-ordered, individually atomic components rather than one transaction that creates a
host table before its identity parent exists:

1. `rpgLocalPreferences` may install immediately after final Phase2B PASS. It is the sole first-
   bootstrap owner of `pebble_storage_component_schema_v1`: the marker table, both local tables, and
   the local marker row commit together or none exists.
2. `lanClientAuthority` is installed only by the Phase-2.5 client credential schema bootstrap after
   that phase's model/storage plan passes. That one bootstrap creates the credential anchor and the
   remaining three client tables/index plus its marker together; no earlier or later phase separately
   creates or alters `lan_client_credentials_v6`.
3. `lanHostOwnerRows` may install only after the exact Phase-2.2/2.3 world-registry and peer-identity
   parent tables exist and pass; it creates both host owner tables with their foreign keys together.

The only legal marker sets are the prefixes `{}`, `{rpgLocalPreferences}`,
`{rpgLocalPreferences,lanClientAuthority}`, and all three. A later component without every earlier
component is `schemaIntegrity`. Each private component-bootstrap capability performs one
`BEGIN IMMEDIATE` transaction that:

1. verifies the exact current earlier-component/core/v6-parent schema and proves none of its new
   object names exists;
2. creates exactly its tables/indexes below using literal SQL in stated order;
3. inserts exactly its marker row into `pebble_storage_component_schema_v1`;
4. verifies `sqlite_master`, `table_info`, `table_list`, `index_list`, `index_xinfo`,
   `foreign_key_list`, and every CHECK/canonical SQL string against its compiled manifest; and
5. commits, verifies autocommit, and makes only that component's façade obtainable.

The marker component values are exactly `rpgLocalPreferences`, `lanClientAuthority`, and
`lanHostOwnerRows`; each has revision 1 and its own 32-byte SHA-256 manifest digest over:

`"Pebble/storage-schema/v1\0" || UInt32BE(componentNameBytes) || componentNameUTF8 ||
UInt32BE(statementCount) || each(UInt32BE(utf8Count) || canonicalSQLUTF8)`.

Canonical SQL is the exact whitespace-normalized literal manifest in source order, not the mutable
text read back from SQLite. At runtime, separately canonicalized `sqlite_master` and pragma results
must equal the compiled structural manifest before the stored digest is trusted.

An existing exact installed component is verified and reused. A partial component, illegal prefix,
extra object, wrong marker/digest/type/collation/index/FK/CHECK, later revision, trigger, view,
virtual table, or same-name object with alternate SQL fails `schemaIntegrity`; it is never repaired
piecemeal. Failure injection at every statement plus reopen observes either the complete prior prefix
or that prefix plus the complete new component. Runtime scopes cannot obtain schema bootstrap.

For the first component, absence of the marker table is legal only when every component table/index
is also absent; its transaction creates the marker table before local DDL and rolls all of them back
together. Later component bootstrap scopes may only verify/read/insert their one row in that exact
marker table; CREATE/ALTER/DROP is denied. For the client component, credential parent plus all three
children/index are one indivisible component, so an FK parent without every child/marker or any child
without the parent is corruption, not a recoverable intermediate. For the host component, both
reviewed parent tables/FKs must be complete before BEGIN, and both child owner tables plus marker
commit together. No bootstrap temporarily disables foreign keys.

### 4.1 Exact marker DDL

```sql
CREATE TABLE pebble_storage_component_schema_v1(
  component TEXT NOT NULL COLLATE BINARY,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision=1),
  manifest_digest BLOB NOT NULL CHECK(typeof(manifest_digest)='blob' AND length(manifest_digest)=32),
  PRIMARY KEY(component),
  CHECK(component IN ('rpgLocalPreferences','lanClientAuthority','lanHostOwnerRows'))
) WITHOUT ROWID;
```

## 5. Local-world RPG preference schema

### 5.1 Exact DDL

```sql
CREATE TABLE rpg_local_preferences_v1(
  world_record_id TEXT NOT NULL COLLATE BINARY
    CHECK(typeof(world_record_id)='text'
      AND length(CAST(world_record_id AS BLOB)) BETWEEN 1 AND 64),
  schema_version INTEGER NOT NULL
    CHECK(typeof(schema_version)='integer' AND schema_version=1),
  revision INTEGER NOT NULL
    CHECK(typeof(revision)='integer' AND revision BETWEEN 1 AND 1000000000),
  slots_payload BLOB NOT NULL
    CHECK(typeof(slots_payload)='blob' AND length(slots_payload) BETWEEN 18 AND 4096),
  payload_digest BLOB NOT NULL
    CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
  migration_origin_digest BLOB
    CHECK(migration_origin_digest IS NULL
      OR (typeof(migration_origin_digest)='blob' AND length(migration_origin_digest)=32)),
  migration_origin_revision INTEGER
    CHECK(migration_origin_revision IS NULL
      OR (typeof(migration_origin_revision)='integer'
        AND migration_origin_revision BETWEEN 1 AND 1000000000)),
  CHECK((migration_origin_digest IS NULL AND migration_origin_revision IS NULL)
     OR (migration_origin_digest IS NOT NULL AND migration_origin_revision IS NOT NULL)),
  PRIMARY KEY(world_record_id)
) WITHOUT ROWID;
```

```sql
CREATE TABLE rpg_local_preference_migrations_v1(
  world_record_id TEXT NOT NULL COLLATE BINARY
    CHECK(typeof(world_record_id)='text'
      AND length(CAST(world_record_id AS BLOB)) BETWEEN 1 AND 64),
  schema_version INTEGER NOT NULL
    CHECK(typeof(schema_version)='integer' AND schema_version=1),
  source_digest BLOB NOT NULL
    CHECK(typeof(source_digest)='blob' AND length(source_digest)=32),
  destination_digest BLOB NOT NULL
    CHECK(typeof(destination_digest)='blob' AND length(destination_digest)=32),
  destination_revision INTEGER NOT NULL
    CHECK(typeof(destination_revision)='integer'
      AND destination_revision BETWEEN 1 AND 1000000000),
  PRIMARY KEY(world_record_id),
  FOREIGN KEY(world_record_id) REFERENCES rpg_local_preferences_v1(world_record_id)
    ON UPDATE RESTRICT ON DELETE CASCADE
) WITHOUT ROWID;
```

There is no player, authority, address, seed, display name, world name, v5 host-world key, or LAN
identity column. `world_record_id` is the exact 1...64-byte `WorldRecord.id`, compared byte-for-byte
under BINARY collation. A `.lanV6` scope is rejected by PebbleCore before a storage row is built and
the façade has no LAN-shaped initializer.

### 5.2 Exact row and aggregate accounting

- At most 256 preference rows and 256 marker rows exist.
- One preference row accounts as
  `256 + worldIDBytes + 2 + 8 + slotsPayloadBytes + 32 + 1 + originDigestBytes +
  originRevisionBytes` and must be at most 4,096 bytes; origin bytes are both zero when absent and
  exactly 32 plus 8 when present.
- One marker accounts as `256 + worldIDBytes + 2 + 32 + 32 + 8` and must be at most 4,096 bytes.
- The sum of every preference and marker accounted byte is at most 1,048,576.
- Count/SUM checks include the candidate replacement delta and run inside the same immediate
  transaction before mutation. Checked `Int64` arithmetic rejects overflow. Reads run COUNT/SUM
  before row materialization and reject an already-over-cap database without returning a prefix.

The 256-byte charge is frozen SQLite row/index/allocator overhead. SQL `length` values and the
constructor's byte counts must reproduce the formula exactly; tests compare both at every boundary.

## 6. Canonical local preference codecs and digests

### 6.1 Slot payload

`RPGQuickSlotPreferencesV1` bytes are exactly:

1. ASCII `PBLQS1` (6 bytes);
2. `UInt16BE(1)` schema;
3. `UInt8(9)` slot count;
4. nine entries in index order. Nil is one byte `0x00`. A value is `0x01 || UInt16BE(n) || n UTF-8
   bytes` where `n` is 1...128 and the value is canonical `skill:<registeredID>` or
   `spell:<registeredID>`.

No trailing byte is permitted. Non-nil tokens are unique. IDs are nonempty, at most 64 UTF-8 bytes,
and canonical registered IDs; storage decoding checks syntax/length/uniqueness while domain decoding
checks the current registry and prepared-state relationship. Intentional nil positions remain nil.
The encoded payload is at most 4,096 bytes even though the grammar's tighter maximum is smaller.

### 6.2 Domain-separated digests

Every integer below is unsigned fixed-width big-endian and every variable field is prefixed by
`UInt32BE(byteCount)`.

- Legacy source digest:
  `SHA256("Pebble/RPGLegacyQuickSlots/source/v1\0" || UInt16BE(envelopeVersion) || slotsPayload)`.
- Local destination digest:
  `SHA256("Pebble/RPGLocalQuickSlots/destination/v1\0" || worldID || UInt16BE(1) || UInt64BE(revision) || slotsPayload)`.
- The stored `payload_digest` is exactly the local destination digest.
- The marker stores the exact source digest and chosen destination digest; it contains no digest of
  JSON serialization, display data, dictionary order, filesystem path, or native-endian integer.

Digest construction is incremental with checked byte counts and a fixed peak scratch charge. Decode
recomputes and fixed-32-byte compares before returning a row. A digest mismatch is corruption, never
a missing/default preference.

## 7. Local preference typed surface and transactions

`PebbleStorage` adds only primitive, immutable values:

```swift
public struct PebbleRPGLocalPreferenceStorageRow: Sendable, Equatable {
    public let worldRecordID: String
    public let schemaVersion: UInt16
    public let revision: UInt64
    public let slotsPayload: Data
    public let payloadDigest: Data
    public let migrationOriginDigest: Data?
    public let migrationOriginRevision: UInt64?
}

public struct PebbleRPGLegacyQuickSlotMigrationStorageRow: Sendable, Equatable {
    public let worldRecordID: String
    public let schemaVersion: UInt16
    public let sourceDigest: Data
    public let destinationDigest: Data
    public let destinationRevision: UInt64
}

public struct PebbleRPGLocalPreferenceMigrationReceipt: Sendable, Equatable {
    public let preference: PebbleRPGLocalPreferenceStorageRow
    public let marker: PebbleRPGLegacyQuickSlotMigrationStorageRow
    public let insertedDestination: Bool
}

public final class PebbleRPGLocalPreferencesStorage {
    public func read(worldRecordID: String) throws -> PebbleRPGLocalPreferenceStorageRow?
    public func materializeIfAbsent(
        candidate: PebbleRPGLocalPreferenceStorageRow
    ) throws -> PebbleRPGLocalPreferenceStorageRow
    public func compareAndSwap(
        expectedRevision: UInt64,
        expectedDigest: Data,
        candidate: PebbleRPGLocalPreferenceStorageRow
    ) throws -> PebbleRPGLocalPreferenceStorageRow
    public func materializeLegacy(
        sourceDigest: Data,
        absentDestination: PebbleRPGLocalPreferenceStorageRow
    ) throws -> PebbleRPGLocalPreferenceMigrationReceipt
}
```

The coordinator adds `rpgLocalPreferences() throws -> PebbleRPGLocalPreferencesStorage`. No method
accepts `RPGLocalPreferenceScope`, a LAN ID, a player/save object, JSON, registry callback, mutation
closure, or generic encoder.

### 7.1 Normal write CAS

`compareAndSwap` requires candidate world ID equality, candidate revision exactly
`expectedRevision + 1`, expected/candidate digest validity, and expected revision in
`1...999_999_999`. Candidate migration-origin digest and revision must equal the stored values
exactly; ordinary writes can neither add, replace, nor clear them. One immediate transaction:

1. reads COUNT/SUM and the exact old revision/digest under the write scope;
2. proves exactly one matching `worlds.id` parent and rejects missing, stale, corrupt, exhausted,
   cap-overflow, or mismatched-world state;
3. performs one explicit-column `UPDATE ... WHERE world_record_id=? AND revision=? AND
   payload_digest=?`;
4. requires `changes()==1`, re-reads the row, byte-compares it with the candidate, and commits.

There is no merge, retry, `INSERT OR REPLACE`, upsert, or automatic replay after stale CAS. The
caller reloads and requires a fresh user activation. Every failure leaves disk and the prior live
preference unchanged.

### 7.2 Nonlegacy default materialization

`materializeIfAbsent` is the only path for a world with no legacy envelope and no preference row.
Its candidate is revision 1 with a nil migration-origin pair. One immediate transaction proves the
exact `worlds.id` parent, validates COUNT/SUM plus candidate digest/caps, and reads the exact row. If
absent it performs an explicit-column insert, requires one change, re-reads, byte-compares, and
commits. If an already-valid row exists, that row wins and returns unchanged; the candidate is not
merged or used to refill nil slots. A corrupt/over-cap row fails closed. The operation writes no
migration marker and never adds an origin pair. This is how stable prepared-action defaults are
materialized exactly once; an explicit all-nil existing row remains all nil.

### 7.3 One-time legacy materialization

`materializeLegacy` is one immediate transaction:

1. validate source digest and absent-destination candidate before enqueue;
2. prove exactly one matching `worlds.id` parent, then read preference and marker for the exact world;
3. if no preference and no marker exist, insert the candidate at revision 1 after all caps pass; a
   marker without a preference is corruption;
4. when the marker is absent, require the chosen existing/new preference's origin pair to be nil,
   set the pair to `(current payload digest,current revision)` without changing slots/revision, and
   insert the marker bound to that pair in the same transaction;
5. when the marker is present, require the preference origin pair to be present and exact-equal to
   the marker's world/source/destination digest/revision/schema; do not compare the marker to the
   mutable current payload/revision and do not rewrite either row;
6. re-read both rows, verify their current digest plus immutable-origin relationship, then commit and
   return one receipt. A newly supplied legacy value never overwrites an existing preference.

A marker without a destination, origin digest drift, different source digest, origin revision
mismatch, or duplicate/conflicting row is corruption and rolls back. The current preference payload/
revision may legitimately advance after migration; omission proof compares the marker to the
immutable origin, not to the current payload. A crash before COMMIT leaves no marker and does not
authorize omission of the legacy key. A crash after COMMIT is idempotent: the next run returns the
same receipt. Only after `GameCore` receives and revalidates that receipt may it mark the in-memory
envelope migration-committed. Migration commit alone does not make the live envelope omittable; the
checked player-row phase below is also mandatory.

### 7.4 Expected-old-row CAS and two-phase omission

An unconditional throwing write is insufficient: a delayed slot-free candidate could overwrite a
newer ordinary save before GameCore rejects publication. The amendment instead adds one checked read
snapshot and one exact expected-old-row CAS. The closed Core surface is:

```swift
public struct SaveDBPlayerRowDigest: Equatable, Sendable {
    public let data: Data

    public init(data: Data) throws {
        guard data.count == 32 else { throw SaveDBPlayerRowError.invalidCandidate }
        self.data = data
    }
}

public struct SaveDBPlayerRowSnapshot {
    public let worldID: String
    public let data: [String: Any]
    public let canonicalDigest: SaveDBPlayerRowDigest
}

public enum SaveDBPlayerRowExpectation: Equatable, Sendable {
    case absent
    case present(SaveDBPlayerRowDigest)
}

public enum SaveDBPlayerRowError: Error, Equatable, Sendable {
    case invalidCandidate
    case invalidStoredRow
    case conflict
    case persistenceFailed
}

public func getPlayerChecked(_ worldId: String) throws -> SaveDBPlayerRowSnapshot?
public func compareAndSwapPlayerChecked(
    _ worldId: String,
    expected: SaveDBPlayerRowExpectation,
    candidate: [String: Any]
) throws -> SaveDBPlayerRowSnapshot
```

`SaveDBPlayerRowDigest.init(data:)` above is the only public/package initializer: access is exactly
`public`, the label is exactly `data`, it throws, and the 32-byte guard precedes assignment. No
synthesized public memberwise initializer, unlabeled initializer, default argument, package/SPI
initializer, unsafe/unchecked constructor, decoding initializer, or other factory is permitted.

The complete PebbleStorage source-level addition is exactly this public block; it adds no package or
SPI declaration:

```swift
public struct PebblePlayerJSONRowDigest: Sendable, Equatable {
    public let data: Data

    public init(data: Data) throws {
        guard data.count == 32 else { throw PebbleStorageError.invalidValue }
        self.data = data
    }
}

public enum PebblePlayerJSONExpectedRowState: Sendable, Equatable {
    case absent
    case present(PebblePlayerJSONRowDigest)
}

public enum PebblePlayerJSONCompareAndSwapResult: Sendable, Equatable {
    case conflict
    case committed(PebblePlayerJSONStorageRow)
}

public extension PebbleLegacyCoreStorage {
    func compareAndSwapPlayerJSON(
        expected: PebblePlayerJSONExpectedRowState,
        candidate: PebblePlayerJSONStorageRow
    ) throws -> PebblePlayerJSONCompareAndSwapResult
}
```

These types have no `Hashable`, `Codable`, `RawRepresentable`, `CaseIterable`,
`CustomStringConvertible`, `CustomDebugStringConvertible`, `LocalizedError`, or protocol-erasure
conformance, no public/package mutable property, and no initializer other than the exact digest
initializer and compiler-provided enum-case constructors. The method is concrete and non-generic;
there is no callback, closure, protocol, `Any`, SQL, table/column name, capability, storage-context,
executor, transaction, or arbitrary-error parameter/return. The extension spelling above counts as
the fourth public addition; no package/SPI mirror is permitted.

The canonical digest is
`SHA256("Pebble/player-row/exact-json/v1\0" || UInt32BE(worldIDUTF8.count) || worldIDUTF8 ||
UInt64BE(exactStoredJSONUTF8.count) || exactStoredJSONUTF8)`. It covers the full exact persisted row,
including world ID and every JSON byte; it never hashes a decoded dictionary, unordered iteration,
display value, native-endian integer, or partial RPG field. `getPlayerChecked` obtains the existing
row under rank 12, releases rank, computes this digest over the exact returned JSON string, decodes
the bounded object, and returns both data and digest. Error mapping is total and frozen:

- candidate world/digest/JSON encoding, canonical string conversion, or row construction failure ->
  `.invalidCandidate`;
- stored wrong SQLite class, invalid UTF-8, oversized world/JSON, invalid JSON syntax, non-object JSON
  root, or bounded decode failure -> `.invalidStoredRow`;
- absent/present/digest mismatch, changed durable row, or missing/invalid exact worlds.id parent ->
  `.conflict`;
- executor lifecycle/open/closed/poisoned, I/O, SQLite operation, transaction, rollback, or durability
  failure -> `.persistenceFailed`.

No underlying error is passed through, and no case falls back to another mapping. No raw path, SQL,
SQLite code, JSON, player value, or underlying error text escapes.

Bounds are inherited exactly from `PebblePlayerJSONStorageRow`: world ID UTF-8 bytes
0/1/1,048,576/1,048,577 and player JSON UTF-8 bytes 786,431/786,432/786,433 are explicit tests.
Digest construction is incremental over the fixed domain, checked big-endian lengths, world bytes,
and JSON bytes; it never concatenates or duplicates the bounded row into one aggregate buffer.
`PebblePlayerJSONRowDigest(data:)` tests 31/32/33 bytes and rejects non-32 before assigning/copying
into an expectation, enqueueing, or entering rank 12. Candidate world/JSON cap violations reject
before enqueue/rank entry. Stored `world`/`json` wrong SQLite classes, oversized text returned by a
hostile database, invalid UTF-8, or cap-plus-one fail in the bounded statement reader before full
copy/digest construction and map exactly to `.invalidStoredRow` without candidate write; they never
map to `.persistenceFailed`.

PebbleStorage adds only concrete `PebblePlayerJSONRowDigest`,
`PebblePlayerJSONExpectedRowState`, `PebblePlayerJSONCompareAndSwapResult`, and
`PebbleLegacyCoreStorage.compareAndSwapPlayerJSON(expected:candidate:)`. The expectation is exactly
`.absent` or `.present(32-byte digest)`. In one existing rank-12 immediate `player` transaction the
facade reads the exact row, recomputes the full digest, and fixed-time compares all 32 bytes. Absent
matches only no row; present matches only an existing row with equal digest. Mismatch returns
`.conflict` without INSERT/UPDATE. A match performs exactly one explicit-column INSERT or UPDATE,
requires one change, re-reads and exact-byte/digest-compares the candidate, then commits and returns
`.committed(row)`. Every thrown failure rolls back; conflict is nonthrowing at the storage boundary
and maps to Core `.conflict`.

The implementation adds one private, non-exported
`StorageAuthorizationScope.playerJSONCompareAndSwapV1`. Its authorizer permits transaction control;
`SELECT` plus `READ worlds.id`; `SELECT` plus `READ player.world`/`player.json`; `INSERT` into exactly
`player`; and `UPDATE` of exactly `player.json`. It denies DELETE, every other worlds/player column,
and all other core/template/local/LAN/schema tables, triggers, views, attached databases, and nested
scope entry. No caller selects this scope directly except the concrete CAS facade.

Inside that transaction, before absent insert or present update, query the exact BINARY
`worlds.id = candidate.world`, allow at most two rows, and require exactly one parent. Missing,
duplicate, wrong-class, or mismatched parent returns `.conflict` without reading a substitute or
mutating player state. Then read at most one exact player row. World deletion and CAS serialize on the
same executor: deletion committed before either absent or present CAS yields missing-parent conflict
and cannot recreate `player`; deletion ordered after a committed CAS removes that row in the later
closed world-delete transaction. Tests cover both orders for absent and present expectations.

Compatibility `putPlayer(_:_:) -> Void` remains source- and behavior-compatible, constructs its
candidate before rank 12, and uses existing serialized `putPlayerJSON(row)`. Every compatibility,
ordinary, saveAndFlush, and shutdown write is serialized by the same storage executor and changes the
exact durable bytes/digest read inside the CAS transaction. A writer ordered before CAS forces
conflict; a writer ordered after CAS is a later write and cannot be overwritten by that finished CAS.
No cached expected row, unconditional checked writer, generic facade, callback, closure, new lock
rank, or production barrier is allowed.

`Player` exposes one pure candidate builder with an explicit flag:

```swift
public func save(omitLegacyQuickSlots: Bool) -> [String: Any]
```

Ordinary `save()` preserves its current behavior and includes the legacy key while the live envelope
is non-omittable. After local preference migration commits, `GameCore` keeps that live envelope
non-omittable and records only migration-committed provenance. On main actor, without `await`, it:

1. revalidates exact world-entry generation, local scope, expected live preference revision,
   envelope version/source digest, and receipt immutable-origin digest/revision;
2. calls `getPlayerChecked`; present verifies the decoded stored envelope equals the current source
   and captures `.present(snapshot.canonicalDigest)`, while no row captures `.absent`;
3. revalidates, builds detached `player.save(omitLegacyQuickSlots: true)`, and synchronously calls
   `compareAndSwapPlayerChecked` with that expectation;
4. after committed return and rank release, immediately revalidates the same provenance; and
5. only then publishes the live envelope as omittable and permits ordinary later saves to omit it.

The precheck, synchronous CAS, postcheck, and publication form one non-suspending main-actor segment,
so world re-entry and envelope replacement cannot interleave. Background writers interleave only by
storage ordering: before CAS they change the digest and cause conflict with zero mutation; after CAS
they are later writes. Invalid/encode/stored-row/conflict/storage failure keeps the live envelope
non-omittable, leaves the durable row unchanged by CAS, changes no revision, and emits only bounded
`Could not save character migration`.

DEBUG-only deterministic barriers live in the test adapter: immediately before CAS facade invocation
at rank 0 and after CAS commit/rank release before Core return. Tests order compatibility putPlayer,
ordinary save, saveAndFlush, shutdown, same-world/A-B-A attempts, and envelope replacement. A stale-
before-write candidate conflicts and cannot change the newer durable row; after-commit writers remain
the final durable row; main-actor session changes cannot enter the non-suspending segment. Crash before
commit is old row; crash after commit is the CAS candidate or a demonstrably later serialized writer.

LAN entry never calls either materializer. World deletion uses the existing
`PebbleLegacyCoreStorage.deleteWorld(id:)` entry point but replaces its private implementation scope
with one closed, non-nestable `coreWorldDeleteWithRPGV1` capability. One immediate transaction first
validates the exact parent/child relationship and caps, then executes in this exact order:

1. `DELETE FROM rpg_local_preference_migrations_v1 WHERE world_record_id=?`;
2. `DELETE FROM rpg_local_preferences_v1 WHERE world_record_id=?`;
3. `DELETE FROM worlds WHERE id=?`;
4. `DELETE FROM chunks WHERE world=?`;
5. `DELETE FROM player WHERE world=?`;
6. `DELETE FROM advancements WHERE world=?`.

Every bind is the same validated world ID. Marker/preference/world/player/advancement changes must
each be 0 or 1; chunks must be 0...1,048,576; marker cannot exist without preference and neither may
exist without exactly one world parent. A wholly absent world with all six counts zero remains the
existing idempotent success. The method checks each statement's exact change count, total checked
sum, postcondition absence, COMMIT, and autocommit. Its returned `Int` remains exactly the sum of the
four pre-amendment core DELETE change counts; marker/preference counts are verified but not added, so
the existing façade result does not change. Any prepare/bind/step/changes/finalize/
postcondition/COMMIT failure rolls back all six deletes. It does not invoke/nest a local-preference
facade or capability and no foreign-key cascade hides a cross-scope write.

## 8. Client LAN-v6 authority checkpoint schema

The client checkpoint is keyed only by raw `(hostInstallationID[16], worldLANID[16],
lookupDigest[32])`. `lookupDigest` must fixed-time equal
`SHA256("Pebble-LAN-v6" || hid || wid)` before a storage key is constructed. Textual 22-character
base64url exists only at UI/wire boundaries; SQL stores fixed BLOBs.

The credential row is the mandatory aggregate anchor. It may exist before owner request-zero; owner
and pending rows are optional. Only the credential anchor carries the current aggregate generation
and aggregate digest. Owner and pending rows carry their own `last_change_generation`, which must be
1...anchor generation; an unchanged component retains its earlier value. Admission-only credential
writes are allowed only while `authority_bound=0`; the exact first complete client authority commit
sets it to 1 while inserting owner state. After that point all credential changes, owner/slot changes,
and pending transitions use the complete authority transaction.

### 8.1 Exact credential anchor DDL

```sql
CREATE TABLE lan_client_credentials_v6(
  hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
  wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
  lookup_digest BLOB NOT NULL CHECK(typeof(lookup_digest)='blob' AND length(lookup_digest)=32),
  schema_version INTEGER NOT NULL CHECK(typeof(schema_version)='integer' AND schema_version=1),
  aggregate_generation INTEGER NOT NULL
    CHECK(typeof(aggregate_generation)='integer'
      AND aggregate_generation BETWEEN 0 AND 1000000000),
  aggregate_digest BLOB NOT NULL
    CHECK(typeof(aggregate_digest)='blob' AND length(aggregate_digest)=32),
  authority_bound INTEGER NOT NULL
    CHECK(typeof(authority_bound)='integer' AND authority_bound IN (0,1)),
  payload BLOB NOT NULL
    CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 65536),
  payload_digest BLOB NOT NULL
    CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
  CHECK((authority_bound=0 AND aggregate_generation=0)
     OR (authority_bound=1 AND aggregate_generation BETWEEN 1 AND 1000000000)),
  PRIMARY KEY(hid,wid,lookup_digest),
  UNIQUE(hid,wid)
) WITHOUT ROWID;
```

### 8.2 Exact owner row DDL

```sql
CREATE TABLE lan_client_owner_checkpoint_v6(
  hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
  wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
  lookup_digest BLOB NOT NULL CHECK(typeof(lookup_digest)='blob' AND length(lookup_digest)=32),
  schema_version INTEGER NOT NULL CHECK(typeof(schema_version)='integer' AND schema_version=1),
  last_change_generation INTEGER NOT NULL
    CHECK(typeof(last_change_generation)='integer'
      AND last_change_generation BETWEEN 1 AND 1000000000),
  payload BLOB NOT NULL
    CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 786432),
  payload_digest BLOB NOT NULL
    CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
  PRIMARY KEY(hid,wid,lookup_digest),
  FOREIGN KEY(hid,wid,lookup_digest)
    REFERENCES lan_client_credentials_v6(hid,wid,lookup_digest)
    ON UPDATE RESTRICT ON DELETE CASCADE
) WITHOUT ROWID;
```

The strict owner payload contains exact canonical owner bytes, nine-slot payload, session epoch,
snapshot ID, simulation tick, owner and inventory revisions, credential generation, last-applied
host checkpoint generation, and their own strict schema/key set. Canonical owner bytes are at most
524,288; the complete owner payload is at most 786,432 before any nested decode.

### 8.3 Exact pending/disposition DDL

```sql
CREATE TABLE lan_client_pending_disposition_v6(
  hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
  wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
  lookup_digest BLOB NOT NULL CHECK(typeof(lookup_digest)='blob' AND length(lookup_digest)=32),
  schema_version INTEGER NOT NULL CHECK(typeof(schema_version)='integer' AND schema_version=1),
  last_change_generation INTEGER NOT NULL
    CHECK(typeof(last_change_generation)='integer'
      AND last_change_generation BETWEEN 1 AND 1000000000),
  mode INTEGER NOT NULL CHECK(typeof(mode)='integer' AND mode IN (1,2)),
  payload BLOB NOT NULL
    CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 131072),
  payload_digest BLOB NOT NULL
    CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
  PRIMARY KEY(hid,wid,lookup_digest),
  FOREIGN KEY(hid,wid,lookup_digest)
    REFERENCES lan_client_credentials_v6(hid,wid,lookup_digest)
    ON UPDATE RESTRICT ON DELETE CASCADE
) WITHOUT ROWID;
```

Mode 1 is `awaitingState`; mode 2 is `dispositionOnly`. Absence means no pending/disposition row; an
empty payload is forbidden.

### 8.4 Exact notification inbox DDL

```sql
CREATE TABLE lan_client_notification_inbox_v6(
  hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
  wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
  lookup_digest BLOB NOT NULL CHECK(typeof(lookup_digest)='blob' AND length(lookup_digest)=32),
  notification_id BLOB NOT NULL
    CHECK(typeof(notification_id)='blob' AND length(notification_id)=32),
  session_epoch BLOB NOT NULL
    CHECK(typeof(session_epoch)='blob' AND length(session_epoch)=16),
  request_id INTEGER NOT NULL
    CHECK(typeof(request_id)='integer' AND request_id BETWEEN 1 AND 1000000000),
  snapshot_id BLOB NOT NULL
    CHECK(typeof(snapshot_id)='blob' AND length(snapshot_id)=16),
  status INTEGER NOT NULL CHECK(typeof(status)='integer' AND status BETWEEN 1 AND 4),
  creation_generation INTEGER NOT NULL
    CHECK(typeof(creation_generation)='integer'
      AND creation_generation BETWEEN 1 AND 1000000000),
  acknowledgement_state INTEGER NOT NULL
    CHECK(typeof(acknowledgement_state)='integer' AND acknowledgement_state IN (0,1)),
  acknowledgement_generation INTEGER NOT NULL
    CHECK(typeof(acknowledgement_generation)='integer'
      AND acknowledgement_generation IN (0,1)),
  payload BLOB NOT NULL
    CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 4096),
  payload_digest BLOB NOT NULL
    CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
  CHECK(acknowledgement_state=acknowledgement_generation),
  PRIMARY KEY(hid,wid,notification_id),
  UNIQUE(hid,wid,session_epoch,request_id),
  FOREIGN KEY(hid,wid,lookup_digest)
    REFERENCES lan_client_credentials_v6(hid,wid,lookup_digest)
    ON UPDATE RESTRICT ON DELETE CASCADE
) WITHOUT ROWID;
```

Status values are exactly 1 accepted, 2 rejected, 3 outcome-evicted, and 4 request-exhausted.
Acknowledgement state 0 is `pendingRender` and requires generation 0; state 1 is `acknowledged` and
requires generation 1 exactly. Every notice names an ordinary request ID
1...1,000,000,000. Request-zero synchronization never creates a notification row.

```sql
CREATE INDEX lan_client_notification_inbox_v6_render_order
ON lan_client_notification_inbox_v6(
  hid,wid,lookup_digest,acknowledgement_state,creation_generation,notification_id
);
```

No inbox row stores a player name, path, address, raw unverified host text, or credential token.

## 9. Client row caps and canonical digests

### 9.0 Exact client payload envelopes

Every payload is a binary, no-trailing-byte envelope. It is never native `Codable` output. Lengths
are checked unsigned big-endian values before slicing/allocation; reserved flag bits and enum values
reject. The canonical component DTO bytes named below are themselves strict, versioned codecs from
the v6 authority phase and must pass their independent validators before these envelopes construct.

- Credential payload: ASCII `PBLCC1`, `UInt16BE(1)`, one flags byte (bit 0 active, bit 1 pending,
  all other bits zero), then the active component when present
  `(UInt64BE(generation 1...1_000_000_000), rawToken[32])`, then the pending component when present
  `(UInt64BE(generation), rawToken[32], handshakeID[16], Int64BE(absoluteExpiryMilliseconds))`.
  Pending fields are all present or all absent. It contains no authority/session/socket/runtime
  lease, address, name, or monotonic deadline.
- Owner payload: ASCII `PBLCO1`, `UInt16BE(1)`, `UInt32BE(ownerByteCount)`, exact canonical
  `LANOwnerSnapshotV1` bytes (1...524,288), `UInt16BE(slotPayloadByteCount)`, exact section-6 slot
  payload, `sessionEpoch[16]`, `snapshotID[16]`, canonical eight-byte simulation tick, canonical
  eight-byte owner revision, canonical eight-byte inventory revision, `UInt64BE(credentialGeneration
  1...1_000_000_000)`, and canonical eight-byte last-applied host checkpoint generation.
- Pending/disposition payload: ASCII `PBLCP1`, `UInt16BE(1)`, the same one-byte mode stored in SQL,
  `UInt32BE(requestByteCount)`, exact raw canonical request bytes (1...65,536), `sessionEpoch[16]`,
  `UInt64BE(requestID 1...1_000_000_000)`, canonical eight-byte expected RPG authority revision,
  one inventory-revision presence tag followed by its canonical eight bytes when present, one closed
  operation tag, one closed send-state tag, `UInt32BE(dispositionBindingByteCount)`, and the strict
  disposition/request-zero binding bytes (zero only for `awaitingState`; nonempty for
  `dispositionOnly`).
- Notice payload: ASCII `PBLCN1`, `UInt16BE(1)`, the same one-byte status stored in SQL,
  `UInt16BE(reasonByteCount)` plus 0...256 raw reason bytes, `UInt16BE(messageByteCount)` plus
  0...512 raw message bytes, `bundleIdentityDigest[32]`, and
  `UInt64BE(creationCheckpointGeneration)`. Raw text is digest-verified protocol data; the two independent display/
  accessibility sanitizers run only after load and never alter this payload.

Credential/owner/pending payload decoders enforce exact end-of-input. Owner canonical bytes and raw
request bytes are length-capped before their strict nested scanners/decoders. A syntactically valid
envelope with semantically invalid owner/request/credential/notice content is corruption and is not
returned as a storage snapshot.

### 9.1 Count and byte caps

- At most 256 distinct client host/world/lookup scopes exist.
- Each credential payload is at most 65,536 bytes; all credential rows together are at most
  16,777,216 payload bytes.
- Each owner payload is at most 786,432 bytes; all owner rows together are at most 201,326,592
  payload bytes.
- Each pending/disposition payload is at most 131,072 bytes; all such rows together are at most
  33,554,432 payload bytes.
- For each exact host/world/lookup scope the inbox is at most 256 rows and 1,048,576 accounted bytes.
  One inbox row accounts as `512 + 16 + 16 + 32 + 32 + 16 + 8 + 16 + 8 + 8 + 8 + payloadBytes + 32`
  and must be at most 4,608 accounted bytes.
- Across all 256 scopes, inbox rows are at most 65,536 and 268,435,456 accounted bytes.
- Every count/SUM and candidate-delta calculation uses checked `Int64`, occurs before mutation in the
  same transaction, and rejects cap-plus-one without eviction except the acknowledged-only pruning
  defined below.

Reads first verify storage class, SQL byte length, per-row cap, per-scope count/SUM, and global
count/SUM before copying a BLOB. They keyset-page by exact BINARY primary/index order; no unbounded
result accumulation or partial prefix is returned from an invalid table.

### 9.2 Canonical row digests

Each row payload is a strict, duplicate-free, sorted-key canonical byte codec owned by PebbleCore,
not arbitrary JSON. Storage constructors verify only fixed identity, cap, generation, and 32-byte
digest shape; the SaveDB adapter recomputes and fixed-time compares the digest before and after every
facade call. Digest inputs are:

- credential: `SHA256("Pebble/LANv6/client-credential/v1\0" || key || UInt64BE(generation) || payload)`;
- owner: `SHA256("Pebble/LANv6/client-owner/v1\0" || key || UInt64BE(generation) || payload)`;
- pending/disposition:
  `SHA256("Pebble/LANv6/client-pending/v1\0" || key || UInt64BE(generation) || UInt8(mode) || payload)`;
- inbox payload:
  `SHA256("Pebble/LANv6/client-notice-payload/v1\0" || key || notificationID || sessionEpoch ||
  UInt64BE(requestID) || snapshotID || UInt8(status) || UInt64BE(creationGeneration) || payload)`.

`key` is exactly `hid[16] || wid[16] || lookupDigest[32]`. The aggregate digest stored on the
credential anchor is:

`SHA256("Pebble/LANv6/client-checkpoint-aggregate/v1\0" || key || UInt64BE(generation) ||
credentialDigest || ownerPresenceTag || ownerLastChangeGenerationIfPresent || ownerDigestIfPresent ||
pendingPresenceTag || pendingLastChangeGenerationIfPresent || pendingDigestIfPresent)`.

Inbox rows are deliberately outside the aggregate digest because their separate acknowledgement
transaction must not rewrite authority generation. Atomic insertion with pending/credential/owner is
provided by the one SQLite transaction, while each notice has its own deterministic identity and
payload digest. Startup recomputes the aggregate from the three authority rows, validates every inbox
row independently plus its per-scope caps/unique identities, and rejects either family before
publishing a candidate.

In the row-digest bullets, owner/pending `generation` means that row's bounded
`last_change_generation`; credential `generation` means the current anchor generation. Startup and
every commit require each present component's last-change generation to be no greater than the
anchor and bind both that generation and digest into the aggregate. This permits a disposition-only
commit to advance credential/pending while leaving owner bytes, owner digest, and owner last-change
generation exactly unchanged.

The deterministic notification ID is exactly:

`SHA256("Pebble-LAN-v6-notice\0" || hid[16] || wid[16] || sessionEpoch[16] || UInt64BE(requestID))`.

The notice payload digest stored in its canonical payload is separately the protocol bundle identity
digest over length-prefixed exact manifest payload, canonical owner bytes, and canonical chunk-
binding encoding. Same ID/same digest is idempotent; same ID/different digest is a protocol violation
that retains the old row and rolls back the complete checkpoint.

## 10. Client checkpoint typed surface

The storage target exports exact primitive values with throwing, bound-checking initializers:

```swift
public struct PebbleLANClientAuthorityStorageKey: Sendable, Equatable, Hashable {
    public let hostInstallationID: Data // 16
    public let worldLANID: Data         // 16
    public let lookupDigest: Data       // 32
}

public struct PebbleLANClientCredentialStorageRow: Sendable {
    public let key: PebbleLANClientAuthorityStorageKey
    public let schemaVersion: UInt16
    public let aggregateGeneration: UInt64
    public let aggregateDigest: Data
    public let authorityBound: Bool
    public let payload: Data
    public let payloadDigest: Data
}
public struct PebbleLANClientOwnerCheckpointStorageRow: Sendable {
    public let key: PebbleLANClientAuthorityStorageKey
    public let schemaVersion: UInt16
    public let lastChangeGeneration: UInt64
    public let payload: Data
    public let payloadDigest: Data
}
public enum PebbleLANClientPendingMode: UInt8, Sendable, Equatable { case awaitingState = 1, dispositionOnly = 2 }
public struct PebbleLANClientPendingDispositionStorageRow: Sendable {
    public let key: PebbleLANClientAuthorityStorageKey
    public let schemaVersion: UInt16
    public let lastChangeGeneration: UInt64
    public let mode: PebbleLANClientPendingMode
    public let payload: Data
    public let payloadDigest: Data
}
public enum PebbleLANClientNoticeStatus: UInt8, Sendable, Equatable {
    case accepted = 1, rejected = 2, outcomeEvicted = 3, requestExhausted = 4
}
public enum PebbleLANClientNoticeAcknowledgement: UInt8, Sendable, Equatable {
    case pendingRender = 0, acknowledged = 1
}
public struct PebbleLANClientNotificationStorageRow: Sendable {
    public let key: PebbleLANClientAuthorityStorageKey
    public let notificationID: Data
    public let sessionEpoch: Data
    public let requestID: UInt64
    public let snapshotID: Data
    public let status: PebbleLANClientNoticeStatus
    public let creationGeneration: UInt64
    public let acknowledgement: PebbleLANClientNoticeAcknowledgement
    public let acknowledgementGeneration: UInt64
    public let payload: Data
    public let payloadDigest: Data
}

public enum PebbleLANClientOwnerRowChange: Sendable {
    case unchanged
    case set(PebbleLANClientOwnerCheckpointStorageRow)
    case remove(expectedDigest: Data)
}
public enum PebbleLANClientPendingRowChange: Sendable {
    case unchanged
    case set(PebbleLANClientPendingDispositionStorageRow)
    case remove(expectedDigest: Data)
}

public struct PebbleLANClientAuthorityCheckpointSnapshot: Sendable {
    public let credential: PebbleLANClientCredentialStorageRow
    public let owner: PebbleLANClientOwnerCheckpointStorageRow?
    public let pending: PebbleLANClientPendingDispositionStorageRow?
    public let oldestPendingNotice: PebbleLANClientNotificationStorageRow?
}

public enum PebbleLANClientAuthorityTransitionKind: UInt8, Sendable, Equatable {
    case firstRequestZeroBind = 1
    case ordinary = 2
}

public struct PebbleLANClientAuthorityCheckpointCandidate: Sendable {
    public let key: PebbleLANClientAuthorityStorageKey
    public let transition: PebbleLANClientAuthorityTransitionKind
    public let expectedAggregateGeneration: UInt64
    public let expectedAggregateDigest: Data
    public let credential: PebbleLANClientCredentialStorageRow
    public let ownerChange: PebbleLANClientOwnerRowChange
    public let pendingChange: PebbleLANClientPendingRowChange
    public let noticeInsert: PebbleLANClientNotificationStorageRow?
}

public struct PebbleLANClientAuthorityCheckpointReceipt: Sendable {
    public let snapshot: PebbleLANClientAuthorityCheckpointSnapshot
    public let committedAggregateGeneration: UInt64
    public let committedAggregateDigest: Data
}
```

All initializers are explicit throwing initializers that enforce the exact sizes/domains above; no
memberwise public initializer is synthesized. The checked-in symbol manifest freezes each concrete
signature and rejects a generic/`Any` carrier. Secret-bearing credential/snapshot/candidate/receipt
types are not `Equatable`, `Hashable`, `Codable`, `CustomStringConvertible`, or
`CustomDebugStringConvertible`; tests compare reviewed digests/fields and token authentication uses
the fixed 32-byte XOR accumulator rather than `Data ==`.

```swift
public final class PebbleClientAuthorityCheckpointV6Storage {
    public func load(
        key: PebbleLANClientAuthorityStorageKey
    ) throws -> PebbleLANClientAuthorityCheckpointSnapshot

    public func commit(
        _ candidate: PebbleLANClientAuthorityCheckpointCandidate
    ) throws -> PebbleLANClientAuthorityCheckpointReceipt

    public func oldestPendingNotice(
        key: PebbleLANClientAuthorityStorageKey
    ) throws -> PebbleLANClientNotificationStorageRow?

    public func acknowledgeNotice(
        key: PebbleLANClientAuthorityStorageKey,
        notificationID: Data,
        expectedPayloadDigest: Data,
        expectedAcknowledgementGeneration: UInt64
    ) throws -> PebbleLANClientNotificationStorageRow
}
```

The coordinator adds `clientAuthorityCheckpointV6() throws`. The Phase-2.5 admission facade may
create/refresh the credential row only with `authority_bound=0`, aggregate generation 0, no owner,
no pending/disposition authority row, and no inbox row. Before first owner bind that credential
payload is pending-only at credential generation 1; refresh may change only the exact pending
handshake/expiry allowed by Phase 2.5 and cannot add active material. It cannot obtain this authority façade. The
authority façade cannot access host credential/token indexes, host identities, permissions, legacy
quarantine, or any core/local-world table.

### 10.1 Complete commit algorithm

Before enqueue, PebbleCore strictly decodes every candidate payload, validates the cross-row host/
world/generation/revision/credential/pending relationship, computes every row/aggregate digest,
reserves the post-COMMIT publication value, and encodes all bytes. Storage then performs one immediate
transaction:

1. require the exact credential anchor and fixed-time compare expected generation/digest;
2. validate each existing owner/pending last-change generation is in 1...old anchor generation and
   validate its digest plus the old aggregate;
3. compute all per-row, per-scope, and global post-candidate caps, including acknowledged-only inbox
   pruning, without mutation;
4. prune only acknowledged inbox rows belonging to the exact candidate
   `(hid,wid,lookupDigest)` in stable `(acknowledgementGeneration,notificationID)` order and only the
   precomputed minimum required set; per-scope pressure can never prune another scope, and global
   pressure rejects rather than cross-scope pruning;
5. apply explicit owner set/update/remove or unchanged state with exact old predicates; set/update
   stamps candidate anchor generation as last-change, while unchanged performs no owner SQL write;
6. apply explicit pending set/update/remove or unchanged state with exact old predicates; set/update
   stamps candidate anchor generation as last-change, while unchanged performs no pending SQL write;
7. insert a notice or prove an exact same-ID/same-digest existing row; conflicting identity rolls
   back;
8. update the complete credential payload and anchor with explicit columns and exact old generation/
   digest; `authority_bound` may transition 0 to 1 but never back;
9. re-read all changed rows plus the pending-render inbox projection, recompute the aggregate digest,
   require exact candidate equality and `changes()==1` for every intended mutation; and
10. COMMIT, verify autocommit, and return the immutable receipt.

Candidate generation is exactly expected + 1 and expected must be 0...999,999,999. Exhaustion never
wraps. `.firstRequestZeroBind` is the sole first-bind transition. Before enqueue, PebbleCore strictly
decodes the old credential receipt and candidate: the old row must be `authority_bound=0`, aggregate
generation 0, pending-only flags, no active token, and one pending raw token at credential generation
1 with its handshake/expiry present. The candidate must be `authority_bound=1`, aggregate generation
1, active-only flags, active generation exactly 1, raw active token fixed-time byte-equal to the old
pending token, and every pending token/generation/handshake/expiry field absent. Host/world/lookup
key and every retained credential byte are exact; the candidate cannot fabricate, substitute,
truncate, normalize, or regenerate credential material.

Inside the immediate transaction, the storage boundary independently decodes the stored old and
candidate `PBLCC1` envelopes, repeats all presence/generation checks and the fixed 32-byte XOR token
comparison before any statement mutates, and requires no owner/pending/inbox rows. It then inserts a
complete owner row at last-change generation 1, updates the complete credential/aggregate anchor to
generation 1, leaves pending absent, and inserts no notice. Request-zero success uses exactly this
owner+credential transaction and never creates a terminal notice. Any one-byte difference or extra/
missing field rolls back. `.ordinary` requires an already-bound anchor at generation at least 1 and
cannot change `authority_bound`; generation-0 ordinary commits fail before SQL.

A disposition-only transition leaves owner bytes, digest, and last-change generation exactly
unchanged while it advances the anchor and changes pending/inbox atomically. A LAN slot
assign/move/clear/default/owner-normalization operation
must supply the complete unchanged credential and pending values plus a complete candidate owner row;
there is no slot-only transaction or partial merge.

Encode, decode, reserve, BEGIN, bind, step, changes, finalize, cap, CAS, same-ID collision,
postcondition, COMMIT, and disk failure preserve all stored rows and all live owner/slot/credential/
pending/inbox state. Stale CAS returns conflict and requires a fresh user activation; it never reloads
and reapplies a slot delta.

### 10.2 Notice acknowledgement

`acknowledgeNotice` is the sole narrow exception to whole-authority commit. It may update only
`acknowledgement_state` and `acknowledgement_generation` for one pending-render row where key,
notification ID, payload digest, and expected acknowledgement generation all match. Candidate
state/generation is exactly `0/0 -> 1/1`; expected generation must be 0 and no second transition is
valid. It requires `changes()==1`, re-reads the row,
and commits. It cannot delete, prune, modify payload, clear pending, change owner/slots/credential,
or change the authority aggregate generation/digest.

The caller may invoke it only after `UIManager.commitSemanticModel` returns the exact screen instance,
semantic revision, notification ID, and payload digest receipt. Storage knows none of those UI types;
PebbleCore verifies them before constructing primitive arguments. Bundle receipt, decode, draw,
screenshot, or accessibility rebuild cannot acknowledge.

## 11. Host owner checkpoint row schema

These rows are dormant components of the later coherent host checkpoint. Creating/verifying the
schema does not expose a writer.

```sql
CREATE TABLE lan_peer_authority_checkpoint_v6(
  hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
  wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
  authority TEXT NOT NULL COLLATE BINARY
    CHECK(typeof(authority)='text'
      AND length(CAST(authority AS BLOB)) BETWEEN 5 AND 24),
  checkpoint_generation BLOB NOT NULL
    CHECK(typeof(checkpoint_generation)='blob' AND length(checkpoint_generation)=8),
  payload BLOB NOT NULL
    CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 786432),
  payload_digest BLOB NOT NULL
    CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
  world_checkpoint_digest BLOB NOT NULL
    CHECK(typeof(world_checkpoint_digest)='blob' AND length(world_checkpoint_digest)=32),
  PRIMARY KEY(hid,wid,authority),
  FOREIGN KEY(hid,wid,authority)
    REFERENCES lan_peer_identity_v6(hid,wid,authority)
    ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
```

```sql
CREATE TABLE lan_host_local_authority_checkpoint_v6(
  hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
  wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
  authority TEXT NOT NULL COLLATE BINARY
    CHECK(typeof(authority)='text' AND authority='host:local'),
  checkpoint_generation BLOB NOT NULL
    CHECK(typeof(checkpoint_generation)='blob' AND length(checkpoint_generation)=8),
  payload BLOB NOT NULL
    CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 786432),
  payload_digest BLOB NOT NULL
    CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
  world_checkpoint_digest BLOB NOT NULL
    CHECK(typeof(world_checkpoint_digest)='blob' AND length(world_checkpoint_digest)=32),
  PRIMARY KEY(hid,wid),
  FOREIGN KEY(hid,wid)
    REFERENCES lan_world_identity_registry_v1(hid,wid)
    ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
```

Guest authority text must additionally pass the strict `lan:<joinedOrdinal>` parser in PebbleCore;
DDL length is defense in depth. Persistent capacity is at most 256 guest owner rows plus exactly zero
or one host-local row per world. Guest owner payload bytes are at most 201,326,592; guest rows,
host-local row, keys, digests, and the frozen per-row/index overhead share one 268,435,456-byte
persistent owner pool per world. Candidate-delta COUNT/SUM checks occur before ordinal allocation or
mutation. This persistent cap is distinct from runtime: one live coherent checkpoint may include at
most eight authenticated guest rows plus the host-local row and at most 7,077,888 owner payload
bytes. Dormant resumable guest rows do not consume a live peer slot merely because they persist.

The payload contains only canonical owner/checkpoint fields, owner/inventory revisions, melee/tick
state, and checkpoint linkage. It has no raw/hashed credential, token index, nonce/claim, permission,
socket/runtime lease, handshake, expiry, identity allocator, quick-slot token, or client notice.

The parent tables must expose the exact matching BLOB/TEXT BINARY unique keys before this component
can bootstrap. If the final reviewed Phase-2.2/2.3 parent column names or keys differ from
`(hid,wid)` and `(hid,wid,authority)`, this DDL returns to Architecture and Security plan; the Builder
may not drop the foreign keys or add an adapter index to make a stale plan compile.

The public/package symbol graph may include primitive row constructors only when the complete host
checkpoint phase is approved. This amendment exposes no `put`, `upsert`, `compareAndSwap`, or
owner-only façade method for these tables. The future
`PebbleHostAuthorityCheckpointV6Storage.commit(_ completeCheckpoint:)` must span the complete world/
journal/entity/relation/RNG/task/descriptor/owner transaction frozen in `LAN_RPG_PROTOCOL_V6.md`.
Its authorizer must deny every credential/index/identity/permission/client table and use explicit
columns plus earliest-expected/latest-result CAS. Until that complete candidate type and all its
tables pass Architecture and Security, runtime access to both host tables is deny-all.

Two other future transactions receive closed, non-general access:

- `allocateLANPeerAuthorityV6` owns ordinal burn plus identity, initial credential/index, permission,
  capacity accounting, and one complete initial guest owner-row INSERT in the same transaction. It
  can insert only a previously absent owner key at checkpoint generation zero/initial digest; it
  cannot update/delete an existing owner, create host-local state, or commit world effects.
- `retireLANPeerAuthorityV6` requires the reviewed no-live-runtime/retirement proof and atomically
  removes token indexes/credential/permission plus the exact guest owner row while updating identity
  lifecycle, retired audit/summary, and capacity accounting. It can read/delete only the named
  retiring owner and cannot insert/update owner payload or touch host-local state.

These are concrete methods on the future closed host identity façade, not a host-owner façade or
capability token exposed to PebbleCore callers. Their candidates contain every affected typed row and
expected digest; no callback/generic/SQL carrier exists. Allocation/retirement authorizer scopes are
inactive until their separately reviewed parent phases pass.

## 12. Authorizer and lock-rank contract

Private capabilities are exact and non-forgeable:

| Capability | Allowed tables/actions | Explicit denials |
| --- | --- | --- |
| three component-specific revision-1 bootstrap scopes | only that component's DDL/marker insert and schema pragmas before its readiness | other component DDL/data and all runtime use |
| `rpgLocalPreferencesReadV1` | SELECT named columns from the two local tables, bounded COUNT/SUM | every write; every LAN/core table |
| `rpgLocalPreferencesWriteV1` | transaction control, explicit SELECT/INSERT/UPDATE on the two local tables, and SELECT of only `worlds.id` to prove the exact parent exists | DELETE; every other core column/table; all LAN tables |
| `playerJSONCompareAndSwapV1` | transaction control; SELECT/READ exactly `worlds.id`; SELECT/READ exactly `player.world` and `player.json`; INSERT exactly one `player` row; UPDATE exactly `player.json` | DELETE; every other worlds/player column or action; every other table; attached databases; triggers/views; nesting; and every other façade/capability |
| `coreWorldDeleteWithRPGV1` | one non-nestable transaction with bounded SELECT/count plus the six exact marker, preference, worlds, chunks, player, and advancements DELETEs/predicates in section 7 | every insert/update; templates, LAN resume/players, v6 tables, and unrelated core rows/columns |
| `lanClientCredentialAdmissionV6` | credential table only, and only rows with `authority_bound=0` | owner, pending, inbox, local, host, identity/index/permission tables |
| `lanClientAuthorityCheckpointV6` | exact four client tables and named index; transaction control | all host/core/local/identity/permission/quarantine tables |
| `lanClientNoticeAcknowledgementV6` | SELECT plus two-column UPDATE on one inbox row | insert/delete/payload update and every other table |
| `lanHostOwnerRowsDormantV6` | deny-all at runtime in this amendment | every operation |
| future `lanHostIdentityAllocationV6` | INSERT one absent guest owner only as part of complete ordinal/identity/credential/index/permission allocation | owner update/delete, host-local, world checkpoint, client/local tables |
| future `lanHostIdentityRetirementV6` | SELECT/DELETE one proven retiring guest owner as part of complete retirement/audit transaction | owner insert/update, host-local, world checkpoint, client/local tables |
| future `lanHostAuthorityCheckpointV6` | only complete reviewed coherent checkpoint table set | credential/token/nonce/identity/permission/client/local tables |

The authorizer validates action, database `main`, table, column, operation generation, and null
trigger/view source at prepare time. Dynamic scope is restored to deny-all after each façade method;
prepared statements cannot escape. A façade cannot select its capability and cross-capability nested
entry fails before SQL.

`PebbleLegacyCoreStorage.deleteWorld(id:)` selects `coreWorldDeleteWithRPGV1` directly; it is the
only façade method that can obtain it. That scope cannot call/re-enter `rpgLocalPreferences*`, and the
local façade has no delete method. Existing outward `SaveDB.deleteWorld` behavior remains idempotent,
but no other core delete or LAN/template operation inherits access to either RPG table.

All methods use the Phase2B SaveDB executor and rank 12. Local/UI/GameCore candidate construction and
publication occur outside rank 12. Client authority lock order is
`admission/domain authority -> saveQueue rank 11 -> SaveDB rank 12`; DB callbacks never acquire an
authority lock, dispatch main, or invoke gameplay. The returned immutable receipt is published only
after rank 12 releases. Reordered receipt tests prove the authority's publication-pending lease stops
later mutations from overtaking durable state.

For checked snapshot/CAS, stored-row digest/decode, candidate JSON encoding, row construction, omit-
candidate construction, and Core error mapping are outside rank 12. Rank 12 contains only one
existing `getPlayerJSON` invocation or one new concrete `compareAndSwapPlayerJSON` transaction.
Instrumentation observes rank 0 -> 12 -> 0, and the GameCore final CAS segment is main-actor,
non-suspending, and holds no gameplay/domain lock. Existing saveQueue callers retain rank 11 -> 12;
the CAS introduces no reverse edge or new rank. Encoding failure never enters the facade.

The amendment adds no new lock rank and cannot weaken Phase2B's rank-10 migration lease or its
security remediation. Local preference migration executes only during ordinary world entry after
legacy loose-save migration/open has completed; the two migration systems never nest.

## 13. Exact v5 and cutover behavior

- `LAN_MULTIPLAYER_PROTOCOL_VERSION` remains 5 throughout local preference/client-schema build.
- `lan_players` and `lan_player_resume` remain readable/writable through the existing v5 façade until
  the separately reviewed atomic v6 cutover. This amendment neither renames nor reads them.
- No local or client-v6 façade accepts a v5 `worldID#seed`, peer ID, player name, host label, address,
  world name, seed, service name, or legacy resume JSON.
- A local single-player/host world may migrate the legacy player quick-slot envelope only after its
  exact loaded `WorldRecord.id` is captured and its matching world row exists.
- A protocol-5 LAN client has no `LANHostInstallationIDV6`/`LANWorldIDV6` scope and cannot call local
  migration or client authority storage. Slot edits fail without disk/live publication, authoritative
  operations submit zero new-sheet v5 intent, and the legacy envelope remains re-encoded.
- V5 public/owner state stops carrying quick slots only in the reviewed Track-B compatibility change
  after local migration persistence exists. No receiver may default omitted slots into authority.
- V6 client owner state begins only after request-zero validates and the complete client checkpoint
  commits. Neither missing v6 state nor any v5/quarantine row supplies owner, inventory, RPG,
  revisions, pose, or slots.
- The later cutover atomically seals/renames v5 tables, verifies the v6 schema marker, disables v5
  callers, and only then activates protocol 6. Failure leaves v5 active and v6 unreachable; it never
  exposes both authority paths.

## 14. Scanner, API manifest, and release-verifier amendment

This work begins from the final security-passed Phase2B scanner, not the currently failed version.
The Phase2B remediation must first prove static literal concatenation/interpolation recognition,
fail-closed attribute handling, exact symbol USR/kind/access/owner inventory, bridge/type/closure
escape rejection, and the complete compiling bypass fixture matrix.

Afterward:

1. Regenerate `pebble-storage-api-v1.json` into a temporary diff only. Review every new public,
   package, or SPI symbol. Accept only the concrete primitive row/candidate/receipt/facade symbols in
   sections 7 and 10, coordinator accessors, and no host mutation façade.
   The old checked-in manifest/hash remains input evidence. The only accepted semantic diff is the
   four exact public symbols in section 7.4 with their frozen signatures/access/conformances. A fifth
   symbol, package/SPI mirror, different signature/access/conformance, generic/callback/unconditional
   checked-write symbol, or broader core facade fails review and verification.
2. Update `pebble-core-storage-capability-v1.json` for exact additional declaration/use occurrences in
   `Saves.swift`, including exact checked get and CAS row/digest/expectation/result occurrences.
   `LegacySaveMigration.swift` is unchanged. `RPGLocalPreferences.swift`, network/UI,
   app, and tests outside `@testable` test imports may not name a PebbleStorage type or qualifier.
3. The scanner must reject copied façade types, aliases, protocols, generic wrappers, stored storage-
   typed properties outside `SaveDB`, closures/callbacks, `Any` carriers, SQL strings, raw table names,
   and a third production import owner. Add independently compiling negative fixtures for each new
   row/facade escape and for a slot-only client checkpoint wrapper.
4. Update the release-surface verifier's reviewed storage source/object/API hashes and symbol
   allowlist. It must still prove fresh `PebbleStorage.o`, `Pebble`, and `pebsmoke`; zero SQLite
   imports/calls in PebbleCore objects; no DEBUG failure seams; no new dylib/framework; and no
   credential/owner payload sentinel in symbols, strings, logs, or errors.
   It must additionally prove exactly one public checked get and CAS plus closed Core row types/error;
   exactly the four reviewed concrete PebbleStorage CAS symbols; no unconditional throwing player
   writer; no checked method outside `SaveDB`; no omission path calling compatibility `putPlayer`;
   and no error string containing JSON/player data, paths, SQL, or SQLite codes.
5. Run source scan and API comparison before build; run binary verifier immediately after the exact
   release build it evaluates. Pipeline/pre-push fail closed if either manifest or verifier is stale.

No script offers `--accept`, overwrites a manifest automatically, or treats a hash mismatch as a
warning. Any post-review symbol/signature/owner change returns to Architecture and Security plan.
The current section-2.1 hashes are input evidence and remain unchanged in this planning edit. New
`Saves.swift`, capability manifest, scanner fixture aggregate, tests, verifier, object, executable,
and plan hashes are captured only from the completed reviewed implementation; no placeholder hash is
written now.

## 15. Required tests

### 15.1 Schema and authorizer

- Empty Phase2B schema -> complete revision 1; every statement failure/restart -> exact old or new;
  exact marker/component/digest; duplicate/partial/future/extra/trigger/view/wrong SQL rejection.
- Exact table/column/type/not-null/PK/BINARY/FK/index/without-rowid/CHECK manifests.
- First local bootstrap owns marker-table creation atomically; later bootstrap cannot create/alter it;
  client credential parent plus three children/index/marker reject every partial subset; host owner
  children cannot bootstrap before both exact parent schemas/FKs and reject every partial subset.
- Every capability's allowed statement prepares and every cross-table/action/column attempt fails;
  admission cannot read owner/pending/inbox, authority cannot read host identity/permission/index,
  notice acknowledgement cannot alter payload, local cannot name LAN, and host rows are deny-all.
- Context escape, wrong queue/generation, nested transaction, caught-error COMMIT, statement leak,
  close race, poisoned rollback, and redacted failure behavior remain green.

### 15.2 Local preference and migration

- Checked get proves absent/present semantics, exact stored bytes, full domain-separated digest field
  mutation, fixed-time 32-byte compare, malformed stored-row rejection, and redacted closed errors.
  Candidate encoding/row failure proves rank-12 entry count zero.
- Exhaustive error-mapping tests route every candidate encode/row failure only to invalidCandidate;
  every stored class/UTF-8/size/JSON/root failure only to invalidStoredRow; every CAS/parent mismatch
  only to conflict; and every lifecycle/I/O/transaction failure only to persistenceFailed, with no
  raw-error passthrough or case overlap.
- Digest constructor 31/32/33; world ID UTF-8 0/1/1,048,576/1,048,577; player JSON UTF-8
  786,431/786,432/786,433; incremental digest allocation; wrong-class/oversized stored world/json;
  and invalid UTF-8 prove rejection before enqueue, rank, full copy, or digest/candidate publication.
- CAS covers absent+absent insert; absent+present conflict; present+absent conflict; present+wrong-
  digest conflict; present+exact update; one change/re-read/exact digest; every BEGIN/prepare/bind/
  step/changes/finalize/postcondition/COMMIT failure; and reopen proof that CAS conflict/failure makes
  zero mutation. Durable state is the exact pre-CAS row unless a demonstrably later serialized writer
  or world delete commits, in which case it is exactly that later writer/delete result.
- The private CAS authorizer admits only exact worlds.id parent and player world/json read plus player
  insert/json-update. Missing/wrong/duplicate parent conflicts for absent and present. World deletion
  committed before CAS cannot recreate a row; deletion after CAS removes it. Tests cover both orders
  and reject DELETE/other column/table/trigger/view/attached/nested access.
- Deterministic pre-facade and post-commit barriers interleave compatibility `putPlayer`, ordinary
  save, saveAndFlush, and shutdown. A writer before CAS changes the digest, returns conflict, and its
  durable row remains byte-identical; a writer after CAS remains the final later row. Compatibility
  writes remain serialized and nonthrowing.
- Same-world re-entry, A-B-A, envelope replacement, live-revision change, and world teardown attempts
  at both barriers prove the main-actor non-suspending segment prevents session interleaving and no
  stale candidate changes durable state. Success alone persists the slot-free row then publishes
  omission; failure leaves Player/live envelope and revisions/notifications unchanged.
- Crash cuts before/after CAS mutation/COMMIT/Core return/publication restart as exact old row, exact
  CAS row, or a proven later writer; no stale candidate overwrites a newer row.
- Rank/scanner/API/verifier tests assert rank 0/12/0, rank11->12 compatibility, exact checked Core and
  four concrete storage symbols, no unconditional checked writer/generic widening, checked-CAS-only
  omission call sites, capability counts, and fresh source/object/executable hashes.

- World ID UTF-8 0/1/64/65, BINARY composed/decomposed equality distinction, wrong SQLite storage
  classes, row count 255/256/257, row 4,095/4,096/4,097, aggregate cap-1/cap/cap+1, and arithmetic
  overflow.
- Slot codec nil/value tags, exactly nine, 0/1/128/129 token bytes, grammar, unique tokens, trailing
  bytes, malformed lengths/UTF-8, fixed-seed decode fuzz and encode/decode metamorphism.
- Source/destination domain separation, every field one-byte mutation, integer endian boundaries,
  incremental chunk boundaries, and fixed-time 32-byte digest comparison.
- Absent destination insertion, existing destination wins, exact marker idempotence, every marker/
  destination/source mismatch, marker-absent/origin-present rejection, marker-present/current-row-
  advanced acceptance, stale CAS, revision max-1/max, injected BEGIN/bind/step/changes/
  finalize/postcondition/COMMIT failure, and delayed completion after switching between equal-named
  worlds with different IDs.
- Nonlegacy `materializeIfAbsent` absent/existing/all-nil/default/corrupt cases prove one insert at
  revision 1, no marker/origin, no refill/merge, and identical idempotent restart.
- Crash before/after destination, marker, COMMIT, GameCore receipt publication, and player save;
  restart proves the old player key remains until the exact marker+destination commit and omission is
  safe/idempotent afterward. Also edit slots after marker COMMIT but before player-save COMMIT, crash,
  and prove the immutable origin still authorizes safe omission without overwriting the newer slots.
- World deletion uses the one non-nestable existing-facade capability; exact 0/1 and chunk-count
  predicates, statement order, postcondition, every statement/COMMIT failure rollback, idempotent
  absent-world behavior, and proof templates/LAN resume/LAN players/every unrelated core row remain
  unchanged.
- LAN/v5/v6 scopes passed to the local adapter fail before storage invocation.

### 15.3 Client complete checkpoint

- Key lengths and lookup digest mismatch; credential 65,535/65,536/65,537; owner
  786,431/786,432/786,433; pending 131,071/131,072/131,073; notice row and per-scope/global inbox
  count/byte caps; 255/256/257 scopes; wrong storage classes and corrupt digests before copy.
- Generation 0 admission; exact first request-zero `bound 0/generation 0/no children -> bound
  1/generation 1/owner last-change 1/no pending/no notice`; every malformed first-bind variant;
  old pending-only credential generation exactly 1 -> candidate active-only generation 1 with
  fixed-time byte-equal token; one-byte mutations of every old pending token/generation/handshake/
  expiry/flag field and every candidate active/pending/token/generation field at both pre-enqueue and
  in-transaction validation seams;
  max-1/max/exhaustion, stale expected digest, authority-bound one-way transition, absent/present
  owner and pending cross-product, component last-change 1/anchor/anchor+1, disposition owner
  unchanged, and exact aggregate recomputation on restart.
- Assign/move/clear/default materialization/owner normalization all use one complete transaction.
  Inject every encode/decode/reserve/BEGIN/statement/CAS/prune/insert/postcondition/COMMIT failure and
  assert byte equality of owner, nine slots, credentials, pending/disposition, inbox, aggregate
  digest/generation, applied-bundle FIFO, and live publication.
- Disposition-only commits, request-zero, credential pending promotion/rotation, pending clear,
  terminal notice insertion, same-ID/same-digest replay, same-ID/different-digest protocol failure,
  request ID 0 rejection and proof request-zero inserts no notice, exact acknowledgement 0/0 -> 1/1
  with every crossed pair rejected, acknowledged-only stable pruning constrained to the exact
  host/world/lookup scope, global pressure with zero cross-scope eviction, full pending-render
  rejection, and no pending clear without its notice.
- Crash before COMMIT, after COMMIT/before publish, after publish/before render, after semantic model
  commit/before acknowledgement, and after acknowledgement; repeated restart proves at-least-once UI
  delivery and no duplicate durable identity.
- Concurrent slot edit versus owner apply, credential rotation, reconnect/disposition, notice ack,
  scope switch, and close. Stale CAS never merges/replays; each successful receipt publishes once and
  in generation order.

### 15.4 Host rows and v5 isolation

- Persistent 0/1/8/9/255/256/257 guest rows, host-local absent/present/duplicate, payload and shared
  268,435,456-byte pool boundaries, plus separate live-checkpoint 8+host/7,077,888 limits; strict
  authority syntax and generation/digest corruption.
- Allocation exact initial INSERT/ordinal/capacity atomicity and retirement exact DELETE/audit/
  capacity atomicity, with every statement/failure cut preserving all affected rows.
- Source/API/authorizer audit proves no standalone host owner writer and no host checkpoint access to
  credential/token/identity/permission/client/local tables.
- V5 world/guest/resume round trips stay unchanged before cutover; no v5 helper sees any new table;
  local slot migration never consumes a LAN envelope; protocol-5 semantic commands submit zero new UI
  RPG intent and create zero v6/local-preference rows.

### 15.5 Scanner and property evidence

- Final Phase2B complete compiling bypass matrix plus new façade/carrier/slot-only wrapper fixtures.
- Exact symbol graph and two-owner capability manifest diff; reverse dependency/import and third-owner
  attempts fail.
- Fixed-seed property tests interleave two local worlds and every 4x4 LAN host/world cross-product,
  random valid/corrupt payloads, generation conflicts, inbox pressure, and injected failure points;
  print seed and minimized sequence on failure.

## 16. Risk-to-evidence map

| Risk | Required closing evidence |
| --- | --- |
| Legacy slot is lost | marker+destination atomic crash matrix and player-key omission proof |
| Best-effort player save loses the last legacy key | checked-write encode/storage/restart matrix and two-phase omission publication |
| Player CAS widens storage authority or leaks data | closed errors, exact concrete symbols, rank probes, API/capability/scanner/verifier diff |
| Stale omit candidate overwrites newer save | full-row digest CAS plus compatibility/ordinary/shutdown barrier races |
| CAS recreates player after world deletion | exact parent proof and delete-before/delete-after absent/present tests |
| Malformed digest/row allocates or crosses rank | digest/world/JSON boundary and wrong-class pre-copy/pre-rank matrix |
| Preference leaks across worlds | exact BINARY world ID and delayed-completion cross-world tests |
| LAN slot splits security state | complete checkpoint byte-equality fault matrix; no slot-only API |
| Stale UI overwrites owner apply | generation+digest CAS conflict and fresh-activation proof |
| Credential promoted without owner/pending | first-bound and promotion crash/interleaving matrix |
| Pending clears without notice | full inbox rollback/cap/restart matrix |
| Notice is spoofed or acknowledged early | deterministic ID, bundle digest, semantic receipt, ack CAS tests |
| Host owner survives without world effects | no standalone writer plus future coherent checkpoint gate |
| v5 silently authenticates v6 | zero bridge/source audit and cutover atomicity tests |
| Schema/API widens SQLite authority | exact pragma/authorizer/symbol/capability/binary manifests |
| Phase2B unsafe migration is inherited | satisfied baseline: all ten blocking Security findings received fresh Security and Tester PASS; hashes must remain exact |

## 17. Gate order

1. **COMPLETED:** Phase2B Builder remediated every Security code FAIL finding.
2. **COMPLETED:** independent Phase2B Security code review PASS.
3. **COMPLETED:** independent Phase2B Tester PASS, with 175/175 expanded and 55/55 decisive tests;
   its root release/verifier/full-suite/`pebsmoke`/pipeline evidence remains part of the retained gate.
4. **COMPLETED:** rehash final Phase2B source, scanner/manifests, verifier, tests, and this amendment's
   pre-baseline contract; exact hashes are section 2.1.
5. **COMPLETED:** reconcile the immutable migration-origin rule into the RPG UI plan and renew its
   affected Architecture/Security review.
6. **COMPLETED:** independent Security plan review PASS for this amendment.
7. **COMPLETED:** safe-deferral Builder implemented the local storage surface while leaving client
   semantic and host writer paths dormant.
8. **COMPLETED:** independent Security code review PASS for that safe-deferral implementation.
9. **COMPLETED:** independent Tester PASS for that safe-deferral implementation.
10. **COMPLETED:** Architecture adds the exact expected-old-row CAS and two-phase omission contract
    in section 7.4 without changing the frozen input hashes.
11. Renewed independent Security plan review of only this API/omission delta.
12. Builder implements checked snapshot/CAS, two-phase GameCore/Player flow, focused race/fault/crash/rank/
    scanner tests, and reviewed manifests/verifier changes. No other storage/API widening.
13. Independent Security code review and Tester PASS of the actual delta; only then record new
    implementation hashes and resume actionable RPG UI Track B wiring.
14. Security code -> installed Design Sign-off -> independent Test -> pipeline -> deploy -> installed
    hash/signature -> Neo, in the ordering required by the RPG UI plan.

Focused storage command, followed by the unchanged full release sequence:

```bash
bash scripts/security-scan.sh
swift test --filter 'SaveDBPlayerRowCASTests|RPGLocalPreferenceStorageTests|RPGLocalPreferencesTests|LANV6ClientAuthorityCheckpointStorageTests|LANV6HostOwnerCheckpointStorageTests|LANV6SchemaAuthorizerTests|PebbleStorageExecutorTests|PebbleStorageAdversarialTests|RPGCharacterStateTests|RPGCoreV2Tests|RPGQuickSlotInputTests|LANClientRoutingTests|LANMultiplayerTests|LANReplicationTests'
swift build -c release
bash scripts/verify-pebble-storage-release-surface.sh
swift test
swift run -c release pebsmoke
bash scripts/pipeline.sh
```

Report actual exit codes, test counts, warning count, scanner fixture count, artifact hashes, and
installed proof. A code change after any gate invalidates the affected evidence.

## 18. Conditions for Builder

- Phase2B and the safe-deferral implementation retain their prior PASS evidence. Preserve every exact
  section-2.1 hash as input evidence; the prior amendment Security-plan PASS does not authorize the
  new CAS API. Renew Security plan review, then record new implementation hashes only after code
  Security and Tester PASS. No exception is implied by parallel UI work.
- Preserve the one physical SQLite owner/executor, rank order, explicit close, lease/tombstone, and
  remediated migration invariants.
- Create the complete revision-1 schema atomically and verify every object/column/index/FK/CHECK and
  marker digest before exposing a façade.
- Only the first local component creates the component-marker table; Phase 2.5 solely bootstraps the
  complete client credential/owner/pending/inbox component; host children wait for exact parent FKs.
  No partial parent/child/component marker state is accepted or repaired.
- Export only the concrete primitive values and named façades frozen here. No generic, callback,
  closure, protocol, `Any`, SQL, capability, table-name, or storage-context escape.
- Add exactly checked get/snapshot and expected-old-row CAS Core APIs/types plus the four closed
  redacted error cases and exact concrete PebbleStorage digest/expectation/result/CAS symbols. Keep
  compatibility `putPlayer(_:_:) -> Void` on existing serialization. Digest/decode/candidate/error
  work occurs at rank 0; rank 12 contains only get or one CAS transaction. No unconditional checked
  writer, generic carrier, callback, production barrier, or new lock rank is permitted.
- PebbleStorage adds exactly the four public declarations in section 7.4 and zero package/SPI mirror.
  Preserve their exact `Sendable`/`Equatable` conformances and 32-byte throwing initializer; every
  listed prohibited conformance/property/initializer/carrier is forbidden.
- The private `playerJSONCompareAndSwapV1` scope reads only exact worlds.id parent and player
  world/json and mutates only player insert or json update. Exactly one parent precedes absent/present
  mutation; missing/duplicate/wrong parent conflicts. World-delete-before cannot recreate and delete-
  after remains later. All digest/world/JSON boundaries reject before copy/rank as specified.
- Local preferences are keyed only by exact local `WorldRecord.id`; LAN uses only exact raw v6
  host/world/lookup identities. No global/settings/name/seed/address/v5 fallback.
- While the owning world still exists and the source envelope remains live and non-omittable, its old
  player slot key remains live and durable after destination+marker COMMIT. GameCore builds an explicit
  omit candidate, calls only exact full-row CAS, and publishes omission only after CAS success plus a
  second scope/generation/revision/envelope/origin validation. CAS conflict/failure itself performs
  zero mutation; durable state is the exact pre-CAS row or the exact result of a demonstrably later
  serialized writer/delete. World deletion legitimately removes the row/key, and envelope replacement
  ends the prior envelope's key-retention claim without authorizing stale omission.
- Persist before publish. Every failure leaves live publication unchanged; its own CAS changes no disk
  state, while a separately ordered later writer/delete remains authoritative.
- Local CAS and client aggregate CAS never merge or replay stale user intent.
- LAN assign/move/clear/default/owner normalization use the whole checkpoint. Do not add a slot-only
  row, transaction, or convenience wrapper.
- Admission credential methods stop at `authority_bound=0`; after first owner bind, only the complete
  client authority transaction may change credentials.
- Notice acknowledgement changes only its two acknowledgement columns after exact UI semantic receipt
  validation; it cannot clear pending or mutate owner/slots.
- Host owner rows have no standalone writer. They become writable only inside the future complete
  coherent host checkpoint transaction, the closed all-fields initial identity allocation INSERT,
  or the closed proven-retirement DELETE; they never contain client slots or credential fields.
- Persistent host capacity is 256 guest rows plus one host-local row in the shared 256-MiB pool;
  runtime admission/checkpoint capacity remains a separate eight guests plus host limit.
- V5 remains active and isolated until one reviewed atomic cutover; this amendment does not activate
  v6 or rename/quarantine legacy tables.
- Update scanner/API/capability/release manifests through reviewed semantic diffs only; every bypass
  fixture must compile before the scanner rejects it.
- Treat the old PebbleStorage API manifest/hash as input only. Its post-implementation semantic diff
  must contain exactly the four frozen public CAS symbols and nothing else; a fifth symbol or any
  package/SPI addition fails. Core capability manifest, scanner fixtures, tests, verifier, and fresh
  hashes update only from reviewed code and must prove CAS-only omission call sites.
- Preserve RPG registration order, saved IDs, deterministic codecs, quick-slot nil positions, v5
  ordinary behavior, non-RPG saves/settings, and all Phase2A/Phase2B tests.

**Architecture verdict: PASS for the expected-old-player-row CAS amendment.** The checked snapshot,
full domain-separated digest, fixed-time transactional CAS, absent/present semantics, closed errors,
compatibility serialization, non-suspending main-actor segment, deterministic races, and manifest/
hash rules are complete without generic widening or stale overwrite. The prior
Security-plan PASS covers the safe-deferral implementation only; renewed Security plan PASS is
required before this delta is built. Any further contract, DDL, API, transaction, test, verifier, or
baseline change returns to Architecture plus Security plan review.

## 19. Renewed Security plan gate record (2026-07-10)

**Reviewed amendment SHA-256:**
`28ab1fb80d9422483477ea1942900b9c2c02b461e51f4742f62212e82a03d2d5`

**Correlated RPG UI plan SHA-256:**
`66ee29e0448a85b1e401dba2457618c2fd77aacd87cc1345bcc736c3d5e14dfe`

**Reviewed scope:** only the expected-old-player-row snapshot/digest/CAS API and the two-phase
GameCore legacy-slot omission delta in section 7.4, including exact public surface, closed error
mapping, bounded incremental digest construction, transaction authorizer, exact-parent proof,
absent/present state matrix, rank ordering, compatibility-writer serialization, stale-writer and
world-delete races, crash boundaries, scanner/API/capability/release manifests, and focused test
obligations. The retained Phase 2.0B and safe-deferral baselines were checked for hash and contract
drift; the correlated RPG UI plan remained at the exact hash above.

**Findings:** none. The prior four amendment inconsistencies and both final wording contradictions
are closed. Hostile stored-row class, size, UTF-8, JSON, and bounded-read failures map exactly to
`.invalidStoredRow`, never `.persistenceFailed`. CAS conflict/failure itself performs no mutation;
the durable row may instead reflect a demonstrably later serialized writer or world deletion, while
live omission is published only after CAS success and the complete second provenance validation.

**Verdict: PASS.** Builder is authorized only for the closed section-7.4 CAS and two-phase omission
delta and only in section 17 order. This PASS does not authorize any additional public/package/SPI
storage surface, generic carrier, callback, SQL/capability escape, protocol-v6 activation, client
semantic adapter, host writer, cutover, or Track C behavior. Security code review and independent
Tester PASS remain mandatory before implementation hashes, installed Design Sign-off, deploy, or
actionable RPG UI wiring.
