#!/bin/bash
set -euo pipefail

if rg -n 'event\.eventNumber|NSEvent[^\n]*\.eventNumber' Sources/Elysium/AppInputRouterM.swift >/dev/null; then
    echo "security scan failed: keyboard router reads NSEvent.eventNumber" >&2
    exit 1
fi
for required in scripts/package-app.sh scripts/appkit-text-entry-integration.sh \
                Tests/ElysiumAppKitIntegration/Driver.swift \
                scripts/installed-signoff-receipt.swift scripts/installed-signoff-receipt.sh \
                scripts/run-release-gate-tool.sh \
                scripts/prepush-release-build.sh scripts/build-automated-gate-evidence.swift \
                scripts/installed-signoff-content-v1.txt \
                scripts/installed-signoff-checklist-v1.json \
                scripts/observe-installed-signoff.sh scripts/observe-installed-signoff.swift \
                scripts/designer-attest-installed-signoff.sh \
                scripts/designer-attest-installed-signoff.swift \
                scripts/finalize-installed-signoff.sh \
                scripts/resume-installed-signoff-commit.sh \
                .githooks/pre-commit .githooks/post-commit .githooks/pre-push; do
    [ -f "$required" ] || { echo "security scan failed: missing $required" >&2; exit 1; }
done
if grep -F 'case "prepare"' scripts/installed-signoff-receipt.swift >/dev/null; then
    echo "security scan failed: caller-evidence prepare command returned" >&2
    exit 1
fi
if grep -E 'automated-gates\.json|PACKAGE_MANIFEST|run_and_record_gate' scripts/pipeline.sh >/dev/null; then
    echo "security scan failed: pipeline regained caller-authored gate evidence" >&2
    exit 1
fi
DISPATCHER_TRANSITIONS="$(grep -Fc 'gate.transition(' Sources/ElysiumReleaseGate/ReleaseGate.swift)"
[ "$DISPATCHER_TRANSITIONS" -eq 7 ] || {
    echo "security scan failed: dispatcher must own exactly seven transition call sites" >&2
    exit 1
}
for adapter in scripts/installed-signoff-receipt.swift \
               scripts/observe-installed-signoff.swift \
               scripts/designer-attest-installed-signoff.swift \
               Tests/ElysiumReleaseGateTests/Fixtures/ReleaseGateWorkflowProbe/main.swift; do
    if grep -E '\.(create|restart|transition|invalidate)\(' "$adapter" >/dev/null; then
        echo "security scan failed: receipt mutation escaped dispatcher in $adapter" >&2
        exit 1
    fi
done
if grep -E 'fixture-bootstrap|fixturePayload|ReleaseGatePayload\(' \
    Tests/ElysiumReleaseGateTests/Fixtures/ReleaseGateWorkflowProbe/main.swift >/dev/null; then
    echo "security scan failed: workflow probe regained payload/bootstrap authority" >&2
    exit 1
fi
PRODUCTION_RELEASE_SURFACES=(
    Sources/ElysiumReleaseGate/ReleaseGate.swift
    scripts/installed-signoff-receipt.swift scripts/run-release-gate-tool.sh
    scripts/installed-signoff-receipt.sh scripts/observe-installed-signoff.sh
    scripts/designer-attest-installed-signoff.sh scripts/finalize-installed-signoff.sh
    scripts/resume-installed-signoff-commit.sh .githooks/pre-commit
    .githooks/post-commit .githooks/pre-push
)
if grep -E '(ELYSIUM_RELEASE_GATE|--(fixture|scenario|fault|alternate-executable|caller-evidence)|case "(fixture|scenario|fault))' \
    "${PRODUCTION_RELEASE_SURFACES[@]}" >/dev/null; then
    echo "security scan failed: production release surface exposes a fixture/fault selector" >&2
    exit 1
fi
EXECUTABLE_RELEASE_SURFACES=(
    scripts/installed-signoff-receipt.sh scripts/run-release-gate-tool.sh
    scripts/observe-installed-signoff.sh scripts/designer-attest-installed-signoff.sh
    scripts/finalize-installed-signoff.sh scripts/resume-installed-signoff-commit.sh
    .githooks/pre-commit .githooks/post-commit .githooks/pre-push
)
CURRENT_UID="$(id -u)"
for surface in "${EXECUTABLE_RELEASE_SURFACES[@]}"; do
    [ -f "$surface" ] && [ ! -L "$surface" ] && [ -x "$surface" ] \
        || { echo "security scan failed: unsafe release entry point $surface" >&2; exit 1; }
    [ "$(stat -f '%u' "$surface")" = "$CURRENT_UID" ] \
        || { echo "security scan failed: wrong owner for $surface" >&2; exit 1; }
    [ "$(stat -f '%Lp' "$surface")" = 755 ] \
        || { echo "security scan failed: wrong mode for $surface" >&2; exit 1; }
done
[ "$(git config --get core.hooksPath || true)" = ".githooks" ] || {
    echo "security scan failed: core.hooksPath is not .githooks" >&2; exit 1;
}
if grep -E 'NSPasteboard|pasteboard|postKey\(9|maskCommand' \
    Tests/ElysiumAppKitIntegration/Driver.swift >/dev/null; then
    echo "security scan failed: unattended AppKit driver accesses Paste/general pasteboard" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "security scan failed: $*" >&2; exit 1; }

