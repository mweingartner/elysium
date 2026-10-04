# Elysium 1.4.1 release-pin receipt

Version 1.4.1 ships the bundled dinosaur recordings: 108 approved clips (36 species × grazing,
attack and injured) in `packaging/DinosaurSounds`, played through a sample bank in
`Sources/Elysium/Audio.swift`, with a fixed 40-block creature-sound range that follows the
listener. The clips match the SHA-256 values approved on September 26, 2026 in
`Assets/dinosaur-audio/sources.json`. See `docs/dinosaur-audio/build.md` for authoring and
validation.

The values below came from the final warning-free `swift build -c release` on October 4, 2026
(Swift 6.4, swiftlang-6.4.0.34.1), using the gate's `strip -S -x` normalization.

| Surface | 1.4.0 pin | 1.4.1 pin |
| --- | --- | --- |
| `Saves.swift` | `5b4a7a287800e2cb3788f3f09750d9fdff3db342151db4cbed7dd850c9463463` | `9294a42711cfc62b6debb79bb334790ce202bcd480b413e8f21962e2c01940a5` |
| `Saves.swift` compiler-AST inventory | `2c0eb59ce97ad79c98f0074c3fda67591c42ffc11dde2e2380a0b1bb7512df78` | `6f8faed90273b1d55f6973ecf3d90701633f905946b296c1c91cbf2e618f7535` |
| storage-capability manifest | `f922b1211186211a274de565ed7f68517693bbff9ac09efc1082760898e792e0` | `ca7196757bf56adc022268b203057a15286c1cf0314f7c8005c597bd940d7350` |
| normalized `ElysiumCore.o` | `22b62d8e311c04dc1a5f0a2f9a726f7d7ab2315a198ba11fe6daca0e7a714932` | `db906dc579360ddbeafb4845260b62b121ab8854b761a63cbef5fd3875e30a8d` |
| normalized `Elysium` | `65d8bceba0152dffe13842b85a83d11f934a5cfc05fb94931114d50a7235289f` | `de83e175aa15e97a6ce3e154123bd551fc080171891b80b629fdbd45b5c2f700` |
| normalized `elysmoke` | `a2f0e6fde18a01df2d764d45b68eab6cad30597568baca9fde690263c14cd08c` | `1b364a0e8a74affcf13a955bea11471181e7e08947839fbf62d4a720cf0eba84` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. The storage source, symbol graph, API
manifest, `ElysiumStorage.o`, `ElysiumTextInput.o`, `GameCore.swift` and `Player.swift` pins are
unchanged from 1.4.0. Atrium remains at `19eb9407e5cee1e511d2cd3df7e5c4eaacbff7e0`.
