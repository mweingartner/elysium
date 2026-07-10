# LAN v6 Phase 2.0A — SaveDB Boundary Security Remediation Contract

Status: Architect amendment awaiting Security plan review.

This amendment is subordinate to section 2.0 of
`LAN_V6_PHASE2_IMPLEMENTATION_PLAN.md` and supersedes that section only where empirical SQLite
behavior made its original wording impossible. It closes the 2026-07-10 independent Security and
Tester FAIL findings before `Saves.swift` may use `PebbleStorage`.

## Files and dependency order

1. Amend constants, closed errors, and test-only failure seams in
   `Sources/PebbleStorage/StorageEngine.swift`.
2. Repair factory ownership and filesystem-error closure.
3. Enforce the authorization transition matrix and UTF-8/byte-accounting contract.
4. Make schema preflight and bootstrap one fail-atomic operation.
5. Separate the typed 64 MiB chunk-value cap from SQLite's whole-record ceiling.
6. Remove the empty-mutation lifecycle bypass.
7. Extend `PebbleStorageExecutorTests.swift`, `LANV6SchemaAuthorizerTests.swift`, and
   `PebbleStorageAdversarialTests.swift`; then repeat independent Security and Tester gates.

`Saves.swift`, v6 schema tables, and Phase 2.1 domain types remain out of this remediation.

## 1. Closed result codes and test configuration

One private helper maps every SQLite result to `(primary: extended & 0xFF, extended: extended)`.
Every `.sqlite` and SQLite-origin `.openFailed` construction uses it. POSIX errors remain numeric
POSIX values and are not masked. An injected extended primary-key constraint test must observe
`SQLITE_CONSTRAINT` as primary and `SQLITE_CONSTRAINT_PRIMARYKEY` as extended.

Debug tests may select only these closed factory failure points:

- immediately after a non-null successful `sqlite3_open_v2` and before post-open verification;
- before bootstrap schema statement index `0...15` for an empty/legacy-prefix fixture.

The selector is internal under `#if DEBUG`, accepts no SQL/path/callback, and has no production
entry point. Runtime operation injection remains the existing closed `PebbleStorageOperationID`
map.

## 2. Factory handle ownership and filesystem redaction

The factory owns any non-null local handle from the instant `sqlite3_open_v2` returns, even if the
return code or later inode/descriptor verification fails. `openAndConfigure` wraps open plus
verification in one ownership scope. Before rethrowing it performs checked `sqlite3_close_v2` on
the local handle, clears it, and tombstones the lease if close fails. It assigns `self.handle` only
after verification succeeds; initializer cleanup must never be the sole owner of a still-local
handle.

`FileManager.createDirectory` is caught at the storage boundary. A direct POSIX-domain numeric code
may become `openFailed`; every other Foundation error becomes closed numeric `EIO`. No underlying
`NSError`, URL, path, userInfo, localized text, or recovery description escapes or is logged.

Tests compare descriptor counts before/after deterministic post-open failure, prove safe reopen,
repeat the real atomic path-replacement race, and reflect/describe/capture output for a sentinel
path whose parent is a regular file.

## 3. Authorization is retain-or-narrow and denial is sticky

`withAuthorization` implements this complete transition matrix:

- `denyAll -> configuration`, only while opening;
- `denyAll -> coreBootstrap`, only while opening;
- `denyAll -> schemaAudit`, while opening or open;
- `coreBootstrap -> schemaAudit`, only for the in-transaction exact audit;
- exact same-scope retain;
- every other transition rejects before changing callback state.

Runtime read/mutation contexts and transaction-control scopes continue through their dedicated
executor paths and cannot be selected through this helper. The denial bit is a dynamic-scope latch:
after either a throwing or normally returning body, any denial forces `capabilityViolation`.
Catching a denied prepare inside the body cannot clear it. Nested scope exit restores the prior
scope and prior denial bit. Tests cover every allowed edge, representative forbidden widening,
caught denial, and no scope/generation change on rejection.

## 4. UTF-8 and byte-accurate metadata

Initialization queries and requires exact `PRAGMA encoding = 'UTF-8'`; it does not convert an
existing UTF-16 database. The configuration authorizer permits only that exact additional pragma.

All byte aggregates use `length(CAST(column AS BLOB))`, including nullable schema SQL and every
world/chunk/LAN/template collection query. With required UTF-8 encoding this counts stored UTF-8
octets, includes bytes after embedded NUL, and materializes no Swift `String`/`Data`. Individual
reads continue to inspect storage class and `sqlite3_column_bytes` before copying.

