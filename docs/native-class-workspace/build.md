# Native class workspace release-pin receipt

This receipt records the narrow release-surface pin renewal for the native macOS character
workspace and the reviewed class/progression implementation. The first pipeline attempt passed
source security and its warning-free optimized build on 2026-09-01, then stopped before packaging
or installation at the expected checked-player caller source-hash boundary.

The changed `GameCore.swift` bytes are limited to the first-entry class-creation comment and chat
guidance: the obsolete inventory-only direction now points to the configurable default `K` route
and the native **Game > Character…** command. Both protected checked-player caller spans remain
byte-identical. The checked getter/CAS counts remain two each, their approved owners are unchanged,
and no storage, SaveDB, or SQLite call was added by the changed Core sources.

The source pin is the plain SHA-256 of `GameCore.swift`. Artifact pins came from the same
warning-free release build and were computed exactly as the verifier does: copy each artifact to a
disposable directory, make it writable, normalize it with the `xcrun --find strip` result using
`strip -S -x`, then hash it with `shasum -a 256`.

| Pin | Old SHA-256 | New SHA-256 | Reviewed reason |
| --- | --- | --- | --- |
| `EXPECTED_GAME_CORE_SOURCE_SHA256` | `ee9913866cf2c06e81e187735cf2c8aad01e183254b6f2028d6d94eed8c3973c` | `dcd46910fd7a693fcd26fe1991029deebde59fc42624032632c88abfa20d44ef` | First-entry class-creation guidance now names the native Character route; protected storage caller spans are unchanged. |
| `EXPECTED_CORE_OBJECT_SHA256` | `339c84fad017900f7585fffdb58f2e8a0e957deb67f77e5b8730bcb38f97eb90` | `426fc12b74e7cf55ac23c7f85adfff6094d7d97955f5139cb5b0b1c07224ea3a` | `ElysiumCore.o` contains the reviewed class definitions, explicit progression criteria, action/loadout behavior, and route guidance. |
| `EXPECTED_ELYSIUM_PRODUCT_SHA256` | `7fc5d168f74ea1f0ea4a0ee430c642b3a2da33d58d03bdf4893278345f891504` | `8c94c8eaf361a1a1e07a4dde7acdc53de6485a25574a741a69ec6a3db6e23a3e` | The Elysium product links the renewed Core and adds the native AppKit/SwiftUI class-creation, progression, actions, spells, and loadout workspace. |
| `EXPECTED_SMOKE_PRODUCT_SHA256` | `9f09f4158d115363df0771a4b0271225e15c6484db09807c2cb3a7d1444a552d` | `53c8155cf583e877ecb1d9df8794fe900d3e0b7e0958685772c939926189f9d3` | `elysmoke` links the renewed Core object; its fixed golden contract is unchanged. |

The following reviewed pins were recomputed or source-checked and remain byte-identical, so they
were deliberately not renewed:

- `EXPECTED_STORAGE_SOURCE_SHA256`
- `EXPECTED_STORAGE_API_SHA256`
- `EXPECTED_STORAGE_OBJECT_SHA256`
- `EXPECTED_SAVES_SOURCE_SHA256`
- `EXPECTED_PLAYER_SOURCE_SHA256`
- `EXPECTED_CORE_CAPABILITY_SHA256`
- `EXPECTED_TEXT_INPUT_SOURCE_SHA256`
- `EXPECTED_TEXT_INPUT_OBJECT_SHA256`

The release verifier rechecks the caller counts and owners, protected spans, SQLite boundary,
symbol surface, artifact freshness, and every unchanged pin before packaging is allowed. The full
nine-stage production pipeline is rerun from the beginning after this reviewed renewal.
