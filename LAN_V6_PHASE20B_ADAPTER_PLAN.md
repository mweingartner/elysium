# LAN v6 Phase 2.0B — SaveDB Typed-Adapter and Legacy-Migration Contract

Status: Implementation complete with independent Security code PASS and Tester PASS. Final focused
evidence is 175/175 expanded persistence tests and 55/55 decisive adversarial tests. Phase 2.0A is
complete with independent Security code PASS and Tester PASS evidence. Design Mock, Design Review,
and Design Sign-off are N/A because this is an internal
persistence rewrite with no intended visible or interactive change. That N/A remains valid only if
the implementation preserves every public v5 save/gameplay failure shape and adds no visible copy,
state, control, timing promise, or interaction.

This phase starts only after Phase 2.0A has independent Security and Tester PASS results, including
the template limits, narrow legacy projections, replace-complete import, durability barrier, and
database-parent identity seam frozen in
`LAN_V6_PHASE20A_TEMPLATE_COMPATIBILITY_AMENDMENT.md`. It removes SQLite from PebbleCore while
preserving valid save formats and public failure shapes. It does not add v6 identity/schema,
transport, gameplay, or UI behavior.

## Frozen dependency and adapter-input baseline

Architecture revalidation used these exact inputs:

- Phase 2 implementation contract SHA
  `5655c1ce68741799ca2d8fa36a5a52e92cb5e44ff9cd92865695e939f8c66241`;
- Phase 2.0A template/import amendment SHA
  `d0648a1852b806dcc142023105bcd31c4962a26b380b08221fecb8526928bb5c`;
- final Phase 2.0A code-review remediation contract SHA
  `b7e94a92f906b2cc4fb10ceace16dda665e6ad636ec5737071efa38c48a81233`;
- current `Package.swift` SHA
  `50270ebc175f60239feba2c4f2ba0ce75ee3f26e4fd97c7af1630a0d9000710a`;
- final Builder `Sources/PebbleStorage/StorageEngine.swift` SHA
  `ae73b775aef8f7e286a47eaae4260d9f63064feb63ec16c916787f32208db5bb`;
- current adapter input `Sources/PebbleCore/Game/Saves.swift` SHA
  `cb1b32c3b973f0486ff6ffc7822086049a0a540d574e96fc6ce7e5b9a78c85e3`;
- mandatory release verifier SHA
  `ca5fe73a61d812365db78e26fc627614b73e138cc50b5e1336eb7ed9e81a12bb`.

The completed Phase 2.0A evidence is Security code-review PASS, independent Tester PASS, 71/71
focused storage/schema/adversarial tests, and 618/618 full XCTest. Its warning-free release build
and the verifier above also passed. Phase 2.0B must preserve that exact executor and verifier.

Before Build, the owner rehashes these files and confirms Phase 2.0A has actual independent Security
code-review and Tester PASS evidence. Any drift in `Package.swift`, the PebbleStorage source, its
externally reachable symbol graph, or the release verifier stops Phase 2.0B and returns to
Architecture plus Security plan review. Drift in `Saves.swift` requires a complete call-site and
outward-semantics reconciliation before Build. A matching hash is a dependency check, not a
substitute for Phase 2.0A gate evidence.

The reviewed PebbleStorage surface is exactly the current closed operation/error types (including
the already-frozen `primary: any Error` fields on transaction/statement failures), primitive row/DTO constructors,
`PebbleStorageCoordinator.open(databaseURL:)`, `legacyCore()`, `close()`,
`verifyDatabaseParentIdentity(device:inode:)`, and the named `PebbleLegacyCoreStorage` methods
already present in that source, including `verifyCoreSchema()`, parameter-free
`prepareLegacyMigrationRename()`, narrow legacy projections, replace-complete
`importLegacyWorld(_:)`, and typed core row methods. Phase 2.0B adds no PebbleStorage symbol and does
not edit `Package.swift`, `StorageEngine.swift`, `scripts/verify-pebble-storage-release-surface.sh`,
`scripts/pipeline.sh`, or `.githooks/pre-push`.

## Files and dependency order

1. Add `Sources/PebbleCore/Game/LockRank.swift` with the closed persistence rank utility.
2. Add `Sources/PebbleCore/Game/LegacySaveMigration.swift` with the fd-relative parser, source
   lease, manifest, import, and rename state machine.
3. Rewrite `Sources/PebbleCore/Game/Saves.swift` as a typed `PebbleStorage` adapter; retain the
   domain JSON, VCK1, and template codecs.
4. Route all `Sources/PebbleCore/Game/GameCore.swift` save-queue entries through the rank-11
   helpers, and explicitly close the database after the terminal save in `Sources/Pebble/main.swift`.
5. Add `Tests/PebbleCoreTests/PersistenceTestSupport.swift`,
   `Tests/PebbleCoreTests/SaveDBLifecycleTests.swift`,
   `Tests/PebbleCoreTests/LegacySaveMigrationTests.swift`, and
   `Tests/PebbleCoreTests/PersistenceLockRankTests.swift`; extend
   `Tests/PebbleCoreTests/SaveDBTests.swift` for the adapter matrix. Update only database ownership,
   unique-temporary-database construction, and explicit-close cleanup in the existing direct
   SaveDB/GameCore owners in `FoodUseTests.swift`, `LANClientRoutingTests.swift`,
   `LANMultiplayerTests.swift`, `RPGConsumerHardeningTests.swift`, `RPGCoreV2Tests.swift`,
   `RPGQuickSlotInputTests.swift`, `RPGSecurityRegressionTests.swift`, and `TemplateTests.swift`.
6. Add `scripts/sqlite-boundary-scan.swift`, scanner fixtures under `Tests/SecurityScanFixtures/`,
   freeze `scripts/pebble-storage-api-v1.json` plus
   `scripts/pebble-core-storage-capability-v1.json`, and call the scanner/self-test from
   `scripts/security-scan.sh`.
7. Update `ARCHITECTURE.md`, `SECURITY.md`, and `CONTRIBUTING.md` with the one-way storage boundary,
   migration limits/recovery states, lock ranks, explicit close, and verifier command.

No adapter implementation may begin before the revised plan passes Security and its Phase 2.0A
dependencies have independent Security and Tester PASS evidence. No file outside the list above
changes in this phase without a renewed plan review.

## Closed factory and lifecycle

`SaveDB` stores exactly:

```swift
private let coordinator: PebbleStorageCoordinator
private let storage: PebbleLegacyCoreStorage
```

It adds:

```swift
public static func open(databaseURL: URL, migrateLegacy: Bool) throws -> SaveDB
public func close() throws
```

Every factory failure is translated; no underlying error is returned or retained:

```swift
public struct SaveDBOpenError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Stage: String, Sendable {
        case storageOpen, schemaVerification, legacyBackupRecoveryRequired
        case migrationParent, migrationLease, migrationManifest
        case migrationDecode, migrationImport, migrationBarrier
        case migrationRename, migrationDirectorySync, cleanup
    }

    public enum Result: String, Sendable {
        case unavailable, conflict, invalidSource, limitExceeded
        case unsupported, durabilityFailure, cleanupFailed
    }

    public let stage: Stage
    public let result: Result
}
```

`description` is exactly `Pebble save open failed: <stage>/<result>` using only the two closed raw
values. It stores no `Error`, `NSError`, errno,
SQLite code/detail, URL/path, filename, identifier, JSON, or payload. The factory opens the
coordinator under rank 12, obtains `legacyCore`, verifies the exact schema, and exits that rank.
When migration is requested it runs the closed migration state machine; it publishes `SaveDB` only
after every required import, barrier, rename, and parent sync succeeds. On failure it best-effort
closes. If cleanup also fails, the original stage is returned with result `cleanupFailed`; neither
underlying failure is exposed.

Construction uses one private temporary `OpenComponents` value containing only the coordinator and
legacy facade, one private throwing `openComponents(databaseURL:migrateLegacy:)`, and one private
designated `init(components:)`. `SaveDB.open` calls the throwing helper and then the designated
initializer. Each compatibility initializer calls a nonthrowing helper that invokes that same
throwing component factory, catches every error, and terminates with the fixed literal below before
delegating to `init(components:)`. There is no second open/schema/migration implementation and no
initializer publishes or assigns a partially initialized `SaveDB`.

The component factory invokes one module-internal, non-callback
`LegacySaveMigration.run(databaseURL:coordinator:storage:) throws -> LegacyMigrationStorageSession`
before returning components. VCK1
encode/decode logic is extracted into module-internal pure helpers in `Saves.swift`; the existing
`SaveDB.decodeChunk` test seam and ordinary get/put methods delegate to those helpers. Migration
instead calls the frozen registry-independent structural validator below and retains raw VCK bytes
unchanged. Thus migration does not require a partially
constructed `SaveDB`, and neither the storage facade nor the migration runner accepts an arbitrary
codec/storage closure.

When `migrateLegacy` is true, `openComponents` first runs a filesystem-only namespace preflight
under the persistent parent migration lock, before calling `PebbleStorageCoordinator.open`. Source,
backup, provenance, and recovery-state classification therefore occurs before SQLite bootstrap can
CREATE/ALTER or otherwise mutate the database. An unmarked backup-only state creates/validates the
recovery-required record and throws without opening a coordinator. Only source-only, neither-state,
or already-valid v2-provenance states may proceed to coordinator open; the source-only lock is held
through coordinator open, import, barrier, restart, and final publication.

The storage-to-public factory mapping is closed and exhaustive. During
`PebbleStorageCoordinator.open`, `duplicateOpen` maps to `storageOpen/conflict`; `invalidValue`,
`invalidStorageClass`, `invalidUTF8`, `schemaMismatch`, and `schemaIntegrity` map to
`storageOpen/invalidSource`; `limitExceeded` maps to `storageOpen/limitExceeded`; every other error
maps to `storageOpen/unavailable`. After a coordinator exists, failure to obtain `legacyCore` or to
run `verifyCoreSchema()` uses the same result mapping with stage `schemaVerification`. Transaction
or statement wrapper errors and unknown errors use `unavailable`; their nested/primary errors are
never inspected, retained, formatted, or returned. Migration owns its already closed stage/result
mapping. If best-effort close after any post-open failure also fails, the original stage is retained
and only its result becomes `cleanupFailed`.

An unmarked backup-only recovery refusal is not mapped to `invalidSource` or `unsupported`: it is
the dedicated `legacyBackupRecoveryRequired/conflict` stage/result. Its persisted recovery record is
validated before the coordinator is published, and the coordinator is closed without any mutation.

The existing no-argument initializer and internal `init(databaseURL:migrateLegacy:)` remain
nonthrowing compatibility seams over the same factory. They terminate with exactly this literal and
never interpolate even the closed error:

```text
Pebble save database initialization failed
```

`close()` synchronously enters rank 12 and delegates to the coordinator lifecycle. A successful
close is stable and idempotent. A failed close whose executor proved physical disposal returns the
same stable terminal failure. An unproven terminal disposal returns `poisoned` on later calls,
retains the path/inode tombstone, and is never described as an idempotent disposed result.
`deinit` never closes synchronously: it copies only the coordinator and enqueues it on one static
serial utility cleanup queue; the fresh closure enters rank 12, closes without logging, and does not
capture `self`. Explicit close/deinit races rely on those exact coordinator terminal semantics;
healthy deinit cleanup eventually releases the lease, while poisoned cleanup eventually disposes
the descriptor but deliberately retains the tombstone.

The app termination path performs `finalizeAndSave(synchronous: true)` when a world is active and
then always executes `try? game.db.close()` outside that condition. Tests and non-app owners
explicitly close; deferred deinit cleanup is only a nonblocking safety net.

## Lock ranks and queue routing

`LockRank.swift` uses DEBUG pthread TLS, storing `rank + 1` with `pthread_setspecific` so nil means
rank zero. `withRank` requires `previous < requested` and restores the exact prior pointer in
`defer`; release builds preserve the wrapper shape with no assertion overhead.

```swift
enum PebbleLockRank: Int {
    case migrationSource = 10
    case saveQueue = 11
    case saveDB = 12
    case publication = 20
}
```

The migration source token is acquired at rank 10 and may synchronously enter SaveDB rank 12; its
registry `NSLock` is released before filesystem or storage work. GameCore adds a per-instance
`DispatchSpecificKey<UInt8>` and sets it on `saveQueue`. All raw queue access is replaced by:

- `withSaveQueueSync`: if already on the exact queue, require current rank 11 and run inline;
  otherwise `saveQueue.sync` and enter rank 11 exactly once.
- `withSaveQueueAsync`: enqueue, then enter rank 11 inside the queued closure.

Every coordinator/facade call—including open, schema verification, ordinary methods, import,
barrier, and close—uses one `withStorageRank` rank-12 wrapper. Domain coding, filesystem work, clock
sampling, logging, and publication occur outside rank 12. Publication/later-rank test scopes reject
12 acquisition; being on the main thread alone is not treated as holding a publication lock.

Tests cover 0→12, 0→10→12, and 0→11→12 success; 12→11, 12→12, and 20→12 subprocess traps;
save-queue self-entry without deadlock; explicit-close/deinit races; deinit returning while cleanup
is queued; healthy eventual lease release; poisoned eventual descriptor disposal with permanent
tombstone rejection; and the source audit proving raw `saveQueue.sync/async` appears only in the two
helpers.

