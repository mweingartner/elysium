#!/bin/bash
set -euo pipefail

if rg -n 'event\.eventNumber|NSEvent[^\n]*\.eventNumber' Sources/Elysium/AppInputRouterM.swift >/dev/null; then
    echo "security scan failed: keyboard router reads NSEvent.eventNumber" >&2
    exit 1
fi
for required in scripts/pipeline.sh scripts/release-source-snapshot.py \
                scripts/package-app.sh scripts/appkit-text-entry-integration.sh \
                Tests/ElysiumAppKitIntegration/Driver.swift \
                scripts/prepush-release-build.sh .githooks/pre-commit .githooks/pre-push; do
    [ -f "$required" ] || { echo "security scan failed: missing $required" >&2; exit 1; }
done
PRODUCTION_RELEASE_SURFACES=(
    scripts/pipeline.sh scripts/release-source-snapshot.py scripts/package-app.sh
    scripts/appkit-text-entry-integration.sh .githooks/pre-commit .githooks/pre-push
)
if grep -E '(--(fixture|scenario|fault|alternate-executable|caller-evidence)|case "(fixture|scenario|fault))' \
    "${PRODUCTION_RELEASE_SURFACES[@]}" >/dev/null; then
    echo "security scan failed: production release surface exposes a fixture/fault selector" >&2
    exit 1
fi
EXECUTABLE_RELEASE_SURFACES=(
    scripts/pipeline.sh scripts/release-source-snapshot.py scripts/package-app.sh
    scripts/appkit-text-entry-integration.sh .githooks/pre-commit .githooks/pre-push
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "security scan failed: $*" >&2; exit 1; }

DRIVER='Tests/ElysiumAppKitIntegration/Driver.swift'
if grep -Eiq 'pasteboard|postKey\(9' "$DRIVER"; then
    fail "unattended AppKit driver accesses Paste/general pasteboard"
fi
if grep -En '(NotificationCenter[^\n]*\.post|notificationCenter\.post|\.post\([[:space:]]*name:[^\n]*(didBecomeActive|didResignActive)|NSApplication(DidBecomeActive|DidResignActive)Notification)' \
    "$DRIVER" >/dev/null; then
    fail "AppKit lifecycle evidence can be posted synthetically"
fi
if grep -En '(recordLocal|recordLocalResign)\([[:space:]]*Notification\(' "$DRIVER" >/dev/null; then
    fail "AppKit lifecycle observer callback can be invoked with constructed evidence"
fi
awk '
  index($0, ".maskCommand") { modifiers++; modifierLine=NR }
  /^[[:space:]]*try[[:space:]]+postKeyOnce\("title\.activate\.modified",[[:space:]]*36,[[:space:]]*flags:[[:space:]]*\.maskCommand,[[:space:]]*$/ { probes++; probeLine=NR }
  /^[[:space:]]*gateStage[[:space:]]*=[[:space:]]*"title-navigation"[[:space:]]*$/ { titles++; titleLine=NR }
  /^[[:space:]]*gateStage[[:space:]]*=[[:space:]]*"field-publication"[[:space:]]*$/ { fields++; fieldLine=NR }
  END {
    valid = modifiers == 1 && probes == 1 && titles == 1 && fields == 1 &&
            titleLine < probeLine && probeLine < fieldLine && modifierLine < fieldLine
    exit(valid ? 0 : 1)
  }
' "$DRIVER" || fail "AppKit Command-key rejection probe contract changed"

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
scripts/release-source-snapshot.py "$ROOT" | \
    grep -Eq '^sha256=[0-9a-f]{64} count=[1-9][0-9]* bytes=[1-9][0-9]*$' \
    || fail "source snapshot contract failed"
for stale in installed-signoff observe-installed designer-attest-installed \
             finalize-installed resume-installed KeychainReceipt ReleaseGatePayload \
             PENDING_INSTALLED_SIGNOFF; do
    if rg -n "$stale" README.md CONTRIBUTING.md ARCHITECTURE.md SECURITY.md AGENTS.md \
        Package.swift Sources Tests scripts .githooks --glob '!security-scan.sh' >/dev/null; then
        fail "retired interactive release authority remains: $stale"
    fi
done
echo 'Bounded local safety checks: passed'

DRIVER_CHECK="$(mktemp /tmp/elysium-appkit-driver-check.XXXXXX)"
COORDINATOR_CHECK="$(mktemp /tmp/elysium-appkit-coordinator-check.XXXXXX)"
PROTOCOL_CHECK="$(mktemp /tmp/elysium-appkit-protocol-check.XXXXXX)"
APPKIT_SOURCE_ROOT="$(mktemp -d /tmp/elysium-appkit-source.XXXXXX)"
mkdir "$APPKIT_SOURCE_ROOT/driver" "$APPKIT_SOURCE_ROOT/coordinator" "$APPKIT_SOURCE_ROOT/protocol"
ln -s "$ROOT/Tests/ElysiumAppKitIntegration/Driver.swift" "$APPKIT_SOURCE_ROOT/driver/main.swift"
ln -s "$ROOT/Tests/ElysiumAppKitIntegration/Coordinator.swift" "$APPKIT_SOURCE_ROOT/coordinator/main.swift"
ln -s "$ROOT/Tests/ElysiumAppKitIntegration/CoordinatorProtocolSecurityHarness.swift" "$APPKIT_SOURCE_ROOT/protocol/main.swift"
trap 'rm -f "$DRIVER_CHECK" "$COORDINATOR_CHECK" "$PROTOCOL_CHECK"; rm -rf "$APPKIT_SOURCE_ROOT"' EXIT
xcrun swiftc -O -warnings-as-errors -framework AppKit -framework ApplicationServices \
    -framework CryptoKit -framework Security -framework SystemConfiguration \
    Tests/ElysiumAppKitIntegration/CoordinatorProtocol.swift \
    "$APPKIT_SOURCE_ROOT/driver/main.swift" \
    -o "$DRIVER_CHECK" || fail "AppKit driver compile failed"
xcrun swiftc -O -warnings-as-errors -framework AppKit -framework CryptoKit -framework Security \
    Tests/ElysiumAppKitIntegration/CoordinatorProtocol.swift \
    "$APPKIT_SOURCE_ROOT/coordinator/main.swift" \
    -o "$COORDINATOR_CHECK" || fail "AppKit Coordinator compile failed"
xcrun swiftc -O -warnings-as-errors -framework CryptoKit \
    Tests/ElysiumAppKitIntegration/CoordinatorProtocol.swift \
    "$APPKIT_SOURCE_ROOT/protocol/main.swift" \
    -o "$PROTOCOL_CHECK" || fail "Coordinator protocol security harness compile failed"
"$PROTOCOL_CHECK" || fail "Coordinator protocol security harness failed"
rm -f "$DRIVER_CHECK" "$COORDINATOR_CHECK" "$PROTOCOL_CHECK"
rm -rf "$APPKIT_SOURCE_ROOT"
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

if grep -RInE 'Process\(|NSTask|system\(|popen\(|dlopen\(|dlsym\(' Sources; then
    fail "dynamic process/loading API reference found in Swift source"
fi

if grep -RInE 'AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|xox[baprs]-[0-9A-Za-z-]+' . \
    --exclude-dir=.git --exclude-dir=.build --exclude='*.png' --exclude='*.icns' --exclude='*.zip'; then
    fail "secret-looking material found"
fi

echo "==> security: passed"
