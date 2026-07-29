# Blender-authored held tools

These 128×128 RGBA sprites are the first-person visuals for every Elysium
`ToolDef` except pickaxes, plus the held shield. Pickaxes deliberately retain
the separately reviewed diagonal Elysium silhouette under
`Assets/Elysium/HeldPickaxes`.

The bow also includes three progressive draw frames. Elysium selects those
frames from the authoritative bow-use tick count so raising, drawing, and
release remain synchronized with projectile charge rather than running as a
decorative animation.

`scripts/generate-held-tools-blender.py` runs inside Blender through the local
Blender bridge. It decodes the corresponding item art from Elysium's managed
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