Tests cover UTF-16 rejection, one-/two-/four-byte scalars, embedded NUL, manifest total
1,048,576/1,048,577, and a small debug-only collection budget proving rejection occurs before page
materialization.

## 5. Exact compatible preflight and fail-atomic bootstrap

Schema audit has two closed modes.

`compatiblePreBootstrap` accepts an absent core table, the exact canonical definition of any
present non-template core table, and exactly ten template revisions: the canonical three-column
base plus each ordered prefix of the nine frozen `ALTER TABLE ... ADD COLUMN` migrations. It also
checks the matching `table_list`, complete ordered `table_info`, exact `index_list/index_xinfo`, no
foreign keys, and no trigger/view/virtual/unknown/index object. Extra/missing/reordered columns,
constraints, collations, wrong PK/ROWID/STRICT flag, out-of-prefix template revisions, or modified
canonical SQL reject before `BEGIN` and before any disk mutation.

After preflight, one `BEGIN IMMEDIATE` performs the literal creates and missing suffix migrations.
Before `COMMIT`, a nested allowed `coreBootstrap -> schemaAudit` scope performs the complete
`exactReady` object, canonical SQL, layout, index, flag, and foreign-key audit while the transaction
is still rollback-capable. Audit failure rolls back. Only an exact ready state may COMMIT. A final
read-only exact audit after COMMIT detects external corruption but is not used to legitimize a
partial upgrade.

Tests snapshot `sqlite_master` and table metadata before and after rejected hostile CHECK, extra/
missing column, wrong PK, wrong ROWID, unknown index, partial-table, and non-prefix template
fixtures. For every empty and legacy-prefix DDL cut, failed open leaves the snapshot byte-identical;
a normal restart produces the one exact full schema.

## 6. Chunk value cap versus SQLite encoded-row envelope

The public chunk BLOB cap remains exactly 67,108,864 bytes and the maximum world-key UTF-8 length
remains 1,048,576 bytes. `PebbleChunkStorageRow` also performs one checked aggregate validation that
its only co-resident variable-width fields, `key.world.utf8.count + data.count`, are at most exactly
68,157,440 bytes (65 MiB). No second text/blob field exists in that row. Every other manifested row
has a strictly smaller checked sum of its simultaneously legal variable-width fields.

`SQLITE_LIMIT_LENGTH` is the closed whole-record ceiling 68,158,464 bytes: that proven 65 MiB
variable-width aggregate plus 1,024 bytes reserved for all three extreme `Int32` encodings, SQLite
serial-type/header varints, and format-stable safety margin. Typed façade per-column and aggregate
checks remain authoritative, so the larger connection ceiling never enlarges any public value cap.

Persisted tests use a maximum-byte world key, the exact 64 MiB BLOB, and extreme `Int32` coordinates
simultaneously to prove the worst-case legal encoded row writes/reads successfully. BLOB cap-1 and
cap both persist; BLOB cap+1 and key cap+1 reject before enqueue. A closed test-only raw probe proves
the configured SQLite whole-record ceiling exactly and rejects ceiling+1 without exposing SQL.

## 7. Empty mutations obey lifecycle and transaction policy

`putChunkBlobRows([])` does not return before executor admission. It executes the same one
`BEGIN IMMEDIATE`/checked `COMMIT` transaction path and returns zero only while open. Closing,
closed, and poisoned states reject exactly like non-empty batches. No public façade has a second
pre-admission success return.

## Required verification

- All adversarial tests that were red before remediation must pass without weakening assertions.
- Focused storage suites report the real test count and zero failures.
- `swift build -c release --target PebbleStorage` and full `swift build -c release` are warning-free.
- `git diff --check` is clean.
- Independent Security reviews the actual repaired code and ends PASS.
- Independent Tester reads the repaired implementation, reruns original plus adversarial suites,
  and ends PASS before Phase 2.0B edits `Saves.swift`.

## Conditions for Builder

- Never release a path/inode lease while any SQLite handle for that attempt is unclosed.
- Never mutate an unrecognized preexisting schema, and never COMMIT before exact full audit.
- Keep the 64 MiB public chunk cap; use 68,158,464 only as the private whole-record ceiling.
- Count UTF-8 octets, including embedded NUL, before materialization.
- Permit only the enumerated authorization transitions; denial remains sticky.
- Expose no Foundation error object or path-bearing text.
- Preserve both primary and extended SQLite codes correctly.
- Treat an empty mutation as a real lifecycle-checked transaction.
- Add no arbitrary SQL, capability selector, raw handle, or production failure-injection surface.
