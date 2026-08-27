#!/bin/bash
set -euo pipefail

fail() {
    printf 'Elysium storage release-surface verification failed: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 0 ] || fail "arguments are not accepted"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCRUN="$(command -v xcrun)" || fail "xcrun not found"
[ -x "$XCRUN" ] || fail "xcrun is not executable"
NM="$($XCRUN --find nm)" || fail "nm not found through xcrun"
STRINGS="$($XCRUN --find strings)" || fail "strings not found through xcrun"
STRIP="$($XCRUN --find strip)" || fail "strip not found through xcrun"
SWIFT_DEMANGLE="$($XCRUN --find swift-demangle)" || fail "swift-demangle not found through xcrun"
SHASUM="$(command -v shasum)" || fail "shasum not found"
for tool in "$NM" "$STRINGS" "$STRIP" "$SWIFT_DEMANGLE" "$SHASUM"; do
    [ -n "$tool" ] && [ -x "$tool" ] || fail "required artifact tool is unavailable"
done

file_sha256() {
    "$SHASUM" -a 256 "$1" | awk '{print $1}'
}

TMP_ROOT="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_ROOT/elysium-storage-release-surface.XXXXXX")" \
    || fail "could not create a temporary directory"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

artifact_sha256() {
    local source="$1" label="$2" normalized
    normalized="$TMP_DIR/$label"
    /bin/cp "$source" "$normalized" || fail "could not copy $label for hashing"
    /bin/chmod u+w "$normalized" || fail "could not make hash copy writable: $label"
    "$STRIP" -S -x "$normalized" || fail "could not normalize debug/local symbols: $label"
    file_sha256 "$normalized"
}

