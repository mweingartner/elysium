# Correct rendering, readable progression, and safe template management

## Purpose

Restore coherent resource-pack rendering after an atlas/decode regression, make
multipart objects face consistently, improve first-person and XP feedback, and
prevent accidental saved-template deletion.

## Value

Players get upright Faithful textures, semantically aligned doors, beds, and double
chests, a visible selected-item hand treatment, and a stable rainbow XP fill without
losing the original progress track or level text. Builders can manage reusable
templates without a single key press immediately destroying persisted work.

## Scope

- PNG decode now exposes visual-top row zero consistently, while mesh inputs carry an
  immutable atlas generation and per-slice pack/procedural provenance.
- Shared meshing applies pack V normalization once and selects multipart crops from
  door half, bed half, chest neighbor part, and facing metadata.
- The HUD adds a deterministic first-person arm/selected-icon overlay and a fixed
  seven-band earned XP prefix.
- Saved Templates captures the normalized storage key and display name when Delete is
  requested, requires explicit confirmation, defaults focus to Cancel, and redacts
  storage failures at the UI boundary.
- The change does not alter block/item registration, placement, collision, simulation,
  RNG draws, save formats, template payload formats, networking, credentials, or
  telemetry. Procedural atlas art is not flipped, and stale mesh jobs cannot publish.

## Functional details

- Resource-pack textures retain their authored top/bottom orientation from decode
  through atlas upload. Missing or short provenance data falls back safely without
  flipping procedural tiles.
- Every mesh job captures one immutable render context. Atlas swaps increment the
  generation; completion must still match the live generation and the exact job
  identity before upload, accounting, removal, or dirty requeue can occur.
- Doors choose upper/lower art independently of facing; beds choose head/foot art;
  double chests choose left/right from neighbor truth. All four facings and orphaned
  states have deterministic fallbacks.
- The selected stack's exact icon is anchored to a compact first-person forearm. It is
  suppressed for hidden GUI, third-person views, open screens, or an empty main hand;
  attack/use motion is clamped.
- XP progress grows through red, orange, yellow, green, cyan, blue, and violet at fixed
  positions. It never cycles with time, and track length plus numeric level remain the
  non-color cues.
- Delete/Backspace opens template confirmation only when the list has keyboard focus.
  Pointer and keyboard actions use the same captured request. Escape/Cancel leaves the
  row intact. Confirm is single-use; a raced missing row refreshes as already gone;
  other storage failures retain the row and show safe, non-diagnostic copy.

## Usage

1. Select a Faithful resource pack and enter a world. Pack-backed blocks render in the
   authored orientation; rotating or placing doors, beds, and joined chests keeps each
   semantic part aligned.
2. Hold an item in first-person view. The compact arm uses that selected stack's icon;
   opening a screen or switching perspective hides it.
3. Earn experience. The earned portion of the existing bar grows left-to-right through
   the fixed rainbow while its length and level number continue to show progress.
4. Open Saved Templates, focus a row, and choose Delete (or press Delete/Backspace while
   the list owns focus). Review the displayed template name. Choose Cancel or press
   Escape to keep it; move focus to **Delete Template** and confirm to remove only the
   captured template.
