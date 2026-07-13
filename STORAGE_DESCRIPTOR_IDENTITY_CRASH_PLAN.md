# Storage Descriptor Identity Launch-Crash Plan

## Design Mock — ordinary launch recovery

**Verdict: PASS.** This change restores access to Elysium’s existing experience; it does not design
a new experience.

### User-visible contract

- A valid ordinary launch reaches Elysium’s existing window, title/world flow, and RPG surface with
  no new screen, dialog, banner, status, control, or copy.
- Existing layout, focus, accessibility, controller/keyboard help, RPG creation, tabs, authority
  presentation, progression, and visual tokens remain pixel- and semantics-equivalent. Harness mode
  and its immutable fixtures are unchanged.
- Storage descriptor identity is never guessed, substituted, or silently repaired merely to keep a
  window open. If the required storage surface cannot be opened safely, launch fails closed before
  any world is loaded or mutated.
- A fail-closed open failure remains diagnosable through the one existing stable, path-redacted fatal
  message and a nonzero exit. Swift's runtime may add toolchain-owned fatal/crash framing; that
  framing is not treated as Elysium application copy. The captured stderr is capped for evidence and
  must expose no save contents, credentials, absolute user paths, or SQL payloads. No new recovery UI
  or user-facing terminology is introduced by this correction.

### Required states

1. **Normal title launch:** the signed installed app opens its ordinary existing title window.
2. **Disposable world plus RPG:** with a fresh `CFFIXED_USER_HOME`, the documented
   `ELYSIUM_AUTOLOAD=1`, `ELYSIUM_NEWWORLD=<seed>`, `ELYSIUM_OPEN_SCREEN=rpg`, and
   `ELYSIUM_SHOT=<disposable path>@<frames>` flow creates only the disposable world, reaches the
   existing RPG surface, writes the requested PNG, and exits normally.
3. **Unsafe or invalid storage identity:** no title/world/RPG surface is published; no fallback
   database is opened; the process produces the bounded diagnostic and exits nonzero.

### Design acceptance

- The installed executable hash and signature are recorded before proof.
- Normal launch produces a real Elysium window and remains alive long enough for ordinary use; there
  is no signal, abort, uncaught exception, or `StorageEngine.swift:1361` termination.
- Disposable-world proof exits zero, produces a valid nonempty PNG of the existing RPG surface, and
  confines every created file to the fresh home plus the explicitly requested screenshot path.
- The disposable screenshot and semantic surface show no new copy or presentation; the current RPG
  Design Sign-off evidence remains applicable except for the separately renewed ordinary-runtime
  proof.
- A forced invalid-identity probe proves fail-closed behavior, bounded diagnostic output, nonzero
  exit, zero world mutation, and no database fallback.
- VoiceOver, physical-controller, LAN, progression rules, save formats, and RPG UI behavior receive
  no design change from this repair. Any observed change returns to Design Review before Build can
  continue.

## Architecture — signed POSIX device identity correction

### Incident evidence and exact root cause

The installed release crash report
`~/Library/Logs/DiagnosticReports/Elysium-2026-07-11-092458.ips` is authoritative evidence. Its
faulting storage-queue frame is `StoragePathLease.descriptorCount(for:)` at
`Sources/ElysiumStorage/StorageEngine.swift:1361`; Swift reports `Negative value is not
representable`. Ordinary launch reaches `SaveDB` -> `ElysiumStorageCoordinator.open` -> SQLite open,
then the post-open descriptor proof scans every successfully `fstat`ed process descriptor. The
database reservation itself had a positive device ID. A different, unrelated open descriptor had a
negative Darwin `dev_t`; the scan evaluated `UInt64(info.st_dev)` before it could compare that
descriptor with the retained database identity, so Swift's checked signed-to-unsigned conversion
trapped. This is a process crash, not a SQLite error and not evidence of database corruption.

