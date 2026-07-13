# LAN v6 Phase 2.0A — Legacy Template and Import Compatibility Amendment

Status: Architect amendment revised after Security plan FAIL; awaiting renewed review.

This amendment is required before Phase 2.0A can pass. It closes compatibility blockers found by
the Phase 2.0B Security plan review; it does not authorize the ElysiumCore adapter or loose-file
parser yet.

## Exact template limits and encoded-row ceiling

The storage boundary preserves the shipped ElysiumCore limits:

- legacy template JSON: exactly 24,000,000 UTF-8 bytes;
- PBT2 template data: exactly 64,000,000 bytes;
- template name, dominant block, and dominant display: at most 1,048,576 UTF-8 bytes each at the
  storage-corruption boundary (ElysiumCore continues to enforce its smaller domain/name limits).

`ElysiumTemplateStorageRow` validates each field and one checked co-resident variable-width sum:

`name + json + data + dominantBlock + dominantDisplay <= 91,145,728` bytes.

`SQLITE_LIMIT_LENGTH` becomes exactly 91,146,752 bytes: that maximum legal aggregate plus a closed
1,024-byte envelope for all fixed numeric columns and SQLite record/header varints. The connection
ceiling is private; it does not enlarge any typed per-column cap. The previously approved 64 MiB
chunk BLOB, 1 MiB chunk world key, and 65 MiB chunk aggregate remain unchanged and fit below this
ceiling.

Tests persist/read template JSON and binary at cap and reject cap+1 before enqueue, persist one row
with every template variable field simultaneously at maximum and every legal fixed numeric field at
its minimum/maximum extreme, verify the exact connection ceiling, and round-trip the existing
maximum-block ElysiumCore template once the adapter exists.

## Database-parent physical binding

`StoragePathLease` retains an `O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY` descriptor for
the canonical database parent plus its `(st_dev, st_ino)` for the coordinator lifetime. It
creates/reserves the database entry relative to that descriptor before SQLite opens the canonical
path, then proves SQLite opened the same file inode. The coordinator exports exactly one comparison
seam:

```swift
public func verifyDatabaseParentIdentity(device: UInt64, inode: UInt64) throws
```

It first requires the open lifecycle, re-`fstat`s the retained parent descriptor, revalidates the
database entry/file identity, and compares only the supplied integers. It returns no path,
descriptor, handle, callback, context, or capability. Phase 2.0B must call it after opening its own
canonical parent descriptor and again immediately before the migration barrier/rename. Parent
replacement, alias, lifecycle, exact-match, and path-redaction tests are required. A supplied
nonmatching identity throws `invalidValue` without poisoning an otherwise intact coordinator;
failure of the retained parent/database self-proof poisons the executor and tombstones its lease.

## Closed legacy read DTOs and methods

Strict full-row DTOs remain unchanged. The legacy facade adds only these named projections; there is
no generic selector, table, column, SQL, predicate, ordering, or callback input:

```swift
public struct ElysiumLegacyLANPlayerJSON: Sendable, Equatable {
    public let playerID: String
    public let json: String
}

public struct ElysiumLegacyTemplateContent: Sendable, Equatable {
    public let format: Int32?
    public let data: Data?
    public let json: String?
}

public struct ElysiumTemplateSummaryCandidate: Sendable, Equatable {
    public let name: String
    public let sizeX: Int32?
    public let sizeY: Int32?
    public let sizeZ: Int32?
    public let blockCount: Int32?
    public let blockEntityCount: Int32?
    public let dominantBlock: String?
    public let dominantDisplay: String?
}

public func listLegacyWorldJSON() throws -> [String]
public func getLegacyWorldJSON(id: String) throws -> String?
public func getLegacyPlayerJSON(world: String) throws -> String?
public func getLegacyLANClientResumeJSON(hostWorld: String) throws -> String?
public func getLegacyLANPlayerJSON(world: String, playerID: String) throws -> String?
public func listLegacyLANPlayerJSON(world: String) throws -> [ElysiumLegacyLANPlayerJSON]
public func getLegacyAdvancementJSON(world: String) throws -> String?
public func listLegacyTemplateNames() throws -> [String]
public func getLegacyTemplateContent(name: String) throws -> ElysiumLegacyTemplateContent?
public func listLegacyTemplateSummaryCandidates() throws -> [ElysiumTemplateSummaryCandidate]
```

