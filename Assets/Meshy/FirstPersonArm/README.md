# First-person arm asset

This directory preserves the source and runtime layers for Elysium's detailed
first-person right arm and closed tool grip.

## Provenance

- Meshy provider: Meshy 6 Image-to-3D
- Meshy task: `019f9cba-3f87-7b50-925b-ff839ba94493`
- Credits consumed: 30
- Approved input: `arm_gripping_pickaxe_reference.png`
- Source model: `first_person_arm_source.glb`
- Meshy preview: `first_person_arm_meshy_preview.png`
- Style reference: Elysium's bundled Faithful 64x wide Steve player texture
- Geometry/content request: one continuous first-person voxel forearm, articulated
  hand, four fingers and crossing thumb closed around a wooden tool handle

The approved input deliberately makes the visible sleeve/arm approximately 25%
smaller than the initial concept while leaving the pickaxe scale unchanged.

## Runtime derivation

`first_person_arm_empty_256.png` is a dedicated closed-fist pose derived from the
approved smaller-arm art. It contains no handle gap or foreground grip and is
used only when the selected slot is empty. The empty pose was edited with OpenAI
image generation, then deterministically chroma-keyed and fitted to the same
256x256 first-person canvas; no additional Meshy credits were consumed.

`first_person_arm_back_256.png` contains the sleeve, wrist, palm, and rear hand.
`first_person_arm_grip_256.png` contains only the camera-facing fingers and thumb.
Elysium draws the selected tool between those layers. This is intentional: the
handle passes through the palm and is occluded by the foreground fingers, so a
tool reads as held rather than as an icon beside the hand. Both layers use the
same 256x256 coordinate system and pivot.

SHA-256:

- reference: `bd5e621e0b232d17569e4cac52ef40630176d12495a7f32fd9e0b45121f925a8`
- source GLB: `35bdf3d350ba448e0811262a0ceaf9d26e44fd753a78d839056fd8d9de867934`
- Meshy preview: `30f99476203cd59d03cc364838b319227cef99d67b30d14d362335c8e224a861`
- empty-hand layer: `d0de00e98d902ef816c3ae8e2e1255ee195ce744ab7be287b1963ed083001157`
- back layer: `999cfb7f5363fc38401bba9c1d314f93f7aaae747451748508ab2d393c4e1feb`
- grip layer: `8eaaefb92e313c8764551ada7423ff594e40e297319b121b19907f1bf1baddea`

Meshy API output use is governed by the account plan used to generate the task.
Faithful texture attribution and license terms remain preserved with the bundled
resource pack and its existing project notices.
