# Minecraft-reference first-person presentation

## Decision and scope

The comparison used one directly observed Minecraft 26.2 session, covering pickaxe,
axe, shovel, sword, bread, and a log, plus pickaxe/sword strokes and equipment changes.
Ordinary items were presented without a visible holding hand, with large textured
silhouettes entering from the outer lower edge and intentional right/bottom cropping.
This replaces Elysium's unsuccessful ordinary anatomical-grip and exact-contact designs.

Elysium now renders ordinary tools/food as native-resolution Faithful/resource-pack
pixel extrusions and blocks through their registered mesher. All pickaxes use pack
art instead of the historical CC0 model override. Empty slots emit no geometry.
The 70-degree first-person lens and HUD-over-item draw order remain unchanged.

The continuous primary swing moves inboard/up, down/forward, and back to rest without
an impact hold or target-dependent repositioning. Its approximately 0.20-second cycle
is an observational choice from a 20fps reference recording, not an extracted engine
constant. Holding input repeats; release completes the current cycle. Existing
lower/raise swaps, the previously requested 360-degree equip flip, and Reduce Motion
behavior remain. Combat, mining, item consumption, and projectile authority are unchanged.

The reference inventory did not contain a bow or shield. Their specialized Elysium
anatomy/mechanics are retained, not claimed as newly matched to Minecraft. The charging
trident retains target convergence but now starts from its ordinary item socket, avoiding
a jump to the former anatomical grip. No Mojang code or assets were copied.

## Verification

The optimized debug-control build used the real Metal renderer and an isolated,
disposable creative world; production saves were not used. Tested executable SHA-256:
`bda7dddec6f112d434bda257316250ed57fe0580b6c48b1fcb2c0f5be9dbc455`.

- 73 affected XCTest cases passed, without warnings: presentation, rig, viewmodel,
  viewport, and resource-pack hardening tests.
- Native idle inspection covered pickaxe, axe, shovel, sword, bread, stone, and empty.
  The item silhouettes were detailed and connected, with no ordinary hand fragments.
- Held pickaxe and sword sequences showed repeated whole-item strokes and recovery
  after release. Captures sample motion and do not independently establish precise cadence;
  timeline tests separately check repeat/release timing.
- Near/far trident charge/release inspection confirmed intact geometry, return to rest,
  and projectile emission. The regression test checks the real renderer call site and
  uses the old displaced grip as a negative control.
- Triangle-silhouette tests cover 4:3, 16:9, and 21:9 and both hands. Deliberately poor
  sword/bread placements fail those checks. They supplement, not replace, native review.
- An independent bounded review of candidate/reference frames found no material visual
  blocker. Minimap occlusion is intentional; no item placement depends on map size.

Private reference recordings and candidate captures remain local under the gitignored
`.artifacts/minecraft-viewmodel-2026-09-12/` directory. They are not shipped game assets.
These observations are bounded acceptance evidence, not a claim of exact Minecraft
parity, universal visual perfection, or user aesthetic approval. Revisit placement or
motion when concrete live feedback contradicts this comparison; do not reintroduce
visible grips or target pinning solely to satisfy superseded tests.

## Release boundary

The app-only presentation changes require a deliberate renewal of the normalized
Elysium executable pin. Storage, Core, text input, smoke, capability manifests, and
runtime special-mesh data remain unchanged. The release workflow independently checks
those pins, warning-free production compilation, XCTest, all 491 golden checks,
packaged AppKit behavior, installed identity, and signing. Installation and GitHub
publication status are reported after those operations, not inferred from debug proof.

The production release run passed all nine stages: 2,347 XCTest cases, 491 golden checks,
packaged AppKit text entry, installation, and signing/identity verification. Installed executable
SHA-256: `bb04cc38c24131a57b6fd2efb36e1f5c48903e4641e21ff484b8675a255541d5`.
Only these documentation closeout notes and the stale player-guide wording changed afterward;
the application source and tested/installed binary were unchanged.