Because Phase 2.0A enforces one process-wide coordinator per physical database, XCTest must never
use the production default database. `PersistenceTestSupport` creates one unique temporary parent
and `SaveDB.open(..., migrateLegacy: false)` per owner, registers cleanup, and explicitly closes
after any GameCore save queue is drained. Every existing bare `GameCore()` in the test target is
replaced by an injected unique test database; tests that deliberately reuse one database share one
still-open `SaveDB` and close only after the last owner. A source audit rejects bare `GameCore()` and
nonthrowing `SaveDB(databaseURL:migrateLegacy:)` construction in test sources except dedicated
compatibility-initializer subprocess cases. This prevents parallel XCTest from converting an
expected duplicate lease into the compatibility initializer's intentional fatal termination.

## Domain adapters and exact outward behavior

`sanitizeJSON`, `chunkKey`, VCK1 `encodeChunk`, and `decodeChunk` remain in PebbleCore. The VCK1
implementation is shared through the module-internal pure helpers frozen above. All domain
validation/encoding finishes before a storage call and all decoding occurs after it returns.
Private adapters perform exact `Int32(exactly:)` coordinate conversion and primitive-row mapping.
PebbleStorage never imports a PebbleCore type.

- `listWorlds` uses `listLegacyWorldJSON`, decodes each bounded JSON string, and skips bad domain
  rows. Storage failure returns `[]`; world order remains unspecified.
- `getWorld` uses `getLegacyWorldJSON`; missing/storage/decode failure returns nil. `putWorld` and
  atomic `deleteWorld` preserve `Void` and swallow storage failure.
- `getChunkKeys` maps bounded ordered keys into the existing `Set<String>`; failure returns empty.
  `getChunk` requires exact Int32 coordinates and retains the VCK1 decoder/failure shape.
- `putChunks([])` remains true on an open database but still crosses the facade lifecycle. Nonempty input is fully
  encoded/mapped before one atomic `putChunkBlobRows`; one encode/range/row/storage failure returns
  false with zero partial writes. After close, the empty call also returns false because the required
  lifecycle crossing fails.
- Player, advancement, resume, and LAN APIs use the narrow legacy JSON reads and typed writes while
  preserving optional/Void shapes. LAN list remains unsigned-UTF8/BINARY player-ID ordered and
  skips individually malformed domain JSON.
- DEBUG `execRawLANPlayerInsertForTesting` accepts no SQL and writes only one bounded typed row; it
  is absent from release builds.
- Template names are normalized before storage. Invalid names still throw `TemplateError.invalidName`.
  `getTemplate` treats nil format as 1. When `format >= 2` and data is nonnil/nonempty it decodes that
  BLOB and propagates a domain decode error without JSON fallback; only format below 2 or absent/empty
  data reaches nonempty legacy JSON. Missing/storage payload returns nil. Put/delete retain their
  Bool/domain-throw shapes. Names and summaries use the narrow methods and remain UTF-8/BINARY ordered.
- For each `PebbleTemplateSummaryCandidate`, stored metadata is used only when every required field
  is nonnil, block count is positive, and both dominant strings are nonempty. Otherwise SaveDB loads
  and summarizes that one template after the list call has returned. A failed fallback skips only
  that row; top-level list failure returns `[]`.

The post-close compatibility matrix is exact: list methods return empty collections; get methods
return nil; Void mutations are no-ops; `putChunks` and template Bool mutations return false;
normalized valid-name `getTemplate` returns nil; and invalid template names still throw
`TemplateError.invalidName` because domain validation precedes storage. `chunkKey` and direct VCK1
decode remain pure and available. Only `close()` and the new throwing factory expose a storage
failure.

### Frozen resume `updated` normalization

One pure helper runs outside storage. Swift/Objective-C numeric types bridge through `NSNumber` and
use `doubleValue`; Bool intentionally preserves legacy behavior (`false = 0`, `true = 1`). Finite
values—including negative/out-of-epoch values—are stored unchanged. NaN becomes 0; positive
infinity becomes `Double.greatestFiniteMagnitude`; negative infinity becomes its negative. Missing,
`NSNull`, strings, arrays, dictionaries, and other nonnumeric values lazily sample the clock exactly
once. Numeric/Bool/nonfinite values never sample it. A nonfinite injected test-clock result becomes
0. JSON sanitation stays unchanged: Bool remains Bool and nonfinite JSON values become zero. The
clock seam is DEBUG-only and fixed-value/count based, never a production callback.

## Fd-relative migration parser

`LegacySaveMigration.swift` contains no SQLite, SQL, `FileManager`, `Data(contentsOf:)`,
`contentsOfDirectory`, or `moveItem`. After the storage coordinator exists, it resolves the database
parent with `realpath`, opens that canonical path with
`O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY`, `fstat`s it, and immediately calls
`verifyDatabaseParentIdentity(device:inode:)`. No weaker fallback is allowed.

It also opens the one database filename relative to that parent with
`O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK`, proves regular type, and retains its device/inode.
The runner brackets that open with coordinator parent/retained-database proofs and requires a
no-follow `fstatat` of the database name to equal the retained migration descriptor before and after
every barrier, restart, equivalence proof, and provenance operation. Thus the provenance database
identity is derived without a new PebbleStorage getter yet cannot bind a raced replacement.

That comparison call is the exact Phase 2.0A public seam: it returns no retained identity or
descriptor. A supplied mismatch is a closed migration-parent failure and does not by itself poison
an intact coordinator; failure of the executor's own retained parent/database proof poisons and
tombstones. Phase 2.0B repeats the comparison immediately before the parameter-free
`prepareLegacyMigrationRename()`. Barrier success means Phase 2.0A completed FULL WAL checkpoint,
`F_FULLFSYNC` of its retained database descriptor, and the mandatory post-sync retained-identity
proof. The adapter adds no separate SQLite checkpoint/sync, cannot observe DEBUG stages, and does not
rename on any barrier throw.

All descendants use a held directory descriptor plus one validated component and `openat` with
`O_NOFOLLOW | O_CLOEXEC`. Every fixed directory (`saves`, `worlds`, `chunks`, `player`, and
`advancements`) is opened with exactly
`O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW` and then verified `S_IFDIR`; no blocking plain
read open is permitted. Candidate files additionally use `O_NONBLOCK`. Every component is nonempty,
not `.`/`..`, and contains no slash or NUL.

Missing optional `player`, `advancements`, `chunks`, or per-world chunk directories mean no rows;
missing `worlds` means no valid worlds and leaves source in place. If any fixed name exists but is
not the required owned directory, migration fails rather than treating it as absent.

Each enumeration pass obtains a fresh open file description with a new directory `openat`, proves
its identity matches the retained descriptor, then transfers that fresh FD to `fdopendir`; it never
uses `fdopendir(dup(fd))` or shares/reuses a prior directory offset. Enumeration uses `readdir` and
`closedir`; reads use checked `pread` loops with `EINTR` retry. A candidate must be `S_IFREG`, have
`st_nlink == 1`, and retain the same device, inode, link count, size, mtime, and ctime before/after
the exact-size read plus one-byte EOF probe. Every entry is strict UTF-8 and accepted entries sort
by raw unsigned UTF-8 bytes. Every errno is captured immediately and mapped to a closed result; no
path/name/ID/data enters an error or log.

