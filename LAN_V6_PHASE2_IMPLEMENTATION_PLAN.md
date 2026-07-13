# LAN v6 Phase 2 — Identity and Persistence Implementation Contract

Status: Architect draft amended to make Phase 2.5 the sole client-authority component bootstrap;
awaiting renewed Security plan review. This contract implements the identity,
credential, permission, runtime-lease, legacy-claim, and client-credential foundations frozen in
`LAN_RPG_PROTOCOL_V6.md`. It does not activate v6 transport or quarantine v5 tables.

## Dependency order

1. SaveDB executor and capability boundary.
2. Pure identity, credential, permission, storage-accounting, and runtime-lease models.
3. Dormant v6 schema and world-identity registry.
4. Host identity, credential/index, permission, and bounded-storage stores.
5. Legacy quarantine/claim foundations without production allocation.
6. Client credential persistence without standalone promotion.
7. Admission-to-authority promotion coordinator after the strict owner checkpoint row exists.
8. Only the later transport cutover may atomically quarantine v5 tables and enable v6 callers.

`joinNew` and `legacyConsume` allocation remain module-internal and unreachable until the exact
projected owner checkpoint participates in capacity validation and the ordinal-burning transaction.

## 2.0 SaveDB executor and capability boundary

Files:

- Add a dependency-free `ElysiumStorage` target in `Package.swift` and
  `Sources/ElysiumStorage/StorageEngine.swift`. `ElysiumCore` depends on it; `ElysiumStorage` never
  imports or depends on `ElysiumCore`.
- The storage target exports only named, typed row values and persistence façades. Its generic
  executor, contexts, statements, SQL, authorizer scopes, and capability identifiers are private to
  one physical implementation boundary and are not visible to `ElysiumCore`.
- Modify the connection/executor seams and rewrite each complete existing transaction body in
  `Sources/ElysiumCore/Game/Saves.swift`; do not change save formats or gameplay semantics.
- Add `Tests/ElysiumCoreTests/ElysiumStorageExecutorTests.swift` and
  `Tests/ElysiumCoreTests/LANV6SchemaAuthorizerTests.swift`.

The private executor owns the one SQLite handle on a private serial `DispatchQueue`. Opening, pragmas,
schema setup, every prepare/bind/step/finalize, transaction, and close execute on that queue.
Synchronous re-entry from the owning queue executes inline; synchronous dispatch to the queue from
itself is forbidden. SQLite callbacks never acquire game/domain locks, dispatch to main, or call
gameplay/publication code.

The exported API is named rather than generic. Phase 2.0 initially exposes a
`ElysiumLegacyCoreStorage` façade with exact methods for the current world/chunk/player/LAN-v5/
advancement/template rows and a coordinator close operation. Later phases add separate
`ElysiumWorldRegistryV6Storage`, `ElysiumHostCredentialV6Storage`, `ElysiumPermissionV6Storage`,
`ElysiumLegacyClaimV6Storage`, `ElysiumClientCredentialAdmissionV6Storage`,
`ElysiumHostAuthorityCheckpointV6Storage`, and `ElysiumClientAuthorityCheckpointV6Storage` façades.
No façade accepts SQL, a capability enum/token, a generic context, a statement ID, table/column
names, or a closure that can issue storage operations. Host checkpoint methods cannot name or
return credential rows; client admission cannot name owner/disposition/inbox rows; only the named
client authority checkpoint method accepts one closed aggregate spanning its four allowed tables.

Phase-2.0 row values contain only storage primitives (`String`, fixed-width integers, `Double`, and
`Data`) and validate bounded lengths before enqueue. Reads apply the same bounds before Swift
materialization: inspect `sqlite3_column_type` and `sqlite3_column_bytes` first, reject the wrong
storage class or one-over length, and only then copy bytes/construct strict UTF-8. Collection reads
first execute bounded `COUNT`/`SUM(length(...))` aggregate checks and then use stable keyset pages;
no unbounded `while SQLITE_ROW` result is accumulated. The closed legacy manifest caps world/
advancement/schema text at 1,048,576 bytes, player/LAN JSON at 786,432, template data at 524,288,
chunk blobs at 67,108,864, worlds/templates at 4,096/1,024 rows, LAN peers at 256 rows, and chunk
keys at the frozen 1,048,576-row/268,435,456-byte baseline limit. Exact v6 façade caps come from the
fixed-limit table in `LAN_RPG_PROTOCOL_V6.md`, never a broad connection maximum.

Before the first SQL operation the factory sets and verifies closed `sqlite3_limit` ceilings:
67,108,864 bytes for a value/row, 1,048,576 SQL bytes, 128 columns, 128 bind variables, zero attached
databases, zero trigger depth, 1,024-byte LIKE patterns, 32 function arguments, eight compound
SELECT terms, expression depth 64, 1,000,000 VDBE operations, and zero worker threads. Per-façade
limits remain smaller. Schema
audit caps each `sqlite_master.sql` value at 65,536 bytes and the complete manifest at 512 objects/
1,048,576 bytes before copying or normalization.

`ElysiumLegacyCoreStorage` has these exact named
operations: list/get/put/delete world rows; list keys/get/put chunk blob rows; get/put player JSON;
get/put/delete LAN-client-resume JSON; get/put/list/delete LAN-player JSON; get/put advancement JSON;
list/get/put/delete template rows and summary columns; one atomic per-world loose-save import; and
the fixed core-schema verify/upgrade operation. Delete-world, chunk batch, template write/delete,
and each imported world are indivisible methods, not caller-composed statement sequences. The
ElysiumCore `SaveDB` adapter alone performs domain JSON/VCK/template encoding and exposes existing
game-facing types.

