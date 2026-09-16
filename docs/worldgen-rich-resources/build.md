# Rich Resources map-generation review

## Release-surface renewal

This change updates world generation, surface structures, passive wildlife, and
witch behavior. It also persists the selected village density in `WorldRecord`'s
existing JSON payload. Missing or malformed legacy values decode as Normal. The
SQLite schema, storage API, `StorageEngine`, `Player`, and text-input surfaces
remain unchanged.

After a warning-free `swift build -c release`, the disposable-copy `strip -S -x`
procedure in `scripts/verify-elysium-storage-release-surface.sh` produced these
reviewed renewals. Each previous value is the immediately prior reviewed value for
that pin. The final closeout renews the persistence source and capability rows for
the village-density implementation, then renews the linked artifacts after the
complete terrain, structures, village, witch, and dungeon-water-envelope work.

| Pin | Previous | Renewed |
| --- | --- | --- |
| `EXPECTED_SAVES_SOURCE_SHA256` | `326a288b1cf42378d25f28d60b54c9c821cf0e34d3e824d91dbad00a8021302e` | `40e0d4ffe5fa7b5f690527c81881837869efc2da84197bd5a6564bc6b2a22702` |
| `EXPECTED_GAME_CORE_SOURCE_SHA256` | `fa4447b252ed0821052a723c0604329033715e4c353b14e8f75445e71a478df8` | `51384ca30482f40a727a8c055569c0fda23572e8f80d92fb59a2330e083bc771` |
| `Saves.swift` compiler parse-AST inventory | `fd22fcb9e29b9fab570432db5dcacb941248e2cd5d44eb06dede02530f5162dc` | `3677417a7530f0fc9da26be37bf6c9072f0f15a2d6f6c42276ea230f437b802f` |
| `EXPECTED_CORE_CAPABILITY_SHA256` | `8350610207e812f32a44e2efc0768ed8b6e57d58e48f2e567bf2c8cc00bdca8a` | `24067f0177a15585e610ba327ba5f89ecc2fc01f4ae1a90ce1618a3725989228` |
| `EXPECTED_CORE_OBJECT_SHA256` | `6c5bbc62bee6eac084729d64062be2bb9501974130057605d6737e18fb2629ab` | `2517de8a5a513c923102c83b3230faa98a8dbad36c24b5d2840718a5c8798566` |
| `EXPECTED_ELYSIUM_PRODUCT_SHA256` | `0027a5ac076339cdc635a9b421ce4744f0901018e2808fdc2d20a32a1c8213a6` | `82efcbe813c7beb53ce1f5fdef6457fba0aa05e51a44fe0435bdd395f0fc53a1` |
| `EXPECTED_SMOKE_PRODUCT_SHA256` | `0ccc2c3ad00a853b26ad2b317408ca43f8b6b15ecf5961f990621bf8deda9e09` | `5bf669a9fe54485c02802186109fa84964990f200e8ed2c734a9de9db27df908` |

The final artifacts include exact-terrain structure admission, deterministic
realized-piece collision resolution, grounded and accessible village/landmark
architecture, repaired dungeon/mineshaft/stronghold/Ancient City routes, and richer
passive-creature bootstrap/spawn cadence. The form pass deliberately leaves the
reviewed SQLite storage API, storage engine, player, text-input, and capability
surface unchanged; the release verifier proves those boundaries before packaging.
