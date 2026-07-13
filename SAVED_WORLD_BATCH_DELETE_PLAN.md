# Saved-World Batch Selection and Deletion Plan

Status: approved for Build on 2026-07-12.

Ordered gates: Design Mock PASS; Architecture PASS after revision; Design Review PASS;
Security (plan) PASS. Build, Security (code), Design Sign-off, Test, and Deploy remain open.

## Design Contract

The Select World and Select World to Host screens allow one or many saved worlds to be
selected by stable `WorldRecord.id`. Each visible row has a persistent visual checkmark and a
non-color-only selected boundary. Plain row click selects one; the checkmark or Command-click
toggles; Shift-click selects an anchored range; Command-Shift-click extends it. Select All and
Clear All operate on the complete checked list. Selection, focus, and range anchor never use a
durable array index.

Play/Host is enabled only for exactly one selected world. A row opens only from the original
unmodified primary AppKit event whose `clickCount == 2`, after checkbox hit testing, while that
exact world is the sole selected and focused ID. Click counts 1, 3, or greater, modifier clicks,
checkbox clicks, busy/error states, and multiple selections never open a world. Bare Delete and
Backspace are consumed without action.

Deletion begins only through the enabled Delete button. A fresh checked storage snapshot must
still contain the selected IDs and exact row digests before a confirmation is shown. The modal
uses `Delete 1 World?` / `Delete N Worlds?`, starts focused on Cancel, states that deletion is
permanent, presents every selected name through a bounded scrollable viewport, and requires an
explicit second activation of `Delete World` / `Delete N Worlds`. During work it shows and
announces `Deleting 1 world…` / `Deleting N worlds…`. A storage failure deletes none and shows
`Worlds weren’t deleted. Try Again or Cancel.`; Try Again obtains a fresh snapshot, returns to a
new confirmation with Cancel focused, and never replays deletion automatically. Stale selection
shows `World list changed. Review your selection and try again.` Success shows `Deleted 1 world.`
or `Deleted N worlds.` and renders the authoritative post-delete snapshot.

Loading uses `Loading saved worlds…`; a checked-load failure uses `Worlds couldn’t be loaded.`
with Try Again and Back. Preconfirmation uses `Checking selected worlds…` and freezes list,
selection, scroll, Play/Host, Delete, and Create. The LAN-host variant preserves its pending host
request and never starts hosting from selection or deletion.

At 360x224 logical pixels, the layout preserves title, a 308x20 selection toolbar, three complete
308x30 rows, three 100x20 primary footer buttons, a 200x20 Back button, and a status line. The
compact confirmation keeps its name viewport and both 100x20 actions visible. Larger layouts grow
the list only in complete rows. Long Unicode names are escaped/bounded for presentation and
ellipsized away from checkmarks and the scrollbar.

Accessibility publishes one retained checkbox-role toggle spanning each visible saved-world row;
the visual checkbox is not a second AX child. Rows expose bounded name/details, selected state,
position/count, focus, and Select/Deselect through stable digested identities. Offscreen rows are
virtualized. Play/Host, Delete, Select/Clear All, Create, Back, modal actions, status, and a
virtualized selected-name list are exposed separately. Stale objects fail screen, generation,
membership, enabled-state, key-window, and action revalidation. Destructive confirmation is never
the default action.

## Architecture

### Pure interaction model

Add a headless `SavedWorldSelectionState` and `SavedWorldSelectionLayout`. Every reducer receives
the current deterministic ordered ID list. Refresh intersects selection with membership and moves
focus to the nearest surviving row by its former position. Sorting is descending `lastPlayed` with
raw UTF-8 ID as the tie-breaker. Keyboard behavior covers Tab/Shift-Tab focus, Up/Down,
Command-Up/Down focus-only movement, Shift range extension, Space toggle, Command-A Select All,
and Return/Space activation of the explicitly focused control. Focus movement scrolls a row fully
into view before rendering or AX publication.

Add `ScreenPointerEvent` to preserve the original `NSEvent.clickCount` and device-independent
modifier flags. Its default adapter delegates to existing `onMouseDown`, so only the world list
changes behavior.

### Checked storage authority

`ElysiumStorage` owns checked collection snapshots and deletion. A checked row contains the exact
stored ID, JSON, stored `lastPlayed`, and row digest. Checked Core mapping rejects the whole list on
invalid storage class/UTF-8/JSON, duplicate IDs, nonfinite time, stored-ID versus decoded-ID
mismatch, stored versus decoded `lastPlayed.bitPattern` mismatch, decode-count mismatch, or any
cap violation. Stored IDs alone authorize membership and deletion; names are presentation only.

Use incremental SHA-256 with big-endian fixed-width count/length framing, deterministic raw-UTF-8
ID ordering, finite timestamp bit patterns, 32-byte child digests, constant-time comparison, and
distinct fixed domains for rows, collections, requests, pre/post snapshots, and receipts. Never
use Swift `Hasher` or concatenate an unbounded snapshot buffer.

One immutable delete request carries the expected collection digest and 1...4,096 unique,
deterministically sorted `(storedID, rowDigest)` expectations. One non-nestable existing
`coreWorldDeleteWithRPGV1` immediate transaction rereads the full snapshot, returns stale before
mutation on any drift, pre-counts with checked arithmetic, deletes the six authorized scopes in
fixed ID/scope order, verifies every change and selected postcondition, preserves every unrelated
row/table, and constructs the bounded post snapshot and receipt before commit. It may use no more
than 13 fixed reusable statements; no dynamic placeholder SQL is introduced.