# These reviewed hashes bind the release artifact gate to the exact storage
# implementation and externally reachable API admitted by the source scanner.
# Artifact hashes are taken from disposable copies with DWARF and local symbols
# removed so the reviewed gate is independent of the physical worktree path.
# SwiftPM's package identity remains intentionally significant because it is an
# ABI input for package-access declarations.
#
# scripting-ui-and-replication (change 3): EXPECTED_CORE_OBJECT_SHA256/
# EXPECTED_ELYSIUM_PRODUCT_SHA256/EXPECTED_SMOKE_PRODUCT_SHA256 renewed — ElysiumCore.o's
# hash necessarily moves whenever any source file in that target changes (this change added
# real code to Sources/ElysiumCore/Scripting and Sources/ElysiumCore/Net), and the Elysium/
# elysmoke product hashes follow transitively since both link ElysiumCore.o. The five reviewed
# *source* hashes above/below (StorageEngine.swift, Saves.swift, GameCore.swift, Player.swift,
# ElysiumTextInput.swift) and the ElysiumStorage.o/ElysiumTextInput.o object hashes are
# untouched and still byte-identical — this change never wrote to any of those files or
# targets, only to Sources/ElysiumCore/Scripting, Sources/ElysiumCore/Net, and Sources/Elysium.
#
# pickaxe-uprighting: the pickaxe moved from the retired procedural rasteriser to a baked
# upright PNG in Sources/Elysium (HeldItemAssets.swift), so only EXPECTED_ELYSIUM_PRODUCT_SHA256
# moves — ElysiumCore.o, the smoke product, and every source/storage pin are byte-identical.
#
# off-hand/tool-hand polish: GameCore gained the shield-raise tick + off-hand toggle handlers
# and Player gained toggleOffhandItem + the shield-block logic, moving their reviewed source
# pins; ElysiumCore.o and the Elysium/elysmoke products follow. The storage surface
# (StorageEngine, Saves, manifests, ElysiumStorage.o, text-input) is untouched and byte-identical
# — these edits are gameplay/HUD only, never storage-reachable.
#
# native-script-editor + combat/HUD polish: EXPECTED_GAME_CORE_SOURCE_SHA256 and
# EXPECTED_PLAYER_SOURCE_SHA256 renewed — GameCore.swift gained a scriptEditorWindowOpen
# pause flag and Player.swift a doubled attack-recovery constant. EXPECTED_CORE_OBJECT_SHA256
# follows (Player/Living/GameCore all live in ElysiumCore), and the Elysium/elysmoke product
# hashes follow transitively. The storage surface (StorageEngine.swift, Saves.swift, the two
# manifests, ElysiumStorage.o/ElysiumTextInput.o and TEXT_INPUT source) is untouched and still
# byte-identical: the checked-player getter/CAS declarations, caller counts, and approved-owner
# set below all still hold — these edits are gameplay/UI only, never storage-reachable.
#
# lua-editor-2: EXPECTED_GAME_CORE_SOURCE_SHA256 renewed after GameCore gained only a read-only
# world-session generation accessor plus synchronous pre-teardown notifications used to fence
# native editor drafts. The checked-player getter/CAS declarations, both caller spans, counts, and
# approved-owner set below remain unchanged. EXPECTED_CORE_OBJECT_SHA256 moves for those additions
# and the scripting schema/runtime work in ElysiumCore; the Elysium and elysmoke product hashes
# follow transitively. StorageEngine.swift, Saves.swift, both storage manifests,
# ElysiumStorage.o, ElysiumTextInput.swift, and ElysiumTextInput.o remain byte-identical.
#
# lua-editor-native-toolbar: EXPECTED_ELYSIUM_PRODUCT_SHA256 renewed after the native AppKit
# toolbar, completion-panel lifecycle, and injectable editor proposal boundary changed only the
# Elysium application target. ElysiumCore.o, elysmoke, and every reviewed storage/text-input source
# and object pin remain byte-identical.
#
# lua-editor-handler-check: EXPECTED_CORE_OBJECT_SHA256 renewed after dry-run Check began creating
# registry-shaped synthetic events for known handler triggers; the Elysium and elysmoke products
# follow transitively. This changes only scripting validation in ElysiumCore. GameCore.swift and
# every reviewed storage/text-input source, manifest, and object pin remain byte-identical.
#
# model-rendered-pickaxes: EXPECTED_ELYSIUM_PRODUCT_SHA256 renewed from
# bf67591da69f4974fd6c37c3cfa90cf8ebdab7256194e929bb234fccab922f8a to
# b46cda7a0cc807b04c61a555ed64ad5588bfe4a25b33c9d4acf9fd97953869bf after the
# Elysium application target gained manifest-bound CC0 pickaxe renders and rigid held-item
# animation. ElysiumCore.o, elysmoke, and every reviewed storage/text-input source, manifest,
# and object pin remain byte-identical. Assets/Elysium/HeldPickaxe3D/build.md records the
# normalization command and complete renewal evidence.
#
# extensible-object-events: EXPECTED_GAME_CORE_SOURCE_SHA256 and
# EXPECTED_PLAYER_SOURCE_SHA256 renewed for the reviewed standard-event producer funnels,
# tool-strike/LAN gesture routing, object-record hydration, lifecycle delivery, and canonical
# actor provenance. EXPECTED_CORE_OBJECT_SHA256 follows those changes plus the bounded custom
# event/attribute runtime; the Elysium and elysmoke products follow transitively, with Elysium
# also containing the schema-driven editor and optional Ollama UI. The smoke product additionally
# carries the reviewed Appendix A fixture update that verifies camelCase Lua attribute sugar is
# persisted and queried through its canonical snake_case spelling. StorageEngine.swift,
# Saves.swift, both capability manifests, ElysiumStorage.o, ElysiumTextInput.swift, and
# ElysiumTextInput.o remain byte-identical. docs/extensible-object-events/build.md records every
# old/new pin and the clean-build normalization evidence.
EXPECTED_STORAGE_SOURCE_SHA256='4d4bf5756df15ed9f50ef550fa93e08c2f5c99f0ebdf5fdf96154807f08c98ba'
EXPECTED_STORAGE_API_SHA256='ea1dd595ee28762bc2ff7c2e080c2fc4cee0eee008a30e52e82747029206f46c'
EXPECTED_STORAGE_OBJECT_SHA256='33fb1578d8262a4044ba42ccb1fc7b67e8dfac2589133ab2ff415b5a5d71326b'
EXPECTED_SAVES_SOURCE_SHA256='104564ee02dd009085cc5bf2f1d09fb6e893915283bef1cc09a3e5f7ab884dec'
EXPECTED_GAME_CORE_SOURCE_SHA256='23d2f5a04f2c5e1cd5981a2cf8394159c40e86670b4ffb7e3348cdb12f71e574'
EXPECTED_PLAYER_SOURCE_SHA256='79dbd2e132f8e65f2a9857f763c263fea0a1b8cd86fc7db6388fc77129373e10'
EXPECTED_CORE_CAPABILITY_SHA256='67dbb84929eeda6bea6acec70567a6b8c3711521ae2c1f93fdfc6a2e957b8118'
EXPECTED_TEXT_INPUT_SOURCE_SHA256='dda602f2008afa7914f471217848e1d6a2e701aced3d6a1ed304fdfc3c6f868e'
EXPECTED_TEXT_INPUT_OBJECT_SHA256='ca500f11c671c45b6a0648962bed37881a9adff2a6491632e7d655a50ed80efc'
EXPECTED_CORE_OBJECT_SHA256='b62b17e26f7edb876771a70a45008e51ed725e3176a869ead4eba75e25cf6f4f'
EXPECTED_ELYSIUM_PRODUCT_SHA256='9f84be3823ec9cc8b658ee0cd74d99ab81c5fa6f051fb58da0ad596f5d39eaea'
EXPECTED_SMOKE_PRODUCT_SHA256='0bc8236305b9619cfdd3e1e1dd95362ec3a1b93b37ec20c7469684466b5c22d0'
STORAGE_SOURCE='Sources/ElysiumStorage/StorageEngine.swift'
STORAGE_API_MANIFEST='scripts/elysium-storage-api-v1.json'
SAVES_SOURCE='Sources/ElysiumCore/Game/Saves.swift'
GAME_CORE_SOURCE='Sources/ElysiumCore/Game/GameCore.swift'
PLAYER_SOURCE='Sources/ElysiumCore/Entity/Player.swift'
CORE_CAPABILITY_MANIFEST='scripts/elysium-core-storage-capability-v1.json'
TEXT_INPUT_SOURCE='Sources/ElysiumTextInput/ElysiumTextInput.swift'
[ "$(file_sha256 "$STORAGE_SOURCE")" = "$EXPECTED_STORAGE_SOURCE_SHA256" ] \
    || fail "reviewed storage source hash drift"
