# Elysium 1.2.1 release-pin receipt

The 1.2.1 release updates the shared `ELYSIUM_VERSION` value and both release and
debug package plists. The core value is the exact LAN handshake compatibility
identifier, so existing mixed-version peers fail closed.

On 2026-09-14, the version edit was built with `swift build -c release` without
warnings. The storage boundary scanner was run with `--self-test`; it regenerated
only the canonical parse-AST digest for `Saves.swift`. All artifact values below
were computed from disposable copies using `strip -S -x`, exactly as
`scripts/verify-elysium-storage-release-surface.sh` does.

| Pin | Old SHA-256 | New SHA-256 | Reviewed reason |
| --- | --- | --- | --- |
| `EXPECTED_SAVES_SOURCE_SHA256` | `4018f336ad76cdbf1e9801c40211fb60c79bb24aecee952ce46f3cf5ef21c36c` | `986a9ab68dbf8d6756ed67679a8f39e6e19eaf51fe7e88b27ec35c0f9d81a070` | `Saves.swift` changes only `ELYSIUM_VERSION` from 1.1.1 to 1.2.1. |
| Saves `compilerParseASTSHA256` | `f4c8ab35dce09857859d9cd0e9850decdecdc41d66be3085a784c5731a99e4ec` | `f81d595e7f1bfac3763c6ea9d96a5cec8c7d4e6d81078cc67c5fa66dbadce3ac` | The checked source literal changed. |
| `EXPECTED_CORE_CAPABILITY_SHA256` | `23eb45f111a2be91e6bcb2b0be41bb9fc58b5457bb3af09f8af0d9ad56987dd5` | `e2a5fd029d571bf391cd965be23a433c834a59582ff1850c103eecd9d75943ba` | The capability manifest contains that one renewed AST entry. |
| `EXPECTED_CORE_OBJECT_SHA256` | `6abb2e6677563db8d2e686726c6d2b8ea87bbfda873677d69cfe2399905ce3c6` | `d93b91e1d0924fbc2a0464e1c59c739b85e4b9c992af029796f299223419757c` | ElysiumCore relinks the changed version literal. |
| `EXPECTED_ELYSIUM_PRODUCT_SHA256` | `26282d4a551117051be8ea8120e35f583680e0fd0b2595c30ad3faf19cb4d974` | `d2a98ee5e34eef6feb5836de6c0a7d3444a8329a2ed633430ff272f581d68166` | The app relinks ElysiumCore. |
| `EXPECTED_SMOKE_PRODUCT_SHA256` | `82a8379ead01acaf7c90a6f788c9ca1d49a7179fa9d009525f770b2b3f11eda1` | `272e90997209b31bbb00173400aa8742fbabbde5f2580690c66465c5908abedf` | `elysmoke` relinks ElysiumCore; its 491-check contract is unchanged. |

The storage API manifest, storage and text-input source/object pins, Player source pin,
and GameCore source pin remain byte-identical.
