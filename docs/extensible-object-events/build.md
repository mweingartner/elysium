# Extensible object events release-pin receipt

This receipt records the narrow release-surface pin renewal for the extensible object event,
attribute, handler, editor, and AI-context implementation. The hashes came from one clean,
warning-free release build on 2026-08-27:

```bash
swift package clean
swift build -c release
```

Artifact pins were computed exactly as the release verifier does: copy each artifact from
`.build/out/Products/Release`, make the disposable copy writable, run `strip -S -x`, then run
`shasum -a 256`. Source pins are the plain SHA-256 of the named source file.

| Pin | Old SHA-256 | New SHA-256 | Reviewed reason |
| --- | --- | --- | --- |
| `EXPECTED_GAME_CORE_SOURCE_SHA256` | `ddc3cff991bd611386909d309514189887b923a969470a5cf6e8ed7cf2b82312` | `23d2f5a04f2c5e1cd5981a2cf8394159c40e86670b4ffb7e3348cdb12f71e574` | `GameCore.swift` gained standard-event producer funnels, one-shot `block.toolStrike` production and LAN routing, lifecycle delivery, object-record hydration, built-in attribute observation, script mutation provenance, and exact LAN pickup/experience convergence. |
| `EXPECTED_PLAYER_SOURCE_SHA256` | `3f364dcd4ff040ed8dd0ef7e1eae25abad8de6780c2877a5228eda432df6b3c9` | `79dbd2e132f8e65f2a9857f763c263fea0a1b8cd86fc7db6388fc77129373e10` | `Player.swift` gained the session-only canonical script-event actor identity used to preserve local/LAN provenance. |
| `EXPECTED_CORE_OBJECT_SHA256` | `79d520435f9221c6462f360aaf9df1e6d3a7e48f731cb9414017c415f82e7be5` | `b62b17e26f7edb876771a70a45008e51ed725e3176a869ead4eba75e25cf6f4f` | `ElysiumCore.o` contains the reviewed source changes above and the bounded, indexed custom event/attribute runtime, persistence, object graph, standard producer catalog, LAN metadata, strict Check/live API contracts, transactional event memory accounting, and scripting API. |
| `EXPECTED_ELYSIUM_PRODUCT_SHA256` | `b46cda7a0cc807b04c61a555ed64ad5588bfe4a25b33c9d4acf9fd97953869bf` | `9f84be3823ec9cc8b658ee0cd74d99ab81c5fa6f051fb58da0ad596f5d39eaea` | The Elysium product links the renewed core and adds schema-driven event/member completion, nearby-object guidance, semantic styling, explicitly invoked optional Ollama completion, complete selected-event schemas with truthful nearby-context truncation metadata, and generation-gated main-thread LAN metadata adoption. |
| `EXPECTED_SMOKE_PRODUCT_SHA256` | `71fc4a0089a74e7b71f6bbc02b47ac1c7dc652c15dac4cce02e689a972a638e1` | `0bc8236305b9619cfdd3e1e1dd95362ec3a1b93b37ec20c7469684466b5c22d0` | `elysmoke` links the renewed core and includes the new event/attribute golden-contract checks. Its Appendix A fixture also verifies that camelCase Lua sugar such as `doorRef` is observed under the documented canonical `door_ref` key; the golden trace itself remains unchanged. |

The following reviewed pins remained byte-identical and were deliberately not renewed:

- `EXPECTED_STORAGE_SOURCE_SHA256`
- `EXPECTED_STORAGE_API_SHA256`
- `EXPECTED_STORAGE_OBJECT_SHA256`
- `EXPECTED_SAVES_SOURCE_SHA256`
- `EXPECTED_CORE_CAPABILITY_SHA256`
- `EXPECTED_TEXT_INPUT_SOURCE_SHA256`
- `EXPECTED_TEXT_INPUT_OBJECT_SHA256`

Pre-release verification against this exact source tree included the source security scan, 10,000
protocol mutations, bounded local-safety checks, the SQLite boundary scan over 225 production Swift
files, and a clean warning-free release build. Focused final-tree results were 81/81 runtime tests,
24/24 attribute and built-in tests, 11/11 block-state tests, 180/180 editor/resource tests, and
116/116 LAN replication/routing tests. The release pipeline re-runs the source scan, release build,
complete XCTest suite, the fixed 491-check smoke contract, packaging, AppKit integration, installation,
and installed-bundle identity/signature verification against one immutable source snapshot.