The selected-column matrix is deliberately strict and deterministic. It narrows only corrupt legacy
rows; valid shipped rows are unchanged.

| Selected value | Accepted SQLite class and cap | NULL/wrong class/invalid result |
|---|---|---|
| JSON/name/dominant text | `TEXT`; raw bytes checked before copy; JSON/player/template cap for that field | mandatory collection value skips that row; single get returns nil; optional summary/content field becomes nil |
| Template data | `BLOB`, at most 64,000,000 bytes | nil; an accepted zero-length BLOB remains empty `Data` |
| Format/summary integer | `INTEGER`, exactly representable as `Int32`; summary values must also be nonnegative | optional field becomes nil; adapter treats nil format as legacy format 1 |

Accepted text copies no more than the field cap. An embedded NUL truncates at the first NUL exactly
as the shipped `String(cString:)` path did; invalid UTF-8 before that NUL is repaired with U+FFFD.
Bytes after an embedded NUL still count against the raw cap, so a large hidden suffix cannot bypass
the limit. The repaired/truncated result's UTF-8 byte count is checked against the same cap before
return so replacement characters cannot expand the Swift result past the bound. No INTEGER/FLOAT/
BLOB-to-text, TEXT-to-number, numeric-prefix, overflow, or BLOB/TEXT coercion is allowed. These
helpers are private to the named legacy methods; strict exact/v6 methods continue to reject any
wrong class for the complete operation.

World list/get selects JSON only and never inspects `lastPlayed`. Player, advancement, and resume
gets select JSON only and never inspect redundant keys or `updated`. LAN get/list selects only the
requested JSON or player ID plus JSON and ignores `updated`/redundant world output. Template content
selects only format/data/JSON. Template candidates inspect the mandatory name first; each optional
metadata field is independently class/size checked before copy, so an oversized optional value is
nil and cannot allocate or discard neighboring candidates.

## Bounded collection termination and order

Each collection first obtains a bounded `count(ROWID)` under the same executor read admission. It does
not aggregate optional-field bytes. Every scanned row increments a checked `scanned` count whether
accepted or skipped; accepted mandatory bytes increment a checked field-specific aggregate. At
completion `scanned` must equal the preflight count and remain within the frozen row cap.

The authorizer adds exactly three private legacy collection scopes:

- `legacyWorldCollection`: `SELECT`, `count`, and reads of `worlds.ROWID/json` plus SQLite's
  synthetic empty-column read for that same table only;
- `legacyTemplateCollection`: `SELECT`, `count`, and reads of `templates.ROWID/name/sizeX/sizeY/
  sizeZ/blockCount/blockEntityCount/dominantBlock/dominantDisplay` plus the synthetic empty-column
  read for `templates` only;
- `legacyLANPlayerCollection`: `SELECT`, `count`, and reads of `lan_players.ROWID/world/playerID/
  json` plus the synthetic empty-column read for `lan_players` only.

Preflights use `count(ROWID)`. On the supported SQLite, preparing that expression emits both
`READ table.ROWID` and a synthetic `READ table.""`; therefore each private scope admits `""` only
when the callback's table is its one exact table. The empty name is not added to the physical-column
manifest or any general scope. Each legacy scope is reachable only from its named facade methods,
transitions only `denyAll -> exact legacy scope -> denyAll`, and inherits sticky denial/generation
checks. It permits no other table, named column, function, pragma, mutation, schema read,
transaction, or ROWID access. Existing `coreRead`, exact, schema, and v6 scopes gain neither ROWID
nor the empty name. Authorizer tests prove the exact same-table empty read succeeds and that the
empty read remains denied for every other table/scope/action.

- `worlds` and both template collections paginate by the physical `rowid`: the first page has no
  cursor predicate; later pages use `rowid > ? ORDER BY rowid LIMIT 256`. Every returned rowid must
  be strictly greater than the prior rowid. Non-progress, duplicate rowid, count drift, or a page
  beyond the prechecked count throws `schemaMismatch`; no text converted from storage is rebound as
  a cursor.
- `lan_players` is already capped at 256 rows per world. It uses one `LIMIT 257` query after the
  count preflight, ordered by rowid, scans exactly the expected rows, and rejects count drift. It
  has no cursor.