echo "==> security: source scans"

if grep -RInE 'XCTest|@testable|TextInputTestHook|InjectedPasteboard|probeLaunchMarker' \
    Sources/ElysiumTextInput Sources/Elysium Sources/ElysiumCore; then
    fail "test-only text-input symbol escaped into production sources"
fi
if grep -RInE 'LANSignEdit(Intent|Result)|signEditRequestResult|Saving sign…' Sources; then
    fail "Sign-specific LAN write surface is forbidden in the text-entry repair"
fi
for required in \
    'ElysiumTextIngressStateMachine' \
    'ElysiumTextFocusTransactionAdapter' \
    'ElysiumTextEventIngressAdapter' \
    'ElysiumTextPasteIngressAdapter' \
    'ElysiumTextAccessibilityIdentity' \
    'TextFocusAuthorization' \
    'private init(token: ElysiumTextOwnerToken)' \
    'establishOrdinaryTextReadiness' \
    'establishAccessibilityTextReadiness' \
    'textActivationDescriptorID' \
    'textIngressMustBeConsumed' \
    'textIngressIsReady' \
    'accessibilityIsAttributeSettable' \
    'elysiumClampTextRect' \
    'captureSignCommitToken' \
    'commitSignEdit'; do
    grep -RFn "$required" Sources >/dev/null \
        || fail "required text-entry security boundary missing: $required"
done
if grep -RFn 'focusTextDescriptor(id:' Sources >/dev/null; then
    fail "raw descriptor-id text focus mutation returned"
fi
if grep -RFn 'field.focused = true' Sources/Elysium/MenusM.swift Sources/Elysium/ScreensM.swift >/dev/null; then
    fail "screen code directly establishes text focus outside UIManager authorization"
fi
if [ "$(grep -Fc 'TextFocusAuthorization.mint(token)' Sources/Elysium/UIManagerM.swift)" -ne 1 ]; then
    fail "text focus capability mint must have exactly one UIManager call site"
fi
if grep -F 'characters.utf8.count' Sources/Elysium/AppInputRouterM.swift >/dev/null; then
    fail "untrusted NSEvent text returned to a full byte-count scan"
fi
if [ "$(grep -Fc 'ElysiumTextEventIngressAdapter.route(' Sources/Elysium/AppInputRouterM.swift)" -ne 2 ]; then
    fail "mapped and unmapped text must share the bounded executable ingress adapter"
fi
if [ "$(grep -Fc 'ElysiumTextPasteIngressAdapter.route(' Sources/Elysium/main.swift)" -ne 1 ]; then
    fail "Paste must use the owner-captured executable adapter"
fi
if [ "$(grep -Fh 'insertWholeProposalAtomically(' Sources/Elysium/UIManagerM.swift Sources/Elysium/ScreensM.swift | wc -l | tr -d ' ')" -lt 2 ]; then
    fail "TextField and Chat typing must use whole-proposal atomic insertion"
fi
if [ "$(awk 'previous ~ /^[[:space:]]*@MainActor$/ && /package func captureSignCommitToken/ { count++ } { previous=$0 } END { print count+0 }' Sources/ElysiumCore/Game/GameCore.swift)" -ne 1 ] || \
   [ "$(awk 'previous ~ /^[[:space:]]*@MainActor$/ && /package func commitSignEdit/ { count++ } { previous=$0 } END { print count+0 }' Sources/ElysiumCore/Game/GameCore.swift)" -ne 1 ]; then
    fail "Sign capture and commit must remain MainActor isolated"
fi
if [ "$(grep -Fc 'guard !token.consumed' Sources/ElysiumCore/Game/GameCore.swift)" -ne 1 ] || \
   [ "$(grep -Fc 'token.consumed = true' Sources/ElysiumCore/Game/GameCore.swift)" -ne 1 ]; then
    fail "Sign commit token one-shot enforcement drift"
fi
if grep -RFn 'validPrefix(' Sources >/dev/null; then
    fail "unbounded materialized text-prefix ingress returned"
fi
if grep -RInE 'screen\.insertText\(ui, game, ElysiumBoundedTextBuffer|screen\.onChar\(' \
    Sources/Elysium Sources/ElysiumCore; then
    fail "direct unguarded legacy text insertion path returned"
fi

echo "==> security: executable text adapter behavior"
swift test --filter 'ElysiumTextInputTests|ElysiumAppSupportTests|SignCommitTokenTests' >/dev/null \
    || fail "executable text adapter or Sign transaction behavior failed"
echo "==> security: bounded local release safety"
if grep -E '(ProcessInfo\.processInfo\.environment|getenv\()[^\n]*(FIXTURE|SCENARIO|FAULT|EXECUTABLE)' \
    scripts/installed-signoff-receipt.swift Sources/ElysiumReleaseGate/ReleaseGate.swift >/dev/null; then
    fail "environment-selected release implementation found"
