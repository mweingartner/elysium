# Character Class Creation Carousel

## Purpose

Character creation previously separated a scrolling six-class list from attribute allocation and then
showed an automatic tutorial after completion. The revised creator keeps one class and its complete
attribute draft together in a compact, navigable dialog and lands directly on the Character surface.

## Value

Players can understand one class at a time, allocate its point pool without losing context, and compare
classes without scrolling through competing cards. The layout remains readable at the supported
360 x 224 minimum while retaining keyboard, controller, mouse, swipe, High Contrast, Reduced Motion,
and Accessibility semantics.

## Scope

This change covers the local presentation and draft-editing flow for the six registered RPG classes:
single-card projection, cyclic navigation, integrated attributes, bounded swipe handling, responsive
geometry, and direct post-create landing. Branch selection and final Review remain subsequent steps.

It does not change class definitions, presets, the 42-point budget, attribute range, Foundation rules,
starter inventory, persistence schema, LAN protocol, or create authority. Registry/draft mismatches,
integer overflow, stale semantic state, and invalid gesture coordinates fail closed. The authoritative
creation transaction and its existing validation/error presentation remain unchanged.

## Functional details

- The class step displays one canonical class card with name, ordinal, Role, Primary attributes, all
  five editable attributes, `Points remaining`, and `Reset to Preset`.
- Previous and next arrows wrap through registered class order. A dominant horizontal swipe begun on
  non-control card content invokes the same transition; vertical, short, stale, non-finite,
  out-of-viewport, cancelled, or control-origin drags do nothing.
- Every class keeps an independent branch and attribute draft. Moving away and back preserves edits;
  Reset changes only the visible class.
- Minus/plus actions remain within the creation range and point pool. Illegal min/max, zero-pool,
  overflow, and Foundation-requirement changes are disabled and rejected again by the reducer.
- Continue becomes available only for an exact valid draft, then advances through Branch to Review.
  Create still executes only from Review through the existing receipt-bound authority checks.
- At 360 x 224, two attribute columns preserve complete abbreviated labels and values 6 through 14 without overlapping
  controls. Essential controls and fixed Close/Continue actions remain visible without class scrolling.
- Successful creation publishes the normal Character surface with no automatic tutorial dialog.
  Validation, authority, inventory, persistence, and save failures remain visible.

## Usage

1. Open Character creation in a world with Character Classes enabled. Click the left/right arrows,
   use keyboard or controller navigation to focus an arrow and then activate it, invoke the equivalent
   Accessibility action, or swipe horizontally on non-control card content to move among the six classes.
2. Use each attribute's minus and plus controls to redistribute points. `Points remaining` updates;
   Continue stays disabled until all 42 points are allocated and the selected Foundation is valid.
3. Navigate to another class and return; the earlier class keeps its edited draft. Use `Reset to
   Preset` to reset only the class currently shown.
4. Continue to choose a Foundation, review the completed character, and create it. On success, Elysium
   opens the normal Character surface directly. If creation fails, correct the displayed validation or
   authority error and retry from the retained draft.
