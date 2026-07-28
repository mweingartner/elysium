# Elysium held pickaxes

These seven transparent 96x96 sprites share one original Elysium silhouette and wooden-handle
palette. Only the head palette changes for wooden, stone, copper, iron, golden, diamond, and
netherite pickaxes.

The silhouette is intentionally a conventional diagonal voxel pickaxe: a straight handle, a long
tapered mining point, and a shorter rear adze. It was designed from first principles after visual
review of the earlier curved Meshy bake and a user-supplied high-level shape reference. No pixels
from that reference are included. The rejected image-generation drafts are not shipped because
their apparent transparency was a baked checkerboard.

Regenerate the runtime sources deterministically from the repository root:

```bash
swift scripts/generate-held-pickaxes.swift
```

`Sources/Elysium/HeldItemAssets.swift` reconstructs the same silhouette and palettes directly into
bounded RGBA buffers, ensuring development, packaged, and installed builds use identical pixels
without filesystem lookup. The PNGs remain reviewable source artifacts with pinned hashes.