Representative exported lifecycle API:

```swift
public enum ElysiumStorageOperationID: String {
    case open, configure, prepare, bind, step, changes, finalize
    case beginImmediate, commit, rollback, authorizer, close
}

public enum ElysiumStorageError: Error {
    case openFailed(primaryCode: Int32, extendedCode: Int32)
    case duplicateOpen
    case sqlite(primaryCode: Int32, extendedCode: Int32,
                operation: ElysiumStorageOperationID)
    case nestedTransaction
    case capabilityViolation
    case inactiveContext
    case wrongExecutorOrQueue
    case statementLeak
    case transactionStillOpen
    case poisoned
    case closed
}

public struct ElysiumStorageTransactionFailure: Error {
    public let primary: any Error
    public let rollback: ElysiumStorageError?
    public let terminal: ElysiumStorageError?
}

public final class ElysiumStorageCoordinator {
    public static func open(databaseURL: URL) throws -> ElysiumStorageCoordinator
    public func legacyCore() throws -> ElysiumLegacyCoreStorage
    public func close() throws
}
```

`ElysiumStorageCoordinator.open` is the sole factory and publishes an instance only after handle open,
configuration, callback installation, and pragma verification all succeed. `SaveDB` has a throwing
`open(databaseURL:migrateLegacy:)` factory for tests and new callers. Its existing no-argument and
internal compatibility initializers delegate to the same throwing path and terminate locally with
one redacted fail-closed initialization error if their legacy nonthrowing signature cannot return an
error; they never expose a partially initialized wrapper or silently continue.

There is no target-visible generic executor entry point and no module-visible raw-handle or
raw-statement callback. All façade SQL implementations and the private executor live in the one
storage implementation boundary. Private bootstrap/open/close machinery is the only code that sees
`OpaquePointer`. Private transaction contexts/statements expose checked typed prepare/query/execute,
bind, column, step, changes, and finalize operations without exposing pointers. Every bind and
finalize result is checked. The test target reaches behavior through typed façades; an internal
test-only harness may inject closed failure points but cannot accept arbitrary SQL.

Only the private executor creates a context. It is non-Sendable, nonescaping by contract, bound to one
executor identity, executor generation, capability, and queue-specific key, and active only for the
dynamic extent of its closure. Every method revalidates those facts; a captured/returned context is
invalidated before the outer call returns and subsequently throws `inactiveContext`. Same-capability
recursive helpers reuse the exact current context. Different-capability or capability-widening
re-entry throws before prepare. Any transaction request while a transaction is active throws before
issuing SQL.

A read scope authorizes only read-only `SELECT`/column access and verified deterministic built-in
functions; any write or transaction action fails. There is no generic write scope. Every mutating
typed façade method is exactly one executor-owned `BEGIN IMMEDIATE` transaction, including a
single-row mutation. Transaction-control SQL is unavailable to façade bodies.

A transaction begins with checked `BEGIN IMMEDIATE`. The context latches its first
prepare/bind/step/changes/finalize failure. Catching that error inside a façade implementation cannot
clear the latch or permit COMMIT. After every body statement and statement
finalization succeeds, checked COMMIT runs and `sqlite3_get_autocommit` must report true. On a body,
statement, finalize, or COMMIT failure, the executor attempts checked ROLLBACK whenever autocommit is
false, verifies autocommit afterward, and preserves both the primary and optional rollback errors.
No operation returns while the connection has an open transaction.

If ROLLBACK fails and autocommit remains false, the executor atomically enters `poisoned`, rejects
all queued and new work, invalidates every context/statement generation, finalizes every tracked
statement, uninstalls callback state only as part of terminal close, and closes the handle on its
owner queue. That handle is never reused even if close itself reports an error. The thrown
transaction failure stores the original arbitrary `Error` object without formatting/logging it,
plus optional rollback failure and `transactionStillOpen` terminal cause.

Initialization enables and verifies:

```sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;
```

Opening occurs on the owner queue, enables extended result codes, and returns a typed fail-closed
initialization result. Each pragma is queried after setting and its exact effective value is
verified (`wal`, normal synchronous level, 5000 ms busy timeout, and foreign keys `1`). No failed
pragma or schema statement is logged and ignored.

One connection-scoped SQLite authorizer is installed immediately after open and remains installed
until terminal close. Its state outside a dynamic operation is deny-all; it is never temporarily
cleared. It maps
each runtime capability to exact action/table/column allowlists and denies cross-capability reads or
writes, schema changes, attach/detach, unsafe pragmas, triggers, virtual tables, and extension
loading. Any authorizer callback with a non-null trigger/view source is denied. Before runtime
readiness the factory audits `sqlite_master` and refuses every trigger, view, virtual table, unknown
index, or other unmanifested schema object, including objects created before this process opened the
database. The private connection-configuration scope exists only inside the throwing factory and permits the four
exact pragma set/query operations above; it is permanently unavailable after construction.
The private legacy-core scope preserves runtime access to existing v5/core tables until cutover but cannot
change schema. `coreSchemaBootstrap` and `dormantV6SchemaBootstrap` are separately allowlisted for
exact known schema statements, are callable only before runtime readiness, cannot access the other
schema family, and become permanently unavailable once readiness is published. Authorizer denial
is typed and never retries without authorization. Nested scopes may retain or narrow the current
capability, never widen it. Every prepared statement stores the executor/context/authorization
generation, validates it for bind/step/column/finalize, is finalized before scope restoration, and
is unusable outside that dynamic scope because authorization was decided at prepare time.

