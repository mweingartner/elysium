# Elysium 1.4.2 release-pin receipt

Version 1.4.2 holds and draws the bow the way Minecraft does (`Sources/Elysium/FirstPersonBow.swift`)
and stops dungeon and cave monsters from droning through rock: the 40-block creature range is now
prehistoric-only and zombie-family groans use a soft voice (`Sources/Elysium/Audio.swift`).

Values from the final warning-free `swift build -c release` on October 4, 2026 (Swift 6.4,
swiftlang-6.4.0.34.1), using the gate's `strip -S -x` normalization.

| Surface | 1.4.1 pin | 1.4.2 pin |
| --- | --- | --- |
| `Saves.swift` | `9294a42711cfc62b6debb79bb334790ce202bcd480b413e8f21962e2c01940a5` | `38b646c1ea1983c0f7104c3d9df353a04cea05b39442180415cf4484dba06479` |
| `Saves.swift` compiler-AST inventory | `6f8faed90273b1d55f6973ecf3d90701633f905946b296c1c91cbf2e618f7535` | `048f2b83daeaedf5fd8606e467e570ec84463c4008b0a430be7b8ffd5f13ac2c` |
| storage-capability manifest | `ca7196757bf56adc022268b203057a15286c1cf0314f7c8005c597bd940d7350` | `ae4018b1c271741c0768684c81ec4fdbb3725e9b12774511033e155eb34a6375` |
| normalized `ElysiumCore.o` | `db906dc579360ddbeafb4845260b62b121ab8854b761a63cbef5fd3875e30a8d` | `77d2c36ddba3ddc64297574b02f18da85b376b023c705b8626f01bd327d11f1b` |
| normalized `Elysium` | `de83e175aa15e97a6ce3e154123bd551fc080171891b80b629fdbd45b5c2f700` | `1613ad21da3116752c4325990c9e65e46991e4a3a5cb75784bf5d57f77afa6fe` |
| normalized `elysmoke` | `1b364a0e8a74affcf13a955bea11471181e7e08947839fbf62d4a720cf0eba84` | `3d57c43a95bbad67cd935f145bb7e03a91a6097c5df39f3498342f6e9801ae71` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal; all other source, storage and text-input
pins are unchanged from 1.4.1. Atrium remains at `19eb9407e5cee1e511d2cd3df7e5c4eaacbff7e0`.
