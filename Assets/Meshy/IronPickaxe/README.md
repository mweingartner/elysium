# Iron pickaxe source assets

This directory preserves the tfwa.games CC0 source GLB, an earlier Meshy retexture
experiment, and its earlier compact render. The current runtime images are reproducible
Blender renders of the CC0 source mesh under `Assets/Elysium/HeldPickaxe3D`; they are
embedded in `Sources/Elysium/HeldPickaxe3DGeneratedAssets.swift`, so development,
packaged, and installed builds use identical immutable bytes without a dynamic model
loader.

- Current geometry provider: [tfwa.games Voxel Tools](https://tfwagames.itch.io/voxel-tools)
- Current geometry license: [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)
- Experimental retexture provider: Meshy
- Meshy retexture task: `019f9c99-5ab2-74f3-a545-35662cc2cf75`
- Accepted model generated: 2026-07-26 UTC
- Accepted GLB SHA-256: `6658c735483beef91680ee865308fd4a6f15fe3136a7ddcf2c694ed7c1ad1300`
- Runtime PNG SHA-256: `0c0a0fc0d54d4cc00a948e6656bd8d7ce4a7c2bc9ae0a231e3d270073fb9487e`
- CC0 source GLB SHA-256: `3d3c188a832b80518f405f7ab95c7982d88cd482ac81fe9be4eb535e39269f1d`
- Meshy workflow reference: <https://www.meshy.ai/blog/minecraft-3d-model>
- Geometry reference: <https://tfwagames.itch.io/voxel-tools> by tfwa.games, CC0 1.0
- Texture reference: bundled Faithful 64x `iron_pickaxe.png`

The accepted workflow preserves the clean voxel geometry of tfwa.games' CC0 pickaxe and asks
Meshy 6 to retexture it against the exact Faithful 64x iron-pickaxe artwork bundled with
Elysium. Fresh UVs were generated because the source MagicaVoxel palette occupied only a
one-pixel strip. PBR and baked lighting were disabled to retain crisp pixel-art shading. The
earlier prompt-only and single-reference results were rejected during visual review and are
not shipped.

`held_iron_pickaxe_96.png` is retained as provenance for the superseded Meshy path and is
not selected at runtime. The source geometry is `tfwa_pickaxe_cc0_source.glb`; the
retextured experiment is `iron_pickaxe_textured.glb`.