The existing unit environment did not contain that descriptor class. Moreover,
`ElysiumStorageExecutorTests.descriptorCount(for:)` compares native `st_dev` values directly, so its
leak assertions do not exercise the production conversion that failed. The adversarial and schema
tests contain their own checked `UInt64(st_dev)` conversions, but only observe the test process's
ordinary files and therefore also missed the negative-device case.

### Identity representation decision

Use the operating system's native identity types for every in-process equality/hash/scan:

- `StorageFileIdentity.device` is `dev_t`; `inode` is `ino_t`.
- Construct the identity once from a successful `stat`/`fstat` result and compare
  `StorageFileIdentity` values. Do not perform numeric conversion while scanning descriptors.
- Equality remains exactly the `(st_dev, st_ino)` pair. Do not compare paths, descriptor numbers,
  mount names, URLs, creation dates, or truncated inode values, and do not weaken the existing
  same-physical-file lease or tombstone rules.

The existing public
`ElysiumStorageCoordinator.verifyDatabaseParentIdentity(device: UInt64, inode: UInt64)` signature
and the legacy `PBLM2` identity fields remain unchanged. At those existing UInt64 boundaries only,
encode Darwin's signed 32-bit `dev_t` as its zero-extended raw bit pattern:
`UInt64(UInt32(bitPattern: device))`. Positive device values therefore remain byte-for-byte
unchanged; a negative native device becomes a stable value in `0...UInt32.max` without a trap.
`ino_t` is already unsigned on the supported Darwin target and is losslessly represented as
UInt64. Do not use `abs`, `UInt64(truncatingIfNeeded:)`, sign extension to 64 bits, or a changed
public signed parameter. Those alternatives either collide identities, obscure the frozen encoding,
or widen the reviewed API.

### Exact implementation surface

1. **`Sources/ElysiumStorage/StorageEngine.swift`**
   - Change the private `StorageFileIdentity` fields to `dev_t`/`ino_t`; give it one initializer from
     `stat` and one computed UInt64 device-bit-pattern representation for the frozen public boundary.
   - Route lease acquisition, parent/file revalidation, descriptor scanning, and retained-parent
     verification through that identity. Remove every direct `UInt64(...st_dev)` in this file.
   - Preserve `StoragePathLease.descriptorCount`'s current serialized window and audited descriptor
     ceiling. Extract only its identity-reading/counting kernel so the real path still calls `fstat`
     once per candidate and a DEBUG-only deterministic seam can supply synthetic observations.
     Failed `fstat` calls count as absent; unrelated identities count zero; no exception or sentinel
     may cause a descriptor to be accepted.
   - Keep `verifyDatabaseParentIdentity(device:inode:)` public signature and error behavior. Compare
     the caller's UInt64 device value with the retained identity's explicit bit-pattern encoding.
   - Under `#if DEBUG`, expose only the internal
     `ElysiumStorageDescriptorIdentityProbe` bounded value-based descriptor-count probe. It accepts a
     target native `dev_t`/`ino_t` pair plus at most 65,536 optional native identity pairs and
     delegates to the same counting kernel. `nil` represents one failed/absent observation. More
     than 65,536 observations is rejected rather than truncated or partially counted. It must not
     accept file paths, raw descriptors, callbacks, global injection, or mutable retained state.

2. **`Sources/ElysiumCore/Game/LegacySaveMigration.swift`**
   - Centralize the existing persistent/public device representation in one private
     `dev_t -> UInt64` raw-bit-pattern helper and use it at all four current `st_dev` capture/compare
     sites. This is the same signedness defect family and prevents a valid negative-device legacy
     parent from becoming the next launch trap after the descriptor fix.
   - Do not change `LegacyFileIdentity`, `LegacyStatIdentity`, provenance/recovery record size or
     ordering, schema/version bytes, path/lease validation, or migration behavior. Add only a
     DEBUG-only internal `legacyDeviceBitPatternForTesting` pure wrapper needed to verify the
     negative bit pattern; no test injection reaches filesystem or migration state.