fi
swift build --target ElysiumReleaseGate >/dev/null \
    || fail "ElysiumReleaseGate target compile failed"
PREFLIGHT_LOG="$(mktemp /tmp/elysium-release-preflight.XXXXXX)"
RELEASE_FOCUSED_LOG="$(mktemp /tmp/elysium-release-focused.XXXXXX)"
KEYCHAIN_FOCUSED_LOG="$(mktemp /tmp/elysium-keychain-focused.XXXXXX)"
chmod 600 "$PREFLIGHT_LOG" "$RELEASE_FOCUSED_LOG" "$KEYCHAIN_FOCUSED_LOG"
cleanup_release_logs() {
    rm -f "$PREFLIGHT_LOG" "$RELEASE_FOCUSED_LOG" "$KEYCHAIN_FOCUSED_LOG"
}
trap cleanup_release_logs EXIT INT TERM
scripts/installed-signoff-receipt.sh preflight >"$PREFLIGHT_LOG" 2>&1 \
    || fail "installed sign-off preflight failed"
[ "$(wc -c < "$PREFLIGHT_LOG" | tr -d ' ')" -le 65536 ] \
    || fail "installed sign-off preflight output exceeded cap"
grep -Fx 'Preflight complete. Tracked and untracked content was enumerated safely.' \
    "$PREFLIGHT_LOG" >/dev/null || fail "installed sign-off preflight output malformed"
if grep -E '([0-9a-f]{64}|/Users/|/tmp/|Keychain|CDHash|sequence=|receipt)' "$PREFLIGHT_LOG" >/dev/null; then
    fail "installed sign-off preflight exposed private state"
fi
run_focused_release_suite() {
    local filter="$1" expected_suite="$2" log="$3"
    swift test --filter "$filter" >"$log" 2>&1 \
        || fail "$expected_suite focused tests failed"
    [ "$(wc -c < "$log" | tr -d ' ')" -le 16777216 ] \
        || fail "$expected_suite focused output exceeded cap"
    grep -Eq 'Executed [1-9][0-9]* tests?, with 0 failures' "$log" \
        || fail "$expected_suite focused tests did not execute"
    ! grep -Eiq 'skipped|Executed 0 tests|with [1-9][0-9]* failures' "$log" \
        || fail "$expected_suite focused tests skipped or failed"
}
run_focused_release_suite 'ElysiumReleaseGateTests\.ReleaseGateTests/' \
    'ReleaseGateTests' "$RELEASE_FOCUSED_LOG"
run_focused_release_suite \
    'ElysiumReleaseGateTests\.KeychainReceiptStateStoreIntegrationTests/' \
    'KeychainReceiptStateStoreIntegrationTests' "$KEYCHAIN_FOCUSED_LOG"
cleanup_release_logs
trap - EXIT
echo 'Bounded local safety checks: passed'

DRIVER_CHECK="$(mktemp /tmp/elysium-appkit-driver-check.XXXXXX)"
trap 'rm -f "$DRIVER_CHECK"' EXIT
xcrun swiftc -O -framework AppKit -framework ApplicationServices -framework CryptoKit \
    -framework SystemConfiguration Tests/ElysiumAppKitIntegration/Driver.swift \
    -o "$DRIVER_CHECK" || fail "AppKit driver compile failed"
rm -f "$DRIVER_CHECK"
trap - EXIT

swift scripts/sqlite-boundary-scan.swift --root "$ROOT" --self-test

NETWORK_REFS="$(grep -RInE 'URLSession|NSURLConnection|NWConnection|NWListener|NWBrowser|import Network|Network\.|CFSocket|GCDAsyncSocket' Sources || true)"
UNAPPROVED_NETWORK_REFS="$(printf '%s\n' "$NETWORK_REFS" \
    | grep -v '^Sources/Elysium/OllamaAgent.swift:' \
    | grep -v '^Sources/Elysium/LANTransport.swift:' || true)"
if [ -n "$UNAPPROVED_NETWORK_REFS" ]; then
    printf '%s\n' "$UNAPPROVED_NETWORK_REFS"
    fail "network API reference found outside approved local Ollama client or LAN transport"
fi

URL_REFS="$(grep -RInE 'https?://' Sources || true)"
UNAPPROVED_URL_REFS="$(printf '%s\n' "$URL_REFS" | grep -v '^Sources/Elysium/OllamaAgent.swift:.*http://localhost:11434' || true)"
if [ -n "$UNAPPROVED_URL_REFS" ]; then
    printf '%s\n' "$UNAPPROVED_URL_REFS"
    fail "URL literal found outside approved local Ollama endpoint"
fi

if grep -RInE 'Process\(|NSTask|system\(|popen\(|dlopen\(|dlsym\(' Sources \
    --exclude-dir=ElysiumReleaseGate; then
    fail "dynamic process/loading API reference found in Swift source"
fi

if grep -RInE 'AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|xox[baprs]-[0-9A-Za-z-]+' . \
    --exclude-dir=.git --exclude-dir=.build --exclude='*.png' --exclude='*.icns' --exclude='*.zip'; then
    fail "secret-looking material found"
fi

echo "==> security: passed"
