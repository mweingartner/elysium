#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "security scan failed: $*" >&2; exit 1; }

echo "==> security: source scans"

NETWORK_REFS="$(grep -RInE 'URLSession|NSURLConnection|NWConnection|Network\.|CFSocket|GCDAsyncSocket' Sources || true)"
UNAPPROVED_NETWORK_REFS="$(printf '%s\n' "$NETWORK_REFS" | grep -v '^Sources/Pebble/OllamaAgent.swift:' || true)"
if [ -n "$UNAPPROVED_NETWORK_REFS" ]; then
    printf '%s\n' "$UNAPPROVED_NETWORK_REFS"
    fail "network API reference found outside approved local Ollama client"
fi

URL_REFS="$(grep -RInE 'https?://' Sources || true)"
UNAPPROVED_URL_REFS="$(printf '%s\n' "$URL_REFS" | grep -v '^Sources/Pebble/OllamaAgent.swift:.*http://localhost:11434' || true)"
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
