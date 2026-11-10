# Elysium 1.4.4 release-pin receipt

Version 1.4.4 is the first polish release for audio, skill trees and scripting: jukebox discs play
from their first note and volume sliders act on what is playing; three skill-progression farms are
closed and every technique has a cooldown; a failing script now says so in chat and `every(n, fn)`
repeats. `CHANGELOG.md` lists the player-visible changes and `ARCHITECTURE.md` records the three
decisions.

Values from the final warning-free `swift build -c release` on November 9, 2026 (Swift 6.4.2,
swiftlang-6.4.2.1.9), using the gate's `strip -S -x` normalization. The "previous" column is the
state after the Swift 6.4.2 toolchain renewal (commit a8b4c13), which re-pinned the unchanged
1.4.3 sources for the new compiler.

| Surface | Previous pin | 1.4.4 pin |
| --- | --- | --- |
| `Saves.swift` | `e87d37bbf5cf4d763fbc020d39cc2b7da2caad4a4cb92da1c2205a0968efc461` | `5af166872a3cbcff3fd104df1fd676e04196eba9776794960426c9f14df0eea6` |
| `Saves.swift` compiler-AST inventory | `66facece6331fa4a4d14d7c1647ad6fb2b4d4d483b7e24882aedd66ba196bf23` | `e3628e0a75528d947bfe9cdb7ab13690798b07402c3ed03c7e3775cd8344066a` |
| storage-capability manifest | `62dec84f63f0199c776aaa6b936f4e2e53bcd6493863c372fa4578acb0f394c0` | `3e53ff8a0b05c23c138f3e0be361719e6fb2bab683e97d78a543ee7185acf87e` |
| normalized `ElysiumCore.o` | `cff9f7a79021b988d4ad784df5c72f6aa2902bef32c49082bbe67d6f4c94b47e` | `4d8f9e57132ed68773a3df5c872c7d1b7ce10596b7a614415108f2bf67d0dbc0` |
| normalized `Elysium` | `159bd86e7af7a6734f52d52413c1e8a87fa85da156eae78648093c36c0f1f6e9` | `9baa8ad25a46aeb6b37549962407e2b9166a83277b6bb4dfcfeecd22778f47da` |
| normalized `elysmoke` | `77aa57bfc74ef2bd11fee6684c66a75be94df26ca89b849b3a7c5cede1085286` | `9e6bedc4c96c0a0d64c3b1524a3f8e9ea6427bfebba86b0d3c84ecc8fc6ccda4` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift`, `Player.swift`, the
storage source, API manifest and object, and the text-input source and object are unchanged from
the toolchain renewal. The Core object moves for the skill-tree and scripting changes and the
jukebox-stop sound hook; the Elysium product additionally carries the mixer changes. elysmoke
stays at 491 passing checks with no golden regenerated.

The toolchain renewal itself (same sources as 1.4.3, Swift 6.4.0.34.1 to 6.4.2.1.9) moved the
Storage, Core and TextInput objects, both products and the storage symbol graph. The storage API
was shown unchanged by re-hashing the 6.4.2 graph (362 symbols, 462 relationships) with
`metadata.generator` set back to the 6.4.0.34.1 string, which reproduces the previous
`symbolGraphSHA256` exactly. Old values are recorded beside each pin in
`scripts/verify-elysium-storage-release-surface.sh`.
