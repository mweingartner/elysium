# Installed resource-pack failure attestation

This is a human-authorized, recoverable release attestation for the installed
Elysium app. It proves that a damaged managed Faithful 64x support copy produces
the truthful built-in fallback UI and that the exact pre-test state is restored.
It is not an automated pipeline step and must never add a fault selector to the
signed app.

## Stop conditions

Run this only with Elysium quit and only against the reserved managed file:

`~/Library/Application Support/Elysium/resourcepacks/Faithful 64x - December 2025 Release.zip`

Stop before mutation if any path component is a symbolic link; the parent is not
owned by the current user; the target is not a regular, single-link file owned by
the current user; its SHA-256 is not
`a136d9101a4748558587980dace3cd7447b758fb72c4684d15fb805d0a812dac`; or the
installed app's corresponding sealed resource does not have that same hash.
Never target the app bundle, a user pack, settings, or a world.

## Required guarded procedure

1. Resolve and record the canonical parent plus target device, inode, owner,
   mode, link count, size, and SHA-256 through held `O_NOFOLLOW` directory and
   file descriptors. Keep those descriptors open through backup and mutation.
2. Create a private temporary backup directory with mode `0700`. Create its
   backup using `openat` with `O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0600`; copy from
   the held source descriptor with complete EINTR-safe reads/writes; sync and
   close it; require a regular, single-link file and rehash it to the recorded
   digest.
3. Before the first chmod, rename, or replacement, install cleanup handlers for
   normal exit, every error, INT, TERM, HUP, and the bounded test timeout. Every
   handler must restore the original parent mode and atomically restore the exact
   archive from the still-verified backup, sync the file and parent, and verify
   owner, mode, size, link count, and SHA-256.
4. Create a bounded invalid regular sibling with mode `0600`, sync it, then use
   descriptor-relative rename to replace only the reserved managed file. Make
   only the managed resource-pack parent temporarily non-writable so startup
   self-healing cannot replace the fixture. Recheck identities after each step.
5. Launch the signed installed `/Applications/Elysium.app`. Record the truthful
   built-in fallback on the title, Video, and Resource Packs surfaces. Require
   `text:title:texture-generation` to report the built-in fallback and require
   `text:resource-pack.baseline` plus `text:resource-pack.status` to report the
   unavailable baseline and current status as static, enabled, non-Press
   Accessibility elements. Record the named bounded announcement exactly once
   after the Title Accessibility tree exists; resize, reopen Title, visit and
   return from Resource Packs, and confirm that it does not repeat. Quit Elysium.
6. Invoke the cleanup path. Verify exact original parent mode and archive bytes,
   removal of the invalid fixture, and unchanged identities/hashes for settings,
   worlds, unrelated packs, the installed executable, and sealed bundle archive.
   Relaunch and require all three static Accessibility elements to report
   Faithful 64x active/current status, with no stale fallback announcement.
7. Record before/failure/restored metadata and hashes with the installed proof.

If restoration cannot be proved, preserve the untouched verified backup and
report its absolute path as a blocking incident. Do not delete that backup and do
not run Security-code, Test, Deploy, archive, commit, or push gates afterward.

## Mandatory rehearsal

Before the real installed mutation, run the packaged AppKit integration gate:

```bash
bash scripts/appkit-text-entry-integration.sh
```

Its disposable `Tests/ElysiumAppKitIntegration/Driver.swift` executable performs
the guarded rehearsal before it launches Elysium. The driver creates a fresh
private temporary tree for each case, installs its signal cleanup source before
the first mutation, waits for a child to report that the named checkpoint was
reached, and sends that child a real `SIGINT`. It checks both of these cases:

1. interrupt after parent-mode mutation;
2. interrupt after replacement of the synthetic managed archive.

Both children must exit zero only after exact original bytes, regular-file
identity, owner, single-link state, `0600` file mode, and `0750` parent mode are
restored. A third child injects restoration failure: it must return nonzero,
retain the verified `0600` single-link backup, and report that exact backup path.
The test owner removes each isolated tree only after those assertions. None of
the fixture names, child modes, or failure controls is linked or copied into the
signed Elysium application.

The successful standalone rehearsal receipt is:

```text
Resource-pack attestation rehearsal: PASS interrupts=2 restore_failure=retained
```

This rehearsal does **not** mutate Application Support and does not authorize
the real installed attestation. Record its exit status and receipt alongside the
manual before/failure/restored evidence. If it fails, do not perform the real
mutation or any later release gate.

## Evidence record

Record, without abbreviating failures:

- installed bundle path, executable SHA-256, designated requirement, and sealed
  archive SHA-256;
- canonical managed-pack parent and the target's pre-test device, inode, owner,
  mode, link count, size, and SHA-256;
- private backup path and its independently re-read identity and SHA-256;
- fallback title, Video, and Resource Packs copy; exact static Accessibility
  IDs/roles/values/help/no-Press state; and the single post-tree announcement
  with no resize/reopen/return replay;
- restored directory mode and archive identity/SHA-256, absence of the invalid
  fixture, and unchanged settings/world/unrelated-pack hashes;
- the restored relaunch's Faithful 64x active visual/static-Accessibility state
  and absence of a stale fallback announcement.

Any missing observation is a failed attestation, not an implied pass.