Outcomes distinguish direct commit, recovered commit, proven precommit failure, stale, and terminal
integrity. Precommit failure is accepted only after an authoritative reread equals the exact pre
snapshot. Failure at or after the commit cut triggers an authoritative read outside the
transaction: exact post means recovered success; exact pre means proven failure; neither remains
terminal. A durable deletion is never presented as failure or offered a deletion retry.

Fixed caps are: 4,096 browser/selected worlds; 256 UTF-8 bytes per stored browser ID; 64 Characters
and 4,096 UTF-8 bytes per presentation name; 67,108,864 aggregate raw snapshot bytes; 1,048,576
selected chunk rows; 4,096 each for world/player/advancement/preference/marker rows; 1,310,720 bytes
per encoded request or receipt; 13 prepared statements; 53,248 statement-work units. Checked
arithmetic and cap+1 rejection occur before decoding or mutation.

### Concurrency and recovery

A main-actor `SavedWorldMaintenanceLease` is acquired before async deletion, revalidated before
storage admission, and held through direct, recovered, precommit, or terminal publication. It
blocks create/load, LAN start/client entry, repeated deletion, conflicting navigation, and stale
pointer/keyboard/controller/AX actions. Already accepted RPG player writers drain first. In-memory
omission receipts retire only after direct or exact-post recovered proof.

Every initial load, preconfirmation, retry refresh, deletion, and terminal reload owns a checked
monotonic request generation plus screen identity, request kind, and expected state. Late callbacks
after Back, close, replacement, or a newer request are ignored. UI/AX mutation occurs in one
non-suspending main-actor reducer; it installs the authoritative snapshot and complete final model,
reconciles focus/selection, retires omissions when proven, publishes one AX generation and one
announcement, and releases the lease only after no stale action can interleave.

If exact pre/post recovery is impossible, publish only a terminal modal and retain the lease:

- Title: `Saved Worlds Need Reloading`
- Body: `Elysium couldn’t verify whether the selected worlds were deleted. Reload saved worlds before continuing.`
- Sole action: `Reload Saved Worlds`
- Busy status: `Reloading saved worlds…`
- Unresolved body: `Elysium still couldn’t verify whether the selected worlds were deleted. Reload saved worlds before continuing.`

Terminal reload is the sole lease exception. It is read-only, one-shot while busy, and bound to the
current screen, state, lease, and action generation for primary click, focused Return/Space, or
revalidated AX Press. Exact post becomes recovered success; exact pre becomes the normal failure
modal; neither remains terminal and mints a new reload generation after the read completes. It
never retries deletion. OS Quit remains available.

### Durable documentation

Update README controls/feature text, ARCHITECTURE persistence/UI boundaries, SECURITY threat model
and recovery/cap rules, and storage release-surface/capability manifests in the same change.

## Risk-to-Test Map

- Stable identity: reorder, insert, remove, duplicate names, same-index replacement, and same-ID
  recreated-row tests.
- Selection: table-driven plain/checkmark/Command/Shift/Command-Shift, Select/Clear All, keyboard
  focus/range, auto-scroll, and 0/1/many/4,096 boundaries.
- Pointer: original click count/modifiers, checkbox-first precedence, exact double-click acceptance,
  and modified/triple/multiple/busy rejection.
- Storage: exact six-scope success, unrelated-data sentinels, stale replay, order permutation,
  corrupt classes/UTF-8/JSON, ID/time mismatch, framing/domain substitution, aggregate overflow,
  and cap-1/cap/cap+1 property tests.
- Faults: every prepare/bind/step/changes/reset/finalize/postcondition/commit/rollback/publication cut,
  exact rollback before commit, exact-post recovery after commit, neither-state terminal recovery,
  and restart durability.
- Concurrency: duplicate lease, create/load/host/navigation/AX attempts, late callbacks, retired
  screens/elements, token exhaustion, and reducer/release ordering.
- Accessibility/layout: one toggle per visible row, focus/action revalidation, modal trap, virtualized
  scrolling, exact copy/announcements, Standard/High Contrast, 360x224 and larger exact rectangles.
- Compatibility: existing one-world deletion, RPG omission/CAS, LAN, text entry, full XCTest,
  warning-free release build, security/storage scanners, and `elysmoke` 457/457.
- Installed proof: disposable support home with 0/1/many/long/scrolling worlds, mouse/modifier/
  keyboard/VoiceOver paths, atomic success/failure/stale/terminal reload, restart absence, survivor
  loadability, LAN-host nonactivation, and exact `/Applications/Elysium.app` identity.

## Conditions for Builder

- Never store selection, focus, anchor, deletion authority, or AX identity by array index or name.
- Never infer a double-click; preserve the original AppKit click count and modifiers.
- Never loop the existing single-world transaction for a batch or swallow checked errors.
- Never report a durable deletion as failure or replay an ambiguous deletion.
- Never retire omission state before direct or exact-post proof.
- Never admit world/LAN/navigation/AX conflicts while the maintenance lease is held.
- Never publish two AX children for one visual world row or one giant selected-name AX value.
- Never expose raw IDs, digests, SQL, paths, corrupt values, or underlying errors in UI/AX copy.
- Preserve exact reviewed strings, compact rectangles, caps, deterministic order, digest framing,
  transaction scope, virtualized presentation, and terminal Reload authority.
- Material changes return to the earliest affected gate.