3. **Focused tests**
   - In `Tests/ElysiumCoreTests/ElysiumStorageExecutorTests.swift`, add
     `testDescriptorCountHandlesNegativeNativeDeviceWithoutTrap`. Its synthetic observations must
     include: a positive target, an unrelated negative device with the same inode, a matching target,
     an absent/failed observation, and a negative target/matching observation. Assert exact counts
     and the raw `0xb00007ff -> 0x00000000b00007ff` boundary value. Also require a distinct negative
     device with the same inode not to match, and require 65,537 synthetic observations to be rejected
     without a partial count.
   - Update parent-identity helpers in that file to use the explicit bit-pattern conversion when
     calling the frozen UInt64 API; keep native comparisons for actual descriptor leak counts.
   - Update `ElysiumStorageAdversarialTests.swift` identity/race helpers and
     `LANV6SchemaAuthorizerTests.swift` descriptor helpers to native `dev_t`/`ino_t` comparisons, so
     the tests themselves cannot trap before evaluating storage behavior.
   - In `LegacySaveMigrationAdversarialTests.swift`, add a pure negative-device encoding regression
     through `legacyDeviceBitPatternForTesting`. The expected low 32-bit pattern is exact, positive
     devices are unchanged, and the sign-extended 64-bit spelling plus every value above
     `UInt32.max` remain unequal to the frozen zero-extended representation.
   - After edits, `rg 'UInt64\([^)]*st_dev' Sources Tests` must return no direct checked conversion.

4. **Reviewed manifests and release verifier**
   - `scripts/elysium-storage-api-v1.json` must have an empty semantic diff: no public/package/SPI
     declaration, signature, conformance, or owner changes. Regenerate/compare it in a temporary
     location; do not accept a changed API to fix a private representation bug.
   - Because `LegacySaveMigration.swift` changes, regenerate and review only that owner's
     `compilerParseASTSHA256` in `scripts/elysium-core-storage-capability-v1.json`; `Saves.swift` and
     the two-owner inventory remain unchanged.
   - In `scripts/verify-elysium-storage-release-surface.sh`, update only reviewed hashes that actually
     change after a clean warning-free release build: storage source, storage object, Core capability
     manifest, Core object, Elysium, and elysmoke. Existing `Saves.swift`, `GameCore.swift`, `Player.swift`,
     and storage API-manifest pins remain unchanged. Add the exact DEBUG seam names
     `ElysiumStorageDescriptorIdentityProbe` and `legacyDeviceBitPatternForTesting` to the binary
     denylist and prove neither exists in `ElysiumStorage.o`, `ElysiumCore.o`, Elysium, or elysmoke.
   - Hashes are consequences, never inputs: no placeholder, blanket rehash, `--accept`, or verifier
     bypass is allowed. Any unexpected manifest/symbol diff returns to Architecture and Security.

5. **Separate pre-existing source-contract test drift**
   - `Tests/ElysiumCoreTests/SaveDBLifecycleTests.swift` currently fails the full suite because
     `testSourceSurfaceHasOneBareGameCoreCompatibilityInitializerAndNoSilentAlternative` searches
     for `public init(db: SaveDB = SaveDB())`, while the reviewed shipping source intentionally uses
     `public convenience init(db: SaveDB = SaveDB())` to delegate to the designated
     `init(db:localSettingsStore:)` introduced for injected local-settings tests.
   - Correct only that expected declaration string (and rename the test only if its current name
     becomes misleading). Continue to assert exactly one `SaveDB()` occurrence, exactly one public
     defaulted compatibility initializer, no alternate silent database construction, exactly one
     `SaveDB` convenience initializer, and the bounded fatal diagnostic. Do not change
     `GameCore.swift` to satisfy a stale text assertion and do not weaken the test to a loose
     substring or regular expression.
   - This is test-contract maintenance, not part of the runtime crash mechanism. It changes no
     production source, manifest, object, product, installed behavior, or hash pin.
   - In the same test file, strengthen the existing compatibility-initializer subprocess assertion:
     asynchronously drain stderr while the child runs, reject and terminate the child if output
     exceeds 65,536 bytes rather than truncating it, require the exact stable
     `Elysium save database initialization failed` message exactly once, and reject the disposable
     home path, `elysium.db`, SQL text, and a caller-provided secret sentinel. Runtime-owned fatal
     framing is permitted; no assertion may depend on its addresses, source locations, or wording.