Every retained regular-file manifest entry has an exact 32-byte SHA-256 content fingerprint,
computed incrementally with CryptoKit over precisely `st_size` bytes read by checked offset-based
`pread` loops plus the one-byte EOF proof. The hasher uses one ledger-reserved 65,536-byte scratch
buffer, retries only `EINTR`, rejects short/long/overflowing reads, and never constructs an
unaccounted whole-file `Data`. Every regular entry's `st_size`, including ignored regular entries,
is checked-added to the 2,147,483,648-byte all-source ledger before hashing, so fingerprint work is
bounded. Each retained digest is charged exactly 32 resident bytes in addition
to its manifest-entry charge. The initial manifest pass records digest plus the full
`(device,inode,mode,uid,nlink,size,mtime sec/nsec,ctime sec/nsec)` tuple. Every materialization reread
recomputes the digest while filling the already charged exact-size buffer and requires digest and
the complete before/after tuple to equal the initial entry before decode/import. Final
re-enumeration rehashes and compares the same values. The complete-manifest root is SHA-256 over
type-tagged, length-prefixed raw names, full stat tuples, and file digests in deterministic tree/
unsigned-UTF8 order. Same-size edits, restored-mtime edits, inode replacement, one-byte mutation,
and change-then-restore races therefore cannot pass on metadata alone.

### Exact grammar and binding

- World candidates are exactly nonempty `<stem>.json` with literal lowercase suffix. After decoding
  `WorldRecord`, its UTF-8 ID bytes must exactly equal the stem bytes or the complete migration
  fails. Stems `.` and `..` are forbidden. Raw-byte and Swift-canonical-equivalence ID sets reject
  duplicates/Unicode aliases before mutation.
- Player and advancement files are opened directly as `<bound-world-stem>.json` in their fixed
  directories; their storage key always comes from the bound world record.
- Chunk candidates are exactly `<dimension>_<chunkX>_<chunkZ>.vck`; each integer is canonical ASCII
  `0 | -?[1-9][0-9]*`, parsed directly into Int32 with checked multiply/add and round-trip spelling.
  A set rejects duplicate tuples. One pure `validateLegacyVCKStructure` validates content without
  reading `blockDefs`, item/entity registries, or any mutable registration state. It checks magic,
  known flag bits, exact frozen dimension geometry, checked block/biome byte spans, JSON-tail length,
  and the bounded streaming JSON grammar/top-level object, but deliberately does not interpret or
  clamp block IDs. It accepts/rejects the same structural container shapes as the shipped decoder,
  including its existing treatment of trailing bytes and malformed optional block-entity payloads.
  Malformed structural content is skipped because it was already unobservable through the legacy
  getter; accepted raw VCK bytes are imported unchanged. After GameCore completes immutable registry
  boot, the ordinary decoder performs the existing out-of-range block-ID-to-air clamp and optional
  domain repair. Migration outcome is therefore independent of cold registry order while later load
  safety and v5 behavior remain unchanged.
- Nonmatching entries remain ignored for compatibility but count toward enumeration limits. An exact
  candidate that is a symlink, wrong type, hard link, raced, unreadable, over-cap, ID-mismatched, or
  duplicate aborts and leaves `saves` retained. Corrupt bounded world JSON remains skippable; ID
  mismatch and canonical alias are structural failures. Bounded malformed optional player/
  advancement JSON is skipped. Every final manifest check freshly re-enumerates all non-dot names
  (including ignored entries) and requires the same sorted names, identities, and fingerprints, so
  additions/removals cannot be hidden between import and rename.

### Payload, structure, and live-memory budgets

All sizes/counts use checked `UInt64` addition. Two independent ledgers fail before allocation or
import: a payload ledger for source/final encoded bytes and a conservative resident ledger for every
simultaneously retained representation.

| Budget | Cap |
|---|---:|
| World JSON file | 1,048,576 bytes |
| Player JSON file | 786,432 bytes |
| Advancement JSON file | 1,048,576 bytes |
| One VCK file | 67,108,864 bytes |
| Valid worlds | 4,096 |
| Canonically named chunk candidates globally | 1,048,576 |
| All non-dot enumerated entries | 1,060,864 |
| All non-dot filename bytes | 268,435,456 |
| Raw chunk payload per world | 268,435,456 bytes |
| Raw or final-row payload per world | 271,319,040 bytes |
| All source payload bytes | 2,147,483,648 bytes |
| Charged live resident memory | 1,073,741,824 bytes |

`271,319,040` is exactly 256 MiB chunks plus one world, player, and advancement payload at their
caps. Raw and encoded payload ledgers are separate: while both coexist both are charged; after a
validated encoded row replaces raw JSON, its raw charge is released. Chunk `Data` ownership is
transferred into the primitive row without copy and remains charged once. Final row constructors
enforce their independent storage caps.

The resident ledger reserves before allocation and releases at explicit lifetime boundaries. Its
minimum conservative charges are frozen as follows:

- each retained manifest entry: `256 + raw filename bytes`; names live once in a raw-byte arena and
  entries retain offsets, not duplicate Swift strings; each temporary duplicate/index entry costs
  another 64 bytes and is released after complete duplicate validation;
- exact owned file buffer: 64 bytes plus requested length rounded up to 16; a second buffer is
  charged separately;
- retained `String`: 64 plus four times its UTF-8 bytes;
- each JSON scalar/member/element node: 256 bytes, plus 128 for each array/object container and four
  times decoded string UTF-8 bytes;
- each retained chunk primitive/array slot: 192 bytes in addition to its one charged `Data` buffer;
- VCK fixed arrays: exact allocated capacities (two bytes per block, one per biome) plus the same
  JSON-node charges for the tail.

No duplicated filename/string/Data representation is allowed without its second charge. The
manifest uses one retained name buffer per entry; indices retain offsets/hashes rather than copied
names. A complete stat-only manifest and global ledgers pass before the first import. World files
are scanned/read/decoded one at a time to bind IDs; only the compact bound ID/fingerprint is retained.
A fingerprint-checked reread materializes one world. World, player, and advancement graphs are
validated, encoded to final row strings, and released sequentially. Each VCK is validated
sequentially and its decode scratch is released before the raw buffer is retained in the chunk row.
The complete compact manifest remains charged through final revalidation; temporary duplicate/
lookup indices not needed by revalidation are released before world materialization.