[ "$(file_sha256 "$STORAGE_API_MANIFEST")" = "$EXPECTED_STORAGE_API_SHA256" ] \
    || fail "reviewed storage API manifest hash drift"
[ "$(file_sha256 "$SAVES_SOURCE")" = "$EXPECTED_SAVES_SOURCE_SHA256" ] \
    || fail "reviewed SaveDB checked-player source hash drift"
[ "$(file_sha256 "$GAME_CORE_SOURCE")" = "$EXPECTED_GAME_CORE_SOURCE_SHA256" ] \
    || fail "reviewed checked-player caller source hash drift"
[ "$(file_sha256 "$PLAYER_SOURCE")" = "$EXPECTED_PLAYER_SOURCE_SHA256" ] \
    || fail "reviewed player omission-candidate source hash drift"
[ "$(file_sha256 "$CORE_CAPABILITY_MANIFEST")" = "$EXPECTED_CORE_CAPABILITY_SHA256" ] \
    || fail "reviewed Core storage capability manifest hash drift"
[ "$(file_sha256 "$TEXT_INPUT_SOURCE")" = "$EXPECTED_TEXT_INPUT_SOURCE_SHA256" ] \
    || fail "reviewed text-input source hash drift"
[ ! -e 'Sources/ElysiumCore/Game/LANV6ClientCheckpointCodec.swift' ] \
    || fail "deferred Core client checkpoint codec unexpectedly exists"