Each named façade selects its fixed private authorizer scope internally; callers cannot select or
forge it. The authorizer action/table/column allowlists remain distinct and are verified against
each façade's prepared statements in tests.

Bootstrap is not a caller-provided closure. A private immutable schema plan contains closed literal
statement IDs and SQL for the current core schema and, later, each dormant v6 schema revision. The
executor runs DDL transactionally, verifies exact `sqlite_master`, `table_info`, `index_list`,
`index_xinfo`, `foreign_key_list`, constraints, and schema marker/fingerprint before readiness, and
fails at the first mismatch. Failure injection cuts every schema statement and restart proves either
the prior complete schema or the complete new schema.

All current `SaveDB` helpers route through typed contexts without changing outward public behavior.
Existing Bool/optional/Void legacy APIs may retain their outward failure shapes, but internal
prepare/bind/step/finalize/transaction failures are checked. `deleteWorld`, `putChunks`, and each
world transaction in legacy import call one indivisible named storage-façade method whose private
implementation owns the complete immediate transaction;
template schema migration and initialization are one bootstrap operation. They cannot interleave a
caller between BEGIN and COMMIT, ignore a failed BEGIN/statement/COMMIT, or return with an active
transaction. New v6 APIs are throwing and never use the legacy log-and-continue adapter.

Executor errors use only closed `ElysiumStorageOperationID` plus primary/extended SQLite result codes. They
never contain SQL text, bind values, paths, IDs, names, or payloads. After rejecting new work,
`close()` drains prior queued work, proves autocommit, rejects live statements, uninstalls callback
state, closes on the owner queue, checks the close result, and cannot synchronously re-enter itself
from deinit. Test-only failure injection is a closed operation ID hook and cannot exist in a
production-selected configuration. Current SQL-prefix and `sqlite3_errmsg` logging is removed;
legacy adapters may log only the closed operation ID and numeric codes.

The factory enforces one process-wide coordinator per physical database. It holds one process lease
lock continuously while reserving the canonical parent-resolved standardized path, opening with
no-follow semantics, reading device/inode identity, checking both indexes, and binding the final
lease. Path aliases, `..`, symlinks, and
hard links collide. Failed factories release reservations after closing their non-null handle.
Successful/idempotent close releases a healthy lease; a poisoned or uncloseable handle retains a
process tombstone so the path/inode cannot reopen unsafely.

Lifecycle is explicit `opening -> open -> closing|poisoned -> closed`. Admission and queue submission
of an operation linearize together under a lifecycle mutex. Close first changes state so later work
is rejected, then enqueues its terminal operation strictly after all previously admitted work;
repeated close returns the same terminal result. No admitted operation can enqueue behind close.

Tests prove queue ownership; 100-way concurrent reads/writes; exact-context recursive legacy calls;
inactive/escaped-context rejection; different/widened-capability rejection; nested transaction
rejection before SQL; rollback on injected BEGIN/body/bind/step/finalize/COMMIT/ROLLBACK failure;
primary-plus-rollback error preservation; autocommit restoration; no transaction interleaving;
foreign-key enforcement; bootstrap/runtime authorizer separation by action/table/column; statement
leak refusal; close and deinit both on and off the executor queue without deadlock; unchanged
`SaveDBTests`; and a source audit proving no direct `sqlite3_*` use remains outside private
executor/context implementation; production `ElysiumCore` cannot name private capabilities,
contexts, statements, or SQL; read-scope writes and caught-error COMMIT both fail; concurrent
same-path/alias/hard-link opens, failed-factory cleanup, close-then-reopen, close races, repeated close,
post-close calls, and descriptor leakage; hostile preseeded trigger/view rejection; redacted stdout/
stderr with sentinel credentials/paths/IDs/payloads; template-schema upgrade, atomic delete-world,
put-chunk rollback, nested template-summary re-entry, exact `changes`, and legacy-import failure that
does not rename its source directory; read/write cap-1/cap/cap+1, wrong SQLite storage classes,
oversized row/result/schema fixtures, and proof rejection occurs before `String`/`Data` copy. A debug storage lock-rank hook asserts SaveDB's frozen rank and
tests/source audits forbid MainActor/domain-lock acquisition or synchronous publication from storage
callbacks.

## 2.1 Pure domain and runtime models

Files:

- `Sources/ElysiumCore/Net/LANV6IdentityModel.swift`
- `Sources/ElysiumCore/Net/LANV6Permissions.swift`
- `Sources/ElysiumCore/Net/LANV6AuthorityRuntime.swift`
- `Sources/ElysiumCore/Net/LANV6StorageLimits.swift`
- Modify the private deadline helpers in `Sources/ElysiumCore/Net/LANV6HandshakeState.swift` and
  add the unpublished-candidate permit seam in
  `Sources/ElysiumCore/Net/LANV6AdmissionControl.swift`.
- Matching pure XCTest files.

### Identity and credential values