File reads allocate one exact-size `UnsafeMutableRawBufferPointer` only after its full charge and
wrap it with `Data(bytesNoCopy:deallocator:)`; no Foundation-created file buffer with unknowable
capacity is accepted. Before every Foundation decode, the ledger reserves the scanner-computed
graph/container/string maximum plus bridge scratch of `2 * inputBytes + 1,048,576`; `defer` releases
that entire decode reservation after the graph is encoded/released. Before every JSONEncoder or
JSONSerialization output call, a pure checked upper-bound function computes
`6 * decodedStringUTF8Bytes + 64 * scalarCount + 8 * (memberCount + elementCount) +
2 * containerCount + frozenDomainKeyBytes + 1,024`; the WorldRecord variant includes every current
encoder-emitted default/key even when absent from legacy input. The reservation bound is the greater
of that result and the exact storage output cap. The ledger reserves
`2 * outputReservationBound + 1,048,576` before calling Foundation: one complete bound for returned
`Data`, one for encoder/bridge scratch, and 1 MiB fixed scratch. After return it validates the actual
count against both the computed bound and storage cap, releases scratch, retains the full-bound
charge for the returned `Data`,
separately charges the resulting String at `64 + 4 * actualUTF8Bytes`, then releases the Data charge
when that buffer dies. Failure paths release every token in `defer`. Returned Foundation `Data` is
never charged by an inaccessible capacity or only after allocation.

Before Foundation JSON decoding/serialization, one streaming byte scanner enforces for every world,
player, advancement, and VCK JSON-tail document: depth at most 128; at most 262,144 total nodes;
65,536 containers; 131,072 object members; 262,144 array elements; 1,048,576 decoded UTF-8 bytes in
one string; 2,097,152 decoded string bytes total; and 64 bytes in one number token. It validates
escapes/UTF-8 and reserves the complete worst-case node/container/string charge before Foundation
materialization. Top-level domain shape is then checked by the existing decoder. DEBUG exposes only
current/peak numeric ledger counters, never allocation callbacks or payloads. A DEBUG-only pure
`LegacyMigrationLedgerProbe` accepts only closed `UInt64` charge/count inputs and runs the identical
checked formulas without paths, data, callbacks, storage, or allocation; it proves exact cap,
cap+1, multiplication/addition overflow, and manifest-entry charges cheaply. Smaller real-file
integration tests prove production reserve/release lifetimes correspond to the pure model.

The 256 MiB raw-chunk boundary and 1 GiB charged-resident boundary are documented compatibility
risks required by all-or-nothing import. Any ledger/cap failure preserves the source, prevents
wrapper publication, and releases all charges. Tests exercise simultaneous manifest/world/JSON/VCK
pressure up to the exact resident cap, reject the next charged byte, and prove the peak counter never
exceeds 1,073,741,824; payload maxima whose combined representations exceed the resident cap are
expected to fail before allocation.

## Durable migration provenance and equivalence recovery

Backup presence alone is never migration provenance. For a new source-only import, the shipped
pre-2.0B migrator ignored failed
writes and could rename `saves` after a partial database import, so an unmarked backup-only state is
untrusted. Phase 2.0B creates a same-parent `.pebble-legacy-migration-v2` provenance file only after:

1. every valid world has completed replace-complete import;
2. the complete source manifest and content digests still match;
3. the Phase 2.0A database barrier succeeds;
4. the exclusive source-to-backup rename and parent-directory sync succeed;
5. the coordinator is explicitly closed, reopened against the same physical database/parent, and
   exact source-to-database equivalence is re-proved from the backup; and
6. the reopened schema and parent identity pass again.

The migration runner therefore returns a `LegacyMigrationStorageSession` containing the same or the
reopened coordinator/facade; `openComponents` publishes only that returned session. The bridge type,
runner, and fields are module-internal, non-Sendable, non-Codable, and scanner-confined to
`Saves.swift` plus `LegacySaveMigration.swift`; they expose no SQL, handle, descriptor, callback, or
capability selector.

Equivalence is exact and per bound legacy world for a Phase 2.0B import. Re-materialize one backup world at a time, derive
the exact primitive rows the current adapter would import, then compare `getWorldRow`, player,
advancement, sorted chunk keys, and every chunk BLOB byte-for-byte. Missing optional source rows must
be absent; the stored chunk-key set must exactly equal the manifest set, so stale rows fail. World
JSON, player JSON, advancement JSON, numeric bit patterns, keys, and raw VCK bytes must equal the
current canonical prepared rows; there is no semantic/default/coercing fallback. Unrelated database
worlds and both LAN-v5 tables are outside the equivalence set and remain untouched. A deterministic
equivalence root hashes tagged, length-prefixed prepared row bytes in unsigned-UTF8 world/key order.

An unmarked backup-only directory from the pre-2.0B migrator is never adopted from database-row
presence, lower-bound completeness, stale same-ID rows, or any inferred success claim. A legitimately
evolved old database is observationally indistinguishable from a partial old import without an
immutable success record, so both states enter the same durable closed recovery state. The read-only
manifest/fingerprint scan may produce a diagnostic report for recovery, but it never writes database
rows, runs the barrier, renames the backup, publishes `SaveDB`, or creates inferred provenance.

The durable recovery state is an exact 80-byte little-endian
`.pebble-legacy-backup-recovery-required` record: eight-byte magic `PBLR2\0\0\0`, `UInt32` version 1,
`UInt32` flags 0, the current database device/inode (both zero only when the database entry is
absent), the backup device/inode, and the 32-byte complete-backup-manifest root. It is created only
after the backup is fully validated, through a
0600 no-follow exclusive temp file, complete write, `F_FULLFSYNC`, exclusive rename, and parent
`fsync`; it contains no path, payload, or authorization. A valid recovery record causes every later
open to throw `SaveDBOpenError(stage: .legacyBackupRecoveryRequired, result: .conflict)` before any
database write. A malformed, foreign, stale, or mismatched record fails closed without replacing it.

The explicit non-destructive recovery path is user-confirmed: copy/export the entire backup
directory and its recovery report to an external location; verify that copy; remove the
backup/recovery-state pair from the live parent only after the copy succeeds; restore the verified
copy as `saves` with no `saves-legacy-backup` sibling; remove the recovery-state record; and reopen.
The normal source-only path then performs a fresh exact import, Phase 2.0A barrier, namespace sync,
restart proof, and exact provenance creation. No automatic path silently overwrites evolved rows,
and no recovery step deletes the sole user copy. If source bytes are unavailable, SaveDB remains
closed until the user supplies them; this phase does not invent inferred provenance or a lossy merge.

The provenance file is an exact 128-byte little-endian record: eight-byte magic
`PBLM2\0\0\0`; `UInt32` version `1`; `UInt32` flags `0`; six `UInt64` values for database
device/inode, backup device/inode, valid-world count, and chunk count; the 32-byte complete-manifest
root; and the 32-byte exact equivalence root. No other flag bit is accepted. It is created via
a fixed `.pebble-legacy-migration-v2.tmp` using `openat(O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,
0600)`, complete write, `F_FULLFSYNC`, identity reproof, exclusive same-parent rename, and checked
parent `fsync`. Final and temporary entries are always no-follow classified. A final marker must be
regular, single-linked, effective-UID-owned, mode 0600, exact length/content, bound to the current
database and backup identities, and match a fresh backup manifest root. It is not an authorization
to rewrite or roll back later gameplay rows; after creation, normal world evolution may change the
database rows without invalidating the provenance. A stale/malformed/mismatched marker fails closed.

