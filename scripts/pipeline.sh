#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

[ "$#" -eq 1 ] && [ "$1" = "--prepare-installed-signoff" ] || {
    echo "usage: scripts/pipeline.sh --prepare-installed-signoff" >&2
    exit 64
}

[ -f Package.swift ] && [ -f ARCHITECTURE.md ] && [ -f SECURITY.md ] || {
    echo "pipeline failed: project intent files missing" >&2
    exit 1
}
[ "$(git config --get core.hooksPath || true)" = ".githooks" ] || {
    echo "pipeline failed: core.hooksPath must equal .githooks" >&2
    exit 1
}

echo "==> pipeline: self-executing closed release authority"
# This command accepts no paths, logs, digests, argv, counts, statuses, or PASS assertions.
# The stable authority binary mints the attempt, runs and seals all seven reviewed gates,
# packages/installs the captured release, binds the live process, and alone publishes prepared.
scripts/installed-signoff-receipt.sh run-prepare-gates
scripts/installed-signoff-receipt.sh verify-current
echo "PENDING_INSTALLED_SIGNOFF: installation succeeded, but deployment completion, commit, and push remain blocked."
echo "Run scripts/observe-installed-signoff.sh before receipt expiry."
exit 75
