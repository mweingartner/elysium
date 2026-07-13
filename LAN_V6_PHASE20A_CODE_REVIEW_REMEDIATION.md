# LAN v6 Phase 2.0A — Security Code-Review Remediation Contract

Status: Architect remediation revised after the second Security code FAIL; awaiting renewed
Security plan review.

This contract closes the four original findings plus the absolute-deadline and release-surface
findings from the latest independent Phase 2.0A Security code reviews. It supplements the
Security-PASS amendment SHA
`d0648a1852b806dcc142023105bcd31c4962a26b380b08221fecb8526928bb5c`. No Phase 2.0B work may begin
until this remediation is built and Phase 2.0A repeats independent Security and Tester PASS.

## 1. Authenticate logical schema objects and physical B-tree ownership

Both `compatiblePreBootstrap` and `exactReady` consume the `rootpage` selected from
`sqlite_master`. Each accepted table/materialized-index root must have SQLite storage class
`INTEGER`, fit positive `Int64`, lie in `2...pageCount`, and be pairwise unique. The exact retained
manifest is `(type, name, table, rootpage)` with no missing/unexpected/drifting objects. Canonical
schema has thirteen physical objects: seven tables and six automatic indexes for rowid tables.
`chunks` is one WITHOUT ROWID table B-tree; `sqlite_autoindex_chunks_1` remains visible through
`index_list` but has no separate `sqlite_master` object/root.

`PRAGMA main.page_count` and `PRAGMA main.page_size` each return exactly one INTEGER row then
`SQLITE_DONE`. Page size is a supported power of two in `512...65,536`. `pageCount == 0` is allowed
only in `compatiblePreBootstrap` when schema-object count is zero; an empty compatible manifest may
also have page count one. Any object requires `pageCount >= 2`. `exactReady` requires thirteen
objects and every root in range.

Root class/range/uniqueness does not detect a hostile unique child-page alias: default SQLite B-tree
pages have no parent marker. Therefore physical ownership is proven by one qualified global scan in
the same snapshot:

```sql
PRAGMA main.quick_check(1)
```

It must produce exactly one `TEXT` value with raw length two and bytes `ok`, followed by
`SQLITE_DONE`. A diagnostic row is never copied to String, logged, retained, or exposed. Wrong
class/bytes/count, prepare/step/finalize error, interruption, or an additional row maps to closed
`schemaIntegrity`.

Placement is exact:

- Keep the cheap compatible preflight for early no-mutation rejection.
- In `bootstrapAndAuditCoreSchema`, immediately after checked `BEGIN IMMEDIATE`, rerun the complete
  compatible root/layout manifest and global quick-check before the first CREATE/ALTER. Trusted
  literal DDL may follow; exact root/layout/uniqueness audit runs before COMMIT without a second
  global scan.
- Runtime `verifyCoreSchema` opens one named deferred read transaction, reads page/root/layout and
  runs quick-check in that same snapshot, then commits. Failure rolls back and publishes no proof.

The runtime snapshot is one private `schemaVerificationSnapshot` executor operation: checked plain
`BEGIN`, exact schema-audit scope, checked COMMIT, and checked rollback/autocommit restoration on any
failure. It accepts no closure/SQL/capability from a caller and cannot mutate schema or core rows.

Quick-check is explicitly O(database contents), not constant/sublinear. A private progress handler
is a corruption circuit breaker. Compute with checked `UInt64`:

`budget = 1,000,000 + 64 * pageCount * pageSize` VM operations.

Convert that checked budget to callback ticks exactly as
`callbackTicks = budget / 1_000 + (budget % 1_000 == 0 ? 0 : 1)`. Install one private C callback at
interval 1,000. Its state decrements exactly one tick per callback and returns nonzero when the
counter reaches zero; this is a deterministic callback-count circuit breaker, not an exact SQLite
instruction ceiling because SQLite documents the progress cadence as approximate. The callback
performs no allocation, SQLite call, lock, dispatch, log, or domain work. Uninstall unconditionally
in `defer` after statement finalization. Budget/tick overflow, interruption, or exhaustion fails
closed. DEBUG adds only closed factory point `quickCheckBudgetExhausted`, which forces an exhausted
counter when opening a test-created nonempty fixture; it accepts no caller budget/callback.

The schema authorizer admits only exact `main`/nil-source tuples for `page_count` and `page_size`
with nil arguments and `quick_check` with argument `1`. Existing manifested `sqlite_master` reads
also require database `main`. It denies `dbstat`, `integrity_check`, partial/table checks,
unqualified/temp/attached schemas, wrong/missing arguments, table-valued pragma forms, and adjacent
actions. No runtime core/v6 scope gains these actions.