After every provenance rename return, including an error, classify temp/final by the captured marker
inode. Temp-only means no publication; final-only proceeds to parent sync; both/neither/foreign is
invalid. If that sync fails, attempt one exclusive final-to-temp rollback, classify and sync again,
then fail regardless. A marker is usable in the current process only after checked final parent
sync. On a later process, an observed final marker is still revalidated completely before use; an
observed temp marker is never promoted without rerunning the complete equivalence/restart proof.

An unmarked backup-only state—whether produced by the old migrator or a crash after the new rename—
is read-only classified, emits the durable recovery-required record, and stops with
`legacyBackupRecoveryRequired/conflict`. It never runs the barrier, writes a database row, renames,
deletes, creates v2 provenance, or publishes `SaveDB`. A leftover temporary recovery record is never
accepted; it is removed only after identity validation and before writing a fresh recovery-required
record, with checked parent sync. Once the user restores source bytes through the explicit runbook,
the source-only path performs the fresh exact import and v2 provenance sequence.

Recovery-state classification is exact: source+backup, source+final-marker, neither source nor
backup with a marker, invalid marker, or foreign temp/final entries fail closed; neither source nor
backup and no marker means no legacy migration; source-only and no marker follows replace-complete
import; backup-only with valid v2 provenance is adopted; backup-only without it enters
`legacyBackupRecoveryRequired` before SQLite open. No branch deletes/overwrites user database,
source, or backup content.

## Exclusive migration lease and recovery states

A process-local fail-fast registry keyed by canonical parent `(device,inode)` prevents two database
files in one parent from inspecting the same source. Its `NSLock` is never held during I/O. Before
any source/backup/provenance/temp inspection, every process unconditionally opens persistent same-parent
`.pebble-legacy-migration.lock` with
`O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK` mode 0600, proves it is regular,
single-linked, effective-UID-owned, exact mode 0600, and acquires a nonblocking write
`fcntl(F_SETLK)`. The file is never unlinked. Its retained device/inode/mode/owner/link identity is
revalidated through both the held FD and `fstatat(parentFD, name, AT_SYMLINK_NOFOLLOW)` before and
after every namespace classification, import/equivalence series, barrier, rename, coordinator
restart, provenance write/rename, sync, and rollback. Failure
is conflict/invalid-source; migration never proceeds without this parent-wide lock.

Every source or backup directory that is inspected additionally receives `flock(LOCK_EX | LOCK_NB)`:
source holds it from enumeration through rename/sync/rollback, and backup holds it through marker
validation or unmarked equivalence/restart/provenance recovery. The held source descriptor continues
to lock the same inode after it is renamed to backup. There is no fallback from either lock and no
state inspection before the persistent lock. This prevents a second process from observing a first
process's transient post-rename/pre-sync or rollback state.

Under the lease:

- neither source nor backup: no migration only when provenance/temp is also absent;
- backup only: accept a fully validated final v2 provenance marker; otherwise create/validate the
  recovery-required state and refuse open until explicit source restoration;
- both: conflict before import;
- source only with no valid worlds: leave source in place and publish without a migration message;
- source with valid worlds: manifest, replace-complete imports, barrier, rename, directory sync.

Every name is classified with `fstatat(..., AT_SYMLINK_NOFOLLOW)`. Source/backup entries, when
present, must be effective-UID-owned directories; symlink/special/foreign-owner entries are invalid.
After opening/flocking source, the complete state and persistent lock identity are classified again
before manifest work.

Before the first import, checked `fsync(parentFD)` proves directory-sync support. Each valid world is
fully prepared, then passed to exactly one replace-complete `importLegacyWorld`. A failed later
world leaves earlier commits retry-safe and retains the source; no attempt is made to undo prior
committed worlds.

After all imports:

1. Recheck the coordinator parent identity.
2. Prove `fstatat(parentFD, "saves", AT_SYMLINK_NOFOLLOW)` is the held source inode and revalidate the
   complete manifest.
3. Call parameter-free `prepareLegacyMigrationRename()` under rank 12.
4. Call `renameatx_np(parentFD, "saves", parentFD, "saves-legacy-backup", RENAME_EXCL)`.
5. Prove backup is the captured inode and source is absent.
6. Retry `fsync(parentFD)` only for `EINTR`.
7. Only after sync proceed to the mandatory close/reopen, repeated equivalence proof, and provenance
   protocol above. Print the existing count-only success message and permit SaveDB publication only
   after the final provenance parent sync succeeds.

After every forward `renameatx_np` return—including an error—the code reclassifies source and backup
by no-follow type/owner and captured source inode before mapping the syscall result. Captured inode
only at source means forward rename did not take effect; captured inode only at backup means it did
and the flow proceeds to checked sync even if the return was ambiguous. Both, neither, or a foreign
entry is terminal invalid state and never triggers deletion. `EEXIST` maps to conflict only after
classification proves source retained. `ENOTSUP`, `EOPNOTSUPP`, `ENOSYS`, and flag-related `EINVAL`
map to unsupported under the same proof; ordinary/check-then-rename fallback is forbidden.

After either success or failure of parent sync, classification runs again. If sync fails with the
captured inode only at backup, code attempts exactly one reverse `RENAME_EXCL`; after that return it
classifies again before deciding whether rollback succeeded, then calls parent sync and classifies
again regardless of that result. Proven rollback restores source but still fails the factory. If
rollback cannot be proven, the factory fails, deletes nothing, and reports only closed state while
retaining whichever captured name is actually proven. A later backup-only open remains closed until
valid v2 provenance or explicit source restoration; source-only performs
replace-complete retry.

## SQLite-boundary scanner

`scripts/sqlite-boundary-scan.swift` lexes Swift sources so comments and ordinary gameplay symbols
do not false-fail. It rejects every symlinked file/directory below production target roots, compares
its canonical regular `.swift` inventory with `swift package describe --type json`, and scans every
compiled production source. Across those sources it rejects SQLite3 imports—including scoped
imports and any prefix attribute (`@testable`, `@_implementationOnly`, `@_exported`, or another
attribute)—plus qualified/bare/backtick-escaped `sqlite3_` and `SQLITE_` identifiers and
`OpaquePointer`. Exactly `Sources/PebbleStorage/StorageEngine.swift` may contain them; no second owner
is allowed.

PebbleCore's adapter capability is independently closed. Exactly
`Sources/PebbleCore/Game/Saves.swift` and
`Sources/PebbleCore/Game/LegacySaveMigration.swift` may contain one plain, unscoped
`import PebbleStorage`; every attribute-bearing, scoped, aliased, conditional, `@testable`,
`@_implementationOnly`, or `@_exported` import/re-export is denied even in those files. Every other
production PebbleCore/Pebble/pebsmoke file rejects the import, module qualifier, and every externally
reachable PebbleStorage type identifier derived from the pinned symbol graph, including DTO names
that do not contain the word `Storage`.