if grep -F 'LANV6ClientAuthoritySaveAdapterV1' Sources/ElysiumCore/Game/Saves.swift >/dev/null; then
    fail "deferred Core client checkpoint adapter unexpectedly exists"
fi

# Freeze the checked Core surface and its only two production consumers. The omission path owns
# exactly one checked read/CAS pair; ordinary persistence owns the other pair. No omission path may
# fall back to the compatibility best-effort writer.
for declaration in \
    'public struct SaveDBPlayerRowDigest: Equatable, Sendable {' \
    'public struct SaveDBPlayerRowSnapshot {' \
    'public enum SaveDBPlayerRowExpectation: Equatable, Sendable {' \
    'public enum SaveDBPlayerRowError: Error, Equatable, Sendable {' \
    '    public func getPlayerChecked(_ worldId: String) throws -> SaveDBPlayerRowSnapshot? {' \
    '    public func compareAndSwapPlayerChecked('; do
    [ "$(grep -Fxc "$declaration" "$SAVES_SOURCE" || true)" -eq 1 ] \
        || fail "checked Core declaration drift: $declaration"
done
for error_case in invalidCandidate invalidStoredRow conflict persistenceFailed; do
    [ "$(grep -Fxc "    case $error_case" "$SAVES_SOURCE" || true)" -eq 1 ] \
        || fail "checked player error surface drift: $error_case"
done
[ "$(grep -Fc 'getPlayerChecked(' "$SAVES_SOURCE" || true)" -eq 1 ] \
    || fail "SaveDB must declare exactly one checked player getter"
[ "$(grep -Fc 'compareAndSwapPlayerChecked(' "$SAVES_SOURCE" || true)" -eq 1 ] \
    || fail "SaveDB must declare exactly one checked player CAS"
[ "$(grep -Fc 'getPlayerChecked(' "$GAME_CORE_SOURCE" || true)" -eq 2 ] \
    || fail "GameCore checked player getter caller count drift"
[ "$(grep -Fc 'compareAndSwapPlayerChecked(' "$GAME_CORE_SOURCE" || true)" -eq 2 ] \
    || fail "GameCore checked player CAS caller count drift"

while IFS= read -r caller; do
    case "$caller" in
        "$SAVES_SOURCE"|"$GAME_CORE_SOURCE") ;;
        *) fail "checked player CAS escaped approved production owners: $caller" ;;
    esac
done < <(grep -R -l --include='*.swift' -F 'compareAndSwapPlayerChecked(' Sources || true)
while IFS= read -r caller; do
    case "$caller" in
        "$SAVES_SOURCE"|"$GAME_CORE_SOURCE") ;;
        *) fail "checked player getter escaped approved production owners: $caller" ;;
    esac
done < <(grep -R -l --include='*.swift' -F 'getPlayerChecked(' Sources || true)

OMISSION_START="$(grep -Fn '    private func beginCheckedLegacyPlayerOmission(' \
    "$GAME_CORE_SOURCE" | cut -d: -f1)"
OMISSION_END="$(grep -Fn '    private func completeCheckedLegacyPlayerOmission(' \
    "$GAME_CORE_SOURCE" | cut -d: -f1)"
ORDINARY_START="$(grep -Fn '    private func persistCheckedPlayerCandidate(' \
    "$GAME_CORE_SOURCE" | cut -d: -f1)"
ORDINARY_END="$(grep -Fn '    private func completeRPGPreferenceWrite(' \
    "$GAME_CORE_SOURCE" | cut -d: -f1)"
case "$OMISSION_START:$OMISSION_END:$ORDINARY_START:$ORDINARY_END" in
    *$'\n'*|*[!0-9:]*) fail "checked player caller boundaries are ambiguous" ;;
