# Elysium 1.4.0 release-pin receipt

Version 1.4.0 replaces the canvas Skills screen with a native window built on the Atrium design
system. Atrium requires macOS 26, so the package now targets macOS 26 with swift-tools 6.2 and
links Atrium from the sibling checkout `../Atrium`, approved at commit
`19eb9407e5cee1e511d2cd3df7e5c4eaacbff7e0`. 1.4.0 hosts and guests cannot join 1.3.0 LAN worlds,
because LAN play requires identical versions.

The values below came from the final warning-free `swift build -c release` on October 3, 2026,
using Swift 6.4 (swiftlang-6.4.0.34.1). Artifact values use the release-surface gate's
disposable-copy normalization (`strip -S -x`).

| Surface | 1.3.0 pin (Swift 6.4.0.34.1) | 1.4.0 pin |
| --- | --- | --- |
| storage symbol graph (`symbolGraphSHA256`) | `541907349e6922a97d1de24e5bdfad0a141ffd5d59310f2b701cac1fee57b54b` | `b073a1b77d8c60cef8f14a56f789694174d7333ec980c0f3efab1368b164a57d` |
| storage API manifest | `511be0c59c5ca0228074819b8f9c6d737d83673634ac6369f5c117596feb7cb3` | `3397082a30b483a157df3982f1d1f15af31d5097b6563c56082bae8bc91e3d74` |
| `Saves.swift` | `21c80f8babbb2423a2bd65a2f5a3ae097ae5b46f4f9612c167904c2b363a3822` | `5b4a7a287800e2cb3788f3f09750d9fdff3db342151db4cbed7dd850c9463463` |
| `Saves.swift` compiler-AST inventory | `e7b213f021d94bb72a353613c40768563dbb159e3391669ab605c795508e858e` | `2c0eb59ce97ad79c98f0074c3fda67591c42ffc11dde2e2380a0b1bb7512df78` |
| storage-capability manifest | `377ee1d5aced0ca72770b6e6e28647ab29397e5a9f56a0328068fecb62b5dffb` | `f922b1211186211a274de565ed7f68517693bbff9ac09efc1082760898e792e0` |
| normalized `ElysiumStorage.o` | `43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8` | `e38636a44a6357ab6b17195cbe81bf56c5ebf8157fb07c30e972087341e16e23` |
| normalized `ElysiumTextInput.o` | `0fcd8840b58e2db50fc3556144417b4615d99f1e7bb75344dd259149dd705bf3` | `d1edea9616bbc18445df21194e4f8f085f25a0466122cb9b35c94f8bcf1a4444` |
| normalized `ElysiumCore.o` | `2f7ebaebc957252ceb8bd76b40fb91fb792b1d19e49b8baa18a66a12215fbd7f` | `22b62d8e311c04dc1a5f0a2f9a726f7d7ab2315a198ba11fe6daca0e7a714932` |
| normalized `Elysium` | `3d7e12decf55ad9ee290d85a5cbc787f6a38a009487d4111df623090692b0927` | `65d8bceba0152dffe13842b85a83d11f934a5cfc05fb94931114d50a7235289f` |
| normalized `elysmoke` | `76aec3dddd9953f5fbf68101212aec4559f00cce0ad00a9780d558c733367134` | `a2f0e6fde18a01df2d764d45b68eab6cad30597568baca9fde690263c14cd08c` |

The storage symbol graph differs from 1.3.0 only in `module.platform.minimumVersion` (14 → 26):
all 362 symbols and 462 relationships are identical. `Saves.swift` changes only the
`ELYSIUM_VERSION` literal. `StorageEngine.swift`, `GameCore.swift`, `Player.swift` and
`ElysiumTextInput.swift` source pins are unchanged; the object pins move because every module
recompiles for the macOS 26 target, and the Elysium product also moves because it now statically
links Atrium.

`swift scripts/sqlite-boundary-scan.swift --root "$PWD" --self-test` passed for 285 production
Swift files, and `bash scripts/verify-elysium-storage-release-surface.sh` verified every source,
capability, caller-boundary, and normalized-artifact pin.

## Window chrome and the AppKit gate

SwiftPM records the deployment target as the binary's SDK version, so 1.4.0 (`minos 26.0`,
`sdk 26.0`) gets the macOS 26 window chrome while 1.3.0 (`sdk 14.0`) got the legacy look. The new
title bar is 32 pt tall. The packaged AppKit text-entry gate used to derive its click geometry
from the whole window frame; with the taller title bar it computed the wrong integer UI scale and
missed **Create World**. `Tests/ElysiumAppKitIntegration/Driver.swift` now measures the game view
(the "Elysium menus and actions" group), exactly as the game lays out its UI. The gate passes
against both the 1.4.0 and the 1.3.0 binaries.