### Risk-to-test map

| Risk / invariant | Required evidence |
|---|---|
| Unrelated negative `st_dev` traps ordinary launch | Shared-kernel synthetic negative observation test; release installed ordinary-launch repetitions |
| Negative target is skipped or aliases a positive device | Exact native negative-target match plus same-inode/different-device non-match |
| Identity proof weakens to a path or descriptor heuristic | Existing alias, replacement, tombstone, post-open race, and physical-binding tests remain green |
| Public API or legacy record encoding drifts | Empty storage API semantic diff; positive-device compatibility and exact negative raw-bit-pattern tests |
| DEBUG injection leaks into release | Verifier denylist over fresh `ElysiumStorage.o`, `ElysiumCore.o`, Elysium, and elysmoke |
| Descriptor leak/close behavior regresses | Existing deterministic post-open failure, close injection, reopen, and adversarial race tests |
| A second direct checked conversion remains | Repository-wide `rg` audit plus focused legacy negative-device test |
| Stale release is installed | Freshness checks, reviewed hashes, installed executable hash/signature, and launch timestamp evidence |
| Full suite remains blocked by stale initializer spelling | Exact source-contract assertion for the intentional `public convenience init(db: SaveDB = SaveDB())`; all other uniqueness/fatal checks retained |

### Dependency and gate order

1. Design Mock above — **PASS**.
2. This Architecture contract — **PASS**.
3. Design Review/Revision confirms no UI or diagnostic contract drift.
4. Security (plan) reviews identity collision, fail-closed behavior, test-seam stripping, public/API
   encoding, and verifier consequences; unresolved findings block Build.
5. Builder implements the files above in order: native storage identity and shared scan kernel;
   legacy bit-pattern boundary; focused regressions; exact source-contract test correction; reviewed
   manifest/verifier changes.
6. Security (code) inspects the actual diff and fresh API/symbol artifacts.
7. Focused Test runs descriptor/lease/adversarial/schema/migration suites, then the full source scan,
   warning-free release build, release-surface verifier, full XCTest, and 457-check `elysmoke`.
   Run `scripts/pipeline.sh` as the final pre-install gate and retain the exact artifact hashes it
   verifies.
8. Install only those exact verified artifacts. Record `/Applications/Elysium.app` executable SHA-256
   and strict signature. With no Elysium process running and no harness variables, record the crash
   report directory baseline, launch the signed installed app normally at least three times, require
   a real window and a live process for at least 15 seconds each, quit cleanly, and prove no new
   Elysium crash report. This is mandatory because the escaped failure was release-only and depended
   on the ordinary app descriptor table.
9. Run the disposable-home RPG screenshot state from the Design Mock. For the installed fail-closed
   open probe, create a second fresh `CFFIXED_USER_HOME`, create its `Library/Application Support`
   directory, and precreate `Library/Application Support/Elysium` as a regular file before launch.
   Launch the installed app with no harness, autoload, world, LAN, or screenshot variable. Require a
   bounded nonzero exit, the stable path-free storage-open diagnostic exactly once while stderr is
   drained with a hard 65,536-byte reject-on-overflow cap and a launch timeout, no Elysium window, no
   database, WAL, SHM, world, or settings file, and a
   before/after manifest of non-directory entries whose only entry is the caller-made obstruction.
   Reject the fresh-home path, `elysium.db`, SQL text, and a unique secret sentinel in captured output;
   do not assert on or publish runtime-owned crash addresses. Remove the disposable home after
   evidence is recorded. This exercises a real unsafe
   storage-open failure without adding a release hook; the focused identity-mismatch tests separately
   exercise the frozen `verifyDatabaseParentIdentity` error. Any code, manifest, rebuild, reinstall,
   or installed-hash change after proof makes the artifact, launch, and disposable evidence stale.

### Conditions for Builder