- Template names/candidates and LAN players are sorted only after the storage scope has finished,
  by unsigned UTF-8 bytes of the accepted Swift string (SQLite `BINARY` semantics), with scanned
  rowid as a deterministic tie-breaker. World order remains unspecified, matching the old API.

Accepted collection memory is checked against the exact row-cap products: worlds JSON
`4,096 * 1,048,576`; template names `1,024 * 1,048,576`; template candidates all three text fields
`1,024 * 3 * 1,048,576`; and LAN player ID plus JSON
`256 * (1,048,576 + 786,432)`. Optional candidate bytes are added only after each field passes its
individual cap; overflow or aggregate overrun fails the collection before the result escapes.

Tests cover valid rows before and after every mandatory/optional wrong-class, NULL, oversize,
embedded-NUL, and invalid-UTF8 value; every ignored column independently; mixed TEXT/BLOB keys well
beyond 256 rows; strict rowid monotonicity/count-drift hooks; exact termination/no omission/no
duplication; UTF-8 byte order; format-1 fallback; and proof that strict full-row/v6 readers still
reject the same corrupt fixtures.

## Replace-complete legacy import and durability barrier

`importLegacyWorld` remains one immediate transaction but first deletes prior `worlds`, `chunks`,
`player`, and `advancements` rows for the imported world, then inserts the complete supplied
aggregate. Optional absence therefore removes stale player/advancement state, and retry cannot retain
stale chunks. LAN resume/peer rows are outside this legacy import and are untouched. Any failure
rolls the complete delete-plus-insert transaction back.

The facade adds one parameter-free named `prepareLegacyMigrationRename()` barrier. It enters the
executor queue without creating a read/mutation context and requires: open lifecycle, autocommit,
`currentContext == nil`, no transaction, no tracked statement, and
`sqlite3_next_stmt(handle, nil) == nil`. The authorizer remains installed with `denyAll` before,
during, and after the barrier.

After revalidating the retained database file and parent identities, it calls exactly:

```c
sqlite3_wal_checkpoint_v2(handle, "main", SQLITE_CHECKPOINT_FULL,
                          &logFrames, &checkpointedFrames)
```

Only `SQLITE_OK` with nonnegative `logFrames == checkpointedFrames` succeeds. Busy, negative, or
remaining frames fail. It then retries `fcntl(retainedDatabaseFD, F_FULLFSYNC)` only on `EINTR`,
fails on every other error, and revalidates the database file and parent identities after sync.
Checkpoint and sync failures leave the database open and retryable; identity failure poisons the
executor and its lease. No rename authority is returned—the successful `Void` result is the only
signal Phase 2.0B may use.

`ElysiumStorageOperationID` adds closed `checkpoint` and `durabilitySync` cases. DEBUG adds only the
closed failure points `checkpointBusy`, `checkpointRemainingFrames`, and `durabilitySyncFailure`,
plus the existing statement-leak seam. They accept no SQL, path, descriptor, errno, callback,
context, or capability and compile out of release builds.

Import tests use table-driven cuts at every delete (`worlds`, `chunks`, `player`, `advancements`),
world insert, optional player insert, optional advancement insert, first/middle/last chunk insert,
and COMMIT. After each injected failure and reopen, all four imported tables must equal their prior
byte-for-byte snapshot and LAN resume/peer rows must be unchanged. Barrier tests cover success after
commit, deny-all scope preservation, leaked-statement rejection, busy/remaining frames, sync failure,
retry, concurrent path replacement before checkpoint and before post-sync proof, identity poisoning,
closed numeric/redacted descriptions, and proof no adapter success is returned on failure.

## Conditions for Builder

- Do not shrink the shipped 24,000,000/64,000,000 template limits.
- Keep the private encoded-row ceiling separate from every public value cap.
- Retain and verify the canonical database-parent identity for the coordinator lifetime.
- Legacy narrow reads use only the frozen selected-column matrix and row-local skip/fallback; no
  storage-class coercion or text-derived cursor is permitted; strict v6 reads remain strict.
- No public API accepts columns, tables, SQL, paths, handles, contexts, or closures.
- Import retry is complete replacement, not additive upsert.
- No legacy source rename can proceed without the named durability barrier.
- Repeat Phase 2.0A focused/adversarial tests, release builds, independent Security, and independent
  Tester after implementation.
