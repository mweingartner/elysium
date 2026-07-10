#!/bin/bash
set -euo pipefail

fail() {
    printf 'Pebble storage release-surface verification failed: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 0 ] || fail "arguments are not accepted"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCRUN="$(command -v xcrun)" || fail "xcrun not found"
[ -x "$XCRUN" ] || fail "xcrun is not executable"
NM="$($XCRUN --find nm)" || fail "nm not found through xcrun"
STRINGS="$($XCRUN --find strings)" || fail "strings not found through xcrun"
SWIFT_DEMANGLE="$($XCRUN --find swift-demangle)" || fail "swift-demangle not found through xcrun"
for tool in "$NM" "$STRINGS" "$SWIFT_DEMANGLE"; do
    [ -n "$tool" ] && [ -x "$tool" ] || fail "required artifact tool is unavailable"
done

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

STORAGE_OBJECT="$RELEASE_DIR/PebbleStorage.o"
PEBBLE_PRODUCT="$RELEASE_DIR/Pebble"
SMOKE_PRODUCT="$RELEASE_DIR/pebsmoke"
ARTIFACTS=("$STORAGE_OBJECT" "$PEBBLE_PRODUCT" "$SMOKE_PRODUCT")
for artifact in "${ARTIFACTS[@]}"; do
    [ ! -L "$artifact" ] || fail "artifact is a symlink: $artifact"
    [ -f "$artifact" ] || fail "artifact is missing or not regular: $artifact"
    [ -r "$artifact" ] || fail "artifact is unreadable: $artifact"
    [ -s "$artifact" ] || fail "artifact is empty: $artifact"
done

[ ! "$STORAGE_OBJECT" -ot Package.swift ] \
    || fail "PebbleStorage.o is older than Package.swift"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_ROOT/pebble-storage-release-surface.XXXXXX")" \
    || fail "could not create a temporary directory"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

SOURCE_LIST="$TMP_DIR/storage-sources"
find Sources/PebbleStorage -type f -print0 > "$SOURCE_LIST" \
    || fail "could not enumerate PebbleStorage sources"
[ -s "$SOURCE_LIST" ] || fail "PebbleStorage has no regular source files"
while IFS= read -r -d '' source; do
    [ ! "$STORAGE_OBJECT" -ot "$source" ] \
        || fail "PebbleStorage.o is older than $source"
done < "$SOURCE_LIST"
for product in "$PEBBLE_PRODUCT" "$SMOKE_PRODUCT"; do
    [ ! "$product" -ot "$STORAGE_OBJECT" ] \
        || fail "linked product is older than PebbleStorage.o: $product"
done

DENYLIST="$TMP_DIR/denylist"
cat > "$DENYLIST" <<'DENYLIST'
PebbleStorageTest
PebbleStorageFactoryFailurePoint
PebbleStorageSQLiteLengthLimitProbe
PebbleStorageLegacyCollectionFailurePoint
PebbleStorageLegacyImportFailurePoint
PebbleStorageBarrierFailurePoint
PebbleStorageSchemaAuditProbe
PebbleStorageTestDeadlineBoundary
PebbleStorageTestBodyError
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
DENYLIST

SENTINEL='PebbleStorage.PebbleStorageCoordinator.open(databaseURL:'
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

STORAGE_SOURCE="Sources/PebbleStorage/StorageEngine.swift"
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

printf 'Pebble storage release surface verified.\n'
