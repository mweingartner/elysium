#!/bin/bash
set -euo pipefail

PREFIX='NON-AUTHORITATIVE DIAGNOSTIC'
NO_AUTHORITY_STATEMENT='This result does not authorize release, installed sign-off, deployment, commit, or push.'
final_statement_emitted=0
work=''

relay_stdout() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    LC_ALL=C printf '%s: %.220s\n' "$PREFIX" "$line" >&3
  done
}
relay_stderr() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    LC_ALL=C printf '%s: %.220s\n' "$PREFIX" "$line" >&4
  done
}

exec 3>&1 4>&2
exec > >(relay_stdout) 2> >(relay_stderr)

diag() { printf '%s\n' "$*"; }
diag_err() { printf '%s\n' "$*" >&2; }
cleanup_optional_work() {
  if [ -n "$work" ]; then
    rm -rf -- "$work"
  fi
}
on_exit() {
  local status=$?
  trap - EXIT INT TERM
  if ! cleanup_optional_work; then
    status=1
    diag_err 'optional diagnostics found issues: cleanup'
  fi
  if [ "$status" -ne 0 ] && [ "$final_statement_emitted" -eq 0 ]; then
    diag_err "$NO_AUTHORITY_STATEMENT"
  fi
  exit "$status"
}
trap on_exit EXIT
on_signal() {
  diag_err "optional diagnostics interrupted: $1"
  exit "$2"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
MANIFEST="Tests/ElysiumReleaseGateTests/Fixtures/release-gate-adversarial-rows-v16.txt"
EXPECTED_HASH='bf782a2be35778c467f4c58fba65fc473e458892c6478a00b84716eae64c6bbd'
EXPECTED_TOTALS=(8 7 7 9 50 7 11 23 20 6)
tests=(
  'ReleaseGateTests.testAdversarialCategory01FixedPrepareWorkflowCleanStartAndRealBuild'
  'ReleaseGateTests.testAdversarialCategory02CommandFailuresForgeryAndTimeout'
  'ReleaseGateTests.testAdversarialCategory03PublicCommandSurfaceRejectsCallerForgery'
  'ReleaseGateTests.testAdversarialCategory04ObserverDesignerChallengeAndEvidenceSubstitution'
  'ReleaseGateTests.testAdversarialCategory05PathAndArtifactReplacementBoundaries'
  'ReleaseGateTests.testAdversarialCategory06LiveProcessIdentityMismatchAndExit'
  'ReleaseGateTests.testAdversarialCategory07TemporaryGitHooksInterruptionRecoveryAndReplay'
  'ReleaseGateTests.testAdversarialCategory08ConcurrencyAndEverySecureStoreBoundary'
  'ReleaseGateTests.testAdversarialCategory09DurableEvidencePersistenceAndRecoveryPoints'
  'KeychainReceiptStateStoreIntegrationTests.testAdversarialCategory10ProductionKeychainCrossProcessAccessibilityAndCleanup'
)

prefix_log() {
  while IFS= read -r line || [ -n "$line" ]; do
    bounded="$(printf '%s' "$line" | LC_ALL=C cut -b 1-220)"
    diag_err "$bounded"
  done < "$1"
}
fail() {
  diag_err "optional diagnostics found issues: $*"
  final_statement_emitted=1
  diag_err "$NO_AUTHORITY_STATEMENT"
  exit 1
}
diag 'optional 148-row diagnostics started; this command is not a release gate.'
[ -f "$MANIFEST" ] || fail 'manifest absent'
[ "$(stat -f '%Lp' "$MANIFEST")" = 644 ] || fail 'manifest mode'
[ "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')" = "$EXPECTED_HASH" ] || fail 'manifest hash'
[ "$(wc -l < "$MANIFEST" | tr -d ' ')" = 148 ] || fail 'manifest row count'
[ "$(LC_ALL=C sort -u "$MANIFEST" | wc -l | tr -d ' ')" = 148 ] || fail 'manifest duplicate'
cmp -s "$MANIFEST" <(LC_ALL=C sort "$MANIFEST") || fail 'manifest order'
for category in $(seq 1 10); do
  prefix="$(printf 'c%02d.' "$category")"
  actual="$(grep -c "^${prefix}" "$MANIFEST")"
  [ "$actual" = "${EXPECTED_TOTALS[$((category - 1))]}" ] || fail "category $category manifest total"
done

work="$(mktemp -d /tmp/elysium-release-gate-adversarial.XXXXXX)"
chmod 700 "$work"
: > "$work/observed.txt"; chmod 600 "$work/observed.txt"

for index in "${!tests[@]}"; do
  category=$((index + 1)); test_name="${tests[$index]}"; log="$work/category-$category.log"
  if ! swift test --filter "$test_name" >"$log" 2>&1; then
    prefix_log "$log"; fail "category $category XCTest"
  fi
  chmod 600 "$log"
  grep -Eq 'Executed [1-9][0-9]* tests?, with 0 failures' "$log" || fail "category $category did not execute"
  ! grep -Eiq 'skipped|unexpected failure|Executed 0 tests|with [1-9][0-9]* failures' "$log" || fail "category $category skipped or failed"
  grep '^ROW_PASS ' "$log" | sed 's/^ROW_PASS //' > "$work/rows-$category.txt"
  chmod 600 "$work/rows-$category.txt"
  expected="${EXPECTED_TOTALS[$index]}"
  [ "$(wc -l < "$work/rows-$category.txt" | tr -d ' ')" = "$expected" ] || fail "category $category emitted row count"
  [ "$(LC_ALL=C sort -u "$work/rows-$category.txt" | wc -l | tr -d ' ')" = "$expected" ] || fail "category $category duplicate row"
  prefix="$(printf 'c%02d.' "$category")"
  ! grep -Ev "^${prefix}" "$work/rows-$category.txt" | grep -q . || fail "category $category foreign row"
  [ "$(grep -Ec "^CATEGORY_PASS ${category} rows=${expected} cleanup=verified$" "$log")" = 1 ] || fail "category $category terminal grammar"
  cat "$work/rows-$category.txt" >> "$work/observed.txt"
  diag "optional category $category/10 completed rows=$expected"
done

grep -qx 'c10.production-adapter-failures' "$work/observed.txt" || fail 'category 10 production adapter row absent'
grep -qx 'c10.stale-coordinator-race' "$work/observed.txt" || fail 'category 10 stale coordinator row absent'
LC_ALL=C sort "$work/observed.txt" > "$work/observed.sorted"
cmp -s "$MANIFEST" "$work/observed.sorted" || fail 'observed rows differ from manifest'
[ ! -e "$work/residue" ] || fail 'cleanup residue'
diag 'optional diagnostics finished categories=10 rows=148 cleanup=verified.'
final_statement_emitted=1
diag "$NO_AUTHORITY_STATEMENT"
