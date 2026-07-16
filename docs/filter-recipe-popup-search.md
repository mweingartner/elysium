# Recipe popup substring filtering

## Purpose

The recipe popup now treats its search field as a live substring filter instead
of leaving nonmatching recipes visible. The same filtered collection drives
rendering, mouse hit testing, scrolling, keyboard navigation, and selection.

## Value

Players can narrow large recipe lists while typing, correct the query with
Delete or Backspace, and select the first or another matching recipe without
leaving the keyboard.

## Scope

This change covers the inventory and crafting-table recipe popups. Matching is
case-insensitive against normalized recipe display names, preserves canonical
recipe order, and does not add prefix ranking or fuzzy matching. It does not
change crafting eligibility, ingredient withdrawal, recipe registration order,
or any persistence/network boundary.

## Functional details

- An empty query exposes the complete eligible recipe list.
- Each query edit recomputes substring matches and highlights the first result.
- Up and Down traverse only matching rows; Return selects the highlighted match.
- Delete and Backspace recompute results so corrections can restore entries.
- A query with no matches shows `No matching recipes`, with no stale row,
  highlight, icon, scrollbar, mouse target, or actionable accessibility row.
- Zero matches retain the entered query header and remain distinct from the
  underlying-empty `No craftable items` state.
- An open popup keeps a nonempty query across inventory or Creative-mode
  refreshes and highlights the first current match; closing and reopening the
  popup starts with an empty query.
- The empty-result status is exposed as non-actionable accessibility text.
- Accessibility exposes the complete unabridged query even when its visible
  header is clipped, and publishes only filtered membership, canonical order,
  and the current highlight.

## Usage

1. Open either recipe popup and type `wood`; only recipes whose normalized
   names contain `wood` remain, and the first is highlighted.
2. Press Down or Up to move through those matches, then Return to select the
   highlighted recipe.
3. Press Delete or Backspace to correct the query; the visible results and top
   highlight update immediately.
4. Enter a query with no eligible matches to see `No matching recipes`.

## Verification

- Core tests cover canonical filtering, correction, zero matches, navigation,
  selection, refresh, and deletion restoration.
- Source-contract tests cover the no-match accessibility descriptor.
- The release pipeline supplies full XCTest, golden smoke, packaging, signing,
  installation, and installed-app verification evidence.
