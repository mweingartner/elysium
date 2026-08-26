# Retired procedural held-pickaxe fallback

These seven transparent 96x96 sprites are retained as historical/fallback source artifacts. They
share one original Elysium silhouette and wooden-handle palette. They are no longer selected at
runtime: every registered pickaxe now resolves first to a genuine Blender model render under
`Assets/Elysium/HeldPickaxe3D`.

The silhouette is intentionally a conventional diagonal voxel pickaxe: a straight handle, a long
tapered mining point, and a shorter rear adze. It was designed from first principles after visual
review of the earlier curved Meshy bake and a user-supplied high-level shape reference. No pixels
from that reference are included. The rejected image-generation drafts are not shipped because
their apparent transparency was a baked checkerboard.

Regenerate the fallback artifacts deterministically from the repository root:

```bash
swift scripts/generate-held-pickaxes.swift
```

`Sources/Elysium/HeldItemAssets.swift` retains the same silhouette and palettes for compatibility.
`modelRenderedPickaxeVisualAssets` has precedence over it, so the fallback cannot replace the
reviewed 3D renders during normal lookup.
