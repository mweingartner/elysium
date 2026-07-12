#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec "$ROOT/scripts/run-release-gate-tool.sh" scripts/installed-signoff-receipt.swift "$@"
