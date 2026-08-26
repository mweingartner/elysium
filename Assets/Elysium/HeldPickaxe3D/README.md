# Model-rendered held pickaxes

These seven transparent 128x128 first-person images are genuine Blender renders of the
bundled `tfwa_pickaxe_cc0_source.glb` mesh. They are not rotated or extruded 2D item
sprites. Every material uses the same indexed voxel geometry, camera, lights, and handle
palette; only the neutral head palette changes.

Source and license:

- Creator: tfwa.games
- Original pack: [Voxel Tools](https://tfwagames.itch.io/voxel-tools)
- License: [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)
- Source geometry: `Assets/Meshy/IronPickaxe/tfwa_pickaxe_cc0_source.glb`
- Pinned source SHA-256: `3d3c188a832b80518f405f7ab95c7982d88cd482ac81fe9be4eb535e39269f1d`

The official source page identifies the pack as 3D voxel art, includes the pickaxe among
its seven tools, and marks the asset license as CC0. Elysium retains this provenance even
though attribution is not required by CC0.

Regenerate and embed from the repository root with exactly Blender 5.1.2. The
generator rejects every other Blender version, and the embedder rejects any
unreviewed generator, camera, model, or output-image hash:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python-exit-code 1 \
  --python scripts/generate-held-pickaxes-blender.py
swift scripts/embed-held-pickaxe-3d-assets.swift
```

`manifest.json` binds the source model and every output image by SHA-256. Runtime code
uses the embedded immutable PNG bytes; attack animation applies rigid translation and
rotation only and never rewrites or non-uniformly scales the art.

The reviewed release-product pin renewal and old/new artifact hashes are recorded in
[`build.md`](build.md).