`scripts/pebble-core-storage-capability-v1.json` freezes, separately for the two allowed files, each
PebbleStorage symbol USR/base identifier and every module-internal bridge identifier
(`LegacyMigrationStorageSession`, runner, and component handoff), with exact occurrence count,
lexical declaration/use kind, and source-relative owner. The scanner rejects moving/copying an
allowed file, an extra occurrence, inferred bridge use from a third file, typealias/protocol/generic
wrapping, storage-typed closure/property escape, or any non-private/non-frozen declaration that
widens this inventory. `SaveDB` remains the only production Core-facing adapter; no other source can
infer a session and call its members. Manifest regeneration requires a semantic diff and renewed
Security review, never an automatic accept mode.

Outside that exact owner, every decoded literal segment and every statically concatenated literal
is also rejected if it contains case-sensitive `sqlite3_` or `SQLITE_`; this includes attribute
arguments. Foreign-linkage attributes `@_silgen_name`, `@_cdecl`, `@cdecl`, `@_extern`, `@extern`,
and any underscored attribute whose normalized name contains `silgen`, `cdecl`, `extern`, `symbol`,
or `linkage` are forbidden outside the owner. To fail closed on future spellings, every other
underscored attribute is also rejected outside the owner except `_implementationOnly` and
`_exported`, and those two are permitted only immediately before a non-SQLite import. Dynamic symbol
APIs remain denied by the existing security scan. Negative fixtures first compile/link against
SQLite successfully, then must be rejected by this scan, proving they are real bypass attempts
rather than invalid token samples.

The lexer handles nested block/line comments; ordinary and multiline strings; raw ordinary/
multiline strings with arbitrary pound counts; escapes; interpolation boundaries; backtick
identifiers; and `+` concatenation. In PebbleCore literal segments, after concatenation and
whitespace/case normalization, it rejects persistence SQL forms: `SELECT ... FROM`,
`INSERT [OR REPLACE] INTO`, `UPDATE ... SET`, `DELETE FROM`, `CREATE/ALTER/DROP TABLE`, `PRAGMA`,
`BEGIN [IMMEDIATE]`, `COMMIT`, and `ROLLBACK`. Interpolation is a wildcard separator and cannot hide
the two fixed halves of a denied form. This SQL-string rule is defense in depth; the enforceable
boundary is no SQLite imports/symbols and no SQL-accepting public facade.

In `LegacySaveMigration.swift` the token scan additionally rejects `FileManager`,
`Data(contentsOf:)`, `contentsOfDirectory`, and `moveItem`. Under PebbleStorage it rejects any import
of PebbleCore, `DispatchQueue.main`, and `MainActor`.

The script runs `swift package dump-symbol-graph --minimum-access-level package
--include-spi-symbols --skip-synthesized-members`, canonicalizes PebbleStorage's `public`, `open`,
`package`, and SPI symbol kinds/access/declaration fragments, and byte-compares them with reviewed
`scripts/pebble-storage-api-v1.json`. That checked-in manifest is the complete externally reachable
API inventory; any addition/removal/signature/access change fails until the manifest and Security
review change together. Across this inventory, "Core callback/generic escape" includes closure
parameters, closure returns/properties/typealiases, `@escaping`, `@Sendable` function values,
externally reachable protocols/associated types, generic declaration parameters, or a carrier type
outside the exact reviewed primitive/row/facade signature. These are rejected for `public`, `open`,
`package`, and SPI—not only public functions. Private executor closures remain legal.

The sole existing existential-carrier exception is the byte-for-byte frozen
`PebbleStorageTransactionFailure.primary: any Error` and
`PebbleStorageStatementFailure.primary: any Error` surface already present in the pinned Phase 2.0A
symbol graph. The scanner permits those two exact declarations only; it rejects another existential,
generic, protocol, closure, callback, or carrier surface. Phase 2.0B never constructs either error
with caller-controlled callbacks and never retains or exposes either through `SaveDBOpenError`.

The security script runs `swift package dump-package`; the scanner parses that JSON and requires
`PebbleStorage.dependencies == []`, a direct `PebbleCore -> PebbleStorage` dependency, and no reverse
edge. Fixtures cover every import attribute/scoped form; escaped identifiers; raw/multiline/
interpolated/concatenated strings; nested comments; symlinked files/directories; omitted/extra source
inventory; silgen/cdecl/extern foreign symbols; and public/open/package/SPI closure parameters,
returns, properties, typealiases, protocols, and generic carriers. Multi-module compiling fixtures
prove package/SPI surfaces are callable before the scanner rejects them. Benign comments/ordinary
`commit` methods and Darwin-only fd code pass. Alternate SQLite owners, lowercase/split SQL, reverse
imports, and main publication fail.
Dedicated fixtures are outside `Sources`.

The frozen API manifest is generated only from the revalidated PebbleStorage SHA above, reviewed as
a semantic diff, and then checked in; the Builder may not make the scanner green by changing the
storage source or deleting an unexpected symbol. Phase 2.0B also inherits the mandatory Phase 2.0A
release-artifact verifier unchanged. After every release build used as gate evidence,
`scripts/verify-pebble-storage-release-surface.sh` runs immediately and must still prove fresh
`PebbleStorage.o`, `Pebble`, and `pebsmoke` artifacts, the production sentinel, the closed DEBUG
denylist, and the one permitted pre-publication `sqlite3_close_v2` import/source call. The new source
scanner complements that binary gate; neither replaces or weakens the other.

## Required tests

- Throwing factory success; duplicate open; the exhaustive storage-open/schema error mapping;
  explicit/repeated disposed and poisoned close; the exact post-close legacy matrix; concurrent
  close/read/write; deferred deinit; healthy lease release; and poisoned descriptor disposal with
  permanent tombstone rejection.
- Compatibility-initializer subprocess captures stdout/stderr and proves the one literal contains
  none of sentinel path, filename, ID, JSON, or template-name values.
- Parallel unique-database test owners never collide; deliberate same-inode/path-alias duplicate
  owners fail through the throwing factory; the test-source audit finds no bare `GameCore()` or
  nonthrowing database initializer outside the dedicated fatal-error subprocess fixture.
- World/player/advancement/resume/LAN round trips; corrupt selected/ignored columns per the Phase 2.0A
  matrix; Bool and every resume timestamp case with exact clock counts.
- Empty chunk success; one unencodable/out-of-Int32 row yields false and zero writes; unchanged VCK1
  full/entity-only/corrupt-ID/malformed-dimension behavior.
- Template binary/legacy round trip at shipped maximum, delete/order, nil/0/1 format JSON fallback,
  `format >= 2` BLOB preference with no decode-error fallback, and valid candidates surrounding every
  malformed optional field.