`LANWorldBindingV6` contains exact host ID, world ID, and lookup digest. Both initializers recompute
`LANV6Crypto.lookupDigest`; a supplied digest uses the fixed 32-byte comparison and mismatch throws.
Its description redacts all three fields.

`LANV6CredentialGeneration` is an invariant-preserving comparable scalar `1...1_000_000_000`.
`checkedRotationSuccessor` maps `999_999_999` to the maximum and rejects another advance; zero is
only the SQL representation for an absent active credential and never constructs this type.

`LANV6PersistedExpiryV6` contains a nonnegative `Int64` wall-clock millisecond instant. Factory
`pendingCredentialExpiry(admissionNow:)` rejects a negative admission instant and performs checked
`now + 120_000`. Its `disposition(at:)` rejects a negative read instant as
`clockRollbackOrCorrupt`, performs checked subtraction, and is:

- expiry `<= now`: `expired`;
- remaining `1...120_000`: `usable`;
- remaining greater than 120,000 or subtraction overflow: `clockRollbackOrCorrupt`.

Subtraction overflow also produces `clockRollbackOrCorrupt`. Both unusable cases map to the same
external admission failure and never reveal whether the row expired, the clock regressed, or the
row was corrupt.

Host-only credential aggregates are module-internal and non-Codable:

```swift
struct LANHashedCredentialV6 {
    let hash: LANV6SHA256Digest
    let generation: LANV6CredentialGeneration
    func matches(rawToken: LANV6Token256) -> Bool
}

struct LANPendingHashedCredentialV6 {
    let credential: LANHashedCredentialV6
    let handshakeID: LANHandshakeIDV6
    let absoluteExpiry: LANV6PersistedExpiryV6
}

struct LANPeerCredentialTupleV6 {
    let binding: LANWorldBindingV6
    let authority: LANV6Authority
    let active: LANHashedCredentialV6?
    let pending: LANPendingHashedCredentialV6?

    func replacingPending(expectedPending: LANPendingHashedCredentialV6?,
                          hash: LANV6SHA256Digest,
                          handshakeID: LANHandshakeIDV6,
                          expiry: LANV6PersistedExpiryV6,
                          permit: LANV6NoLiveRotationLeasePermit) throws -> Self
    func refreshingPending(expected: LANPendingHashedCredentialV6,
                           handshakeID: LANHandshakeIDV6,
                           expiry: LANV6PersistedExpiryV6) throws -> Self
    func promotingPending() throws -> Self
    func expiringPending(at nowMillisecondsSince1970: Int64) throws
        -> LANPeerCredentialExpiryOutcomeV6
}
```

The authority is guest-only. Active and pending cannot both be absent. Active-absent requires
pending generation one. Active-plus-pending requires the exact checked rotation successor; an
active maximum cannot have pending. `replacingPending` requires an active credential and derives
the successor internally. Its optional `expectedPending` must be nil exactly when the tuple has no
pending value or must be byte-equal to the complete existing pending value. This deliberately
allows an active-token fallback to replace a persisted pending tuple after its prior live rotation
lease ended, without waiting for or expiring an otherwise usable 120-second credential. The method
preserves active, writes a fresh hash/handshake/expiry at the same derived `active + 1` generation,
and consumes a dynamically validated permit issued only by the locked runtime authority scope after
it proves no live candidate/rotation lease. `refreshingPending` requires byte-equality with the
complete expected pending credential and changes only handshake/expiry.
Promotion moves that exact pending hash/generation to active and clears pending. Expiration accepts
the wall-clock instant, derives the checked disposition internally, and refuses `.usable`; an unusable pending-only tuple returns a
typed request to delete the provisional identity rather than constructing an empty tuple. Host
credential tuples, transition proofs, and mutators are module-internal, non-`Codable`,
non-`Hashable`, fixed-redaction values with no raw-token field. Raw tokens exist only as ephemeral
arguments to the constant-time hash match and are never retained.

### Exact permission model

`LANV6PermissionKeyV1: CaseIterable` has exactly ten cases: `canBuild`, `canUseContainers`,
`canCraft`, `canUseTemplates`, `canUseCommands`, `canUseAI`, `canChangeDimensions`, `canRespawn`,
`canUseCreative`, and `canPVP`. `LANPeerPermissionsV1` has ten explicit Boolean initializer
arguments with no defaults, `allows`, and immutable `setting` helpers.

New-guest defaults are true only for build, containers, craft, templates, and respawn. Host-local
defaults are true for the first nine fields and false for PvP. `allDisabled` is all false. Internal
`LANValidatedLegacyPermissionsV5` has exactly the prior nine fields; migration preserves every bit
and adds `canPVP=false` without defaults.

`LANPermissionRowV1` contains binding, guest or host-local authority, full
`LANVersionedCounterV1`, and payload. Initial rows use `.zero`. `planMutation(expectedRevision:
payload:)` rejects stale expected revision, returns `noChange` without advancement for identical
payload, or returns exact old/new CAS rows using checked successor. A successor reaching terminal
returns `terminalRevocation` with all ten false and requires authority termination. A terminal row
with any true permission is unrepresentable.

