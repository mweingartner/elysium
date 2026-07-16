# Saved-world multi-selection and safe batch deletion

## Purpose

The saved-world browser lets a player select one, several, or all local worlds and permanently delete
the chosen set without confusing selection with opening a world. Deletion uses fresh storage authority,
explicit confirmation, and truthful recovery so an ambiguous database result is never presented as
success or safely retriable failure.

## Value

Players can clean up multiple saves in one operation using familiar macOS pointer, keyboard, and
VoiceOver interactions. Stable world identity preserves the intended selection when the list changes,
while an atomic transaction and fail-closed recovery protect unrelated worlds and all data belonging to
the selected worlds.

## Scope

- The feature applies to local saved worlds in the normal `Select World` browser and the
  `Select World to Host` browser. It does not delete a remote host's data, change the LAN protocol,
  create cloud deletion, or start LAN hosting as a side effect.
- Selection, focus, range anchors, checked requests, and receipts bind exact stored world IDs. Display
  names are bounded, escaped presentation text and never authorize deletion.
- One batch can contain 1 through 4,096 worlds, subject to the checked collection, encoded-byte,
  dependent-row, chunk-row, and statement-work limits. An over-limit or malformed collection fails as
  a whole; the browser does not silently omit rows.
- One immediate SQLite transaction removes the selected worlds from exactly six authorized scopes:
  world records, chunks, players, advancements, RPG preferences, and RPG migration markers. Existing
  single-world compatibility APIs remain available to their existing callers, but the browser uses only
  the checked batch API.
- A main-actor maintenance lease blocks conflicting open, create, host, join, navigation, repeated
  delete, and retained Accessibility actions while irreversible work is unresolved. OS Quit remains
  available. No network request or external service is involved.
- Recovery after an ambiguous commit is read-only. It checks only the original exact pre- or post-delete
  authority; it never repeats `DELETE`, repairs data, or bootstraps missing schema.

## Functional details

The browser shows a persistent selected count and one checkbox-role row per visible world. A plain row
click replaces the selection; clicking a row's check target or Command-clicking toggles it; Shift-click
replaces the selection with the inclusive anchored range; Command-Shift-click unions that range. Select
All selects the complete checked list and becomes Clear All. Refreshes reconcile selected, focused, and
anchored IDs against the new deterministic order without selecting an unrelated replacement.

Keyboard operation follows the same model. Up/Down replaces selection as focus moves;
Command-Up/Down moves focus only; Shift-Up/Down selects an anchored inclusive range;
Command-Shift-Up/Down adds that range; Space toggles the focused row; and Command-A selects all worlds.
Delete and Backspace are deliberately inert. Play Selected or Host Selected is enabled only when exactly
one world is selected. An unmodified primary double-click on that selected row's body performs the same
single-world action; check-target, modified, stale, busy, or multi-selected input cannot open or host.

Delete is always a two-step operation. Activating the enabled Delete button freezes mutable controls and
performs a fresh checked precheck. If membership or any selected row changed, no mutation occurs and the
browser asks the player to review the reconciled selection. Otherwise a blocking dialog lists the
selected presentation names, initially focuses Cancel, and exposes a separate non-default `Delete World`
or `Delete N Worlds` action. The names viewport scrolls independently when more than five names are
selected.

The transaction revalidates exact collection and row authority, deletes all six scopes atomically, and
proves its post-state while preserving unrelated rows. Direct or recovered commit proof refreshes the
list and announces `Deleted 1 world.` or `Deleted N worlds.` Proven precommit failure reports
`Worlds weren’t deleted. Try Again or Cancel.`; Try Again performs a new checked precheck and returns to
a new confirmation rather than replaying deletion. A stale result returns to review without mutation.

If Elysium cannot prove whether a commit happened, the non-dismissible `Saved Worlds Need Reloading`
state retires all stale background actions and exposes only `Reload Saved Worlds`. Reload performs the
read-only classification once. Exact post becomes recovered success, exact pre becomes proven failure,
and any other result remains terminal and fail-closed.

The retained Accessibility tree publishes only visible rows and visible confirmation names. Rows expose
checkbox role, bounded inert name/details, selected state, and position/count. Selection mutations renew
the tree immediately. Offscreen elements are virtualized, and every focus or Press action revalidates the
active key window, screen and layout generation, membership, maintenance lease, enabled state, and
action identity; stale elements are inert. Control characters, Elysium formatting markers, and Unicode
format/bidirectional controls in stored names are rendered as visible `\u{...}` escapes.

## Usage

### Delete several worlds with the pointer

1. Open the saved-world browser and click the first world to select it.
2. Command-click additional rows to toggle them, or Shift-click another row to select the inclusive
   range from the anchor. Use Command-Shift-click to add a range without clearing existing selections.
3. Activate Delete. Review the complete selected-name list after `Checking selected worlds…` finishes.
4. Leave Cancel focused to back out safely, or explicitly activate `Delete N Worlds` to perform the
   permanent batch deletion.

### Select all or use only the keyboard

1. Activate Select All, or press Command-A while the list owns keyboard focus. The toolbar changes to
   `All N selected` and offers Clear All.
2. Use Up/Down and the Shift/Command variants to adjust focus and ranges; press Space to toggle the
   focused world. Bare Delete and Backspace do nothing.
3. Tab or navigate to Delete, activate it, review the confirmation, then move from the default Cancel
   action to the destructive action and press Enter or Space.

### Open or host one world

Select exactly one world, then activate Play Selected or Host Selected. An unmodified primary
double-click on that selected row's body is equivalent. Selecting multiple worlds disables the
single-world action; deleting while in `Select World to Host` preserves the pending host settings and
does not start a host.

### Respond to a changed or uncertain result

- If the browser says `World list changed. Review your selection and try again.`, review the refreshed
  rows and begin deletion again; nothing was deleted by that stale attempt.
- If it says `Worlds weren’t deleted. Try Again or Cancel.`, Try Again refreshes and reconfirms; it does
  not repeat the prior transaction automatically.
- If `Saved Worlds Need Reloading` appears, use its sole Reload Saved Worlds action. Do not assume either
  success or failure until Elysium publishes a proven result; if verification remains unresolved, the
  browser stays locked in the recovery state.
