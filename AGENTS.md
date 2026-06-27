# AGENTS.md

Source of record: [ModelPairedDev.pdf](/Users/mweingar/Documents/ModelPairedDev.pdf), "The Model-Paired Development Playbook", updated 2026-06-13. This file adapts that playbook to Pebble.

## Operating Protocol

Use the model-paired development method for all non-trivial Pebble work: written intent, separated adversarial roles, and verification gates backed by real command output.

Before editing, read the intent-shaping docs relevant to the task:

- [README.md](/Users/mweingar/dev/pebble/README.md)
- [CONTRIBUTING.md](/Users/mweingar/dev/pebble/CONTRIBUTING.md)
- [ARCHITECTURE.md](/Users/mweingar/dev/pebble/ARCHITECTURE.md)
- [SECURITY.md](/Users/mweingar/dev/pebble/SECURITY.md)
- Any source, test, golden, packaging, or script files directly affected by the request

Keep durable docs current when behavior, architecture, security posture, test workflow, or release workflow changes.

## Tiering

Skip the pipeline for one-line fixes, typos, comments, pure config, and additions that mirror an existing pattern exactly.

Lite tier is the default for normal multi-file work:

1. Pre-grep the tree and check `git status --short --branch`.
2. Write an Architect plan with file paths, exact edits, edge cases, test expectations, and "Conditions for Builder".
3. Build from the plan, matching existing patterns and adding inline tests for new behavior.
4. Perform a Security review of the actual code on disk.
5. Run the full relevant verification gate and report command evidence.

Full tier is required for saves, settings, resource-pack parsing, SQLite/blob decoding, untrusted input, dynamic loading/execution, network behavior, sandboxing, cryptography, persistence format changes, or any capability with no shipped analog:

1. Architect plan.
2. Security review of the plan.
3. Builder implementation with tests.
4. Security review of the actual code on disk.
5. Tester/regression pass against the implementation.
6. Full verification gate.

When sub-agent tooling is available, keep Architect, Security, Builder, and Tester as separate roles. Otherwise, preserve the same separation as explicit phases in the current session.

## Pebble Verification Gates

Use the smallest gate that honestly covers the risk, but do not call work complete without empirical evidence.

For ordinary development:

```bash
swift build -c release
swift test
swift run -c release pebsmoke
```

For security-sensitive changes, also run:

```bash
bash scripts/security-scan.sh
```

For release/deploy readiness:

```bash
bash scripts/pipeline.sh
```

The release build must be warning-free. `pebsmoke` is the golden contract and must report the expected 456 checks passing unless the project deliberately changes that count in the same reviewed change.

For behavior changes that move goldens, read each failure, justify every changed value, regold only deliberate behavior changes with `PEBBLE_REGOLD=1 swift run -c release pebsmoke`, then rerun the suite. Never blanket-regold to make red go green.

For deterministic engine code, preserve these load-bearing contracts:

- Registration order is ABI; append new blocks/items/biomes/enchantments after frozen ranges.
- Simulation code uses deterministic math/RNG only.
- No unordered `Dictionary` or `Set` iteration may affect world state.
- Structure-piece RNG draws before chunk-relative checks.
- Chunks publish through `adoptChunk` on main; renderer/AppKit state stays main-thread-only; saves use the serial save queue.
- CPU-rewritten GPU buffers must be ring-buffered or staged.

## Machine-Enforced Gate

This repo uses `.githooks/pre-push` as the local machine-enforced gate. After cloning or when hooks are not active, run:

```bash
git config core.hooksPath .githooks
```

The hook runs source security scans, a warning-free release build, XCTest, and `pebsmoke`. Missing gate scripts fail closed instead of silently skipping the scan. Bypassing the hook requires an explicit `--no-verify`; do that only for a stated reason.

## Source Control

- Treat existing worktree changes as user-owned unless you made them in this task.
- Stage specific files only; never use `git add -A`.
- Keep one logical change per commit.
- Never commit secrets, private keys, `.env` files, build products, `.build/`, app bundles, or generated Xcode projects.
- Surface unexpected diffs, stale docs, or contradictory test results before acting on them.
