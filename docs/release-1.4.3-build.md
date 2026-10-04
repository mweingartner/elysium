# Elysium 1.4.3 release-pin receipt

Version 1.4.3 lets true dinosaurs drop 0–2 feathers (plus looting) and keeps chickens on dinosaur
maps for arrow fletching: every land profile's spawn table ends with a chicken entry (about one in
eight land spawns), dawn refill picks chickens with the herbivores up to six per player area, and
generated-entity admission accepts a non-roster mob only when the profile itself spawns it.

Values from the final warning-free `swift build -c release` on October 4, 2026 (Swift 6.4,
swiftlang-6.4.0.34.1), using the gate's `strip -S -x` normalization.

| Surface | 1.4.2 pin | 1.4.3 pin |
| --- | --- | --- |
| `Saves.swift` | `38b646c1ea1983c0f7104c3d9df353a04cea05b39442180415cf4484dba06479` | `e87d37bbf5cf4d763fbc020d39cc2b7da2caad4a4cb92da1c2205a0968efc461` |
| `Saves.swift` compiler-AST inventory | `048f2b83daeaedf5fd8606e467e570ec84463c4008b0a430be7b8ffd5f13ac2c` | `66facece6331fa4a4d14d7c1647ad6fb2b4d4d483b7e24882aedd66ba196bf23` |
| storage-capability manifest | `ae4018b1c271741c0768684c81ec4fdbb3725e9b12774511033e155eb34a6375` | `62dec84f63f0199c776aaa6b936f4e2e53bcd6493863c372fa4578acb0f394c0` |
| `GameCore.swift` | `c697261db513b3652729face7a5ba4f2eb531b1b27417816176bdd0aaa7801ed` | `a3df1d3ae3f1039361b3b59205ec7a6cb16832dc1d916b4002b305ae14b58d6d` |
| normalized `ElysiumCore.o` | `77d2c36ddba3ddc64297574b02f18da85b376b023c705b8626f01bd327d11f1b` | `a936716f2e339b401a4c226a2c46df1bb42ff3ec9e4c49f386c24735cb2978bf` |
| normalized `Elysium` | `1613ad21da3116752c4325990c9e65e46991e4a3a5cb75784bf5d57f77afa6fe` | `883a0240e55faa7661dae0dfea9ca7104c3c64e276146ee86a40ec222549e151` |
| normalized `elysmoke` | `3d57c43a95bbad67cd935f145bb7e03a91a6097c5df39f3498342f6e9801ae71` | `edf92a0ed3d32b5c3280b54198ae31660a3bfa97b36d68c0c03f1c03c175dcf4` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift` changes only the
prehistoric branch of `shouldMaterializeGeneratedEntity`; no checked-player caller changes. Storage,
text-input and `Player.swift` pins are unchanged. elysmoke stays at 491 passing checks.
