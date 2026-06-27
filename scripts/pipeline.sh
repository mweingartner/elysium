#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

stage() { echo; echo "==> pipeline: $*"; }
fail() { echo "pipeline failed: $*" >&2; exit 1; }

stage "architect"
[ -f Package.swift ] || fail "Package.swift missing"
[ -f ARCHITECTURE.md ] || fail "ARCHITECTURE.md missing"
[ -f SECURITY.md ] || fail "SECURITY.md missing"
[ ! -e Pebble.xcodeproj ] || fail "unexpected Xcode project present"

stage "security"
./scripts/security-scan.sh

stage "asset verification"
./scripts/verify-pack-assets.sh

stage "build"
BUILD_LOG="$(mktemp /tmp/pebble-build.XXXXXX)"
if ! swift build -c release 2>&1 | tee "$BUILD_LOG"; then
    fail "release build failed"
fi
if grep -q 'warning:' "$BUILD_LOG"; then
    rm -f "$BUILD_LOG"
    fail "release build emitted warnings"
fi
rm -f "$BUILD_LOG"

stage "security check binary"
./scripts/security-check-binary.sh .build/release/Pebble

stage "test"
swift test
swift run -c release pebsmoke

stage "deploy"
./pebble install
./scripts/security-check-binary.sh "$HOME/Applications/Pebble.app"

stage "clean pass deployed"
