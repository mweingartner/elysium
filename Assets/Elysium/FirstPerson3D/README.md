# First-person runtime meshes

These are actual Blender-authored triangle meshes, not pre-rendered sprites. The
game consumes `Sources/Elysium/FirstPersonModelAssets.swift`: embedded immutable
Float32 data decoded once, independent of bundle paths or a Blender installation.
The `.f32` exports and manifest permit a byte-level comparison with the embedded
stream. The `.blend` is an editable isolated inspection scene. PNGs show model
geometry and grip alignment; they are **not** runtime or gameplay proof.

## Source and reproducibility

The pickaxe preserves the existing accepted tfwa.games [Voxel Tools](https://tfwagames.itch.io/voxel-tools)
mesh under [CC0-1.0](https://creativecommons.org/publicdomain/zero/1.0/), pinned by
SHA-256 `3d3c188a832b80518f405f7ab95c7982d88cd482ac81fe9be4eb535e39269f1d`.
No generated Meshy mesh, paid-generation credit, or external download is used.
Only a proper axis rotation, translation, and uniform scale are applied to this
geometry. The material helper changes neutral head colors, never the handle.

The arm, hand, and shield are original Elysium geometry and pixel-face palettes
under the repository's MIT license. They do not copy a Minecraft skin or shield
texture. The arm is a connected tapered cuboid with broad pixel patches; the hand
and shield are exposed surfaces of connected voxel unions. Greedy face merging
reduces triangle count without changing the voxel silhouette or colors. Finger
creases are face colors on closed geometry, not detached overlay cards.

Regenerate using Blender 5.1 in a **separate background process**, preserving any
open user scene:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python scripts/generate-first-person-models-blender.py
swiftc -typecheck Sources/Elysium/FirstPersonModelAssets.swift
```

The generator rejects a changed source hash, detached voxel components,
degenerate triangles, and non-finite values. `manifest.json` records source,
coordinate transformation, bounds, triangle counts, and binary/Swift hashes.

## Grip and renderer contract

- Every stream has ten little-endian Float32 values per vertex: position XYZ,
  flat outward normal XYZ, and **linear** RGBA. Triangles wind counter-clockwise
  when viewed from outside. Mirroring a hand must also reverse triangle winding.
- Local +Y runs from pommel to head; +X is screen-right in the canonical front
  view; +Z faces the player. Grip position is exactly `(0, 0, 0)`.
- `pickaxe` is 0.85 units high, with the grip 15% up its height. Its reinforced
  lower handle is 0.10625 units wide. The accepted head is 0.57375 units wide.
  `pickaxe(material:)` provides wooden, stone, copper, iron, golden, diamond,
  and netherite head palettes without modifying the wood or silhouette. Runtime
  presentation applies the explicit 0.98/0.85 scale, then translates +0.05 in Y
  so its pommel stays inside the fist rather than the independently bent wrist.
- `hand` is separate from the arm, so grips can adapt to smaller handles without
  resizing the tool or distorting the forearm. Its bore is approximately
  ±0.064 in X/Z, fitting the 0.1225-wide reinforced pickaxe handle after the
  runtime's explicit 0.98/0.85 uniform presentation scale. In the authored mesh,
  curled fingers are on +Z and the back of the hand is on -Z. Runtime applies a
  proper 180-degree Y rotation to holding hands **only**, so the back faces the
  wearer without turning the item, changing handedness, or moving the grip and
  wrist anchors. The Blender previews apply the same hand-only attachment turn
  after export. The dedicated bow draw hook retains its own unrotated frame.
  The wrist overlaps the legacy arm
  over Y=-0.12...-0.08. There is no baked handle in either mesh.
- `handNarrow` closes its fingers and palm around a rectangular bore of nominal
  X±0.045, Z±0.025 for the measured 0.078–0.084-wide Faithful diagonal haft
  geometry and 0.045 extrusion depth. It preserves the wide hand's outer bounds and exact
  wrist join; do not scale the whole fist to tighten its grip. `grip-narrow.png`
  uses an inspection-only 0.08×0.045 shaft, which is not a runtime asset.
  Both fists close their lateral surfaces; only the top and bottom of the grip
  open around the real shaft, so no brown handle sliver appears beside the thumb.
- `handShield` uses X/Z±0.032 around the shield's 0.06-wide rear handle;
  `handRound` uses X/Z±0.028 around the bow's 0.052-wide limb. These dedicated
  closed voxel grips keep the same outer palm and wrist-joint footprint, instead
  of leaving a pickaxe-sized hole or scaling the entire fist. A shared-position
  adjustment fits the inner surfaces precisely between the source voxel grid
  planes; the shoulder-facing wrist join stays unchanged.
- `handDraw` is the bow's dedicated right-hand archery hook: three separated,
  curled fingers, a relaxed thumb, and a solid palm with **no shaft bore**. Its
  0.16-wide palm/finger silhouette is 20% narrower than the tool fists, while
  keeping the same `(0,-0.10,0)` wrist joint. Local X runs across the finger pads;
  `handDrawStringContact = (0.025,0.040,-0.0415)` locates the nock between index
  and middle fingers, and `handDrawStringAxis = (1,0,0)` is the string direction.
  A 0.007-wide string at that position touches the inner hook surfaces at
  Z=-0.045. Bind the real nock to this contact after orienting the hand; do not
  reuse the +Y handle-grip orientation. The two `bow-draw-hook` previews show
  both the closed palm side and the actual hooked contact side.
- `arm` extends from Y=-0.08 to -1.28, with a modest toward-camera slope. Its
  enlarged near-wrist depth covers the real pickaxe pommel instead of exposing a
  small brown fragment between wrist and fingers. The original forearm remains
  unchanged through Y=-0.68; a same-width sleeve extension continues its shoulder
  direction below that point. This was an intermediate repair for a visible cap;
  the stream is now archived and is not used by the runtime. The focused
  `FirstPersonArmViewportTests` exercises the replacement segmented rig, with
  `FirstPersonRigTests` covering contact, joint continuity, and fixed bone lengths.
- New runtime `forearm` and `upperArm` streams replace that archived one-piece
  arm with two rigid, independently posed segments. `forearm` has wrist joint
  `(0,0,0)` and elbow joint `(0,-0.40,0)`, with geometry over Y=-0.425...+0.025.
  `upperArm` has elbow joint `(0,0,0)` and shoulder joint `(0,-0.45,0)`, with
  geometry over Y=-0.48...+0.035. Place the wrist joint at the hand socket's
  `(0,-0.10,0)`. Both axes point -Y; transform positions and normals rigidly,
  never stretch X/Z to connect a distant shoulder. Overlap conceals the wrist
  and elbow caps. Small planar bevels and controlled skin/fabric pixel patches
  give joints and edges readable depth. `segmented-arm-grip.png` inspects an
  actual bent two-bone pose, not just two individually valid meshes.
- `wristJoint` is a closed faceted 0.164-wide cube with a single 0.018 bevel,
  centered at `(0,0,0)` and drawn at the solved wrist joint. Its skin surface
  fills the corner gaps when the fist and forearm rotate independently. The
  ±0.082 outer planes deliberately avoid the existing collars' coplanar faces.
  This is solid shared joint geometry, not a floating patch or another hilt.
- `shield` is 0.5 wide by 0.8 high. Its board occupies Z=-0.19...-0.14,
  leaving 0.03 clearance from the palm instead of penetrating it;
  its rear grip is centered at the origin and extends toward +Z. The decorative
  outer face points **-Z away from the player**, leaving the rear handle visible
  to the wearer. The shield handle is roughly 0.06 wide; its fist must close more
  tightly than the reinforced pickaxe grip.

At the reviewed export the segmented pickaxe/forearm/upper-arm/wide-hand assembly
is 3,886 triangles (1,564 + 972 + 1,020 + 286 + 44 at the wrist joint).
Each dedicated grip's exact count
is recorded in `manifest.json`. The legacy one-piece arm
remains available for archive tests but is not the new runtime rig. The rest of
the rendering and animation system owns camera placement, lighting, material
selection, mirrored left-hand transforms, action timing, occlusion, and empirical
in-game review.