Tests cover nonexistent/zero-byte/one-page-empty bootstrap; all ten template prefixes; exact
thirteen-root canonical layout; wrong-class/zero/one/out-of-range/duplicate direct-root alias;
unique interior-page, leaf-page, autoindex-child, and WITHOUT ROWID-child aliases; committed
uncheckpointed WAL; quick-check before DDL in the writer transaction; byte-identical rejection;
authorizer adjacency; and diagnostic redaction. Dense valid fixtures at page sizes 512, 4,096, and
65,536 remain under the formula. Exhaustion/overflow rejects and proves the handler removed. Alias
fixtures demonstrate an unprotected connection accepts/exposes the tree while global quick-check
reports duplicate ownership.

## 2. Bound and stabilize chunk-key pagination across processes

`listChunkKeys(world:)` moves from general `coreRead` to private `legacyChunkKeyCollection`. It
admits only SELECT, `count/sum/length`, reads of `chunks.world/dim/cx/cz` plus SQLite's same-table
synthetic empty column, and qualified `PRAGMA main.data_version`. It cannot read `chunks.data`,
mutate/transact, or access another table. General core/exact/v6 scopes gain no data-version/ROWID.

Read and exact-validate one INTEGER `data_version` immediately before preflight and after pagination.
Mismatch rejects the complete result. Before each append, checked-validate:

```swift
page.count <= StorageBounds.pageRows
result.count <= expectedCount
page.count <= expectedCount - result.count
result.count + page.count <= StorageBounds.chunkRows
```

Each nonempty page is strictly SQL-tuple ordered and duplicate-free; its last
`(dimension, chunkX, chunkZ)` strictly advances the prior cursor. Empty/short pages terminate. A
full page continues only after guards. Final `result.count == expectedCount` and unchanged
data-version are mandatory. Growth, insertion/deletion behind cursor, count-neutral replacement,
non-progress, duplicate, or page drift rejects.

Real bounded `/usr/bin/sqlite3` subprocess tests pause after preflight and cover later full-page
growth, insertion behind cursor, deletion of an emitted key, and one-transaction delete/replace with
unchanged count. Every write changes data-version and rejects; a read-only subprocess is the
false-positive control. Existing million-row/count-byte thresholds remain covered without ordinary
CI allocating one million rows.

## 3. Prove terminal disposal before publishing closed

Every `closeOnQueue()` error is materialized before teardown, then invokes
`terminalClose(tombstone: true)`. Terminal close finalizes all `sqlite3_next_stmt` statements and
calls `sqlite3_close`; only `SQLITE_OK` proves disposal, permits `handle = nil`/authorizer release,
and allows stable `.closed(.failure)` with the original error. `sqlite3_close_v2` is not terminal
proof and is removed there. Its one pre-publication factory-cleanup use may remain because no
statement/BLOB/backup resource can yet exist.

If final `sqlite3_close` is not OK, retain handle/callback, enter `.poisoned`, tombstone path/inode,
and reject all work/reopen; never publish closed. DEBUG reuses closed `.close` injection count: one
fails ordinary close then allows terminal disposal; two also simulates terminal disposal as
unproven, retaining the handle until deinit performs the now-uninjected real close. No arbitrary
failure API is added.

Tests retain the failed coordinator, count physical-inode descriptors, prove count-one disposal,
tombstone/reopen rejection, closed facade, and stable repeated original error. Count two proves
poisoned semantics, descriptor retention until deinit, tombstone blocking, and eventual real
disposal. A source gate denies all `sqlite3_blob_*`/`sqlite3_backup_*` calls and permits
`sqlite3_close_v2` only at the exact pre-publication factory cleanup. Release symbols contain no
test injection/stage API.

## 4. Two closed DEBUG observation latches

Exactly two DEBUG-only stages exist:

```swift
enum ElysiumStorageTestStage: Sendable {
    case afterChunkKeyPreflight
    case afterDurabilitySyncBeforeIdentityProof
}
```

`_testArmStage(_:)` returns a latch containing no path, descriptor, SQL, table/column, error code,
callback, closure, payload, context, statement, or authorization capability. Both waits use
absolute `DispatchTime.uptimeNanoseconds` deadlines and strict-before arbitration. The first
`waitUntilReached()` call locks the latch and captures its checked absolute external deadline as
`now + 5_000_000_000`; the executor's `armed -> reached` transition locks the same latch and captures
its checked absolute resume deadline by the same formula. Overflow is immediate timeout. Repeated
wait calls reuse the first deadline and never extend it. The notification result from
`DispatchGroup.wait(timeout:)` is never itself success: after either `.success` or `.timedOut`, the
caller reacquires the latch lock and the recorded transition tick must be strictly less than its
deadline. A transition at `now == deadline` is expired. Its monotonic locked states are:

`armed -> reached -> resumed -> consumed`

with terminal side states `cancelled` and `executorTimedOut`. Every state-reading or state-mutating
entry first samples the continuous clock while holding the lock and runs the same expiration helper.
Only `.armed` without an accepted `reachedAt` may expire to `cancelled`; only `.reached` without an
accepted `resumedAt` may expire to `executorTimedOut`. A transition already recorded strictly before
its deadline remains accepted even if the waiting thread reacquires the lock later; resumed/consumed
success is never retroactively expired. The helper signals both dispatch groups exactly once before
unlocking. Terminal state is irreversible and `waitUntilReached()`, the now-throwing
`resume()`, and `executorReachAndWait()` always throw `ElysiumStorageTestStageError.timeout`; the
executor may never treat a cancelled latch as a successful no-op. Thus a reach/resume racing the
waiter's timeout succeeds only when its recorded tick is strictly before the applicable deadline;
a transition at or after the deadline cannot resurrect or consume the latch.

Early/double resume remains idempotent only before expiry: early resume records a monotonic
`resumeRequestedAt` tick while armed; on reach the executor may advance through
reached/resumed/consumed without waiting only if all applicable strict-before checks pass. The
executor wait is bounded by its one absolute resume deadline rather than a newly computed timeout.
`observeTestStage` uses one `defer` to identity-check and clear `activeTestStage` on success or throw.
An externally cancelled wrong-stage latch is terminal/reapable and `_testArmStage` clears it before
rearm; a later matching observation must throw and then clear it. Resumed/consumed and
`executorTimedOut` observations clear immediately. This is the only detachment ownership; the latch
receives no executor reference or cleanup callback.

Deterministic boundary coverage uses one additional closed DEBUG-only seam, not wall-clock sleeps:
`ElysiumStorageTestDeadlineBoundary` has exactly `.externalWait` and `.executorWait`, and
`_testExpireDeadline(_:)` accepts only that enum. Under the latch lock, `.externalWait` is valid only
while armed and captures the external deadline if absent; `.executorWait` is valid only while
reached. It sets that deadline equal to the current uptime tick and calls the same production
expiration/arbitration helper before unlocking. Any wrong state throws `invalidValue`.
It accepts no duration, clock, callback, closure, payload, or context. Tests prove equality expires,
post-deadline wait/reach/resume all throw, terminal state cannot resurrect, both groups release,
matching observation detaches, wrong-stage cancellation/rearm works, and the intact retry remains
usable. The existing real five-second behavior needs one bounded integration test only; all race
boundary assertions use the closed seam. No stage/latch/deadline type or name survives release
compilation.

At `afterDurabilitySyncBeforeIdentityProof`, capture a stage timeout but always run retained parent/
database identity proof. Identity failure takes precedence, poisons, terminal-closes/tombstones, and
returns no success. Throw stage timeout only when identity is intact, leaving barrier retryable.

The chunk-key subprocess tests use the first stage. Barrier tests cover replacement with resume;
replacement with no resume; intact path with no resume then retry; wrong-stage cancellation/rearm;
early/double resume; executor timeout; single-use; identity precedence; and release-symbol absence.

## 5. Machine-enforce the closed release surface

Add executable `scripts/verify-elysium-storage-release-surface.sh` with no optional/skip mode and no
arguments. It runs only after a successful `swift build -c release` in the same gate. It resolves one
absolute release directory with `swift build -c release --show-bin-path` and requires these exact,
non-symlink, nonempty artifacts; glob/fallback discovery is forbidden:

- `$RELEASE_DIR/ElysiumStorage.o`
- `$RELEASE_DIR/Elysium`
- `$RELEASE_DIR/elysmoke`

Artifact discovery fails closed on absent `xcrun`/`nm`/`strings`/`swift-demangle` tools,
multiple/nonabsolute bin-path output, missing or unreadable artifacts, or command failure.
`ElysiumStorage.o` must be no older than `Package.swift` or
any regular file under `Sources/ElysiumStorage`; each linked product must be no older than that
object. `xcrun nm -a` and `xcrun strings -a` run successfully against all three artifacts into fresh
temporary files removed by `trap`. Demangled `nm` output for each artifact must contain the exact
production sentinel `ElysiumStorage.ElysiumStorageCoordinator.open(databaseURL:` so an unrelated or
empty artifact cannot pass.

The following fixed-string denylist is closed and is checked independently against both
raw/demangled `nm` output and `strings` output for every artifact:

