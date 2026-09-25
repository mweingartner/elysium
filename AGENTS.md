# AGENTS.md

## Operating Protocol

Do not use MPD or an OpenSpec phase pipeline for Elysium work. Work directly in the repository:
understand the relevant behavior, make the smallest coherent change, review the actual diff, run
the proportionate verification commands below, and report build, test, install, commit, push, and
remote-parity states separately. Never commit around a failing hook.

For completed Elysium implementation tasks, the user's standing closeout instruction is to deploy
the verified production release to `/Applications/Elysium.app`, commit the task's changes locally,
and push them to `main` at `https://github.com/mweingartner/elysium`. Perform all three without
requiring another reminder unless the user requests a pause or a different delivery scope. Run the
release pipeline and active hooks, verify installed identity and remote `main` parity, and preserve
unrelated worktrees and stashes. A failing gate, dirty destination, or non-fast-forward conflict must
be resolved safely or reported; this instruction does not authorize bypasses or destructive pushes.
Read-only analysis/review tasks do not require a deployment or commit.

Before editing, read the intent-shaping docs relevant to the task:

- [README.md](/Users/mweingar/dev/elysium/README.md)
- [CONTRIBUTING.md](/Users/mweingar/dev/elysium/CONTRIBUTING.md)
- [ARCHITECTURE.md](/Users/mweingar/dev/elysium/ARCHITECTURE.md)
- [SECURITY.md](/Users/mweingar/dev/elysium/SECURITY.md)
- Any source, test, golden, packaging, or script files directly affected by the request

Keep durable docs current when behavior, architecture, security posture, test workflow, or release workflow changes.

For UI/gameplay changes, inspect the built application when the affected state is observable there.
For security-sensitive changes, review the concrete trust boundary and run the security checks; do
not promote unrelated baseline warnings into feature findings. Scale planning and evidence to risk
instead of producing mandatory phase artifacts.

## Elysium Verification Gates

Use the smallest gate that honestly covers the risk, but do not call work complete without empirical evidence.

For ordinary development:

```bash
swift build -c release
python3 scripts/test-impact.py --plan
python3 scripts/test-impact.py --run
swift run -c release elysmoke
```

Scope regression tests to the change's blast radius. `scripts/test-impact.py --plan` reports the
selected scope as JSON; `--run` executes it. The release pipeline and pre-push hook automatically
union reviewed impact groups from changed paths. Unknown paths, sweeping changes, or
shared-engine changes fall back to the full suite. `ELYSIUM_FULL_TESTS=1` explicitly requests the
full suite and can only broaden coverage; never bypass a gate to narrow testing.

The initial reviewed groups cover dedicated rendering code (75 test cases), release workflow
(`AutomatedReleaseSourceTests` plus selector self-tests), and the broader app shell
(`ElysiumResourcePackTests`, `ElysiumDebugProtocolTests`, and `AutomatedReleaseSourceTests`).
Shared entrypoints such as `main.swift`, `HudM.swift`, and `DebugControlRuntime.swift` broaden the
selection to app-shell coverage rather than relying on narrow changed-line exceptions.
These are maintained impact rules, not a claim of complete automatic dependency analysis.

For security-sensitive changes, also run:

```bash
bash scripts/security-scan.sh
```

For release/deploy readiness:

```bash
bash scripts/pipeline.sh
```

The pipeline compares against the merge-base with `origin/main`; when that equals a clean `HEAD`,
it inspects the last commit using `HEAD^`. Pre-push supplies the actual remote base via `--base`.
Test selection does not remove security, warning-free build, golden smoke, packaging, AppKit,
installation, or installed-identity checks from the gates that own them.

For UI/gameplay/world-state/LAN changes, verify the real built or installed app when the needed state
is observable there. If product code changes afterward, renew affected proof.

The release build must be warning-free. `elysmoke` is the golden contract and must report the expected 491 checks passing unless the project deliberately changes that count in the same reviewed change.

For behavior changes that move goldens, read each failure, justify every changed value, regold only deliberate behavior changes with `ELYSIUM_REGOLD=1 swift run -c release elysmoke`, then rerun the suite. Never blanket-regold to make red go green.

For deterministic engine code, preserve these load-bearing contracts:

- Registration order is ABI; append new blocks/items/biomes/enchantments after frozen ranges.
- Simulation code uses deterministic math/RNG only.
- No unordered `Dictionary` or `Set` iteration may affect world state.
- Structure-piece RNG draws before chunk-relative checks.
- Chunks publish through `adoptChunk` on main; renderer/AppKit state stays main-thread-only; saves use the serial save queue.
- CPU-rewritten GPU buffers must be ring-buffered or staged.
- `ElysiumScript` is the sole Lua owner (`CLua` is never imported elsewhere, no `lua_`/`luaL_`/`LUA_` identifier outside it); every script-visible math and RNG call routes through `ScriptMath`/`ScriptRandomStream` to `DetMath`/`RandomX`, never libm or `Foundation` directly.

## Machine-Enforced Gate

This repo uses `.githooks/pre-push` as the local machine-enforced gate. After cloning or when hooks are not active, run:

```bash
git config core.hooksPath .githooks
```

The hook runs source security scans, a warning-free release build, impact-selected XCTest (or the
full fallback), binary/AppKit checks, and `elysmoke`; packaging and installation remain pipeline
gates. Missing gate scripts fail closed. Do not bypass the hook or a failing gate.

## Source Control

- Treat existing worktree changes as user-owned unless you made them in this task.
- Stage specific files only; never use `git add -A`.
- Keep one logical change per commit.
- Never commit secrets, private keys, `.env` files, build products, `.build/`, app bundles, or generated Xcode projects.
- Surface unexpected diffs, stale docs, or contradictory test results before acting on them.
