# Elysium 1.3.0 release-pin receipt

Version 1.3.0 adds the opt-in, versioned Prehistoric Worlds profiles. The
persisted-world boundary now rejects an unknown or malformed prehistoric
profile rather than silently rebuilding it as a normal world; the matching
host/client profile identity, runtime controllers, world generation, and
renderer work relink `ElysiumCore` and its two production consumers.

The values below came from the final warning-free `swift build -c release` on
September 17, 2026. Artifact values use the release-surface gate's
disposable-copy normalization (`strip -S -x`), not raw debug-symbol bytes.

| Surface | Previous pin | 1.3.0 pin |
| --- | --- | --- |
| `Saves.swift` | `c9e0c55b400444f1262f3ff0c6f63fdcd4e5ff95e40e4d87f7dbee919c58a2b1` | `5efd5a22b43aeb04760462c8a3fd3dfae5c49ff61b7271cc30ec981b86b9786f` |
| `Saves.swift` compiler-AST inventory | `f3991fdefe51070cd883779520475f85abcb59b4d4cac094edf044e9cdc26525` | `02d792abb67d5d2aabc4072c8d8a27664d9ede83367c947862dbd94162d91500` |
| storage-capability manifest | `74174593860b79cca66bec942e05cfd707276281517d6739a8ce9db7221becd8` | `2c14c21b1045d414dd7b4931c63db6074df16ffe0cdbf2f29b1c6cd5abcd169e` |
| `GameCore.swift` | `9aae5e19b00304145157b2a84ccd81dbf7dcb6effc0092d1c1e6952116a28f45` | `2734c85e3710b4992cdc4478c0a55dbff761ecc6268ab41e78928291692b871d` |
| normalized `ElysiumCore.o` | `fe800a9ece392f1917ce9b3fcf749f8ccaa4f179a2ad954af4611ce9447c29e9` | `2e0921f07e97e975947c768267205b8bffe004feca7f5b467012da258028fc94` |
| normalized `Elysium` | `553559e3ab03ca61d4b2c16e05d909e5796cff2352c1679f8bb9a3a96dcd8758` | `a9eb3393c93a97f26d59ea239349f7a5407e71422d32f80b6e5b442262916af1` |
| normalized `elysmoke` | `0a13660761c0e273359a089375ccff8bcba6589722a4af7cf79f3b937022e0cd` | `fe5561b89197d0175ef53f27126169db3e928b9f3f9061bc8d9973cc89738f97` |

The reviewed `StorageEngine.swift`, storage API manifest, `Player.swift`,
`ElysiumStorage.o`, `ElysiumTextInput.swift`, and `ElysiumTextInput.o` pins
are unchanged. The semantic AST review found only the version bump and the
strict `WorldRecord` preset-decode boundary; it did not add a storage API,
SQLite capability, checked-player caller, or text-input surface.

The final closure also rejects every legacy generated landmark occupant and
returns retained spawners before timer/RNG mutation in prehistoric profiles.
Its bounded ambient-audio timer is saved atomically with the creature's private
controller words, preventing an artificial early controller draw after reload;
route waypoints still deliberately recompute from current terrain.

`swift scripts/sqlite-boundary-scan.swift --root "$PWD" --self-test` passed
for 259 production Swift files after the manifest update, and
`bash scripts/verify-elysium-storage-release-surface.sh` verified every
source, capability, caller-boundary, and normalized-artifact pin.