esac
[ -n "$OMISSION_START" ] && [ "$OMISSION_START" -lt "$OMISSION_END" ] \
    || fail "omission caller boundary drift"
[ -n "$ORDINARY_START" ] && [ "$ORDINARY_START" -lt "$ORDINARY_END" ] \
    || fail "ordinary persistence caller boundary drift"
span_count() {
    sed -n "$2,$(($3 - 1))p" "$1" | awk -v needle="$4" \
        'index($0, needle) { count += 1 } END { print count + 0 }'
}
[ "$(span_count "$GAME_CORE_SOURCE" "$OMISSION_START" "$OMISSION_END" \
    'getPlayerChecked(')" -eq 1 ] \
    || fail "omission consumer must contain exactly one checked getter"
[ "$(span_count "$GAME_CORE_SOURCE" "$OMISSION_START" "$OMISSION_END" \
    'compareAndSwapPlayerChecked(')" -eq 1 ] \
    || fail "omission consumer must contain exactly one checked CAS"
[ "$(span_count "$GAME_CORE_SOURCE" "$ORDINARY_START" "$ORDINARY_END" \
    'getPlayerChecked(')" -eq 1 ] \
    || fail "ordinary persistence must contain exactly one checked getter"
[ "$(span_count "$GAME_CORE_SOURCE" "$ORDINARY_START" "$ORDINARY_END" \
    'compareAndSwapPlayerChecked(')" -eq 1 ] \
    || fail "ordinary persistence must contain exactly one checked CAS"
[ "$(span_count "$GAME_CORE_SOURCE" "$OMISSION_START" "$OMISSION_END" \
    'putPlayer(')" -eq 0 ] \
    || fail "omission path calls compatibility putPlayer"
[ "$(grep -Fc 'putPlayerChecked' "$SAVES_SOURCE" || true)" -eq 0 ] \
    || fail "unconditional checked player writer unexpectedly exists"

RELEASE_OUTPUT="$(swift build -c release --show-bin-path)" \
    || fail "could not resolve the release bin path"
