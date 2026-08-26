# Pack-derived held-tool sprites

These 128×128 RGBA sprites are the first-person visuals for every Elysium
`ToolDef` except pickaxes, plus the held shield. This legacy pipeline normalizes
and rotates flat item pixels; it does not build mesh
geometry or perform a Blender scene render. Pickaxes use genuine model renders
documented under `Assets/Elysium/HeldPickaxe3D`.

The bow also includes three progressive draw frames. Elysium selects those
frames from the authoritative bow-use tick count so raising, drawing, and
release remain synchronized with projectile charge rather than running as a
decorative animation.

For compatibility, `scripts/generate-held-tools-blender.py` retains its historical
filename and runs inside Blender through the local bridge. It decodes the item art from Elysium's managed
Faithful 64x baseline, normalizes it to a transparent 128×128 nearest-neighbour
canvas, and records both source and output SHA-256 values in `manifest.json`.
This keeps the familiar Minecraft-compatible silhouettes and Faithful detail
without making runtime behavior depend on Blender or an external file lookup.

The source art is by the Faithful Resource Pack contributors under Faithful
License v3. Elysium's bundled license and detailed attribution are preserved in
`packaging/FAITHFUL-LICENSE.txt` and `packaging/FAITHFUL-ADDONS-CREDITS.txt`.

To regenerate with Blender 5.1 and the reviewed localhost bridge:

```sh
python3 ~/dev/blender-bridge/bb.py file scripts/generate-held-tools-blender.py
```

`held_tools_blender_contact.png` is a generated review sheet in manifest order;
it is not loaded by the game.

## Upright alignment stage

The melee/mining tools (sword, axe, shovel, hoe) ship a Minecraft-item diagonal
silhouette, but the first-person fist grips a *vertical* handle. After the Blender
step, `scripts/align-held-tools-upright.py` stands each of those tools upright and
writes `held_<item>_upright_128.png`, then repoints the manifest `output` (and
`output_sha256`) at the upright file — the diagonal `held_<item>_128.png` remains the
Faithful-derived source. Run it before the embed step, and re-run it whenever the
pack-normalization step regenerates the diagonal sources:

```sh
python3 scripts/align-held-tools-upright.py
swift scripts/embed-held-tool-assets.swift
```

The obsolete procedural pickaxe fallback remains embedded for compatibility, but
`modelRenderedPickaxeVisualAssets` takes precedence for every registered pickaxe.

## Remaining 3D migration

The other 36 held-tool entries are still flat source art and must not be described as 3D.
Two creator-published CC0 model families have been verified for the next migration:

- [tfwa.games Voxel Tools](https://tfwagames.itch.io/voxel-tools) matches the current pickaxe and
  also supplies sword, axe, hoe, shovel, hammer, and scythe geometry. The free OBJ archive retrieved
  on 2026-08-26 had SHA-256
  `2f930616a25c797d144d53435a89ed16848a38a9c885a83fc014d990690322a0`.
- [Kenney Survival Kit 2.0](https://kenney.nl/assets/survival-kit) supplies compact GLB models for
  pickaxe, axe, hoe, shovel, and hammer, including upgraded variants. The official archive retrieved
  on 2026-08-26 had SHA-256
  `c3586341b5932c87eb43d75d915434f47daed168b17ed36a03e8ca9977c7443e`.

Adoption must retain the creator URL, CC0 notice, source archive hash, per-model hash, and a
deterministic render or bounded runtime-mesh conversion. Special equipment not covered by either
family (bow, crossbow, fishing rod, shears, flint and steel, trident, brush, and the flying wand)
needs separately licensed geometry or a reviewed native model before the flat fallback can be
retired.