- Preserve exact `(dev_t, ino_t)` physical identity semantics, path reservation, no-follow opens,
  serialized SQLite binding proof, descriptor ceiling, tombstones, poison/close behavior, and lock
  ordering. A negative device value is valid identity data, not an error or wildcard.
- Convert a device only at the two frozen UInt64 representation boundaries, by explicit zero-extended
  32-bit raw bit pattern. Never convert while enumerating unrelated process descriptors.
- Add no public/package/SPI API, dependency, schema/DDL, migration record revision, fallback database,
  path disclosure, user-facing UI/copy, or release test hook.
- The DEBUG scan seam is pure, finite, stateless, and compiled out of release. It cannot open, close,
  retain, or substitute a descriptor and cannot alter the process-wide lease registries.
- Preserve unrelated dirty worktree changes. Stage only this logical correction, update hashes only
  after their exact reviewed build, and do not claim deployment until the installed ordinary-launch
  proof succeeds.

**Architecture verdict: PASS.** The crash has a single confirmed mechanism, the internal native
identity removes the trapping conversion without weakening physical-file binding, and the explicit
raw-bit-pattern boundary preserves the reviewed UInt64 API and legacy record format. Build remains
blocked until Design Review and independent Security-plan PASS. Any broader API, format, scanner,
lease, or lifecycle change invalidates this verdict and returns here before implementation.

## Security (plan) review — 2026-07-11

Security reviewed the pre-amendment plan at SHA-256
`a84251c1cbf91f680090a71524c33454ac4adf4ed0545cf321dbe9fdf19fab43`. Three gaps were made
binding above: the DEBUG observation seam now has the production 65,536 ceiling plus exact release
denylist names; the legacy audit now names the actual four conversion sites and tests zero-extension
against sign extension and out-of-range UInt64 callers; and the invalid-support-path proof now
separates Elysium's stable path-redacted fatal message from toolchain-owned crash framing while
bounding and scanning captured evidence.

The native `(dev_t, ino_t)` equality is collision-preserving on the supported Darwin target. The
boundary encoding `UInt64(UInt32(bitPattern: device))` is injective over signed 32-bit `dev_t`: the
positive half remains unchanged and the negative half occupies the disjoint
`0x80000000...0xffffffff` UInt64 range. Caller values outside `UInt32` or using 64-bit sign extension
are compared without truncation and therefore fail closed. Failed `stat`/`fstat` observations remain
absent, never wildcard identities. The public storage API and PBLM2 bytes remain frozen; DEBUG seams
are internal, stateless, bounded, and release-denied; unexpected manifest, symbol, or hash drift
returns to review.

**Security(plan) verdict: PASS.** Build is authorized only for the exact implementation, test,
manifest, and verifier surface above. Security(code), full verification, release pin renewal,
installed ordinary-launch proof, and the invalid-support-path probe remain mandatory downstream.

## Builder evidence — 2026-07-11

Builder implemented the approved contract at SHA-256
`c52692d662e2c6186cc5f090960206f7f7c5d4a373c17e46577b50a3a329cfdd`. Storage now keeps
descriptor identities as native `dev_t`/`ino_t`, production scanning and the bounded DEBUG probe use
one count kernel, and conversion to UInt64 occurs only as the explicit zero-extended 32-bit device
bit pattern at the frozen public/persistent boundaries. Legacy migration uses one shared conversion
helper at all four audited sites. The focused native negative-device, exact high-bit, non-aliasing,
failed-observation, and 65,537-observation rejection regressions were added. The compatibility
initializer assertion now names the intentional convenience initializer exactly and its subprocess
stderr reader is asynchronous, bounded to 65,536 bytes, and path/SQL/secret rejecting.