[ -n "$RELEASE_OUTPUT" ] || fail "release bin path was empty"
case "$RELEASE_OUTPUT" in
    *$'\n'*) fail "release bin path produced multiple lines" ;;
    /*) ;;
    *) fail "release bin path was not absolute" ;;
esac
RELEASE_DIR="$RELEASE_OUTPUT"
[ -d "$RELEASE_DIR" ] || fail "release directory is missing"

STORAGE_OBJECT="$RELEASE_DIR/ElysiumStorage.o"
CORE_OBJECT="$RELEASE_DIR/ElysiumCore.o"
TEXT_INPUT_OBJECT="$RELEASE_DIR/ElysiumTextInput.o"
ELYSIUM_PRODUCT="$RELEASE_DIR/Elysium"
SMOKE_PRODUCT="$RELEASE_DIR/elysmoke"
ARTIFACTS=("$STORAGE_OBJECT" "$ELYSIUM_PRODUCT" "$SMOKE_PRODUCT")
for artifact in "$CORE_OBJECT" "$TEXT_INPUT_OBJECT" "${ARTIFACTS[@]}"; do
    [ ! -L "$artifact" ] || fail "artifact is a symlink: $artifact"
    [ -f "$artifact" ] || fail "artifact is missing or not regular: $artifact"
    [ -r "$artifact" ] || fail "artifact is unreadable: $artifact"
    [ -s "$artifact" ] || fail "artifact is empty: $artifact"
done
[ "$(artifact_sha256 "$STORAGE_OBJECT" ElysiumStorage.o)" = "$EXPECTED_STORAGE_OBJECT_SHA256" ] \
    || fail "reviewed ElysiumStorage.o hash drift"
[ "$(artifact_sha256 "$CORE_OBJECT" ElysiumCore.o)" = "$EXPECTED_CORE_OBJECT_SHA256" ] \
    || fail "reviewed ElysiumCore.o hash drift"
[ "$(artifact_sha256 "$TEXT_INPUT_OBJECT" ElysiumTextInput.o)" = "$EXPECTED_TEXT_INPUT_OBJECT_SHA256" ] \
    || fail "reviewed ElysiumTextInput.o hash drift"
[ "$(artifact_sha256 "$ELYSIUM_PRODUCT" Elysium)" = "$EXPECTED_ELYSIUM_PRODUCT_SHA256" ] \
    || fail "reviewed Elysium product hash drift"
[ "$(artifact_sha256 "$SMOKE_PRODUCT" elysmoke)" = "$EXPECTED_SMOKE_PRODUCT_SHA256" ] \
    || fail "reviewed elysmoke product hash drift"

[ ! "$STORAGE_OBJECT" -ot Package.swift ] \
    || fail "ElysiumStorage.o is older than Package.swift"
SOURCE_LIST="$TMP_DIR/storage-sources"
find Sources/ElysiumStorage -type f -print0 > "$SOURCE_LIST" \
    || fail "could not enumerate ElysiumStorage sources"
[ -s "$SOURCE_LIST" ] || fail "ElysiumStorage has no regular source files"
while IFS= read -r -d '' source; do
    [ ! "$STORAGE_OBJECT" -ot "$source" ] \
        || fail "ElysiumStorage.o is older than $source"
done < "$SOURCE_LIST"
CORE_SOURCE_LIST="$TMP_DIR/core-sources"
find Sources/ElysiumCore -type f -print0 > "$CORE_SOURCE_LIST" \
    || fail "could not enumerate ElysiumCore sources"
[ -s "$CORE_SOURCE_LIST" ] || fail "ElysiumCore has no regular source files"
while IFS= read -r -d '' source; do
    [ ! "$CORE_OBJECT" -ot "$source" ] \
        || fail "ElysiumCore.o is older than $source"
done < "$CORE_SOURCE_LIST"
TEXT_INPUT_SOURCE_LIST="$TMP_DIR/text-input-sources"
find Sources/ElysiumTextInput -type f -print0 > "$TEXT_INPUT_SOURCE_LIST" \
    || fail "could not enumerate ElysiumTextInput sources"
[ -s "$TEXT_INPUT_SOURCE_LIST" ] || fail "ElysiumTextInput has no regular source files"
while IFS= read -r -d '' source; do
    [ ! "$TEXT_INPUT_OBJECT" -ot "$source" ] \
        || fail "ElysiumTextInput.o is older than $source"
done < "$TEXT_INPUT_SOURCE_LIST"
for product in "$ELYSIUM_PRODUCT" "$SMOKE_PRODUCT"; do
    [ ! "$product" -ot "$STORAGE_OBJECT" ] \
        || fail "linked product is older than ElysiumStorage.o: $product"
    [ ! "$product" -ot "$CORE_OBJECT" ] \
        || fail "linked product is older than ElysiumCore.o: $product"
    [ ! "$product" -ot "$TEXT_INPUT_OBJECT" ] \
        || fail "linked product is older than ElysiumTextInput.o: $product"
done

TEXT_INPUT_SURFACES=("$TEXT_INPUT_OBJECT" "$ELYSIUM_PRODUCT" "$SMOKE_PRODUCT")
for artifact in "${TEXT_INPUT_SURFACES[@]}"; do
    label="$(basename "$artifact")"
    if "$NM" -a "$artifact" | "$SWIFT_DEMANGLE" | \
        grep -E 'ElysiumTextInputTests|probeLaunchMarker|TextInputTestHook|InjectedPasteboard' >/dev/null; then
        fail "text-input test/probe symbol present in $label"
    fi
    if "$STRINGS" -a "$artifact" | \
        grep -E 'ElysiumTextInputTests|probeLaunchMarker|TextInputTestHook|InjectedPasteboard' >/dev/null; then
        fail "text-input test/probe string present in $label"
    fi
done

DENYLIST="$TMP_DIR/denylist"
cat > "$DENYLIST" <<'DENYLIST'
ElysiumStorageTest
ElysiumStorageDescriptorIdentityProbe
ElysiumStorageFactoryFailurePoint
ElysiumStorageSQLiteLengthLimitProbe
ElysiumStorageLegacyCollectionFailurePoint
ElysiumStorageLegacyImportFailurePoint
ElysiumStorageBarrierFailurePoint
ElysiumStorageSchemaAuditProbe
ElysiumStorageTestDeadlineBoundary
ElysiumStorageTestBodyError
ElysiumStorageRPGLocalTestOperation
SaveDBPlayerCASBarrier
SaveDBPlayerCASBarrierStage
ElysiumStorageRPGLocalFailureStage
testRPGLocalPreferencesWrite
testCoreWorldDeleteWithRPG
testSetRPGLocalFailure
injectActiveRPGLocalFailure
withActiveRPGLocalTestOperation
LANV6ClientCheckpointCodec
LANV6ClientAuthoritySaveAdapterV1
LANV6ClientCheckpointValidatedStateV1
InjectedLocalSettingsFailure
LocalSettingsSystemWriteCut
LocalSettingsFileIO
LocalSettingsStore.init(directoryURL:
faultInjector
encodeFaultInjector
systemWriteCut
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
legacyDeviceBitPatternForTesting
DENYLIST

CORE_RAW_NM="$TMP_DIR/ElysiumCore.nm"
CORE_DEMANGLED_NM="$TMP_DIR/ElysiumCore.demangled"
CORE_STRINGS="$TMP_DIR/ElysiumCore.strings"
CORE_UNDEFINED_NM="$TMP_DIR/ElysiumCore.undefined"
"$XCRUN" nm -a "$CORE_OBJECT" > "$CORE_RAW_NM" \
    || fail "nm failed for ElysiumCore.o"
"$SWIFT_DEMANGLE" < "$CORE_RAW_NM" > "$CORE_DEMANGLED_NM" \
    || fail "swift-demangle failed for ElysiumCore.o"
"$XCRUN" strings -a "$CORE_OBJECT" > "$CORE_STRINGS" \
    || fail "strings failed for ElysiumCore.o"
"$XCRUN" nm -u "$CORE_OBJECT" > "$CORE_UNDEFINED_NM" \
    || fail "undefined-symbol scan failed for ElysiumCore.o"
if grep -E '(^|[[:space:]_])sqlite3_' "$CORE_UNDEFINED_NM" >/dev/null; then
    fail "ElysiumCore.o gained a direct SQLite call"
fi
for required_core_surface in \
    'ElysiumCore.SaveDBPlayerRowDigest' \
    'ElysiumCore.SaveDBPlayerRowSnapshot' \
    'ElysiumCore.SaveDBPlayerRowExpectation' \
    'ElysiumCore.SaveDBPlayerRowError' \
    'ElysiumCore.SaveDB.getPlayerChecked' \
    'ElysiumCore.SaveDB.compareAndSwapPlayerChecked'; do
    grep -Fq "$required_core_surface" "$CORE_DEMANGLED_NM" \
        || fail "checked Core surface missing from ElysiumCore.o: $required_core_surface"
done
while IFS= read -r denied; do
    for surface in "$CORE_RAW_NM" "$CORE_DEMANGLED_NM" "$CORE_STRINGS"; do
        if grep -Fq -- "$denied" "$surface"; then
            fail "closed DEBUG surface '$denied' present in ElysiumCore.o"
        fi
    done
done < "$DENYLIST"

SENTINEL='ElysiumStorage.ElysiumStorageCoordinator.open(databaseURL:'
REQUIRED_STORAGE_TYPES="$TMP_DIR/required-storage-types"
cat > "$REQUIRED_STORAGE_TYPES" <<'REQUIRED_STORAGE_TYPES'
ElysiumRPGLocalPreferenceStorageRow
ElysiumRPGLegacyQuickSlotMigrationStorageRow
ElysiumRPGLocalPreferenceMigrationReceipt
ElysiumRPGLocalPreferencesStorage
ElysiumLANClientAuthorityStorageKey
ElysiumLANClientCredentialStorageRow
ElysiumLANClientOwnerCheckpointStorageRow
ElysiumLANClientPendingDispositionStorageRow
ElysiumLANClientNotificationStorageRow
ElysiumLANClientAuthorityCheckpointCandidate
ElysiumLANClientAuthorityCheckpointReceipt
ElysiumClientAuthorityCheckpointV6Storage
ElysiumPlayerJSONRowDigest
ElysiumPlayerJSONExpectedRowState
ElysiumPlayerJSONCompareAndSwapResult
REQUIRED_STORAGE_TYPES
for artifact in "${ARTIFACTS[@]}"; do
    label="$(basename "$artifact")"
    raw_nm="$TMP_DIR/$label.nm"
    demangled_nm="$TMP_DIR/$label.demangled"
    raw_strings="$TMP_DIR/$label.strings"
    undefined_nm="$TMP_DIR/$label.undefined"
    "$XCRUN" nm -a "$artifact" > "$raw_nm" \
        || fail "nm failed for $artifact"
    "$SWIFT_DEMANGLE" < "$raw_nm" > "$demangled_nm" \
        || fail "swift-demangle failed for $artifact"
    "$XCRUN" strings -a "$artifact" > "$raw_strings" \
        || fail "strings failed for $artifact"
    "$XCRUN" nm -u "$artifact" > "$undefined_nm" \
        || fail "undefined-symbol scan failed for $artifact"

    grep -Fq "$SENTINEL" "$demangled_nm" \
        || fail "production storage sentinel missing from $artifact"
    grep -Fq 'ElysiumStorage.ElysiumLegacyCoreStorage.compareAndSwapPlayerJSON' "$demangled_nm" \
        || fail "checked player CAS method missing from $artifact"
    while IFS= read -r required; do
        grep -Fq "ElysiumStorage.$required" "$demangled_nm" \
            || fail "reviewed storage type '$required' missing from $artifact"
    done < "$REQUIRED_STORAGE_TYPES"
    while IFS= read -r denied; do
        for surface in "$raw_nm" "$demangled_nm" "$raw_strings"; do
            if grep -Fq -- "$denied" "$surface"; then
                fail "closed DEBUG surface '$denied' present in $artifact"
            fi
        done
    done < "$DENYLIST"
    if grep -E 'sqlite3_(blob|backup)_' "$undefined_nm" >/dev/null; then
        fail "forbidden SQLite streaming surface present in $artifact"
    fi
    close_v2_count="$(awk '$NF == "_sqlite3_close_v2"{n++} END{print n+0}' \
        "$undefined_nm")"
    [ "$close_v2_count" -eq 1 ] \
        || fail "expected exactly one undefined _sqlite3_close_v2 in $artifact"
    if awk '$NF != "_sqlite3_close_v2" && index($NF,"sqlite3_close_v2"){bad=1} END{exit bad ? 0 : 1}' \
        "$undefined_nm"; then
        fail "adjacent sqlite3_close_v2 symbol present in $artifact"
    fi
done

if grep -E 'sqlite3_(blob|backup)_' "$STORAGE_SOURCE" >/dev/null; then
    fail "forbidden SQLite streaming call present in storage source"
fi
source_close_v2_count="$(awk 'index($0,"sqlite3_close_v2"){n++} END{print n+0}' "$STORAGE_SOURCE")"
[ "$source_close_v2_count" -eq 1 ] \
    || fail "storage source must contain exactly one close_v2 spelling"
exact_cleanup_count="$(grep -Fxc '                let closeRC = sqlite3_close_v2(localHandle)' \
    "$STORAGE_SOURCE" || true)"
[ "$exact_cleanup_count" -eq 1 ] \
    || fail "the sole close_v2 call is not the approved pre-publication cleanup"

printf 'Elysium storage release surface verified.\n'
