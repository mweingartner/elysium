# AGENTS.md

Editable source of record: [Model-Paired-Development-Playbook.md](/Users/mweingar/dev/hype-v2/docs/Model-Paired-Development-Playbook.md); exported copy: [ModelPairedDev.pdf](/Users/mweingar/Documents/ModelPairedDev.pdf), protocol version 2026-07-09. This file adapts that playbook to Elysium.

## Operating Protocol

Use the model-paired development method for all non-trivial Elysium work: written intent, separated adversarial roles, and verification gates backed by real command output.

For any non-trivial change: mpd begin, then loop mpd next --harness <h> → do exactly what the brief says → mpd gate <phase> --pass|--fail, until mpd archive. Author the OpenSpec artifacts under openspec/changes/<name>/ when a phase calls for them. Never bypass a FAIL gate or commit around the pre-commit hook.

Before editing, read the intent-shaping docs relevant to the task:

- [README.md](/Users/mweingar/dev/elysium/README.md)
- [CONTRIBUTING.md](/Users/mweingar/dev/elysium/CONTRIBUTING.md)
- [ARCHITECTURE.md](/Users/mweingar/dev/elysium/ARCHITECTURE.md)
- [SECURITY.md](/Users/mweingar/dev/elysium/SECURITY.md)
- Any source, test, golden, packaging, or script files directly affected by the request

Keep durable docs current when behavior, architecture, security posture, test workflow, or release workflow changes.

## Ordered Development Gates

Every Elysium change follows this order, with artifact depth scaled to semantic risk:

`Design Mock → Architecture → Design Review/Revision → Security (plan) → Build → Security (code) → Design Sign-off → Test → Deploy`

1. **Design Mock** — for any human-visible or interactive change, the Designer audits existing Elysium screens, HUD conventions, controls, copy, assets, accessibility, and relevant design docs; then specifies elegant, discoverable representation, every state, and checkable acceptance criteria.
2. **Architecture** — write a plan with file paths, exact edits/APIs, dependency order, failure modes, test/deployment expectations, a risk-to-test map, and "Conditions for Builder."
3. **Design Review/Revision** — for UI/UX work, the Designer confirms the plan preserves the design intent before code is written or returns it for revision.
4. **Security (plan)** — review trust boundaries, abuse cases, privacy/data flow, deterministic contracts, and relevant persistence/network/input risks. PASS or resolved CONDITIONAL PASS is required before Build.
5. **Build** — implement the approved plan, match existing patterns, and add initial tests in the same pass.
6. **Security (code)** — inspect the actual diff on disk. Findings return to the earliest affected phase; material fixes rerun this gate.
7. **Design Sign-off** — for UI/UX work, inspect the actual built/installed surface and representative states against the design contract. Unseen work cannot be signed off.
8. **Test** — independently exercise functional, regression, integration, boundary/error, and applicable non-functional behavior (performance, load/stress, resource use, concurrency, accessibility, resilience), plus seeded fuzz/property/metamorphic coverage for structured input. Run the full relevant Elysium gate and report commands, counts, and exit status.
9. **Deploy** — only after Test, perform the authorized Elysium install/deploy and verify the real installed target; if deployment was not requested or concretely authorized by current repo instructions, deliver deploy-ready evidence instead.

Only Design Mock, Design Review/Revision, and Design Sign-off may be marked N/A, only when there is no human-visible behavior or interaction impact, and only with a written rationale. No other phase is skipped for a typo, one-line change, comment, config, or familiar pattern; those changes receive concise, proportionate artifacts. Every review returns PASS, CONDITIONAL PASS, or FAIL. A conditional pass names conditions, owner, and closing evidence; FAIL blocks. Material changes invalidate downstream approvals.

Full-depth rigor is required for saves, settings, resource-pack parsing, SQLite/blob decoding, untrusted input, dynamic loading/execution, network behavior, sandboxing, cryptography, persistence format changes, or any capability with no shipped analog: explicit threat model, independently separated roles, deep Tester evidence, and Security reruns after fixes.

When sub-agent tooling is available, keep Designer, Architect, Security, Builder, and Tester as separate roles. Otherwise preserve the same separation as explicit phases and artifacts in the current session.

## Elysium Verification Gates

Use the smallest gate that honestly covers the risk, but do not call work complete without empirical evidence.

For ordinary development:

```bash
swift build -c release
swift test
swift run -c release elysmoke
```

For security-sensitive changes, also run:

```bash
bash scripts/security-scan.sh
```

For release/deploy readiness:

```bash
bash scripts/pipeline.sh
```

For UI/gameplay/world-state/LAN changes, the final Design Sign-off and Deploy stages must use the real installed app when the needed state is observable there. If code changes after a successful install or proof run, that evidence is stale; rerun every affected gate and renew installed-app proof.

The release build must be warning-free. `elysmoke` is the golden contract and must report the expected 457 checks passing unless the project deliberately changes that count in the same reviewed change.

For behavior changes that move goldens, read each failure, justify every changed value, regold only deliberate behavior changes with `ELYSIUM_REGOLD=1 swift run -c release elysmoke`, then rerun the suite. Never blanket-regold to make red go green.

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

The hook runs source security scans, a warning-free release build, XCTest, and `elysmoke`. Missing gate scripts fail closed instead of silently skipping the scan. Bypassing the hook requires an explicit `--no-verify`; do that only for a stated reason.

## Source Control

- Treat existing worktree changes as user-owned unless you made them in this task.
- Stage specific files only; never use `git add -A`.
- Keep one logical change per commit.
- Never commit secrets, private keys, `.env` files, build products, `.build/`, app bundles, or generated Xcode projects.
- Surface unexpected diffs, stale docs, or contradictory test results before acting on them.