The v6 permission types have no initializer accepting, conversion from, protocol conformance shared
with, or fallback bridge to the existing defaulted `LANPeerPermissions`; an absent v6 row is an error, never guest defaults,
host defaults, or a v5 row. Only `LANValidatedLegacyPermissionsV5`, constructed after exact
nine-field validation, can migrate into v6. The mutation result is the closed sum
`noChange(current:) | compareAndSwap(old:new:) | terminalRevocation(old:terminal:)`.
`terminalRevocation` is deliberately not accepted by the ordinary live-row CAS method: it routes to
the ranked teardown transaction that commits all-disabled and terminates the authority.

### Checked storage accounting

`LANV6PhysicalRowChargeV1` accepts at most 128 already-measured SQLite TEXT/BLOB column lengths,
rejects negative values, and computes one physical row's `512 + sum(lengths)` with checked
`UInt64` arithmetic before materialization/allocation. `LANV6StorageBatchChargeV1` is bound at
construction to exactly one closed `LANV6StoragePoolV1`, contains the explicit logical-count delta
plus all physical-row charges, and sums them without wrap. Empty, mixed-pool, or caller-defined
widened-limit batches are unrepresentable. `LANV6StorageUsageV1.projectedAdding` requires the same
pool and checks logical row count and accounted-byte addition before ordinal/token allocation.

`LANV6AtomicStorageProjectionV1` contains one closed candidate delta for each affected pool and
validates them as one indivisible projection against a fixed `LANV6StorageUsageSetV1`; callers
cannot omit an affected pool or validate/commit candidates separately. A new guest charges live
identity count `+1` with the identity, permission, credential, and owner/checkpoint physical-row
charges; permission count `+1` with that same permission-row charge; and the exact token-index rows
to the token pool. The permission row is intentionally present in both independent byte budgets.
Host-local permission charges only the permission pool. Every pool candidate passes before any
ordinal, credential, index, row, or memory-only lease mutation.

The closed pools are: live identities 256/268,435,456; token indexes 512/2,097,152; quarantine
128/67,108,864; retired audit 1,024/1,048,576; combined permission rows 257/1,052,672 with a 4,096
single-row maximum. Every physical identity, permission, credential, owner/checkpoint, and index row
therefore contributes its own 512-byte overhead even when one logical identity owns several rows.
Credential rows additionally cap at 65,536 bytes, authority/owner rows at 786,432 bytes, and
permission rows at 4,096 bytes, all checked from SQLite type/length metadata before copy or decode.
No function clamps, loads blobs, crosses pools, accepts a caller-supplied limit, or advances an
allocator before all row and aggregate checks pass.

### Runtime authority registry

Runtime identity domains remain distinct:

- existing `LANV6SocketID` identifies the accepted TCP socket reservation;
- module-internal `LANV6ConnectionID` is `1...UInt64.max`, fresh and nonreused within one epoch;
- public `LANV6SocketGeneration` is `1...1_000_000_000`, increasing per authority and resetting only
  under a fresh session epoch.

`LANRuntimeAuthorityLeaseV6` is module-internal/non-`Codable`/non-`Hashable` and contains exactly
session epoch, connection ID, socket generation, handshake ID, monotonic deadline, and a closed phase
`awaitingClientReady | readyAwaitingOwnerBudget | authenticated | closing`.
`LANRuntimeAuthorityBindingV6` contains exactly one lease and one `LANV6SocketID`. A per-authority
cell holds at most one candidate binding and one authenticated binding, while one reverse
`socketID -> (authority, connectionID, socketGeneration)` index proves a socket appears in exactly
one cell/role. The admission lock is the sole synchronization owner for that global reverse index
and the global connection-ID allocator. Candidate installation uses a closed mode
`newIdentity | pendingResume | activeRotation`; pending resume may replace only the candidate,
active rotation requires no candidate/live rotation lease and never evicts the authenticated
binding, and a socket already bound to any authority is rejected.

The registry, not callers, owns checked connection-ID and per-authority socket-generation
allocators. Values are burned when a binding reservation succeeds and are never rolled back or
reused within the epoch, including later handshake/persistence failure. Connection-ID or socket-
generation exhaustion atomically enters host stop; it never wraps. Callers supply neither ID,
generation, deadline, nor trusted `now`.

Every install, promotion, candidate invalidation that removes a socket, authenticated-close
transition, and stop operation holds admission before the affected authority lock(s); only these
admission-held transitions read or mutate the reverse index or global connection allocator.
`markClientReadyValidated` and ordinary authenticated/deferred callbacks take only the one authority
lock and validate the cell-forward binding plus their immutable, generation-bound connection
context; they never read the reverse index. Per-authority socket generation and last-clock sample
remain protected by that cell lock. Tests and source audits reject any reverse-index access without
the admission scope and any authority-to-admission lock inversion.

The registry owns its injected, synchronized `LANV6MonotonicClock`. Each authority cell stores its
own last-observed instant under that cell's lock; no mutable clock sample is shared unsafely across
independent authority locks. Candidate operations reject regression for that binding and construct
the exact ten-second deadline with checked addition. Overflow fails closed and invalidates the
candidate. A preauthentication lease is expired at `now >= deadline`, not only after it. Elapsed
handshake deadlines are enforced only in `awaitingClientReady` and `readyAwaitingOwnerBudget`.
Authenticated validation still requires the exact stored deadline field as identity proof but does
not expire on that old handshake instant; deferred/prepared work owns its separate frozen deadline.
The private Phase-1D handshake deadline helper is changed from `UInt64.max` saturation to a throwing
checked addition with the same regression and exact-boundary rules.