The raw ElysiumStorage symbol-graph hash changed because private additions moved source locations.
Before renewing that raw pin, Builder reconstructed the pre-fix storage source in a disposable tree,
removed generator and location metadata, sorted symbols and relationships, and compared canonical
graphs. Both graphs contained exactly 296 symbols and 379 relationships and were byte-identical
after canonicalization at SHA-256
`6718519ef65b4479fb30f28ac51db0900cb3c6631c671c30406dcaaa41182798`. No probe or private
identity symbol appeared in the externally reachable graph. On that evidence, the reviewed raw
graph location hash was renewed to
`3ef21a963a12029462112c17e540ad129d9ae7d2f1c85504acff5d1f130d4d7d` rather than treating a
location-only byte change as API growth. The Legacy owner compiler-parse digest was regenerated to
`aa1539d1a2361fa73c89ededa6e1756976ea351a593f251aebb67ec8795166f0`; the Saves owner remained
exactly `e195fc67b22ecb26e7b27ae397caea418b8bc3745e85399d3ee734f71cc4fea7` and the two-owner
inventory was unchanged.

Verification evidence, all exit status 0:

- focused negative/high-bit tests: 2 tests, 0 failures;
- storage executor/adversarial/schema/migration/lifecycle suites: 108 tests, 0 failures in 24.617 s;
- full `swift test`: 962 tests, 0 failures in 228.186 s;
- `swift build -c release`: warning-free, completed in 110.07 s;
- `swift scripts/sqlite-boundary-scan.swift --root "$PWD" --self-test`: passed 126 production Swift
  files;
- `rg 'UInt64\([^)]*st_dev' Sources Tests`: no matches;
- `bash scripts/security-scan.sh`: passed;
- `bash scripts/verify-elysium-storage-release-surface.sh`: verified, including absence of
  `ElysiumStorageDescriptorIdentityProbe` and `legacyDeviceBitPatternForTesting` from release objects
  and products;
- `swift run -c release elysmoke`: 457 passed, 0 failed;
- `git diff --check`: passed.

Reviewed source and manifest SHA-256 consequences:

- `StorageEngine.swift`: `60d19e245770fdb0edff35bf812bb978e113e79e56e0dd24b776ab55a3b39d6b`;
- `LegacySaveMigration.swift`: `b2c3a5356f661747f480e1468eab4d292063a0e60623ac7df01dd280805237a4`;
- storage API manifest: `c5c44bb0f37a9989dc2c90c98503abafad76a5e6a0f5d2abe46919a3c47b542e`;
- Core capability manifest: `af2caf0d306172437f0b311e9c0ca1c65c8b89520b2174794c885a3708af654d`;
- release verifier: `47ed918601ac8a7962b9e65a2d9ccf4cf52518a98d5a734d5c6d376a6043a9f7`.

Fresh release artifact SHA-256 values, rechecked after `elysmoke` rebuilt the release graph:

- `ElysiumStorage.o`: `ed37590e383037968b25905cb7ecd1d29e8faa43ba1f62a4919baebf9aabc6ba`;
- `ElysiumCore.o`: `7e7caeec1e760a60739736ad240993562bd972e29e6a03c6c54ace486b37751a`;
- `Elysium`: `70847c5282589a387b2aa08e3d5233cb81e5d8bbe01edfb527934cd60f5285ea`;
- `elysmoke`: `5e1d47e14ab3e427a0ff35ef6ae2a00b887d38c5c53883bf2afc40a556e5f2ec`.

**Builder verdict: PASS.** The implementation and local build/test/release-surface gates are green.
Per the assigned Builder boundary, no install, ordinary installed-app launch proof, deployment,
commit, or push was performed; those downstream gates remain for the owning orchestrator.

## Security (code) review — 2026-07-11

**Security(code) verdict: PASS.** Security independently reviewed the actual production, test,
manifest, scanner, verifier, and release-artifact surfaces against the approved plan SHA-256
`c52692d662e2c6186cc5f090960206f7f7c5d4a373c17e46577b50a3a329cfdd`. Reviewed production
hashes were `60d19e245770fdb0edff35bf812bb978e113e79e56e0dd24b776ab55a3b39d6b` for
`StorageEngine.swift` and `b2c3a5356f661747f480e1468eab4d292063a0e60623ac7df01dd280805237a4`
for `LegacySaveMigration.swift`; manifest/verifier hashes were
`c5c44bb0f37a9989dc2c90c98503abafad76a5e6a0f5d2abe46919a3c47b542e`,
`af2caf0d306172437f0b311e9c0ca1c65c8b89520b2174794c885a3708af654d`, and
`47ed918601ac8a7962b9e65a2d9ccf4cf52518a98d5a734d5c6d376a6043a9f7` for the storage API
manifest, Core capability manifest, and release verifier respectively.