```text
ElysiumStorageTest
ElysiumStorageFactoryFailurePoint
ElysiumStorageSQLiteLengthLimitProbe
ElysiumStorageLegacyCollectionFailurePoint
ElysiumStorageLegacyImportFailurePoint
ElysiumStorageBarrierFailurePoint
ElysiumStorageSchemaAuditProbe
ElysiumStorageTestDeadlineBoundary
ElysiumStorageTestBodyError
StorageLegacyImportFailurePoint
_test
testOpen
testInject
testSet
testArmStage
testAutocommit
testForeignKeysEnabled
testPhysicalIdentityBound
testSameScopeReentry
testEscapedStatementRejects
testReadScopeWriteProbe
testLegacy
testCrossTableMutationProbe
testBootstrapAfterReadinessProbe
testNestedTransactionProbe
testCaughtBindFailureCannotCommit
testForceAuthorizationGenerationBoundary
testLeakRawStatementForClose
testBodyAndFinalizeFailure
testAuthorizationContract
testSchemaAuditDeniedProbe
testSQLiteLengthLimitProbe
testExtendedPrimaryKeyConstraint
testWorldCollectionThreeByteBudget
activeTestStage
observeTestStage
factoryProbe
injectFactoryFailureBeforeBootstrapStatement
injectLegacyImportFailure
injectedFailures
testLeakedRawStatement
authorizationTransitionCoverage
legacyCollectionFailurePoint
legacyImportFailurePoint
barrierFailurePoint
consumeLegacyCollectionFailure
consumeLegacyImportFailure
consumeBarrierFailure
quickCheckBudgetExhausted
afterSQLiteOpen
beforeBootstrapStatement
afterChunkKeyPreflight
afterDurabilitySyncBeforeIdentityProof
externalWait
executorWait
```

The script also fails if `nm -u` exposes any `sqlite3_blob_*` or `sqlite3_backup_*` symbol. The exact
undefined `_sqlite3_close_v2` import is allowed and required once per artifact; this is not proof of
call-site count, so the existing source gate remains mandatory and requires exactly one source call,
`sqlite3_close_v2(localHandle)`, inside the pre-publication `sqlite3_open_v2` cleanup where no
statement/BLOB/backup can exist. No other `close_v2` spelling/call is allowed.

`scripts/pipeline.sh` invokes the verifier immediately after its warning-free release build and
before `security-check-binary`. `.githooks/pre-push` invokes the same verifier immediately after its
warning-free release build and before XCTest. Both check that the verifier exists and is executable;
missing/nonexecutable is a hard failure. `scripts/security-scan.sh` remains a pre-build source scan
and does not substitute for or skip this release-artifact gate.

The Builder may edit only:

- `Sources/ElysiumStorage/StorageEngine.swift`
- `Tests/ElysiumCoreTests/ElysiumStorageExecutorTests.swift`
- `Tests/ElysiumCoreTests/ElysiumStorageAdversarialTests.swift`
- new executable `scripts/verify-elysium-storage-release-surface.sh`
- `scripts/pipeline.sh`
- `.githooks/pre-push`

`Package.swift`, `scripts/security-scan.sh`, Phase 2.0B, and all gameplay/LAN/RPG/UI/save-adapter
files are out of scope.

## Verification and gate order

Builder runs focused feedback first:

```bash
swift test --filter 'ElysiumStorageExecutorTests|LANV6SchemaAuthorizerTests|ElysiumStorageAdversarialTests'
swift build -c release --target ElysiumStorage
swift build -c release
bash scripts/verify-elysium-storage-release-surface.sh
bash -n scripts/verify-elysium-storage-release-surface.sh scripts/pipeline.sh .githooks/pre-push
git diff --check
```

Then a fresh independent Security code review must PASS. Only then may an independent Tester add/run
adversarial regressions and root rerun focused/full gates. Material fixes repeat Security first.

## Conditions for Builder

- Both schema modes validate exact physical root manifests; no direct/child alias reaches readiness.
- Global quick-check runs once in the coherent pre-DDL/runtime snapshot with a deterministic circuit
  breaker and no diagnostic disclosure.
- Fresh databases and legal dense/page-size fixtures remain usable.
- Chunk keys cannot exceed preflight and cannot escape an intervening external commit.
- No stable closed result retains a live/zombie handle; unproven disposal is poisoned/tombstoned.
- Only the two closed DEBUG stages exist and expose synchronization, never storage authority.
- Deadline equality/expiry is terminal under one lock; no post-deadline transition can report
  success or silently continue, and boundary tests do not depend on scheduler timing.
- Post-sync identity proof always runs and outranks a stage timeout.
- Fresh release storage/object/app/smoke artifacts contain no closed DEBUG surface, and pipeline plus
  pre-push enforce the same fail-closed verifier after building release.
- No Phase 2.0B/gameplay/LAN/RPG/UI/save-format/deployment work enters this fix.