`LANRuntimeAuthorityRegistryV6` owns the authority locks and exposes only named synchronous
operations: `installCandidate`, `markClientReadyValidated`, `withLockedPromotion`,
`validateAuthenticated`, `invalidateCandidate`, and `beginAuthenticatedClosing`. It has no
standalone validate/commit promotion pair and no public mutation escape hatch. Every operation
validates exact epoch/connection/socket/handshake/phase/deadline and its cell-forward binding;
admission-held install/promotion/invalidation/close/stop transitions additionally validate the
reverse index.

Admission owns the host lifecycle
`running(epoch) -> stopping(epoch,outstandingSockets) -> stopped`. Before `startHost`, the dormant
v6 storage façade transactionally performs conservative pending-expiry cleanup, verifies tuple/index
consistency, and returns one private-init, single-use bootstrap snapshot containing the exact unique
pending-only guest authorities plus its host/world binding and storage revision. Under admission,
`startHost` validates that snapshot, rejects more than eight or any duplicate/inconsistency, installs
those authorities into pending-only accounting, creates a fresh CSPRNG epoch, resets only runtime/
socket accounting and allocators, fills rate buckets, and then enters running/advertises. Persisted
pending-only accounting is never reset merely because runtime sockets were lost.

`stopHost` first transitions running to stopping under admission, freezing accepts, installs, and
promotions. While admission remains held it derives the complete socket set from the admission
ledger, including awaiting-hello and otherwise unbound handshake sockets; the runtime reverse index
is used only to invalidate its bound subset. It locks authority cells in stable ordinal order,
invalidates every binding/callback/deferred/prepared reference, changes every ledger socket to
closing without removing it from the 16 open-or-closing accounting cap, and records one exact
outstanding set. It returns the sorted unique set for transport closure outside all locks.
Epoch-bound `completeClose` removes each member exactly once. The gate remains stopping until the
outstanding set and `ledger.sockets` are empty, then becomes stopped; it does not clear
`pendingOnlyAuthorities`. Before the next running epoch that retained partition must byte-equal, or
be atomically reconciled to, the fresh storage bootstrap snapshot after expiry cleanup. `startHost`
rejects while any old close is outstanding; duplicate/stale completion callbacks are powerless
against a later epoch. Restart never reuses an epoch and every old-epoch callback fails before
mutation.

`LANV6AdmissionGate.withUnpublishedPromotionCandidate` holds admission and builds an unpublished
ledger candidate. It creates one private-init reference scope bound to gate identity, registry
identity, admission generation, authority generation, and an `active` bit. Every permit/context use
revalidates those identities/generations and the still-active dynamic scope while the corresponding
lock is already held; validation never recursively acquires the admission `NSLock`. The scope is
invalidated in `defer` before the nonescaping closure returns. Stored references or copies therefore
become powerless, and these types are not `Sendable`.

Only the active `LANV6AdmissionPromotionPermitV6` can call
`LANRuntimeAuthorityRegistryV6.withLockedPromotion`. The registry holds the stable authority lock
across exact lease/reverse-index/deadline prevalidation and all owner/send/checkpoint reservations.
Every fallible candidate, callback, buffer, and enqueue slot is fully allocated and validated before
credential mutation. The later typed credential/index CAS façade receives the exact monotonic
deadline and the same synchronized class-bound clock source as the registry; inside its SQLite
transaction it samples that clock immediately before COMMIT, rolls back on regression or
`now >= deadline`, and otherwise commits. SQL COMMIT success is the point of no return.

After successful COMMIT there is no clock resample, failure injection, allocation, throwing
postcheck, or rollback claim. Held-lock lease identity is an invariant assertion. The registry makes
only nonthrowing assignments of the prebuilt runtime binding and admission ledger and performs a
nonthrowing enqueue into already-reserved request-zero capacity. Its active scope mutates the gate's
candidate directly under the already-held admission lock without re-locking. Thus ordinary
authority callbacks cannot observe authenticated runtime state without matching admission state.
Any throw before COMMIT discards candidates/reservations, invalidates only the failed candidate as
required, and preserves persisted credentials plus the old authenticated binding/callback
byte-for-byte. The current immediate `promote`, a standalone runtime commit, and direct ledger
publication are removed before any Phase-2 transport caller exists.

### Phase 2.1 tests and conditions

Tests cover binding byte mutations; generation 0/1/max-1/max/one-over; every complete tuple/transition;
replacement with no active, nil/matching/mismatched existing pending, or live lease; replacement of
a still-usable persisted pending after its runtime lease ended; refresh mismatch; usable-expiry refusal;
expiry past/now/+1/+120,000/+120,001/negative/overflow/rollback; exact permission defaults and ten
sentinels; all 512 legacy permission combinations; absent rows, accidental legacy bridges,
no-change/stale/rebase/terminal permission plans and proof terminal cannot use ordinary CAS;
physical-row overhead for multirow identity bundles, permission double-charge across live/permission
pools, atomic multi-pool failure, pool mismatch, zero/negative/128/129/overflow,
65,536/786,432/4,096 row caps, and every aggregate cap before ordinal allocation; epoch
rotation/collision; concurrent multi-authority connection allocation uniqueness; connection/socket
allocation burn and exhaustion; admission-owned reverse-index mutation/read races and socket reuse;
all three candidate modes; candidate replacement and every stale proof field; deadline
before/exact/after/overflow/regression with per-cell registry-owned clock; proof authenticated leases
ignore elapsed handshake deadline; promotion failures at every pre-COMMIT seam and proof no
fallible operation exists after COMMIT; pending-only bootstrap at 8/9, inconsistent snapshot, and
expiry cleanup; stop/restart with one and eight retained pending-only identities and zero sockets;
awaiting-hello plus bound-socket stop races, blocked restart until every exact close,
stale/duplicate close completion; eight-authority admission/start/stop/supersession races with each
socket closed once; escaped/copied permit after dynamic invalidation; and source audits forbidding `Codable`, `Hashable`,
SQL, transport imports, raw-token storage, caller clocks/deadlines, mixed clocks, and sensitive
descriptions.