- Pure-ledger exact cap/cap+1/overflow/manifest formulas plus smaller real reserve/release integration;
  parser file/structure cap-1/cap/cap+1; Int32 extrema/decimal aliases; ID/stem mismatch,
  composed/decomposed aliases, duplicate reducers, symlink/FIFO/socket/device/hard-link/directory,
  invalid-UTF8 entry, truncate/grow/replace races, shuffled enumeration, ignored-entry cap, and
  one-byte mutation binding properties.
- Exact incremental fingerprint tests cover empty/one-byte/chunk-boundary/cap files, same-size
  one-byte mutation with restored mtime, inode replacement with identical bytes/stat times,
  change-then-restore between initial/materialize/final passes, digest ledger charge/cap overflow,
  and manifest-root order/domain separation.
- A fresh subprocess with empty block/item registries migrates full and entity-only VCK rows through
  the registry-independent structural validator, proves imported BLOB bytes unchanged, then performs
  registry boot and proves ordinary decode preserves valid IDs and clamps only out-of-range IDs.
- Seeded filename, world/player/advancement JSON, and VCK/header-tail parser fuzz/metamorphic tests
  log their fixed seed on failure and assert structural/live-ledger caps.
- Two databases in one parent and alias paths race for the source; at most one reaches mutation.
- Existing backup, two-process rename/sync/rollback observation, unsupported rename, import/barrier/rename/sync failures, rollback success/failure,
  replace-complete stale-row removal, and retry idempotence.
- Table-driven legacy provenance states cover old backup-only with every world/player/advancement/
  first-middle-last-chunk partial-write cut, stale same-ID rows, legitimately evolved old DBs, and
  missing/malformed required rows—all entering `legacyBackupRecoveryRequired` with zero database
  mutation; recovery-record creation/validation/restart behavior; explicit source restoration followed
  by fresh exact import; source-only cuts before/after barrier,
  post-rename/pre-sync crash, post-sync/pre-reopen crash, reopen/proof failure, pre-marker/temp/
  final-marker sync cuts, malformed/stale/foreign markers, later legitimate world evolution after
  valid v2 provenance, and restart proof that no partial/unmarked state publishes.
- Backup-only recovery tests prove namespace preflight rejects before coordinator/SQLite bootstrap,
  database bytes/WAL/schema and user rows are unchanged, the 80-byte recovery state survives restart,
  and only explicit verified source restoration permits a later fresh exact import.
- Ambiguous forward/reverse rename returns exercise captured inode under source, backup, both, and
  neither; every branch proves namespace state after each rename and sync result.
- Every fixed directory replaced by FIFO/socket/device fails under a subprocess timeout; repeated
  fresh enumeration passes return the same complete entry set.
- Subprocess restart cuts before barrier, after barrier, after rename, and after parent sync verify
  exact database/source/backup recovery states.
- Scanner positive/negative/compiling-bypass fixture matrix, frozen package/SPI API inventory,
  exact two-file Core capability inventory, third-file import/qualified/inferred-bridge use,
  `@_exported`/scoped/aliased imports, copied-owner files, typealias/protocol/generic/closure escapes,
  and Package dependency/source-inventory checks. Every negative capability fixture first compiles
  in an isolated permissive fixture package, then the scanner must reject it.

## Gate order

1. Rehash the frozen dependencies, then require Phase 2.0A independent Security code-review and
   Tester PASS, including parent identity, terminal disposal, and release-artifact evidence.
2. Freeze this Architect amendment; Design Mock/Review remain documented N/A.
3. Independent Security plan PASS.
4. Builder implementation with focused local feedback only.
5. Independent Security code review of the actual diff; any material fix repeats this gate.
6. Design Sign-off remains N/A only if installed behavior is visually unchanged.
7. Independent Tester/adversarial pass against the implementation.
8. Root verification, in order:

```bash
bash scripts/security-scan.sh
swift test --filter 'SaveDBTests|SaveDBLifecycleTests|LegacySaveMigrationTests|PersistenceLockRankTests|PebbleStorageExecutorTests|PebbleStorageAdversarialTests|LANV6SchemaAuthorizerTests|TemplateTests'
swift build -c release
bash scripts/verify-pebble-storage-release-surface.sh
swift test
swift run -c release pebsmoke
bash scripts/pipeline.sh
```

Report real test/check counts, warning status, deployed `/Applications/Pebble.app` evidence, and
remember that later LAN/RPG/UI changes stale this phase's deployment proof.

## Conditions for Builder

- Phase 2.0A must PASS before this build starts, including exact template caps, narrow reads,
  replace-complete import, durability barrier, physical parent binding, terminal disposal, and the
  release verifier; every frozen dependency hash must match.
- Do not edit `Package.swift`, PebbleStorage, the release verifier, pipeline, or pre-push hook in
  Phase 2.0B. Any required change returns to Architecture and Security plan review.
- Zero SQLite/SQL/handle/schema knowledge remains in PebbleCore; every mutation uses one named facade.
- Valid public Bool/optional/Void/throwing behavior and ordered results remain exact.
- The seven current core/v5 SQLite tables and all v5 LAN callers remain live with unchanged names,
  schema, formats, and authority semantics; this phase creates no v6 table, v6 schema marker,
  fallback, or quarantine and never renames `lan_players` or `lan_player_resume`.
- Migration never crosses from a parent different from the storage coordinator's retained parent.
- No path-based descendant traversal, symlink, special file, hard link, race, mismatch, duplicate, or
  over-budget candidate reaches storage.
- Every materialized regular file is bound by exact incremental SHA-256 plus the complete retained
  stat identity at initial, materialization, and final passes; metadata equality alone is never a
  content proof.
- Every count/byte total is checked before allocation/import; one world is materialized at a time.
- At most one process imports one physical source; no migration proceeds without a proven lease.
- World import is replace-complete; rename never precedes the storage barrier; publication never
  precedes checked parent sync; no nonexclusive rename fallback or deletion exists.
- Backup-only is not success without valid durable v2 provenance. Every unmarked old backup-only
  state—including normal evolved databases, stale same-ID rows, and partial imports—enters the
  durable `legacyBackupRecoveryRequired` state, performs no database mutation, and requires explicit
  non-destructive source restoration before a fresh exact import.
- Migration VCK validation is registry-independent and stores raw bytes; only ordinary post-registry
  decode performs the existing block-ID clamp.
- Public initialization errors contain only closed stage/result; logs contain counts only.
- Rank order is migration source 10 / save queue 11 -> SaveDB 12; publication 20 cannot acquire 12.
- `SaveDB.deinit` never blocks or enters storage synchronously; production owners and all test
  owners explicitly close, and parallel tests never use the production default database.
- Resume timestamp normalization and clock sampling follow the frozen table exactly.
- The scanner owns the one-way dependency as a machine-enforced gate.
- The scanner confines all PebbleStorage and migration-session capability to the exact reviewed
  `Saves.swift`/`LegacySaveMigration.swift` inventories and forbids every re-export.
- Security code review precedes independent Tester; material implementation changes repeat Security.
