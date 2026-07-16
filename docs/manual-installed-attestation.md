# Automated Release Workflow

## Purpose

Replace Elysium's interactive installed-signoff receipt, screenshot, Observer, Designer, and finalizer chain with one automated release command that builds, tests, packages, installs, and verifies the exact local application candidate.

## Value

The workflow removes repetitive manual ceremony while preserving the checks that establish practical release readiness: security scanning, a warning-free release build, release-surface validation, XCTest, the 457-check golden contract, packaged AppKit text entry, installation, executable identity, and strict codesign verification.

## Scope

- `bash scripts/pipeline.sh` is the authoritative zero-argument local release pipeline.
- `.githooks/pre-commit` runs staged MPD policy and secret checks.
- `.githooks/pre-push` accepts exactly one non-deletion outgoing SHA, requires it to equal the clean stable checkout's `HEAD` and local ref, then runs the automated pre-push source/build/test gate.
- The retired installed-signoff receipt, screenshot, Keychain, Observer, Designer-action, finalizer, resume, and post-commit machinery is removed.
- Subjective visual quality is deliberately outside automated authority.

## Functional details

The pipeline runs nine ordered stages and stops at the first failure:

1. Source security
2. Warning-free release build
3. Release surface and binary checks
4. Full XCTest
5. `elysmoke` with 457 passing checks and zero failures
6. Signed application packaging
7. Packaged AppKit text-entry integration
8. Installation to `/Applications/Elysium.app`
9. Installed executable identity and strict codesign verification

The source snapshot covers tracked and nonignored-untracked inputs and is revalidated after each stage. The pre-sign release executable hash is validated through packaging input and AppKit authority; the package manifest's validated post-sign executable hash is used for the packaged, installed, and final executable identity.

Each successful stage prints `[n/9] ... PASS`. A failure prints one `AUTOMATED RELEASE FAIL stage=<stage> exit=<status>; later stages not run` line. Only complete success prints `AUTOMATED RELEASE PASS path=/Applications/Elysium.app executable_sha256=<sha256>`.

## Usage

Run the complete local release workflow:

```bash
bash scripts/pipeline.sh
```

Activate repository hooks after cloning:

```bash
git config core.hooksPath .githooks
```

Commit normally; do not bypass hooks. Push normally from a clean checkout whose sole outgoing ref resolves to `HEAD`.

PASS proves this checkout produced and installed the verified local `/Applications/Elysium.app`; it does not mean committed, pushed, CI-green, published, or subjectively visually approved.
