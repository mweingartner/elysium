# Stateful texture-mapping audit — build evidence

## Scope

This change corrects stateful/directional texture coordinates for doors,
trapdoors, fence gates, signs, pistons, anvils, and the affected functional
blocks. It adds a guarded PhotoBooth audit that only runs with an explicitly
new throwaway world and output directory. The resource-pack loader now reads
sign boards from Java entity sheets and preserves full entity crops when their
source-to-atlas scale is non-integral.

## Reviewed release-surface renewal

The following values were produced from one warning-free `swift build -c
release` on 2026-09-21. Each artifact was copied to a disposable path,
normalized with `xcrun strip -S -x`, then hashed with `shasum -a 256`, matching
`scripts/verify-elysium-storage-release-surface.sh` exactly.

| Pin | Previous | Renewed |
| --- | --- | --- |
| `EXPECTED_CORE_OBJECT_SHA256` | `49d23f2ae571ff4436476a55067d44360ef426fd75acf858852182a85c2c2340` | `36c132d622886299acc1efb57bf1291c688042cf50a0c71989237f754e5b7fa6` |
| `EXPECTED_ELYSIUM_PRODUCT_SHA256` | `8d533050ca617b44481618b465562740568000cbcd5079e557572c6525595a8d` | `c16333c4b11d8fd11a7f816c2ce0b48d0d12e3ed8d6318872440b8c1ab05c55f` |
| `EXPECTED_SMOKE_PRODUCT_SHA256` | `6332cd84b934cd6900548ff619aefd3e764a68f447b2de574c80cb934fd988ac` | `90c0a7d6b001a1b3a1b505b2b6dc15f4ca20afee9a61ea92a4f3d0205d56793b` |

Core mapping sources change the Core object. Those changes flow into both
products, and app-owned resource-pack/PhotoBooth sources additionally change
the application product. Storage, `Saves.swift`, `GameCore.swift`, `Player.swift`,
both capability manifests, `ElysiumStorage.o`, and the text-input source/object
remain unchanged and continue to be protected by their existing pins.

An independent final review then found that the non-integral entity-crop path
could omit its final source texel. The endpoint-preserving sampler renews only
the application-product row above; Core and `elysmoke` remain byte-identical.

## Focused evidence

- `swift test --filter 'DoorTextureMappingTests|StatefulOpenableTextureMappingTests|DirectionalFunctionalTextureTests|PistonAndAnvilTextureMappingTests|SignTextureMappingTests|FenceGateRenderingTests'` — 19 passed.
- `swift test --filter SignResourcePackMappingTests` — 2 passed, including exact Faithful entity-sheet crops and non-integral 16×/64× scaling.
- A built Faithful-64x debug run created 160 paired front/back PNGs for every
  openable-state matrix subject; representative mirrored and open door,
  bamboo-gate, and trapdoor views were visually inspected.
- `swift run -c release elysmoke` — 491 passed, 0 failed.