Builder conditions: keep wall expiry and monotonic deadline separate and checked; preserve all
three runtime identity domains plus unique forward/reverse socket binding; keep pending tuples
indivisible and host models token-free; permit fallback replacement of persisted pending only after
its live lease ends; firewall strict v6 permissions from legacy defaults; atomically charge all
affected pools, including permission double-accounting, before allocation; bootstrap durable
pending-only counts before advertising; preserve admission-before-authority order; make promotion
one dynamically enforced admission/authority critical section with SQL COMMIT as its point of no
return; perform no fallible work after COMMIT; keep stop accounting until every admission-ledger
socket completes close; preserve the old authenticated lease on every pre-COMMIT failure; remove
immediate/standalone promotion; and do not activate SQLite integration or transport here.

## 2.2 Dormant schema and world identity registry

Files:

- `Sources/ElysiumCore/Game/LANV6SaveSchema.swift`
- `Sources/ElysiumCore/Game/LANV6WorldIdentityRegistry.swift`
- Extend the named schema/registry façade implementations inside
  `Sources/ElysiumStorage/StorageEngine.swift`; no SQL/context enters either ElysiumCore file.
- Matching schema/registry tests.

Dormant tables:

- `lan_v6_schema_marker`
- `lan_world_identity_registry_v1`
- `lan_peer_ordinal_allocator_v6`

The installation ID is an exact 16-byte file at the application-support root, created with
`SecRandomCopyBytes`, `O_CREAT|O_EXCL`, mode `0600`, no symlink following, complete write, and fsync.
If registry rows exist but the file is missing, malformed, wrong-owner, or overly permissive,
hosting fails; it never generates a replacement.

The registry stores exact 16-byte host/world/storage/lineage IDs, 32-byte fingerprint, bounded
world record/location strings, versioned revision, and one closed availability value:
`identityCommitted`, `manifestCommitted`, `readyLazy`, `ready`, `namespaceRewritePending`,
`movePending`, or `quarantined`. Unique constraints cover world storage ID, world record ID, and
canonical location. Phase 2 refuses ambiguous copy/import/move state; it does not implement partial
rekey or identity preservation.

## 2.3 Host credential, index, permission, and bounded-storage stores

File: `Sources/ElysiumCore/Game/LANV6HostIdentityPersistence.swift` for typed domain coordination;
extend the named host-identity/credential/permission façade implementations inside
`Sources/ElysiumStorage/StorageEngine.swift`. The ElysiumCore file contains no SQL or generic storage
access.

Tables:

- `lan_peer_identity_v6`
- `lan_peer_credentials_v6`
- `lan_peer_token_index_v6`
- `lan_peer_permissions_v6`
- `lan_host_local_permissions_v6`
- `lan_peer_import_quarantine_v6`
- `lan_peer_retired_audit_v6`
- `lan_peer_retired_summary_v6`

Credential rows contain hashes only. One SQL `CHECK` makes all pending columns present or absent.
The token index key is `(hid,wid,token_hash)` and stores authority, `active|pending`, and generation.
Every tuple/index create, pending replace/refresh, promotion, expiry, and exhaustion transition is
one `BEGIN IMMEDIATE` transaction with explicit columns, exact old-tuple predicates, and
`changes == 1`. No v6 table uses `INSERT OR REPLACE`.

Secret discovery is one indexed query while holding no authority lock. It releases the executor,
then the caller takes only the returned authority lock and transactionally revalidates index plus
tuple. Orphans, collisions, stale roles/generations, expiry, and CAS loss roll back and expose one
generic failure.

Ten permission Booleans are physical checked columns with a versioned revision. Identical payload
returns `noChange`; mutation uses complete-row CAS and checked successor. Remote frames have no API
route to this controller.

Exact caps are checked in SQL before blob loading or ordinal allocation: 256 live/provisional
identities and 268,435,456 accounted bytes; 512 token-index rows and 2,097,152 bytes; 128 quarantine
rows and 67,108,864 bytes; 1,024 audit rows and 1,048,576 bytes. Identity pagination is stable by
`(joinedOrdinal,rowID)`, limit `1...50`, with a bounded host/world/filter-bound cursor.

No production-callable provisional allocator exists until it accepts a later strict
`LANPeerAuthorityCheckpointRowV6` and includes that row in the same capacity/ordinal transaction.

## 2.4 Legacy claims and quarantine foundations

Files:

- `Sources/ElysiumCore/Net/LANV6LegacyMigration.swift`
- `Sources/ElysiumCore/Game/LANV6LegacyPersistence.swift`
- Extend only the named legacy-claim façade implementation inside
  `Sources/ElysiumStorage/StorageEngine.swift`; ElysiumCore owns validation/orchestration, not SQL.