The production lease, tombstone, path revalidation, retained-parent proof, and descriptor scan now
compare exact native `(dev_t, ino_t)` values. No descriptor enumeration performs a signed-to-unsigned
conversion. The sole storage UInt64 boundary compares the caller without truncation against
`UInt64(UInt32(bitPattern: device))`; this is injective across the signed 32-bit Darwin `dev_t`
domain, keeps positive values unchanged, and maps negative values into a disjoint high-UInt32 range.
Inode conversion remains lossless on the supported target. Failed `fstat` observations are absent,
not wildcard identities, and the shared kernel cannot exceed 65,536 matches.

The DEBUG `ElysiumStorageDescriptorIdentityProbe` accepts only native value tuples and a bounded array;
it exposes no descriptor, path, callback, registry, lease, retained state, or mutation hook, and
65,537 observations are rejected without a partial count. Legacy migration uses the one frozen
zero-extension helper at all four audited `st_dev` sites without changing the UInt64 identity fields,
PBLM2 ordering, size, or version. The negative, positive, sign-extended, out-of-range, same-inode,
distinct-device, failed-observation, and exact-match regressions pass. Repository-wide direct checked
`UInt64(...st_dev)` search is empty.

Security independently regenerated the current storage symbol graph: its raw SHA-256 exactly matches
the renewed manifest pin
`3ef21a963a12029462112c17e540ad129d9ae7d2f1c85504acff5d1f130d4d7d`; it contains 296 symbols
and 379 relationships. Removing generator/location metadata and deterministically sorting the graph
reproduces the reviewed canonical SHA-256
`6718519ef65b4479fb30f28ac51db0900cb3c6631c671c30406dcaaa41182798`. Neither DEBUG seam is
externally reachable. The raw pin renewal is therefore location-only rather than API growth. The
Legacy compiler-AST pin reproduces through the source scanner, the Saves owner and two-owner inventory
remain frozen, and the API/capability scans fail closed on drift.

Independent closing evidence:

- storage executor, adversarial/schema, legacy adversarial/base, and lifecycle suites executed
  **108 tests with 0 failures**;
- the invalid-support-path subprocess test passed its asynchronous 65,536-byte reject-on-overflow
  capture, exact-once stable diagnostic, path/database/SQL/secret redaction, and nonzero-exit checks;
- the lifecycle source contract requires exactly one delegating defaulted GameCore compatibility
  initializer, one public SaveDB convenience initializer, and the one bounded fatal message;
- `scripts/security-scan.sh` passed the 126-file source/semantic scan; the release-surface verifier
  passed with fresh pinned objects/products;
- independent symbol and string scans found both DEBUG seam names absent from `ElysiumStorage.o`,
  `ElysiumCore.o`, Elysium, and elysmoke; release hashes exactly matched
  `ed37590e383037968b25905cb7ecd1d29e8faa43ba1f62a4919baebf9aabc6ba`,
  `7e7caeec1e760a60739736ad240993562bd972e29e6a03c6c54ace486b37751a`,
  `70847c5282589a387b2aa08e3d5233cb81e5d8bbe01edfb527934cd60f5285ea`, and
  `5e1d47e14ab3e427a0ff35ef6ae2a00b887d38c5c53883bf2afc40a556e5f2ec`;
- artifact mtimes were newer than the reviewed storage/Core sources and `git diff --check` passed.

No Security(code) findings remain. This PASS does not claim installed ordinary-launch recovery,
installed invalid-support-path proof, deployment, commit, or push; those downstream gates remain
mandatory and any code, manifest, artifact, or pin change invalidates this review.