Dormant tables include claim, nonce index, and legacy identity mapping. A detached claim stores only
the nonce hash, an exact six-character display code, bounded metadata, absolute expiry, and closed
status. Approval allocates no identity. Consume remains internal until owner-row allocation exists.
Legacy JSON is length-checked at 786,432 bytes, strictly scanned/decoded without defaults, and never
directly seeds v6 authority. Valid nine-field permissions migrate with `canPVP=false`; quick slots
are stripped. Raw nonces never persist or log.

This phase does not rename `lan_players` or `lan_player_resume`. The later cutover performs a single
schema-fingerprint-verified transaction that renames them to quarantine, creates/verifies final v6
tables, writes a ready marker, commits, and only then disables v5 callers.

## 2.5 Client credential persistence

Files:

- `Sources/ElysiumCore/Net/LANV6ClientCredentialModel.swift`
- `Sources/ElysiumCore/Game/LANV6ClientCredentialPersistence.swift`
- Implement the `lanClientAuthority` component bootstrap and named client-credential façade inside
  `Sources/ElysiumStorage/StorageEngine.swift` exactly as frozen in
  `RPG_STORAGE_SURFACE_AMENDMENT_PLAN.md`; the ElysiumCore wrapper receives typed primitive rows and
  never selects a capability or statement.

`lan_client_credentials_v6` is keyed by exact `(hid,wid,lk)`, recomputes `lk`, groups complete
active/pending fields, and is capped at 65,536 bytes before decode. Host stores never contain raw
tokens; this client-only table does. Errors and descriptions redact them.

Phase 2.5 is the sole schema-bootstrap owner of `lan_client_credentials_v6`. Its one
`lanClientAuthority` component transaction creates that credential anchor, client owner checkpoint,
pending/disposition, notification inbox/index, and component marker together using the amendment's
exact DDL. No Phase 2.2/2.3 schema bootstrap and no later owner-checkpoint phase creates, replaces,
or alters the credential table. Phase 2.5 initially exposes only the admission façade limited to an
unbound generation-zero credential row; the complete client-authority façade remains unobtainable
until the owner-checkpoint coordinator passes its own Architecture, Security, and Test gates.

Resume candidates return pending first and active second as separate one-secret attempts. An issued
server accept durably installs the raw pending token before clientReady. A `.resumedExisting`
accept must match an already retained pending token, generation, and tuple before clientReady; it
cannot fabricate or replace a token. There is no public standalone pending promotion. Promotion is
only a future coherent client checkpoint transaction with owner/disposition state.

The pre-owner credential anchor is aggregate generation 0, `authority_bound=false`, active absent,
and pending-only at credential generation 1. The first request-zero checkpoint is the sole promotion:
its active token/generation must be fixed-time byte-equal to that stored pending pair and its pending
token/generation/handshake/expiry must all become absent in the same owner+credential transaction.
Neither admission nor the checkpoint may fabricate replacement credential bytes.

## 2.6 Atomic promotion coordinator gate

The current `LANV6AdmissionGate.promote` remains module-internal. Before transport integration, add
a named coordinator that:

1. Holds the global admission lock and creates an unpublished candidate ledger.
2. Acquires the one authority lock in ranked admission-before-authority order.
3. Revalidates epoch, connection, socket generation, handshake, phase, and deadline.
4. Reserves the complete initial bundle, send ledger, checkpoint staging, and request-zero work.
5. Transfers the handshake reservation to the authority slot in the candidate ledger.
6. Immediately performs and revalidates the exact credential/index CAS while holding the authority
   lock and SaveDB executor in the frozen order.
7. Enqueues request zero, publishes the candidate ledger/runtime lease, and only then marks an old
   same-authority socket closing.

Any reservation, CAS, deadline, stop-host, or send-capacity failure discards the candidate, retains
the old authenticated socket, and leaves the pending credential resumable. Tests inject failure at
every step and race close, supersession, host stop, and pending resume.

## Verification sequence

For each subphase: focused new suites, all `SaveDBTests`, all `LANV6*` tests, then `swift test
--filter 'LAN|RPG'`. After all Phase 2 code: warning-free release build, full `swift test`,
`elysmoke`, Security code review, Tester regression pass, then `scripts/pipeline.sh` at the final
release gate.

## Conditions for Builder

- The SQLite handle is used only on its serial executor; no transaction can interleave.
- Capability separation fails closed and is tested at SQLite prepare time.
- New v6 writes throw typed errors; no v6 mutation logs and continues.
- Host storage contains no raw token; client storage never logs raw tokens.
- Persisted tuples contain no runtime epoch, connection, socket, deadline, or authenticated flag.
- Runtime leases never enter SQL and are invalidated before socket close on host stop.
- Credential discovery is index-only and releases DB before acquiring the returned domain lock.
- Tuple and every affected index row change atomically with exact CAS predicates.
- No ordinal burns before owner checkpoint plus every physical row passes count/byte capacity.
- Permission rows contain exactly ten physical Booleans and a versioned CAS revision.
- v5 tables and callers remain live and unrenamed until one atomic, verified cutover.
- Copy/import/move ambiguity is nonhostable until the full namespace rewriter/move coordinator.
- Standalone admission promotion and standalone client pending promotion remain unavailable.
- No secret, full public ID, player name, payload, SQL bind value, or credential delivery enters
  ordinary logs, descriptions, probes, or errors.
