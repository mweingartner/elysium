# RPG Progression UI Implementation Plan

**Gate:** Architecture  
**Status:** Track B Builder steps 0...9 and their pre-install Security/Tester gates passed, but installed Design Sign-off remains **FAIL** (2026-07-11). Section 20 Architecture and Security(plan) are **PASS**; Builder completed steps 20.2...20.5 and remediated the first Security(code) review's three findings. The expanded affected debug group passes 180 tests. Renewed Security(code) re-review, fresh installed Design Sign-off, independent full Test, release pins/pipeline/deploy, and installed local-world proof remain pending; Track C remains blocked.
**Human-visible change:** yes; Design Mock, Design Review/Revision, and installed Design Sign-off are mandatory  
**Authoritative contract:** `RPG_CLASSES_PROGRESSION_DESIGN.md`  
**Network contract:** `LAN_RPG_PROTOCOL_V6.md`; this plan consumes its client presentation boundary but does not activate protocol v6

## 0. Architecture revalidation and exact build boundary

Architecture revalidated the clean `feature/lan-shared-state` tree at commit `58fe3d8` before any
new implementation. The exact frozen inputs relevant to this plan were:

- `Package.swift`: `50270ebc175f60239feba2c4f2ba0ce75ee3f26e4fd97c7af1630a0d9000710a`;
- `Sources/ElysiumStorage/StorageEngine.swift`:
  `ae73b775aef8f7e286a47eaae4260d9f63064feb63ec16c916787f32208db5bb`;
- `Sources/ElysiumCore/Game/Saves.swift`:
  `cb1b32c3b973f0486ff6ffc7822086049a0a540d574e96fc6ce7e5b9a78c85e3`;
- `scripts/verify-elysium-storage-release-surface.sh`:
  `ca5fe73a61d812365db78e26fc627614b73e138cc50b5e1336eb7ed9e81a12bb`;
- `LAN_V6_PHASE20B_ADAPTER_PLAN.md`:
  `c7c10539189fe6b8912f952648cea9aeb97dac7067232157a485f23ddbf95325`.

Those hashes are a historical pre-Phase-2.0B record, not the current Builder baseline. Phase 2.0B
subsequently removed SQLite ownership from ElysiumCore and received independent Security code and
Tester PASS. The safe-deferral implementation of `RPG_STORAGE_SURFACE_AMENDMENT_PLAN.md` then
received independent Security code and Tester PASS with local-world storage operational and its
client/host authority surfaces deliberately dormant. This table remains the passed safe-deferral
implementation input baseline; the amendment-plan row is intentionally the pre-checked-API contract
hash and is not rewritten by this planning edit:

| Closed input | SHA-256 |
| --- | --- |
| `RPG_STORAGE_SURFACE_AMENDMENT_PLAN.md` | `dd2f035e0c97228ca871edbdde0156481967902ea460d56cb361a8036ca993ee` |
| `LAN_V6_PHASE20B_ADAPTER_PLAN.md` | `86c87ae1fb2b4ba2e3c710a3ac5d97768aeef7cf7b9e2927d16d4ab86fc50589` |
| `Sources/ElysiumStorage/StorageEngine.swift` | `0a226d3b4a78cbe44738f1111776a2d66f5351c8e9699c078da9fa073b5c3b04` |
| `Sources/ElysiumCore/Game/Saves.swift` | `3d8a9e897046ef1674f7d6db947718c3a73078607151fc4c4abb9e8d1ce30342` |
| `Sources/ElysiumCore/Game/RPGLocalPreferences.swift` | `7cc47fb13e09369d4071e48a1c603a2081c8c09b0bbedeae8ecb992e944a801d` |
| `scripts/elysium-storage-api-v1.json` | `b65f67f5bec8209862221e3a09ff1452501f9a2769e70190d6595f8a36617f22` |
| `scripts/elysium-core-storage-capability-v1.json` | `8c14d434f43b8f7666135aafb4c12dac918f21eadbda76fbcf24333ac1744a1e` |
| `scripts/verify-elysium-storage-release-surface.sh` | `f9889eaed05fa941ee1b332bebcb2ccf2173f7df9267a83447a7f01d90e3458c` |

The current `SaveDB` boundary exposes four Track-B local-world preference operations:

1. `loadRPGQuickSlotPreferences(worldRecordID:)`;
2. `materializeRPGQuickSlotPreferences(worldRecordID:defaults:)`;
3. `compareAndSwapRPGQuickSlotPreferences(worldRecordID:expected:candidatePreferences:)`; and
4. `materializeLegacyRPGQuickSlotPreferences(worldRecordID:legacy:)`.

Step 3 found that compatibility `putPlayer(_:_:) -> Void` swallows failure, and Security then found an
unconditional throwing replacement could overwrite a newer ordinary save. The storage amendment now
authorizes exact full-row checked snapshot/CAS APIs, pending renewed gates:

5. `getPlayerChecked(_:) -> SaveDBPlayerRowSnapshot?`; and
6. `compareAndSwapPlayerChecked(_:expected:candidate:) -> SaveDBPlayerRowSnapshot`.

The Core surface includes concrete 32-byte digest, absent/present expectation, snapshot, and closed
`invalidCandidate`/`invalidStoredRow`/`conflict`/`persistenceFailed` error types. Compatibility
`putPlayer` remains serialized and nonthrowing; no unconditional checked writer exists.
`SaveDBPlayerRowDigest` exposes only exact
`public init(data: Data) throws` with a pre-assignment 32-byte guard; no synthesized/memberwise,
package/SPI, unlabeled, defaulted, unsafe, decoding, or factory initializer exists. Error mapping is
fixed: candidate encode/canonical-string/row failure -> `invalidCandidate`; stored wrong class/UTF-8/
oversize/invalid JSON/non-object root -> `invalidStoredRow`; expectation/digest/row mismatch or missing
parent -> `conflict`; lifecycle/I/O/SQLite/transaction/durability failure -> `persistenceFailed`.

All decode/digest work occurs after the rank-12 storage critical section. The returned
`RPGQuickSlotStorageSnapshot` carries preferences, revision, digest, and immutable migration-origin
digest/revision; the legacy call returns `RPGLegacyQuickSlotMigrationResult`. The storage-amendment
Builder, not the UI Builder, may add only four public ElysiumStorage CAS additions:
`ElysiumPlayerJSONRowDigest`, `ElysiumPlayerJSONExpectedRowState`,
`ElysiumPlayerJSONCompareAndSwapResult`, and
`ElysiumLegacyCoreStorage.compareAndSwapPlayerJSON(expected:candidate:)`. In `Saves.swift` it may add
only the exact checked Core digest/expectation/snapshot/error types plus `getPlayerChecked` and
`compareAndSwapPlayerChecked`. The old section-0 source/API/manifest/verifier hashes remain passed
input evidence and are not rewritten by this plan; new hashes are recorded only after implementation
Security code review and Tester PASS. Any fifth storage addition, other Saves adapter change, or
generic/callback/protocol/`Any`/SQL/capability carrier is unauthorized and stops UI work.

The resulting three-track boundary is now:

1. **Track A — pure foundations.** The evaluator, local-preference values/reducers/codecs,
   `LocalSettingsStore`, pure screen/layout/tutorial/harness models, chord resolver/router model,
   controller reducer, and semantic activation model remain prerequisites to production wiring and
   retain their focused test obligations.
2. **Track B — authorized local production only.** Builder may wire exact-local-world quick-slot
   load/materialization/migration/CAS through the four `SaveDB` calls above; enforce candidate ->
   persist -> publish in `GameCore`; remove quick slots from authoritative/player state only after
   the migration receipt proves the destination and immutable origin and a checked slot-free player
   row save succeeds; wire settings/keybind/tutorial
   persistence; and connect the pure model to the AppKit renderer, shared input router, Controls,
   HUD/entry points, accessibility bridge, isolated harness, and physical RPG-scoped controller
   adapter. `Sources/Elysium/LANTransport.swift` may only project `.unavailable` for a protocol-5 LAN
   client and prove zero `LANRPGIntent`/zero local mutation fallback. This local-production scope may
   proceed through installed Design Sign-off, Test, pipeline, deploy, and installed local-world proof.
3. **Track C — still blocked.** Track B must not add a ElysiumCore client semantic adapter, call or
   wrap `ElysiumStorageCoordinator.clientAuthorityCheckpointV6()`, acquire a client checkpoint facade,
   add a host owner/checkpoint writer, enable host authority persistence, activate protocol v6,
   change cutover/version/quarantine/credentials, publish pending/terminal LAN authority state,
   acknowledge a durable notice, or submit any new LAN RPG authority operation. Those changes require
   the missing reviewed strict client codecs/coordinator, coherent host checkpoint transaction, and
   transport cutover to pass their own Architecture, Security, and Tester gates. Neo/LAN acceptance
   remains Track C.

The current typed v6 identity names remain `LANHostInstallationIDV6` and `LANWorldIDV6`; no Builder
may invent stale aliases. Pure `.lanV6` scope/model fixtures may remain for compile-time continuity,
but Track B production code must reject them before storage or mutation and may not turn dormant
storage primitives into a semantic adapter.

## 1. Purpose and release boundary

This plan replaces the current prototype RPG screen with the complete four-step creation flow and
five-tab progression shell required by the approved design contract. It also separates local quick
slots from authoritative RPG state, makes key chords configurable, adds RPG-scoped controller input,
and exposes the custom Metal UI through a real AppKit accessibility tree.

The implementation is not allowed to make dormant v6 code callable. In particular, this UI change
must not change `LAN_MULTIPLAYER_PROTOCOL_VERSION`, a v6 ready marker, schema cutover, credential
promotion, admission publication, socket routing, v5 quarantine, or any file under
`Sources/ElysiumCore/Net/LANV6*`. The transport/authority phase owns that cutover. The UI consumes one
read-only `RPGAuthorityPresentation` snapshot supplied by the authority layer after that layer has
passed its own gates. If an active LAN client has no installed v6 authority coordinator, the snapshot
is `.unavailable`; the sheet remains inspectable and every authoritative operation is disabled.
Local slot editing remains usable only when the exact writable v6 preference scope/checkpoint already
exists; a protocol-5 client has no such scope and fails slot edits without publication. It must never
fall back to the current optimistic v5 mutation path.

Track B may now complete local-world mutation wiring and the production UI, then proceed through
installed Design Sign-off, Test, pipeline, deploy, and installed local-world verification. In that
scope `RPGAuthorityPresentation` is production-populated only as `.localReady` for an eligible local
world or `.unavailable` for a protocol-5 LAN client; every other authority phase is an immutable
harness/model fixture and is not evidence of an active authority coordinator.

Track C production wiring and Neo/LAN completion remain blocked until the v6 authority implementation
has independently proven:

- client requests are read-only locally and at most one canonical request is pending;
- creation and its starter kit commit atomically on the host;
- owner accept/reject bundles durably commit complete owner state before main-thread publication;
- quick slots are absent from host authority and preserved by client owner apply;
- durable pending/disposition/notification state can supply the presentation cases defined below.

The former Phase-2.0B and local storage-surface blocks are closed by the frozen section-0 baseline.
That closure authorizes consumption of the four local `SaveDB` methods only; it does not authorize
the dormant client checkpoint primitive, any host writer, or any v6 semantic/transport capability.
No Track B build may claim pending/terminal LAN states, LAN authority, Neo completion, or v6 activation.

## 2. Reconciled current-state audit

The implementation begins from these observed facts, not from the intended contract:

| Area | Current source | Required consequence |
| --- | --- | --- |
| Registry | `CharacterProgression.swift` has 6 paths, 18 branches, 54 skills, 19 active skills, and 17 spells | Reuse frozen registry order; do not create a UI-only registry |
| Purchase legality | `rpgLearnSkill` embeds legality; there is no `rpgEvaluateSkillPurchase` | Extract one pure canonical evaluator and make the mutator call it |
| Creation | `RPGScreensM.swift` shows one screen, cycles paths/starters, and permits manual starter-spell selection | Replace with Path -> Branch -> Attributes -> Review; send an empty spell list |
| Sheet | Current tabs are Overview, Skills, Spells, Progress; all spells are listed | Replace with Character, Skills, Actives, Spells, Progression and path-scoped projections |
| Mutation | `drawSheet` repairs live state; skill/spell row clicks learn, prepare, unprepare, or slot | Drawing/model queries become pure; rows select only; every mutation receives its own labeled operation |
| Quick slots | `RPGCharacterState.actionQuickSlots` is encoded, assignment also selects, and owner apply replaces the whole state | Migrate slots to local preferences, omit them from authoritative encoding, and never select on assign/use |
| LAN v5 | client creation mutates/grants a kit before sending; the host creates state without granting the kit | Never route the new sheet through v5; await the reviewed v6 coordinator |
| Input | K/O/L and Shift+digits are hard-coded in `GameCore.keyDown` | Add canonical persisted chords and route all three input modalities through semantic commands |
| Controls | `DEFAULT_KEYBINDS` has 13 one-key entries; Controls is an unclamped fixed two-column list | Add 12 RPG actions and a clamped virtualized list with conflict confirmation and per-action reset |
| Accessibility | `Screen`, `UIManager`, and `GameView` expose no semantic/accessibility substrate | Add bounded descriptors, semantic revisions, activation, and `NSAccessibilityElement` children |
| Controller | No `GameController` import, adapter, or linker entry exists | Add an RPG-scoped adapter only; do not claim general controller gameplay support |
| Tutorial | No tutorial state or UI exists | Add local versioned four-page tutorial, written only by Finish/Skip |
| Proof | Existing screenshot hooks can open `rpg`, but cannot select all deterministic states or dump semantics | Add an allowlisted installed RPG UI harness and retain the existing screenshot path |

## 3. Source ownership and exact file map

### 3.1 New ElysiumCore files

1. `Sources/ElysiumCore/Game/RPGProgressionEvaluation.swift`
   - Owns `RPGSkillPurchaseEvaluation`, `RPGSkillPurchaseFailure`,
     `rpgEvaluateSkillPurchase`, specialization completion math, and level-one guidance.
   - Contains no `Player`, `World`, UI, AppKit, transport, or persistence mutation.

2. `Sources/ElysiumCore/Game/RPGLocalPreferences.swift`
   - Owns bounded `RPGLocalPreferenceScope`, `RPGQuickSlotPreferences`, syntactic/semantic
     normalization, assign/move/clear reducers, and bounded legacy `actionQuickSlots` extraction
     from raw player JSON.
   - Owns no authoritative revision, action sequence, selected action, or LAN message.

3. `Sources/ElysiumCore/Game/RPGScreenModel.swift`
   - Owns all app-independent creation/sheet projections, stable semantic IDs, semantic
     descriptors, bounded geometry/virtualization, focus navigation, tutorial model, installed
     fixtures, and the sole LAN presentation input.

4. `Sources/ElysiumCore/Game/InputChords.swift`
   - Owns canonical chord parsing/formatting, modifier/key domains, binding definitions, conflict
     detection, zero-or-one command resolution, and the pure routing/dedupe state exercised with
     synthetic `performKeyEquivalent`/`keyDown` sources.

5. `Sources/ElysiumCore/Game/RPGControllerInput.swift`
   - Owns the platform-independent controller reducer, thresholds, hysteresis, neutral arming,
     repeat timing, and emitted `RPGSemanticCommand` values. It imports no GameController framework.

6. `Sources/ElysiumCore/Game/LocalSettingsStore.swift`
   - Owns byte-capped, known-field-tolerant settings/keybind decoding and Result-returning atomic
     persistence. No UI mutates published Settings/keybind values before this store succeeds.

### 3.2 Modified ElysiumCore files

1. `Sources/ElysiumCore/Game/CharacterProgression.swift`
   - Removes quick slots from `RPGCharacterState` authority/encoding.
   - Makes `rpgLearnSkill` consume `rpgEvaluateSkillPurchase`.
   - Removes quick-slot helpers that accept/mutate `RPGCharacterState` and replaces action lookup
     helpers with `(state, RPGQuickSlotPreferences)` inputs.
   - Removes implicit selection from action-slot assignment.
   - Replaces the current optimistic `public extension GameCore` `requestRPG*` methods, which mutate
     before sending a v5 intent, with the explicit operation dispatcher owned by `GameCore`; no
     compatibility wrapper may preserve mutate-before-authority behavior for a LAN client.
   - Keeps registration IDs/order and schema-v2 gameplay fields unchanged.

2. `Sources/ElysiumCore/Systems/RPGActions.swift`
   - Removes selection writes from generic action execution.
   - Replaces `rpgUseActionQuickSlot(_:slot:)` with
     `rpgUseActionQuickSlot(_:slot:preferences:)`, resolving an explicit kind/ID and executing it
     without changing authoritative selection.

3. `Sources/ElysiumCore/Game/Settings.swift`
   - Adds the optional, backward-compatible `rpgTutorialVersion` field; quick slots are not a
     process-global setting and never live in this type.
   - Adds the 12 RPG default chords and uses the canonical chord sanitizer for every known action.

4. `Sources/ElysiumCore/Game/GameCore.swift`
   - Owns the current local quick-slot value and its local persistence mode.
   - Owns the checked nonzero world-entry generation and wraps every local preference request/result
     with exact scope, generation, and expected live revision before invoking the closed `SaveDB` API.
   - Owns the current `RPGAuthorityPresentation` snapshot and explicit sheet-operation dispatch.
   - Installs and tests the localReady/protocol-5-unavailable authority/scope guard and semantic
     activation dispatcher before any renderer or input path can carry an actionable command.
   - Routes configured chords instead of K/O/L/Shift-digit literals.
   - Migrates old raw player `actionQuickSlots` only after entering its exact local-world scope,
     before saving a slot-free RPG state; LAN entry never consumes or clears that envelope.
   - Treats the preference receipt as migration-committed only, checked-reads the exact durable player
     row, calls expected-digest CAS with an explicit detached omit candidate in one non-suspending
     main-actor segment, and publishes omission only after success plus second provenance validation;
     compatibility `putPlayer` is forbidden on this path.
   - Dismisses the RPG screen through `GameHost` when `rpgClasses` is disabled.
   - Owns the three `persistAndPublish*Candidate` APIs in section 4.3 and is the only live
     settings/keybind/tutorial publication owner.

5. `Sources/ElysiumCore/Entity/Player.swift`
   - New saves with no pending legacy migration encode the slot-free repaired RPG state.
   - A bounded internal `RPGLegacyQuickSlotEnvelope` retains and re-encodes an old
     `actionQuickSlots` value until its local-world destination and migration marker commit. It is
     cleared only after destination/marker plus expected-old-row CAS and second provenance validation,
     so LAN entry, failed migration, or stale player candidate cannot silently delete it.
   - Gives that envelope a checked nonzero version; migration completion must match both the current
     envelope version and canonical source digest before omission becomes eligible.
   - Adds pure `save(omitLegacyQuickSlots:)`; ordinary `save()` follows live eligibility, while the
     explicit true candidate never mutates the live envelope.

6. `Sources/ElysiumCore/Net/LANMultiplayer.swift`
   - Track B may make only the compatibility edits forced by removing quick slots from the existing
     authoritative/public/player state and update the matching protocol-5 fixtures. It must not add a
     message, intent, semantic adapter, host writer, v6 DTO, checkpoint call, or transport route.

7. `Sources/ElysiumCore/Game/Saves.swift` and `Sources/ElysiumStorage/StorageEngine.swift`
   - A separately gated storage-amendment Builder adds only the exact concrete player digest/
     expectation/result/CAS storage symbols and checked get/CAS Core types/methods. Digest/decode/
     candidate/error work stays outside rank 12; rank 12 contains one get or one transactional CAS.
     The UI Builder calls only the six exact `SaveDB` methods in section 0; it
     never imports `ElysiumStorage`, holds a storage facade, or prepares SQL.
   - Client checkpoint primitives and host row layouts remain dormant storage-only prerequisites.
     Track B adds no ElysiumCore client semantic adapter and no host writer or access path.

### 3.3 New macOS app files

1. `Sources/Elysium/RPGControllerM.swift`
   - Imports `GameController` and adapts compatible physical controller callbacks to the pure
     `RPGControllerInput` reducer.

2. `Sources/Elysium/RPGAccessibilityM.swift`
   - Owns `ElysiumAccessibilityElement`, GUI-to-screen frame conversion, semantic snapshot caching,
     AppKit activation/focus callbacks, and accessibility notifications.
   - Every press-capable cached element retains its full committed origin tuple and dispatches Press
     with that tuple plus a fresh receipt; it never reconstructs activation identity from current UI.

3. `Sources/Elysium/RPGUIHarnessM.swift`
   - Parses only the allowlisted installed-harness environment values, constructs deterministic
     fixtures, and emits bounded sorted semantic summaries. It never edits a world/save.

4. `Sources/Elysium/AppInputRouterM.swift`
   - Is the thin `NSEvent` adapter into the sole pure routing/deduplication path shared by
     `performKeyEquivalent(with:)` and `keyDown(with:)`; neither override contains an independent
     shortcut or screen-routing ladder.

### 3.4 Modified macOS app files

1. `Sources/Elysium/RPGScreensM.swift`
   - Replace the prototype implementation. This file becomes a thin renderer/controller for
     `RPGScreenModel`; it owns no legality, registry filtering, quick-slot authority, or LAN state.

2. `Sources/Elysium/UIManagerM.swift`
   - Add structured key events, semantic snapshot/activation defaults on `Screen`, shared semantic
     revision ownership, focus routing, and dirty notifications.

3. `Sources/Elysium/main.swift`
   - Parse/validate harness mode before constructing GameCore, settings, SaveDB, player, or network
     services; in ordinary mode construct structured modifier-aware key events.
   - Delegate both AppKit keyboard entry points to `AppInputRouter`; preserve only lifecycle wiring
     in `GameView`.
   - Build every nonempty main-menu key equivalent from the shared shipping shortcut catalog, so the
     menu and binding-protection set cannot drift.
   - Own `RPGControllerAdapter` and `RPGAccessibilityBridge` lifetimes.
   - Forward app resign/focus/screen-context transitions to clear controller held state.
   - Delete the shipping `ELYSIUM_RPG_AUTOCREATE` path and replace its proof cases with pure harness
     fixtures; do not broaden ordinary screenshot paths.

4. `Sources/Elysium/MenusM.swift`
   - Replace the Controls fixed list/capture with the virtualized chord editor.

5. `Sources/Elysium/HudM.swift`
   - Resolve the nine displayed actions from `game.rpgQuickSlotPreferences` plus repaired
     authoritative state; no HUD method reads slots from `RPGCharacterState`.

6. `Sources/Elysium/ScreensM.swift`
   - Keep Inventory/Creative Character entry points, but route through one rule/presentation-aware
     open helper and preserve focus when returning.

7. `Sources/Elysium/MenusM.swift`, `Sources/Elysium/HudM.swift`, and
   `Sources/Elysium/RPGScreensM.swift`
   - Use High Contrast and Reduce Motion from `Settings`; no state is conveyed by color alone.

8. `Package.swift`
   - Add `.linkedFramework("GameController")` to the Elysium executable only. ElysiumCore remains
     headless and AppKit/GameController-free.

9. `Sources/Elysium/LANTransport.swift`
   - During Track B, explicitly projects `.unavailable` for a v5 LAN client and clears/rejects
     every new-sheet authoritative submission before the existing `lanRPGIntentHandler`; local-slot
     editing remains separately scoped and rejects without publication when no v6 scope/store
     exists. It does not translate new semantic operations back into `LANRPGIntent`.
   - Its only Track B diff is that zero-fallback boundary and its test seam. Any future coordinator
     presentation/operation boundary is Track C and requires renewed review; the screen never gains a
     socket, frame, request, checkpoint, host writer, or v5 intent callback.

### 3.5 Durable documentation and scripts

- Update `README.md`, `ARCHITECTURE.md`, and `SECURITY.md` in the same logical change.
- Update `RPG_CLASSES_PROGRESSION_DESIGN.md` only to record verified implementation status or an
  explicitly reviewed contract correction; do not weaken its acceptance criteria.
- Preserve section-0 API/capability/verifier hashes as passed input evidence. The storage-amendment
  implementation alone may produce a reviewed API-manifest semantic diff containing exactly the four
  frozen public CAS symbols; a fifth or package/SPI symbol fails. Update capability/scanner/verifier
  hashes only after code Security/Tester PASS. UI code cannot import SQLite3 or prepare SQL.
- Extend `scripts/live-lan-test.sh` only after the v6 authority phase exposes its reviewed probes.
  The UI commit must not invent a test-only network mutation path.

## 4. Core API contract

### 4.1 Sole skill-purchase evaluator

`RPGProgressionEvaluation.swift` adds:

```swift
public enum RPGSkillPurchaseFailure: Equatable {
    case characterNotCreated
    case unknownOrCrossPathSkill(String)
    case authorityRevisionExhausted
    case alreadyAtMaximumRank(String)
    case insufficientLevel(required: Int)
    case insufficientAttribute(RPGAttributeID, required: Int)
    case missingPrerequisite(String)
    case insufficientSkillPoints(required: Int, available: Int)
}

public struct RPGSkillPurchaseEvaluation: Equatable {
    public let skillID: String
    public let currentRank: Int
    public let targetRank: Int
    public let cost: Int?
    public let levelGate: Int?
    public let attributeRequirements: [RPGAttributeRequirement]
    public let prerequisiteSkillID: String?
    public let availableSkillPoints: Int
    public let failure: RPGSkillPurchaseFailure?
    public let effectText: String?
    public let specializationImpact: RPGSpecializationImpact
    public var permitted: Bool { failure == nil }
}

public func rpgEvaluateSkillPurchase(
    _ skillID: String,
    in repairedState: RPGCharacterState
) -> RPGSkillPurchaseEvaluation
```

The function evaluates only `currentRank + 1`; it never repairs or mutates. Its first failure is
exactly: not created, unknown/cross-path, revision exhausted, maximum rank, level, first unmet
attribute in the definition's stored order, immediately previous branch node below rank 2, then
points. `rpgLearnSkill` calls it once, converts its failure to the existing public progression error,
and commits only the returned target rank. No UI code calls `rpgLearnSkill` on a copy.

`RPGSpecializationImpact` contains remaining specialization cost, total points still earnable through
level 20, whether the selected specialization can still complete, and the first missed roadmap
milestone. It uses checked integer arithmetic and the frozen 19-earned/17-specialization/2-utility
proof. It warns about a legal divergence; it never rejects it.

`RPGSpecializationRoadmap` is generated for each of the eighteen branches from its three registered
nodes, never from copied skill IDs. Its selected-branch milestones are exactly: free Foundation I at
creation; Foundation II at level 4; Technique I at 5; Foundation III at 8; Technique II at 10;
Mastery I at 12; Technique III at 14; Mastery II at 16; Mastery III at 20. It displays costs
`0,2,1,3,2,1,3,2,3`, for 17 earned points after the free rank, and the two-point level-20 utility
budget. A cross-branch projection derives the same cells through `rpgMinimumLevel` and
`rpgSkillPointCost`, so its +2 levels/+1 costs and unreachable level-22 Mastery III cannot drift.

`RPGPathProgressionGuidance` is a closed six-case registry, displayed in Creation Review and on
Character through level 1:

- Warden: five causally owned hostile melee defeats (`5 x 10 = 50`), with mitigation as an
  alternative.
- Ranger: seventeen bounded loaded-chunk discoveries (`17 x 3 = 51`).
- Delver: thirteen legal deep excavations (`13 x 4 = 52`).
- Arcanist: nine effect-producing practice casts across bounded windows (`9 x 6 = 54`).
- Mender: nine qualifying provision outputs (`9 x 6 = 54`), with causal support healing as an
  alternative.
- Tinker: one first engineering recipe plus seven outputs (`4 + 7 x 6 = 46`), then one output after
  rollover (`+6 = 52`).

Tests must derive the awards/window caps from the real XP gate and fail if this guidance ceases to be
truthful; the UI never owns a second XP formula.

### 4.2 Local quick-slot value and migration

```swift
public enum RPGLocalPreferenceScope: Hashable, Codable {
    case localWorld(worldRecordID: String)
    case lanV6(hostInstallationID: LANHostInstallationIDV6,
               worldLANID: LANWorldIDV6)
}

public struct RPGQuickSlotPreferences: Codable, Equatable {
    public let tokens: [String?] // normalized to exactly 9
}

public func rpgNormalizeQuickSlotPreferences(
    _ raw: RPGQuickSlotPreferences,
    against repairedState: RPGCharacterState
) -> RPGQuickSlotPreferences

public func rpgAssignQuickSlot(...)
public func rpgMoveQuickSlot(...)
public func rpgClearQuickSlot(...)
public func rpgQuickSlotActions(
    state: RPGCharacterState,
    preferences: RPGQuickSlotPreferences
) -> [RPGPreparedAction?]
```

`RPGLocalPreferenceScope` has custom validating initializers/Codable rather than synthesized decode.
It is resolved once when world entry commits and is passed explicitly through
every load/save/async completion; no callback may look up a mutable "current world". A local scope
accepts only the exact loaded `WorldRecord.id`, 1...64 UTF-8 bytes, and compares it byte-for-byte. It
must not use a world name, seed, display path, or normalized/sanitized derivative. A LAN scope accepts
the reviewed v6 typed identities only: the host installation ID and world LAN ID are each exactly 16
raw bytes (22 unpadded base64url characters only at a textual boundary). It must not use the v5 world
identifier, a server label, address, player name, or either identity alone. This enum is an explicit
routing type, not permission to give both cases the same persistence row.

`GameCore` wraps every local preference invocation and completion in this non-storage provenance;
the four closed `SaveDB` signatures remain unchanged:

```swift
public enum RPGExpectedLivePreferenceRevision: Equatable, Sendable {
    case absent
    case exact(UInt64)
}

public struct RPGLocalPreferenceRequestContext: Equatable, Sendable {
    public let scope: RPGLocalPreferenceScope          // `.localWorld` only in Track B
    public let worldEntryGeneration: UInt64            // checked, nonzero
    public let expectedLiveRevision: RPGExpectedLivePreferenceRevision
}

public struct RPGLocalPreferenceCompletion<Value> {
    public let context: RPGLocalPreferenceRequestContext
    public let result: Result<Value, Error>
}
```

`worldEntryGeneration` is a process-local `GameCore` session generation, initialized unavailable at
zero and advanced with checked `addingReportingOverflow(1)` for every committed world entry and every
world teardown/replacement, including leaving and re-entering the same `WorldRecord.id`. It never
resets or wraps. Overflow latches RPG local persistence unavailable for the process and issues no
request. Every read, default materialization, legacy materialization, and CAS request captures the
exact nonzero generation, exact local scope, and expected live revision; the completion returns the
same context rather than consulting the current world.

Before any preference completion may publish, advance migration state, increment a preference/semantic revision, or
post a notification, main-thread `GameCore` revalidates all of: active generation equality; exact
scope equality; `.absent` versus the still-absent live value or `.exact(n)` versus the still-live
revision `n`; returned world ID; and operation-specific revision/digest postconditions. Any mismatch
discards the completion byte-for-byte with no retry/merge/replay. Thus leave/re-enter of the same
world cannot create an ID-equal ABA acceptance.

A retained `RPGLegacyQuickSlotEnvelope` also owns a checked nonzero `envelopeVersion` advanced on
decode/replacement and never wrapped. Legacy materialization captures that version plus the canonical
source digest. On completion, `GameCore` revalidates the current envelope's version and source digest,
the request context, the receipt's source digest, and the returned snapshot's immutable migration-
origin digest/revision against the receipt marker. Only that exact match may publish the snapshot and
mark the envelope migration-committed but still non-omittable. Omission requires the separate checked
player-row phase below. A changed/cleared/redecoded envelope, same-world re-entry, stale live revision,
or origin mismatch retains/re-encodes the legacy key and publishes nothing.

Only `.localWorld` may address `rpg_local_preferences_v1`. That standalone non-authoritative table
allows one row per exact local world, 256 rows total, 4,096 encoded bytes per row, and 1 MiB aggregate.
Each row contains schema version, exactly nine normalized tokens, a checked local revision, and a
payload digest. Its separate legacy-migration marker table is likewise local-world-only and bounded
to one marker per local row under the same aggregate quota. A `.lanV6` scope passed to either table
API is a typed error before SQL is prepared. Reads exceeding any bound fail closed without publishing
a partial value.

This local-world paragraph and the migration transaction below are the complete Track B persistence
authorization. The following `.lanV6` checkpoint paragraphs are retained as a Track C contract only;
Track B neither implements their semantic codec/adapter nor obtains their dormant storage facade.

In Track C, `.lanV6` quick slots are backed exclusively by the frozen
`LANClientOwnerCheckpointRowV1` selected by
the exact typed host installation ID plus world LAN ID. That one checkpoint generation atomically
contains the acknowledged owner snapshot, local nine-slot value, credentials/counters, durable
pending/disposition state, and bounded notice inbox. No parallel `rpg_local_preferences_v1` row,
marker, settings fallback, or slot-only transaction exists for LAN.

In Track C, LAN assign/move/clear and owner-apply normalization each load one complete checkpoint generation,
derive one complete candidate aggregate, and commit it with the checkpoint's generation compare-and-
swap. The CAS changes the owner/slots/credentials/pending/inbox aggregate and its digest/generation as
one unit even when only slots differ. A stale generation reloads presentation and requires a fresh
user activation; it never merges or replays a slot edit onto newer owner/security state. Only after
CAS success may `GameCore` publish the new aggregate or acknowledge owner/notice work. Any encode,
disk, transaction, CAS, or postcondition failure leaves both the stored and live prior aggregate
byte-for-byte unchanged across every field and projects `persistenceFailure`.

Normalization accepts only unique bounded `skill:<id>`/`spell:<id>` tokens naming currently prepared
active skills or prepared known spells, retains intentional nil positions, and never autofills an
explicit nine-slot value. A missing local-world row may receive the old save's bounded slot array
once; if both are missing, defaults fill stable prepared-action order once and persist the resulting
explicit nine slots. Once a local row exists, an all-nil array is meaningful and remains all nil. A
Track C LAN scope uses its checkpoint slot value, or materializes defaults inside the whole-checkpoint CAS
when absent; it never imports, marks, or clears `RPGLegacyQuickSlotEnvelope`. There is no process-
global/settings fallback that can leak one world's slots into another. Owner apply normalizes the
runtime LAN value only inside its complete checkpoint candidate, removing only tokens that no longer
name an acknowledged prepared action.

Remove `actionQuickSlots` from `RPGCharacterState` authority, equality, repair, and all owner/public
DTOs, but migrate the old player JSON transactionally:

1. `Player` bounded decoding accepts only an array of at most nine nil/string values, each token at
   most 128 UTF-8 bytes and the total legacy field at most 2,048 bytes. It retains a canonical
   `RPGLegacyQuickSlotEnvelope` containing the normalized value and source digest. Until migration
   commit is confirmed, every player save re-encodes that legacy key.
2. After local-world entry has captured its exact `.localWorld` scope, one storage-executor
   transaction reads the
   destination, writes it if absent, and writes a separate migration-marker row containing scope,
   source digest, chosen destination digest/revision, and schema version. Destination plus marker
   commit in the same transaction. The preference row stores that chosen digest/revision as an
   immutable migration-origin pair. If a destination already exists, it wins; the marker binds its
   current digest/revision as the origin and the legacy value is not allowed to overwrite it.
3. After the preference transaction returns committed and its receipt passes the section-4.2 session/
   envelope/origin checks, `GameCore` may publish the destination but records the live envelope only
   as migration-committed; it remains non-omittable and ordinary `player.save()` still includes
   `actionQuickSlots`.
4. In one main-actor non-suspending segment, `GameCore` revalidates, calls `getPlayerChecked`, validates
   any present stored envelope, captures absent or exact full-row digest, builds detached
   `player.save(omitLegacyQuickSlots: true)`, then synchronously calls
   `compareAndSwapPlayerChecked`. The storage transaction fixed-time compares the actual old row
   digest before INSERT/UPDATE. Any prior compatibility/ordinary/shutdown writer causes conflict and
   the newer durable row remains unchanged; a writer ordered afterward is a later write.
5. Only CAS success followed by a second main-thread scope/generation/live-revision/envelope-
   version/source-digest/origin validation publishes the live envelope omittable. A crash before the
   CAS commit restarts from the old row with the key. A crash after the CAS slot-free row
   commits but before live publication restarts safely from that row plus durable destination/marker.
   Current preference payload/revision may advance while preserving the immutable origin; stale
   completion never overwrites newer slots or publishes omission into another session.

The two digests use versioned, domain-separated canonical bytes. The source digest is SHA-256 over
`Elysium/RPGLegacyQuickSlots/source/v1`, then a length-prefixed source-envelope version and exactly
nine slot encodings. The destination digest uses
`Elysium/RPGLocalQuickSlots/destination/v1`, then the length-prefixed canonical scope encoding,
destination schema/revision, and exactly nine slot encodings. Every slot is encoded with an explicit
nil/value tag; values are UTF-8 byte-length-prefixed canonical tokens. All integer lengths are
fixed-width big-endian and checked before allocation. Neither digest hashes JSON text, dictionary
order, display names, normalized world names, or platform-native integer bytes.

Local assign/move/clear/migration/default materialization follow candidate -> validate -> one
local-world row transaction -> publish. In Track C only, LAN assign/move/clear/default materialization/owner
normalization follow complete checkpoint candidate -> generation CAS -> publish. A failure preserves
the prior live value/revision and projects `persistenceFailure`; no UI may imply success. Track B tests
cover two local worlds with equal names/different IDs, local migration crash cuts, rapid local-scope
delayed-completion mixups, and protocol-5 zero storage calls. Track C owns the LAN host/world cross-
product and checkpoint encode/disk/transaction/CAS/postcondition byte-preservation matrix.

Assign, move, clear, and quick-slot use do not change `selectedPreparedActionID`,
`selectedPreparedSpellID`, `authorityRevision`, `actionSequence`, owner revision, inventory revision,
or LAN pending state. Generic `rpgPrepareAction` must also stop writing selected action; explicit
Select and Cycle remain the only selection mutations.

### 4.3 Bounded, field-tolerant settings and keybind persistence

`LocalSettingsStore` replaces direct `Data(contentsOf:)`/`try?`/best-effort writes with explicit
`Result` APIs:

```swift
public func loadSettings() -> Result<Settings, LocalSettingsStoreError>
public func persistSettings(_ candidate: Settings) -> Result<Void, LocalSettingsStoreError>
public func loadKeybinds() -> Result<[String: String], LocalSettingsStoreError>
public func persistKeybinds(_ candidate: [String: String]) -> Result<Void, LocalSettingsStoreError>
```

`GameCore` is the sole main-thread publication owner and exposes these named candidate-copy APIs;
callers never mutate a live `Settings`, keybind dictionary, or tutorial field in place:

```swift
@MainActor
public func persistAndPublishSettingsCandidate(
    _ candidate: Settings, expectedLiveRevision: UInt64
) -> Result<UInt64, LocalSettingsStoreError>

@MainActor
public func persistAndPublishKeybindCandidate(
    _ candidate: [String: String], expectedLiveRevision: UInt64
) -> Result<UInt64, LocalSettingsStoreError>

@MainActor
public func persistAndPublishTutorialVersionCandidate(
    _ candidateVersion: Int, expectedLiveRevision: UInt64
) -> Result<UInt64, LocalSettingsStoreError>
```

Settings and keybinds each have a checked nonzero live revision; tutorial publication shares the
settings revision because it persists in the settings document. Each API first byte-copies the live
value, rejects a stale expected revision or checked revision exhaustion, derives and fully sanitizes
one candidate without changing the live copy, persists the candidate through `LocalSettingsStore`,
and only after success atomically replaces the live value and returns the incremented revision.
`LocalSettingsStoreError` includes closed `staleLiveRevision` and `revisionExhausted` results. No
failure path assigns the candidate, increments a live or semantic revision, marks UI dirty, rebuilds
the semantic model, or posts AppKit/value/layout/VoiceOver notifications.

The reader consumes at most 262,145 bytes for settings and 16,385 bytes for keybinds and rejects the
cap-plus-one sentinel before JSON parsing; accepted documents are at most 256 KiB and 16 KiB. The
root must be a JSON object. Each known settings field is decoded independently from its bounded JSON
value: one malformed known field falls back only that field and records a bounded diagnostic;
missing fields use defaults; unknown fields are ignored. A malformed root or over-cap document
returns failure and is never silently overwritten during load.

Before Foundation object decoding, a bounded JSON structural scanner permits at most 32 nesting
levels, 2,048 total tokens, 512 object members, 256 array elements, 128 UTF-8 bytes per key, and
8,192 UTF-8 bytes per string scalar. It validates UTF-8, string escapes, delimiter balance, and
number-token length without materializing an unbounded object graph. Exceeding any structural limit
fails the load as invalid input; tests exercise exact limits, limit-plus-one, deep and wide inputs,
and a printed fixed-seed corpus.

Keybind decoding produces exactly the 25 entries in stable `KEYBIND_DEFINITIONS` order (13 existing
plus 12 RPG). Each stored chord must be a string of at most 64 UTF-8 bytes accepted by the canonical
parser. Unknown action keys are dropped, missing keys use that action's default, and one malformed
known chord falls back only that action. Persist rejects extra/missing actions, duplicate semantic
commands, non-string values, overlong output, or any noncanonical/protected chord before writing;
normal UI edits first construct the exact sanitized 25-key candidate.

Writes use a same-directory uniquely created temporary file, bounded canonical encoding, complete
write, file sync, atomic rename, and parent-directory sync through the repository storage abstraction.
Every create/write/sync/rename error is returned; temporary files are removed on failure where safe,
and no `try?` can convert failure into success. Settings/keybind/tutorial/chord state always follows
candidate -> validate -> persist -> publish. On failure the old live value remains active and the UI
projects `persistenceFailure`. Tutorial Finish/Skip publishes the seen version only after persistence
succeeds. Quick slots use the local-world row transaction or complete LAN checkpoint-generation CAS
in section 4.2 and are never routed through this file store.

On load, `rpgTutorialVersion` sanitizes to zero independently when missing, negative, the wrong JSON
type/malformed, or greater than `RPG_TUTORIAL_VERSION`; only an integer in
`0...RPG_TUTORIAL_VERSION` survives. Finish and Skip call only
`persistAndPublishTutorialVersionCandidate`; dismissal/navigation does not write or publish it.

Tests cover empty/missing files, exact caps and cap-plus-one, malformed/non-object roots, unknown
fields, one bad known field among valid peers, hostile nesting/arrays/numbers, invalid UTF-8,
overlong chords, protected chords, all 25 defaults, stable canonical output, and injected temporary
create/write/file-sync/rename/directory-sync failures. Restart tests require either the complete old
document or complete new document, never a truncated/mixed value, and prove failed persistence does
not publish slots, tutorial version, or chords.

Integration fault tests call each of the three named publication APIs and inject candidate encode/
validation, temporary create, partial/complete write, file sync, rename, directory sync, stale live
revision, and revision-exhaustion failures. After every failure they compare byte-identical live
settings/keybind/tutorial state, unchanged live and semantic revisions, unchanged dirty count, and
zero value/layout/VoiceOver notification intents. Tutorial load tests cover missing, `-1`, malformed
string/object/fractional values, and `RPG_TUTORIAL_VERSION + 1`, all sanitizing exactly to zero while
valid peer settings fields survive.

### 4.4 Explicit operations

```swift
public enum RPGSheetAuthoritativeOperation: Equatable {
    case create(RPGCreationDraft)
    case rankUp(skillID: String)
    case spendAttribute(RPGAttributeID)
    case prepareSkill(String)
    case unprepareSkill(String)
    case prepareSpell(String)
    case unprepareSpell(String)
    case selectSkill(String)
    case selectSpell(String)
}

public enum RPGSheetLocalOperation: Equatable {
    case assignSlot(token: String, slot: Int)
    case moveSlot(from: Int, to: Int)
    case clearSlot(Int)
    case tutorialBack
    case tutorialNext
    case tutorialFinish
    case tutorialSkip
}
```

Every visible mutation maps to one of these cases. Path/branch/card/rank/action/spell/slot selection,
hover, scrolling, focus, tab change, and inspector expansion are presentation commands, not mutation.
The Skills inspector alone exposes `Rank Up`. Actives and Spells expose distinct Prepare, Unprepare,
Select, Assign Slot, and Clear Slot controls as applicable. Unknown/unlearned actions expose `View in
Skills`, which changes tab/selection only. There is no row-wide mutation or double-click shortcut.

### 4.5 One LAN authority presentation boundary

```swift
public enum RPGAuthorityPresentationPhase: Equatable {
    case localReady
    case awaitingHost
    case committingAcceptedOwnerCheckpoint
    case committingRejectedOwnerCheckpoint
    case reconnecting
    case awaitingDispositionCheckpoint
    case authorityExhausted
    case unavailable
}

public enum RPGStatusKind: String, Equatable {
    case success, pending, rejection, cooldown, fatigue
    case missingFocus, missingEquipment, permissionDenied
    case persistenceFailure, authorityExhausted
}

public enum RPGStatusOperation: Equatable {
    case sheet(RPGSheetAuthoritativeOperation)
    case saveQuickSlots
    case cyclePreparedAction
    case usePreparedAction
    case useQuickSlot(Int)
}

public enum RPGStatusTarget: Equatable {
    case character
    case skill(String)
    case spell(String)
    case attribute(RPGAttributeID)
    case slot(Int)
    case equipment(String)
    case permission(String)
}

public enum RPGStatusPersistence: Equatable {
    case localUntilReplaced
    case authorityPhase
    case durableInboxPendingRender
    case durableInboxAcknowledged
}

public enum RPGStatusAcknowledgementEligibility: Equatable {
    case never
    case afterCommittedModelRevision(UInt64)
    case acknowledged
}

public enum RPGDurableNoticeStatus: String, Equatable {
    case accepted
    case rejected
    case outcomeEvicted
    case requestExhausted
}

public struct RPGDurableNoticeIdentity: Equatable {
    public let notificationID: String // exactly 64 lowercase hexadecimal characters
    public let payloadDigest: String  // exactly 64 lowercase hexadecimal characters
}

public struct RPGDurableNoticePayload: Equatable {
    public let identity: RPGDurableNoticeIdentity
    public let status: RPGDurableNoticeStatus
    public let reason: String  // at most 256 UTF-8 bytes as received
    public let message: String // at most 512 UTF-8 bytes as received
}

public enum RPGStatusIdentity: Equatable {
    case local(counter: UInt64, operationTag: String)
    case authorityPhase(requestFingerprint: String, phase: RPGAuthorityPresentationPhase)
    case durable(RPGDurableNoticeIdentity)

    public var stableID: String { get }
}

public struct RPGStatusPresentation: Equatable {
    public let identity: RPGStatusIdentity
    public let operation: RPGStatusOperation
    public let target: RPGStatusTarget
    public let kind: RPGStatusKind
    public let text: String
    public let persistence: RPGStatusPersistence
    public let acknowledgement: RPGStatusAcknowledgementEligibility
}

public struct RPGAuthorityPresentation: Equatable {
    public let phase: RPGAuthorityPresentationPhase
    public let requestIdentity: String? // nil only for localReady/unavailable; otherwise exactly 64 lowercase hex
    public let operation: RPGSheetAuthoritativeOperation?
    public let status: RPGStatusPresentation?
    public let semanticRevision: UInt64
}
```

This value, including its request identity and optional status, is the sole pending/LAN/terminal-notice input to
`RPGScreenModel`. The screen must not inspect sockets,
transport state, request IDs, checkpoints, replay caches, peer records, or v5/v6 types. The authority
coordinator maps its durable state to this snapshot:

Track B production supplies only `.localReady` for an eligible local world and `.unavailable` for a
protocol-5 LAN client. It implements the complete pure enum/model/presentation switch and all harness
fixtures so the UI can be designed and tested, but it does not persist, receive, acknowledge, or
publish any other phase. Every pending/commit/reconnect/disposition/exhaustion production mapping and
the authority coordinator sentence below are Track C only.

`requestIdentity` is absent only for `.localReady` and `.unavailable`. Every other phase carries the
exact coordinator-owned request fingerprint as 64 lowercase hexadecimal characters; construction
rejects any other length/alphabet and a phase/identity mismatch. The screen treats it as an opaque
semantic-input component and never displays, parses, persists, or acknowledges it.

| Authority state | Presentation phase | Authoritative controls | Local slots |
| --- | --- | --- | --- |
| single-player local / reviewed Track C host ready | `localReady` | enabled by semantic legality | assign/move/clear enabled; use is authoritative and separately gated |
| request durably pending | `awaitingHost` | all disabled, including slot use | assign/move/clear enabled |
| accepted bundle validating/committing | `committingAcceptedOwnerCheckpoint` | all disabled, including slot use | assign/move/clear enabled |
| rejected bundle/resync validating/committing | `committingRejectedOwnerCheckpoint` | all disabled, including slot use | assign/move/clear enabled |
| disconnected with durable pending | `reconnecting` | all disabled, including slot use | assign/move/clear enabled |
| disposition-only/evicted awaiting request-zero | `awaitingDispositionCheckpoint` | all disabled, including slot use | assign/move/clear enabled |
| terminal revision/counter exhaustion | `authorityExhausted` | permanently disabled, including slot use | move/clear already-valid tokens only |
| LAN client without reviewed coordinator | `unavailable` | disabled; no v5 fallback, including slot use | assign/move/clear enabled only with an exact writable v6 preference scope; a protocol-5 client has none and fails without publication |

`rpgAuthorityPhasePresentation` is an exhaustive switch over all eight phases and returns one frozen
`RPGAuthorityPhasePresentation` containing `proceduralIconID`, `visibleTitle`, `visibleHelp`, optional
`disabledControlExplanation`, and `voiceOverAnnouncement`. The authority phase chip remains visible
even when an operation status/notice is also present. These are the exact non-color mappings:

| Harness selector / phase | Procedural non-color icon and shape | Exact visible title | Exact visible help and authority-disabled-control explanation | Exact VoiceOver announcement |
| --- | --- | --- | --- | --- |
| `ready` / `localReady` | `authority.ready` (outlined check) | `Ready` | `Character controls are available when their requirements are met.` Authority supplies no disabled-control explanation; a disabled operation shows only its exact canonical evaluator reason. | `Ready. Character controls are available when their requirements are met.` |
| `pending` / `awaitingHost` | `authority.awaitingHost` (outlined hourglass) | `Awaiting host` | `Character changes are disabled until the host responds. Local quick slots remain available.` | `Awaiting host. Character changes are disabled until the host responds. Local quick slots remain available.` |
| `acceptedCommit` / `committingAcceptedOwnerCheckpoint` | `authority.savingAccepted` (disk outline with check) | `Saving accepted update` | `Character changes are disabled while Elysium saves the accepted host update. Local quick slots remain available.` | `Saving accepted update. Character changes are disabled while Elysium saves the accepted host update. Local quick slots remain available.` |
| `rejectedCommit` / `committingRejectedOwnerCheckpoint` | `authority.savingRejected` (disk outline with cross) | `Restoring host state` | `Character changes are disabled while Elysium restores the host’s character state. Local quick slots remain available.` | `Restoring host state. Character changes are disabled while Elysium restores the host’s character state. Local quick slots remain available.` |
| `reconnecting` / `reconnecting` | `authority.reconnecting` (two opposed circular arrows) | `Reconnecting` | `Character changes are disabled until the connection and pending request recover. Local quick slots remain available.` | `Reconnecting. Character changes are disabled until the connection and pending request recover. Local quick slots remain available.` |
| `disposition` / `awaitingDispositionCheckpoint` | `authority.finalizing` (inbox outline with solid dot) | `Finalizing host response` | `Character changes are disabled while Elysium finishes processing the host response. Local quick slots remain available.` | `Finalizing host response. Character changes are disabled while Elysium finishes processing the host response. Local quick slots remain available.` |
| `exhausted` / `authorityExhausted` | `authority.exhausted` (octagonal stop outline) | `Authority exhausted` | `Character changes are permanently disabled for this character session. Valid local quick slots may still be moved or cleared.` | `Authority exhausted. Character changes are permanently disabled for this character session. Valid local quick slots may still be moved or cleared.` |
| `unavailable` / `unavailable` | `authority.unavailable` (closed padlock outline) | `Character changes unavailable` | `Character changes are unavailable in this LAN session. Quick-slot editing requires a compatible host session.` | `Character changes unavailable. Character changes are unavailable in this LAN session. Quick-slot editing requires a compatible host session.` |

The presentation switch and all visible/accessibility assertions reject internal implementation
terms in these sinks. In particular, visible title/help, disabled reasons, accessibility value/help,
and VoiceOver announcements may not contain `owner checkpoint`, `request-zero checkpoint`,
`reviewed v6 coordinator`, `v5 fallback`, or `owner session`; those terms remain internal-only.

For every non-ready phase, every otherwise-legal authoritative descriptor, including Cycle, Use
Selected, and Use Quick Slot, copies the table's exact
help sentence into its visible focused/hovered reason and its accessibility help; it is not
tooltip-only. The phase title precedes that reason in the fixed status band. Local slot controls do
not inherit an authority-disabled reason only for Assign/Move/Clear and retain their separate local
legality, except the documented exhaustion restriction. Slot use is authoritative gameplay and
never shares that exemption. For `localReady`, the harness uses an otherwise-legal operation
and asserts it is enabled; if another operation is disabled by gameplay legality, only the canonical
evaluator reason appears.

The phase matrix assumes the separate local-preference precondition. `.unavailable` does not mint a
scope: a protocol-5 client has no typed v6 host/world identity and therefore exposes Assign/Move/
Clear as persistence-disabled, leaves its legacy envelope untouched, and submits no operation. A v6
client that already has the exact reviewed host/world scope and writable complete checkpoint may keep
those local controls enabled even while its authority coordinator presentation is unavailable.

The icon/title chip is a focusable informational descriptor and never actionable. Its full
`visibleHelp` appears, without ellipsis, in a bounded wrapped authority-help panel directly below the
18-unit fixed icon/title band whenever the chip or an authority-disabled control is focused/hovered.
The panel uses the exact required wrapped height up to 72 units, reduces/reclamps the content viewport
rather than overlapping it, and is sufficient for the longest table sentence at 360x224. Harness
visual assertions focus the chip, so all eight exact help sentences are present in draw output at
every required viewport.

The phase chip is an accessibility group labeled `RPG authority`, with value equal to the exact
visible title and help equal to the exact visible help. A phase transition posts the exact VoiceOver
announcement in the table once; a byte-identical rebuild does not reannounce. Icon geometry, title,
help, disabled reason, accessibility value/help, and announcement are all derived from this single
switch. High Contrast thickens/duplicates the listed geometry and color may supplement it, but no
phase may change or lose its shape/text distinction.

Every status initializer rejects a greater-than-64-byte symbolic target, a slot outside 0...8, or an
empty/greater-than-160-byte already-sanitized display string. Local IDs are checked monotonic
`local:<counter>:<operation-tag>` identities owned by `GameCore`; operation tags are a closed enum at
construction and never parsed from UI text. Phase IDs are deterministically derived by the authority
coordinator from a bounded request fingerprint and phase. A durable identity accepts only exactly 64
lowercase hexadecimal characters for both `notificationID` and `payloadDigest`; uppercase,
whitespace, prefixes, shorter/longer strings, and non-hex characters fail closed. UI drawing never
invents an ID or parses one back into authority.

The durable payload status is the closed four-case `RPGDurableNoticeStatus`. Its raw `reason` is at
most 256 UTF-8 bytes and raw `message` at most 512 UTF-8 bytes before storage; neither is allowed to
select a UI icon, role, command, target, or acknowledgement. The authority adapter alone maps the
closed status plus the locally known operation/target to `RPGStatusKind`: `accepted -> success`,
`rejected -> rejection`, `outcomeEvicted -> rejection`, and
`requestExhausted -> authorityExhausted`. The payload digest is verified over the protocol's raw
canonical payload bytes before any display sanitization.

The status band uses the following closed non-color mapping. The icon and leading text are mandatory;
color is supplementary:

| Kind | Procedural icon ID | Required leading visible/VoiceOver text | Replacement/persistence |
| --- | --- | --- | --- |
| `success` | `status.check` | `Success` | local until next attempted operation, or durable inbox until projected/acknowledged |
| `pending` | `status.hourglass` | `Awaiting host` | authority-phase status; survives close/reopen/disconnect |
| `rejection` | `status.cross` | `Rejected` | local until replaced, or durable inbox terminal |
| `cooldown` | `status.clock` | `Cooldown` | local until replaced; includes remaining bounded seconds |
| `fatigue` | `status.fatigue` | `Not enough fatigue` | local until replaced; includes required/available values |
| `missingFocus` | `status.focus` | `Focus required` | local until replaced; names either-hand requirement |
| `missingEquipment` | `status.equipment` | `Equipment required` | local until replaced; names the bounded equipment class |
| `permissionDenied` | `status.lock` | `Permission denied` | local/durable rejection; names build/container/PvP policy only |
| `persistenceFailure` | `status.diskWarning` | `Could not save` | persists until a successful retry/replacement; never implies commit |
| `authorityExhausted` | `status.stop` | `Authority exhausted` | permanent for that owner/session; never offers retry |

Each rendered string is `required leading text + ": " + bounded operation/target detail`. Host text
passes through two independent sinks after digest verification. The display sanitizer removes C0/C1
controls and bidi-format controls (`U+061C`, `U+200E...U+200F`, `U+202A...U+202E`, and
`U+2066...U+2069`), converts line separators/newlines to spaces, collapses whitespace, and truncates
at a Unicode-scalar boundary within the 160-byte total. The accessibility sanitizer independently
removes/replaces the same controls, produces one line, and caps its result at 512 UTF-8 bytes; it does
not reuse either raw text or the display buffer. Empty sanitized host text is omitted. High Contrast
changes icon outline and border pattern as well as color. No kind may share only a color distinction.

`GameCore` holds exactly one current local/authority status projection. A newly accepted operation
replaces the prior local status with pending; a synchronous rejection replaces it immediately;
accepted/rejected durable terminal status replaces the matching pending status only after the client
checkpoint commits. Closing/reopening the sheet, resizing, drawing, and owner request-zero do not
clear it. The durable inbox is capped per exact LAN host/world scope at 256 rows and 1,048,576 encoded
bytes, and exposes only its oldest `pendingRender` row, keeping the screen model bounded to one
status. Insertion is idempotent only for the same exact notification ID and payload digest. The same
ID with a different digest is a protocol violation: retain the existing row, publish no replacement,
send no acknowledgement, fail the current authority operation closed, and terminate the offending
session through the reviewed coordinator. Full row/byte capacity rejects the new notice without
evicting an unacknowledged row.

Acknowledgement requires a model-commit receipt. `UIManager.commitSemanticModel` atomically installs
the main-thread screen model and accessibility snapshot, increments/records its semantic revision,
and returns `(screenInstanceID, semanticRevision, notificationID, payloadDigest)`. Only that exact
receipt may change the matching presentation to
`afterCommittedModelRevision(semanticRevision)`. A digest-checked storage transaction then marks the
same row acknowledged and the protocol acknowledgement may be emitted; only after commit does the UI
project `acknowledged`. Receiving, decoding, building, returning from a builder, drawing, screenshot
capture, or an uncommitted accessibility rebuild is ineligible. A changed screen/revision/ID/digest
requires a new committed receipt. Local and phase statuses are always `never`.

`UIManager` maintains a 32-identity FIFO of status announcements for the current process. On a new
identity, or a local/phase identity whose checked kind/text changes, it posts the AppKit VoiceOver
announcement notification with the independently sanitized icon-independent accessibility text;
success/pending use normal priority and rejection/failure/exhaustion use high priority. A durable
identity is announced at most once per process for an identical digest. Byte-identical model rebuilds
do not reannounce. A durable row replayed after process restart announces again, satisfying
at-least-once visible/audible delivery. Tests prove exact hex/digest/status/text bounds, controls and
bidi sanitization at both sinks, closed mapping, 256-row/1-MiB capacity, same-ID/same-digest
idempotence, same-ID/different-digest fail-closed behavior, replacement, close/reopen persistence,
committed-revision acknowledgement, crash cuts, replay, and VoiceOver announcement intent for every
kind.

Synchronous local accept/reject immediately rebuilds the model but is not represented as a fake
pending phase. Closing/reopening the sheet never clears pending or status.

## 5. Pure screen and creation model

### 5.1 Stable types

`RPGScreenModel.swift` defines:

- `RPGCreationStep`: `.path`, `.branch`, `.attributes`, `.review`.
- `RPGCharacterTab`: `.character`, `.skills`, `.actives`, `.spells`, `.progression` in that order.
- `RPGUIElementID`: a bounded `RawRepresentable<String>` with factory methods only. Rank IDs are
  `skill:<skillID>:rank:<1...3>`; operation IDs append `:operation:<name>`; tabs, creation steps,
  paths, branches, attributes, actions, spells, tutorial pages, and slots have distinct prefixes.
- `RPGCreationSession`: current step/path plus exactly six registry-ordered per-path drafts.
- `RPGPathCardModel`: path ID, `rpgAssetIDForPath` icon ID, display name, full role summary,
  registry-ordered primary-attribute labels, all five preset values, selected state, wrapped visual
  lines, full accessibility label/help, frame, focus selection, and explicit Choose command.
- `RPGScreenSelection`: selected semantic ID and inspector item.
- `RPGScrollState`: one finite offset per creation pane/tab/branch/Controls pane.
- `RPGScreenModelInput`: repaired authoritative state; local quick slots; the exact optional
  `RPGLocalPreferenceScope`, checked world-entry generation, preference revision, and writable flag
  captured at world-entry commit; authority presentation; checked RPG-rules generation; inventory revision; equipment/focus
  revision; creation session; tutorial state; viewport; tab; selection; offsets; High Contrast;
  Reduce Motion. These values are one immutable main-thread snapshot and are the only inputs to the
  semantic-input fingerprint; the model never reads a mutable GameCore/player/store value.
- `RPGScreenModel`: header/status/footer, visible draw elements, complete semantic descriptors,
  inspector, enabled operations, content/viewport/offset metrics, and the next focusable ID.
- `RPGSemanticDescriptor`: ID, role, group ID, label, value, help/reason, selected/prepared/slotted,
  enabled/locked, `isFocusable`, optional presentation-only `focusSelection`, logical frame, visible
  frame, and optional explicit `actionCommand`. `isActionable` is derived as
  `actionCommand != nil && enabled`; focusability and actionability are never aliases.

All collections have registry-derived caps. Model creation uses frozen arrays and sorted/stable IDs;
no unordered Dictionary/Set iteration affects output. Inputs with nonfinite or sub-minimum viewport
values fail to a bounded error model. Building/drawing/querying the model never repairs or writes
Player/GameCore/Settings/LAN state.

### 5.2 Four-step creation reducer

`rpgInitialCreationSession()` starts on Path with Warden selected and its exact
`rpgCreationPreset`. `rpgReduceCreationSession` implements only selection/edit/back/next/reset:

1. **Path** renders all six definitions. First visit to a path stores its preset. A later visit
   restores that path's branch and edited attributes. Next requires a selected registered path.
   Every card contains, in this order: the 24x24 `rpgAssetIDForPath(path.id)` icon; display name;
   visible `Role: <path.summary>`; visible `Primary: <attributes>`; visible
   `Preset: STR n · DEX n · END n · INT n · LUCK n`; and selection state. The exact source values are:

   | Path | Role text | Primary | Preset |
   | --- | --- | --- | --- |
   | Warden | Armor, shield timing, threat control, and short-range protection. | STR + END | STR 11 · DEX 7 · END 10 · INT 7 · LUCK 7 |
   | Ranger | Bows, scouting, terrain movement, ambushes, and survival fieldcraft. | DEX + LUCK | STR 7 · DEX 11 · END 8 · INT 7 · LUCK 9 |
   | Delver | Mining, traps, underground navigation, lockwork, and risky treasure work. | STR + END | STR 10 · DEX 8 · END 10 · INT 7 · LUCK 7 |
   | Arcanist | Fatigue-driven spellcasting, illusions, creations, wards, and rituals. | INT + END | STR 6 · DEX 8 · END 8 · INT 12 · LUCK 8 |
   | Mender | Healing, food efficiency, antidotes, protective rites, and rescue timing. | INT + LUCK | STR 6 · DEX 8 · END 10 · INT 10 · LUCK 8 |
   | Tinker | Redstone devices, automation, gear mods, explosives, and compact tools. | INT + DEX | STR 7 · DEX 10 · END 8 · INT 10 · LUCK 7 |

   Attribute display order is always STR, DEX, END, INT, LUCK; primary order remains the path's
   registry order. Selected cards show all three non-color cues: `status.check`, literal `Selected`,
   and a two-pixel double border. Unselected cards expose a literal `Choose <Path>` operation and no
   selected cue. Color is supplementary. At compact width, role and preset use the shared bounded
   wrapper at the exact card inner width; card height grows to retain every wrapped line, and the
   two-column pane virtualizes the resulting equal row height. No role, primary, or preset text is
   ellipsized. The accessibility label is `<Path>, selected|not selected`; help is the full unwrapped
   `Role; Primary; Preset` text plus `Choose <Path>` when unselected. Tests compare all six visible
   strings/icon IDs/presets/selection cues and full help at all three viewports and prove no wrapped
   line overlaps another card or becomes actionable outside its full frame.
2. **Branch** uses `path.branchIDs` in registry order. Its free starter is exactly
   `branch.skillIDs[0]`; it must also occur in `path.starterSkillIDs`. A registry mismatch disables
   Next with `Starter registry mismatch` and is a failing test, never a zip/fallback. The card shows
   Foundation rank-1 benefit, passive/active kind, and spell unlocks whose rank is 1.
3. **Attributes** edits only 6...14, exact total 42. It shows remaining/over budget, Reset to Preset,
   and the first unmet selected-Foundation requirement. Next uses the canonical creation validator.
4. **Review** derives the exact starter kit via `rpgStarterKit`, auto-known/prepared spells from the
   Foundation rank-1 unlocks, focus requirement, level-one guidance, configured chords, controller
   scope, inventory-capacity caveat, and host-authority caveat. Create constructs
   `RPGCreationDraft(pathID:attributes:starterSkillID:starterSpellIDs: [])`.
   The authority caveat is context-bound exact copy, visible and repeated as accessibility help:
   `.localReady` uses `Create saves this character and starter kit to this world.`;
   `.unavailable` uses `This LAN host does not support character creation. Your draft will not be
   submitted.` No Track B context uses host-authoritative, protocol, version, request, or coordinator
   wording. Harness and installed assertions compare these exact strings.

Back from Path closes. Escape backs one step before closing. Accepted creation rebuilds from the
acknowledged/repaired owner; rejected creation retains all local drafts and focuses Create/reason.

### 5.3 Five-tab projections

- **Character:** path, specialization, level/absolute XP and next threshold, fatigue, five
  attributes, derived stats, SP/AP, next actionable milestone, and level-one guidance while level 1.
- **Skills:** only the current path's three branches in `path.branchIDs` order. Each branch has its
  three nodes and exactly three rank cells per node. Purchased cells, future cells (`Requires prior
  rank`), and the exact-next evaluator cell are distinct. The inspector shows exact delta, cost,
  selected/cross gate, requirements, prerequisite, canonical reason, and specialization impact.
- **Actives:** only current-path skills whose definition kind is active, in global skill registry
  order. Rows state learned/prepared/selected/slotted/cooldown/fatigue and link to their Skills node.
- **Spells:** only spells appearing in a spell unlock owned by a current-path skill, in spell
  registry order. Each row names every exact unlocking skill/rank and circle, INT, fatigue,
  target/range, known/prepared/selected/slotted state. Paths with no reachable spell show the
  non-caster empty state.
- **Progression:** exactly levels 1...20 with absolute thresholds, earned SP/AP, roadmap purchases,
  actual completion, banked points, attribute milestones, next legal purchase, and divergence
  warning. The roadmap is guidance and never a hidden gate.

Six deterministic installed fixtures must each project 3 branches, 9 nodes, and 27 rank cells. The
aggregate must project 6/18/54/162 with 162 unique rank-cell IDs and exact registry coverage. A live
screen/accessibility tree contains only its path's 27 cells; it never attaches the aggregate.

## 6. Layout, virtualization, and focus contract

### 6.1 Fixed metrics

All layout is calculated by pure `rpgBuildScreenModel`; drawing, hit testing, controller focus, and
accessibility consume the same rectangles.

- Outer margin: 6 GUI units.
- Panel: `min(700, viewportWidth - 12)` by `min(420, viewportHeight - 12)`, centered, with a minimum
  logical size of 348 by 212 at the required 360x224 probe.
- Header: 24; step/tab bar: 20; status band: 18; footer: 26. These four bands never scroll.
- A focused/hovered authority chip or authority-disabled control reserves a wrapped help panel of
  the exact needed height, capped at 72, at the top of content; the remaining content rectangle is
  recomputed and reclamped. The panel never overlays or ellipsizes its exact phase sentence.
- Content is the exact remaining rectangle after that optional panel. Interactive elements require their entire frame to be
  inside either content or their fixed band; partially clipped controls are non-actionable.
- Large mode requires both width >= 520 and height >= 330. Compact mode is used otherwise.
- Row/card strides: 28 for list rows, 38 for compact cards, 20 for rank cells, 22 for Controls rows.
- Scroll wheel/keyboard/controller increments are one stride; focus reveal uses the minimum delta.

Large Path is a 3x2 grid; compact Path is two columns. Large Branch is three columns; compact Branch
is three full-width cards. Large Attributes/Review uses two panes when the content rectangle is wide
enough; compact uses one virtual pane. Skills always identifies three branches: at 360 each is one
equal-width column (minimum 104) with its inspector below the column strip; at larger sizes the
inspector uses the right/lower available pane without changing semantic order.

### 6.2 Virtualization and clamping

The model retains complete stable row descriptors but emits draw/hit elements only for rows whose
full rectangle intersects the viewport. Accessibility retains all 27 path-valid rank descriptors.
Every content measure uses checked finite `Double` arithmetic and registry caps.

One `rpgClampedScrollOffset(contentHeight:viewportHeight:requested:)` function is used after open,
resize, GUI scale, step/tab/filter/content change, inspector expansion, rank/prepare mutation, owner
ack/resync, tutorial transition, and focus reveal. Empty/short content is exactly zero. Scrollbars use
the same content/viewport/offset tuple. Tests cover 360x224, 520x330, 700x420 and seeded widths/heights
between them.

### 6.3 Semantic focus

`RPGSemanticCommand` is the only keyboard/controller/accessibility command vocabulary:

```swift
case moveFocus(RPGFocusDirection)
case focusNext
case focusPrevious
case activate
case back
case previousTab
case nextTab
case scrollRows(Int)
case openCharacter
case cyclePreparedAction
case useSelectedAction
case useQuickSlot(Int)
```

Tab/Shift-Tab traverses every `isFocusable` descriptor in stable semantic order; it does not filter
on `enabled` or `isActionable`. Arrows are spatial within grids/columns. Informational rows, locked
nodes, purchased rank cells, the current rank, exact-next rank cells, and future/requires-prior-rank
cells are focusable so their complete value/reason/help is reachable. Rank cells have no
`actionCommand`: focus (or a mouse click) may update the presentation-only inspector selection, but
Enter/Space/VoiceOver Press does not buy a rank. Only a distinct visible `Rank Up` descriptor with an
enabled command is actionable. The same rule applies to Prepare, Unprepare, Select, Assign, Move,
Clear, Create, Spend Attribute, tutorial controls, tabs, and close/back controls: only their explicit
enabled descriptors carry action commands.

Enter/Space/VoiceOver Press invokes `actionCommand` only when `isActionable`; a focusable descriptor
without one announces its information and performs no mutation. Focus retains the same ID after a
model rebuild even when it becomes locked/nonactionable. If the ID disappears, choose the nearest
preceding focusable element in the prior stable order, then the first focusable element; never skip a
locked/informational cell merely because it is not actionable. Every focus move reveals via the
shared clamp. Mouse selection updates the same focus ID. No second focus system exists for controller
or VoiceOver.

Traversal tests enumerate forward and reverse focus order for all six paths at 360x224, 520x330, and
700x420. Each run must encounter all 27 path rank IDs exactly once, including purchased, current,
locked, and future fixtures; activating each nonactionable cell must leave RPG state, local slots,
pending state, settings, and semantic revision unchanged except for inspector/focus presentation.

### 6.4 Revision-bound semantic activation

Every mouse click, Enter/Space press, controller activation, and AppKit accessibility Press reaches
one dispatcher with the same capture:

```swift
public struct RPGSemanticActivationCapture: Equatable {
    public let activationReceipt: UInt64
    public let screenInstanceID: UInt64
    public let id: RPGUIElementID
    public let semanticRevision: UInt64
    public let commandFingerprint: String
    public let semanticInputFingerprint: String
}

UIManager.dispatchSemanticActivation(
    _ capture: RPGSemanticActivationCapture,
    source: RPGSemanticActivationSource
) -> RPGSemanticActivationResult
```

The command fingerprint is the 64-lowercase-hex SHA-256 of the descriptor's bounded canonical
`actionCommand` encoding, including operation and target IDs; it is not derived from label/help text.
The semantic-input fingerprint is a separately domain-separated SHA-256 over a bounded canonical
capture containing the exact local-preference scope, RPG-rules generation, RPG authority revision,
checked world-entry generation, expected live preference revision, operation-required owner and
inventory revisions, authority phase plus request identity, and the
operation-specific expected state (for example current/target rank, prepared/known/selected state,
slot token/revision, or creation-draft digest). The committed screen model and this exact gameplay/
authority input snapshot publish atomically on main; no dispatcher constructs the fingerprint from
mutable state after the capture. `activationReceipt` is deliberately excluded from both fingerprints:
it identifies a fresh user activation, while the fingerprints continue to identify the unchanged
semantic command and committed semantic input.

`UIManager` is the sole receipt generator. On main, each genuine fresh mouse press, nonrepeat
keyboard activation, controller activation edge, or AppKit accessibility Press advances a private
process-global `lastIssuedActivationReceipt` with checked `UInt64.addingReportingOverflow(1)` from
zero and captures the resulting nonzero value. A receipt is never copied into a later press, reset on
screen/world replacement, synthesized from an event or semantic fingerprint, or reused after a stale
result. If checked generation overflows or would produce zero, `UIManager` latches activation-receipt
exhaustion for the process; that and every later activation fail closed without capture, rebuild,
command, routing serial, mutation, or authority request.

Mouse assigns the receipt on button-down and verifies that capture on button-up. Keyboard,
controller, and accessibility assign a new receipt from the same committed descriptor immediately
before dispatch. OS key repeat and controller repeat timing do not manufacture a fresh activation
receipt for mutation. No modality may call a screen closure, reducer, `GameCore`, or authority
coordinator directly.

On dispatch, before fetching a screen or performing any semantic revalidation, `UIManager` first
requires a nonzero receipt issued by its generator and atomically consumes it on main. Consumption
updates a scalar `highestConsumedActivationReceipt` and a recent-consumed FIFO plus membership set;
the FIFO/set contains at most the latest 64 receipts, evicting the oldest together, while the scalar
permanently rejects every receipt less than or equal to its high-water mark even after FIFO eviction.
A zero, unissued, already-present, or at-or-below-high-water receipt returns a replay/invalid result
without rebuild, command, routing serial, mutation, or authority request. Because capture and dispatch
are main-thread serialized, a newer receipt consumed before an older issued receipt makes the older
receipt stale permanently. The first valid attempt consumes its receipt even if later descriptor,
fingerprint, target, rule, or authority revalidation fails; replaying that capture can therefore never
dispatch after a subsequent rebuild. A genuine later user press receives a new receipt and may be
evaluated against the then-current model.

Only after receipt consumption does `UIManager` re-fetch the current screen and committed descriptor
by ID. Semantic revisions are checked process-global monotonic values and are never reset on screen
replacement; the current screen must still own the captured screen instance, revision, ID, command
fingerprint, and semantic-input fingerprint from the now-consumed activation tuple. The descriptor must
still be focusable, actionable, enabled, and carry that exact command. It then re-resolves the
registered target, current rule enablement, current prepared/known/equipment/focus prerequisites,
captured local-preference scope, authority/request identity, expected operation state, and current
`RPGAuthorityPresentation` legality. Authoritative
commands require `localReady`; local slot commands require the exact captured scope and a writable
store. After all revalidation succeeds, the dispatcher allocates one checked routing serial and
submits the re-resolved command at most once. The routing serial remains a separate counter and
at-most-once ledger from activation receipts: receipt consumption proves one activation attempt;
routing-serial consumption prevents a successfully validated attempt from fanning out twice. Routing-
serial exhaustion also fails closed without mutation or authority request. The dispatcher never
trusts an enabled bit captured from an older model.

Any screen/revision/fingerprint/target/authority/rule mismatch performs at most one bounded model
rebuild, returns `.staleRequiresFreshActivation`, and submits nothing. It never translates the old ID
to a new target and never auto-replays after rebuild. A fresh user press is required. For an offscreen
descriptor, focus/reveal happens first; if that commits a different semantic revision, the original
Press is rejected with the same fresh-activation rule. Normal VoiceOver focus reveals before its
subsequent Press, so the ordinary path remains one Press on a currently committed element.

Tests interleave capture/dispatch with owner acknowledgement, rule disable, path/tab/screen change,
rank purchase, prepare/unprepare, slot scope switch, equipment/focus loss, target removal, offscreen
reveal, semantic-revision exhaustion, activation-receipt exhaustion, routing-serial exhaustion, and
receipt replay before and after 64-entry FIFO eviction. They run every interleaving through mouse,
keyboard, controller, and accessibility and assert identical results, a distinct nonzero receipt for
each genuine fresh activation even when both fingerprints are byte-identical, consumption before
failed revalidation, zero mutation for stale/replayed/invalid captures, and at most one mutation/
authority request for a valid activation.

## 7. Configurable chord and Controls contract

`InputChords.swift` adds `ElysiumKeyModifiers` (Command, Control, Option, Shift),
`ElysiumTerminalKey`, `ElysiumKeyChord`, `ElysiumKeyEvent`, and `KEYBIND_DEFINITIONS`. Modifier tokens
and terminal tokens are distinct domains. The terminal allowlist is exactly the physical terminal
values in `KEYCODE_MAP` plus legacy synthesized `ShiftLeft` and `ControlLeft`; bare `Command`,
`Control`, `Option`, and `Shift` are modifiers and can never be terminal keys. The two synthesized
legacy terminals are accepted only as complete one-key legacy chords, preserving Sneak/Sprint; forms
such as `Shift+ShiftLeft` or `Control+ControlLeft` reject.

Parsing is limited to 64 UTF-8 bytes, one allowlisted terminal key, unique modifiers, and canonical
`Command+Control+Option+Shift+Key` order. Legacy one-key strings canonicalize unchanged. Empty,
unknown, modifier-only, repeated modifier, empty segment, non-canonical modifier order, and
multiple terminal-key values fall back only the affected action.

`SHIPPING_MENU_COMMANDS` is the sole definition table for main-menu items with nonempty key
equivalents. `main.swift` maps its command IDs to selectors and builds those `NSMenuItem`s from the
table; headings/About remain empty and are excluded. The reviewed table is exactly Command+Q (Quit),
Command+C (Copy Object Template), Command+V (Paste/Place Template), and Command+M (Minimize).
`PROTECTED_APP_CHORDS` is derived as every chord whose terminal is F11, every chord in that shipping
menu table, plus exact Command+Z (app undo). Thus it explicitly includes Command+Q, Command+C,
Command+V, Command+M, and Command+Z.

At app startup and in tests, recursive enumeration of the constructed main menu's nonempty key
equivalents must equal the catalog set exactly; any new/changed nonempty shipping menu equivalent is
therefore protected automatically or fails construction/testing before settings load. Binding
capture rejects every protected chord with `Reserved by Elysium`; `Use Anyway` is never offered. Load
sanitization falls back only the affected action, persistence rejects a candidate containing one,
and dispatch never sends one to screen/world binding resolution. The same immutable protected set is
passed to `LocalSettingsStore`, Controls capture, and `AppInputRouter`; no layer keeps a copied subset.

Append these exact defaults to `DEFAULT_KEYBINDS`:

- `rpgCharacter = KeyK`
- `rpgCycleAction = KeyO`
- `rpgUseAction = KeyL`
- `rpgQuickSlot1...9 = Shift+Digit1...9`

`AppInputRouterM.swift` is the one AppKit event router. Both
`GameView.performKeyEquivalent(with:)` and `GameView.keyDown(with:)` call
`appInputRouter.route(event:source:)`; neither override checks F11, Command shortcuts, Escape,
screens, bindings, or gameplay independently. The router sends a full `ElysiumKeyEvent` to a new
`Screen.onKeyEvent` hook; the existing `onKey` default remains for non-RPG screens. `GameCore.keyDown`
is removed as a raw-event fan-out; `GameCore` receives at most one already resolved command.

The router runs this exact precedence:

1. Compute `AppKeyEventFingerprint` from event number, key code, timestamp rounded to microseconds,
   window number, device-independent modifier bits, repeat flag, and event origin. If a consumed
   fingerprint is already in the dedupe FIFO, consume without dispatching again.
2. Handle nonrepeat F11 globally; consume a repeat without invoking the action.
3. Evaluate nonrepeat Command+C/V/Z through the existing object-template shortcut eligibility
   (world loaded, no open screen, matching operation available). Consume only when the shortcut
   commits/open succeeds; otherwise continue so a focused field/system key equivalent is not stolen.
4. Before any screen or binding resolution, return every unconsumed shipping-menu equivalent as
   `.unhandledForMainMenu`. Command+Q and Command+M always take this path; ineligible Command+C/V do
   too. Both AppKit entry points return unhandled/super without inserting a consumed fingerprint, so
   the main menu remains the sole Quit/Minimize fallback and no binding can observe the chord.
5. Return any remaining protected non-menu chord, currently an ineligible Command+Z, unhandled to
   AppKit/super before screen or binding resolution.
6. If a screen exists, call `screen.onKeyEvent` first for every key, including Escape. If handled,
   stop.
7. Only then, for unhandled Escape, close a `closeOnEsc` screen and recapture if clear. Next evaluate
   the configured inventory-close behavior for eligible non-text screens.
8. With no screen, call the canonical resolver once for map/HUD/template-independent and world
   bindings, then send its optional single command through the semantic/world dispatcher once;
   otherwise return unhandled to AppKit/super.

The dedupe FIFO holds at most 16 consumed fingerprints and expires entries after 250 monotonic
milliseconds. An unconsumed `performKeyEquivalent` event is not inserted, so later `keyDown` can
handle it. A consumed physical event delivered to both entry points dispatches exactly once.
`flagsChanged` updates `ElysiumKeyModifiers` and may emit a legacy `ShiftLeft`/`ControlLeft` terminal
edge with a checked local serial and `.synthesizedLegacy` origin; that terminal fingerprint cannot
alias the physical event, and changing a modifier never masquerades as a terminal key.

Discrete actions use exact chord matching. An unmodified legacy movement binding remains active
while ordinary modifiers are held, but a more-specific exact chord wins and consumes the event.
Therefore the configured Shift+digit action runs once and leaves the hotbar unchanged, while a digit
with no matching modifier selects the normal hotbar. Repeats never submit an RPG mutation.

`resolveKeyCommand(event:context:bindings:) -> ResolvedKeyCommand?` is the sole binding resolver and
returns zero or one command. Protected chords are handled by the router and never become binding
candidates. `Screen.onKeyEvent` calls this resolver exactly once and, when it returns an activation,
routes only the resulting semantic capture through section 6.4. While a screen is open, only that
screen's semantic context participates; world/hotbar/
movement candidates cannot fall through behind it. With no screen, candidates are ordered by:

1. exact modifier match over the legacy unmodified-movement compatibility match;
2. the closed context priority `appHUD > RPGWorldAction > hotbar > movement`;
3. stable `KEYBIND_DEFINITIONS` index.

The first candidate wins; conflict presentation names every candidate and the exact current winner.
Even after an explicit same-chord `Use Anyway`, this order is deterministic. One resolver call has a
checked routing serial, and the command dispatcher rejects a second dispatch with that serial, so one
physical/synthesized edge can cause at most one command and at most one mutation. No later `if`
ladder independently checks the same key in `GameCore`, HUD, or RPG screen code.

Controls uses the binding-definition order (13 existing, then 12 RPG = 25). Below width 520 it is a
single virtualized column; otherwise two columns share one clamped vertical offset. Each row exposes
binding, full chord, conflict text, Capture, and Reset. Capture displays every modifier; Escape
cancels. A conflict writes nothing and reveals all conflicting action IDs plus a distinct `Use
Anyway` control. Only activating `Use Anyway` commits the chord; starting another capture cancels the
pending conflict. Reset restores only that action's default. Save runs through sanitized keybinds.
Tests cover every pairwise collision across all 25 definitions and legacy movement/hotbar contexts,
recursive equality between every nonempty constructed shipping-menu equivalent and the protected
catalog, and for each such chord: capture rejection, per-action load fallback, persistence rejection,
and dispatch to its app action or `.unhandledForMainMenu` before any binding. They also cover
Command+Z/F11 protection, exact Shift+digit precedence, both AppKit callbacks, legacy synthesized
modifier terminals, repeats, screen/world exclusion, deterministic winner copy, one routing serial,
one resolved command, and one mutation maximum.

## 8. RPG-scoped controller adapter

`RPGControllerM.swift` observes compatible `GCController` connect/disconnect notifications and
dispatches callbacks to main. It feeds normalized values/edges to the pure reducer. Scope and copy
must say `RPG menus and actions`; it must not claim movement, camera, inventory, crafting, or general
gameplay controller support.

Every installed callback captures the controller's stable object identity plus checked adapter and
context generations. Main-thread delivery validates all three before entering the reducer.
Disconnect, active-controller replacement, app focus loss, and screen/world-context change first
remove handlers and clear held/repeat state, then advance the appropriate generation. Delayed
callbacks from an earlier generation are ignored. The most recently producing connected compatible
controller becomes active only after a neutral sample; another connected controller cannot emit
commands until it wins the same neutral-then-input arbitration.

The reducer uses these fixed values:

- stick/D-pad navigation enter magnitude 0.60, exit 0.35;
- trigger enter 0.65, exit 0.45;
- scroll repeat delay 300 ms, repeat interval 90 ms, maximum 8 repeats per callback catch-up;
- one physical edge emits at most one activate/world mutation command;
- connect, disconnect, app focus loss, screen transition, and world/sheet context transition clear
  repeats and require every relevant control to return neutral before rearming.

Mappings are exactly:

- Sheet: D-pad/left stick focus; A activate; B back/close; shoulders previous/next tab; right-stick
  vertical scroll.
- World: Options open Character; left shoulder cycle; right shoulder use selected.
- Left trigger held: slots 1...4 D-pad Up/Right/Down/Left; slots 5...8 Y/B/A/X; slot 9 right-stick
  click. Slot commands are suppressed until trigger and destination control have both crossed neutral
  after a context change.

Controller glyph help becomes primary only after a real controller command, but keyboard help stays
visible. Synthetic tests do not satisfy installed controller proof.

## 9. AppKit accessibility bridge

`Screen` receives default-empty `semanticSnapshot`, `focusSemanticElement`, and `semanticRevision`.
Accessibility activation is not a screen callback: it constructs the section 6.4 capture and calls
the sole `UIManager.dispatchSemanticActivation`. Each press-capable cached
`ElysiumAccessibilityElement` stores the complete origin tuple from one atomically committed model:
`(screenInstanceID, semanticRevision, ID, commandFingerprint, semanticInputFingerprint)`, plus its
layout generation, viewport, and descriptor. It does not look up or substitute any tuple component
from the current screen when Press occurs. Nonactionable elements expose no Press action.

`UIManager` invalidates the current cache on explicit model/layout commits, not on every draw frame,
but an old `NSAccessibilityElement` reference remains origin-bound: invalidation never rewrites its
tuple in place. Its Press constructs `RPGSemanticActivationCapture` with that exact cached origin
tuple and a newly issued activation receipt, then enters the section 6.4 consume-before-revalidate
dispatcher. A same-ID element from a replacement screen instance, a same-ID newer semantic revision,
a changed command/semantic-input fingerprint, or any other stale cached element must reject and
require the caller to fetch the newly committed accessibility element.

`RPGAccessibilityBridge` makes `GameView` an accessibility group and publishes main-thread
`ElysiumAccessibilityElement` children. GUI top-left frames convert through UI scale, backing scale,
view/window coordinates, then `window.convertPoint(toScreen:)`. Descriptors map to AppKit roles:
buttons, static text, tabs/tab group, groups, rows, and scroll areas. Labels, values, rank,
selected/prepared/slotted, enabled/locked, canonical reason/help, and press action are populated.

All 27 live path rank cells remain children even when offscreen; other paths' 135 cells do not.
Focusing an offscreen element calls the screen's semantic focus/reveal path and rebuilds layout. A
direct Press received before that focus commit follows section 6.4: reveal, reject the stale capture,
and require a fresh Press rather than acting under old geometry/authority. The Skills root announces
current path and `3 branches, 9 skills, 27 ranks`.
Tests retain old accessibility element references across same-ID screen replacement, same-screen
semantic revision/fingerprint change, tab replacement, and offscreen focus/reveal. Pressing each old
reference consumes its fresh activation receipt but dispatches zero command/mutation; only a newly
fetched element carrying the newly committed full origin tuple may activate.
The visible focus ring uses the same semantic focus ID for mouse, keyboard, controller, and
accessibility.

After committed transitions only, post:

- focused-element-changed for semantic focus;
- value-changed for accepted local/owner value updates;
- layout-changed for tab/step/tutorial/viewport/content changes.

High Contrast changes border width/pattern and fill as well as color. Reduce Motion removes tutorial
and selection interpolation; state changes and focus rings remain. Installed VoiceOver inspection is
mandatory because pure descriptor tests cannot prove the AppKit bridge.

## 10. Tutorial and installed harness

`RPG_TUTORIAL_VERSION = 1`. `Settings.rpgTutorialVersion` is optional; missing, negative, malformed,
or future unsupported values sanitize to zero. When a created character first enters an accepted
sheet with a lower seen version, show four pages:

1. rank Foundation/Technique/Mastery branch skills;
2. prepare and explicitly Select actions;
3. choose and assign a local quick slot;
4. close and use configured keyboard/controller chords.

Back/Next/Finish/Skip are ordinary semantic controls. Only Finish/Skip persists version 1. Opening,
closing, crash, or progressing to an intermediate page writes nothing. Creation appears first for an
uncreated character; an accepted Create then opens the tutorial. First-XP guidance remains on
Character at level 1 regardless of tutorial status.

Harness detection is the first bootstrap decision in `main.swift`, before any `GameCore.shared`,
`SaveDB`, `StorageEngine`, `LocalSettingsStore`, player/world loader, audio engine, controller monitor,
LAN socket/listener, or background task is constructed. `RPGUIHarnessBootstrap.parseIfPresent` reads
a bounded environment snapshot and returns either ordinary mode, one fully validated fixture, or a
bounded fatal harness diagnostic. When `ELYSIUM_RPG_UI_CASE` is present, the complete allowed
`ELYSIUM_` key set is exactly:

- `ELYSIUM_RPG_UI_CASE`;
- `ELYSIUM_RPG_UI_AUTHORITY`;
- `ELYSIUM_RPG_UI_VIEWPORT`;
- `ELYSIUM_RPG_UI_APPEARANCE`;
- `ELYSIUM_RPG_UI_SEMANTIC_SUMMARY`;
- optional `ELYSIUM_SHOT`, solely for an explicitly requested screenshot output.

Any other `ELYSIUM_` key, including autoload/new-world/command/LAN/probe/bot/AI/debug/open-screen and
the retired `ELYSIUM_RPG_AUTOCREATE` family, rejects the entire harness invocation before side
effects; values are never combined and ordinary mode is not used as fallback. The shipping
`pendingRPGAutoCreate` state, parser, and `runRPGAutoCreateIfNeeded` mutator are removed. Creation
step/review coverage comes only from immutable fixture profiles.

Harness environment inspection accepts at most 64 total environment entries, 4,096 aggregate UTF-8
bytes across keys and values, 128 bytes per key, and 512 bytes per value except the 192-byte case
selector and the screenshot value below. Exceeding any bound rejects before side effects.

The installed harness accepts one closed case selector of at most 192 UTF-8 bytes:

`ELYSIUM_RPG_UI_CASE=<case>`, where `<case>` is exactly one of:

- `creation:<path|branch|attributes|review>:<pathID>:<branchID>:<preset|editedValid|underBudget|unmetRequirement|inventoryFull>`;
- `tutorial:<1|2|3|4>:<pathID>:<branchID>`;
- `tab:<pathID>:<branchID>:<character|skills|actives|spells|progression>`;
- `skill:<skillID>:<1|2|3>:<purchased|current|nextLegal|locked|future>`;
- `active:<skillID>:<unknown|known|prepared|selected|slotted>`;
- `spell:<spellID>:<locked|known|prepared|selected|slotted>`;
- `slots:<pathID>:<branchID>:<0|1|2|3|4|5|6|7|8>:<empty|sparse|maximal|repairInvalid>`;
- `status:<success|pending|rejection|cooldown|fatigue|missingFocus|missingEquipment|permissionDenied|persistenceFailure|authorityExhausted>:<sheet|saveSlots|cycle|useSelected|useSlot>:<character|skillID|spellID|attributeID|slot0...slot8|equipmentID|permissionID>:<local|authority|durablePending|durableAcknowledged>`;
- `error:<cooldown|fatigue|missingFocus|missingEquipment|permissionDenied|persistenceFailure>:<skill|spell>:<registeredID>`.

Every path/branch/skill/spell/attribute/equipment/permission token is registry/closed-enum validated;
the selected branch must belong to the path, active IDs must be active, spell IDs must be reachable
for their fixture path, and rank/status combinations build a canonical state rather than patching an
invalid state. `editedValid`, `underBudget`, `unmetRequirement`, and `inventoryFull` are fixed fixture
profiles, so all six path drafts and all eighteen Review branches are reproducible. `skill` reaches
each of the 162 inspector/rank combinations. Slot profiles build exact nine-token local values:
`empty` all nil; `sparse` uses slot 0 and slot 4 when a second unique action is legally attainable,
otherwise slot 0 only; `maximal` is a deterministic inclusion-maximal set of unique legally learned
and prepared path actions in stable registry order up to nine; and `repairInvalid` begins with one
legally prepared token before adding bounded duplicate/unknown preference corruption and showing its
normalized result. The `ranger:ranger_survivalist` level-20 fixture has only one action attainable
within the real skill-point/prerequisite budget, so its exact sparse result is slot 0 populated and
slot 4 empty. The maximal search accepts at most 16 candidates and 256 legal-transition simulations,
then proves that no remaining candidate is attainable from its final state when it stops below nine.

Action-failure `error:*:skill:<id>` selectors require a registered active skill because passive
skills cannot produce cooldown/fatigue/focus/equipment/permission action failures. For
`error:persistenceFailure:<skill|spell>:<registeredID>`, the registered ID is bounded display context
only: the typed status is always `saveQuickSlots` targeting `character`, and passive or active skill
context is valid because merely viewing a skill can precede a local quick-slot save attempt.

The remaining allowlisted selectors are:

- `ELYSIUM_RPG_UI_AUTHORITY=<ready|pending|acceptedCommit|rejectedCommit|reconnecting|disposition|exhausted|unavailable>`;
- `ELYSIUM_RPG_UI_VIEWPORT=<360x224|520x330|700x420>`;
- `ELYSIUM_RPG_UI_APPEARANCE=<standard|highContrast|reduceMotion|highContrastReduceMotion>`;
- `ELYSIUM_RPG_UI_SEMANTIC_SUMMARY=1`.

If `ELYSIUM_SHOT` is present, its value is one relative basename plus an optional `@<frames>` suffix;
the basename is 1...96 bytes from `[A-Za-z0-9._-]`, may not be `.` or `..`, and frames are 1...600.
The output resolves beneath the harness-owned canonical temporary directory, is created no-follow
and exclusive, and rejects existing files, symlinks, absolute paths, separators, traversal, and
extra suffixes before bootstrap. Harness mode cannot overwrite a caller-selected arbitrary path.

Each of the eight `ELYSIUM_RPG_UI_AUTHORITY` fixtures uses the table in section 4.5 without alternate
copy. Its pure draw output must contain the exact icon ID/shape, title, and visible help; its semantic
summary must contain `RPG authority`, the exact value/help, exact announcement string, and every
otherwise-legal authoritative control's exact enabled state/reason. `ready` asserts the canonical
legal operation is enabled and has no authority reason. The other seven assert it is disabled with
the table sentence visible and in accessibility help; local-slot availability must match the phase
matrix. Installed probes repeat all eight fixtures in standard and High Contrast and compare those
exact visible strings, non-color shapes, and VoiceOver announcement text. Missing, paraphrased,
truncated, color-only, or duplicate-announced output fails the fixture.

The `status` cases reach every terminal/phase status, stable ID, persistence mode, icon/text mapping,
payload digest, closed durable status, and acknowledgement state using fixed valid 64-hex identities.
The `error` cases reach the local semantic action failures explicitly
required for cooldown, fatigue, focus, equipment, permission, and preference persistence without
calling a mutator. Tutorial cases select each page. Appearance is independent, so every case can be
repeated under High Contrast and Reduce Motion.

Unknown, inconsistent, or overlong values are rejected with one bounded diagnostic and no fallback
fixture. Valid mode constructs only `RPGUIHarnessRuntime`: the pure fixture/model builders, bounded
semantic snapshot, renderer, and a harness AppKit view. The runtime has no reference or factory for
GameCore, SaveDB/StorageEngine, SettingsStore, player/world state, LAN, controller discovery, or
authority acknowledgement. It cannot replace a player, grant inventory, mutate RPG/tutorial/quick
slots, write support state, submit LAN work, consume a durable notice, post an acknowledgement, or
enable v6. Semantic summary output is sorted and bounded to IDs/roles/focusable/actionable/state/help/
status metadata; it contains no credentials, raw notice text/payloads, player names, save paths, or
owner data.

Harness tests inject dependency factories whose GameCore/storage/settings/player/network counters
must remain exactly zero; run every selector with a fresh temporary support home; compare recursive
directory manifests before/after; and assert no files, database handles, sockets, listeners, or
network tasks are created. Combined-mutation-environment tests cover every shipping `ELYSIUM_` family
and must reject before those counters change. Zero-mutation runs omit `ELYSIUM_SHOT`; when explicitly
present, `ELYSIUM_SHOT` may create only its named screenshot output and still may not create or alter
support/save/settings/network state.

## 11. Failure-state behavior

- No Player/world: show a bounded unavailable model, then Close; no force unwrap.
- `rpgClasses` disabled while open: synchronously terminate reviewed RPG transients through GameCore,
  close the sheet/tutorial, clear controller repeat/focus, and show exactly `RPG classes are disabled
  in this world`.
- Invalid registry relationship: disable the affected operation and expose `Registry mismatch`; do
  not infer/zip/fallback.
- Invalid viewport/offset: use bounded error layout and zero offset.
- Local semantic rejection: state/inventory/preferences are byte-for-byte unchanged; keep selection,
  show canonical reason beside the attempted control, and announce it.
- Starter inventory capacity failure: retain the complete creation draft and focus Create/reason.
- Pending/reconnect/disposition: never redraw-trigger, duplicate, replace, or clear the request.
- Rejected owner bundle: complete resync publishes before controls re-enable; preserve valid local
  draft/selection/slots and focus acknowledged item/reason.
- Malformed/incomplete owner bundle: the authority layer publishes reconnecting; model never sees or
  partially applies payload fields.
- Exhaustion: no retry/wrap/new request; existing valid local tokens may move/clear/use only as
  allowed by the authority contract.
- Local slot persistence failure: do not publish the candidate; retain old slots and show `Could not
  save RPG quick slots`.
- Local storage completion with stale scope/world-entry generation/expected live revision, or legacy
  envelope version/source/origin mismatch: discard silently as stale, retain the legacy envelope,
  and change no live or semantic revision/notification.
- Player snapshot/CAS invalid/conflict/storage failure: keep live envelope non-omittable, require the
  CAS to leave the exact prior durable row unchanged, change no revision/notification, and show only
  `Could not save character migration`.
- Settings/keybind/tutorial publication failure at any stage: retain byte-identical live values and
  revisions, post no notification, and show persistence failure without marking the candidate active.
- Any-modality activation with a stale ID/revision/fingerprint: consume its nonzero activation
  receipt before revalidation, rebuild at most once, announce that a fresh activation is required,
  and submit no command. Zero, unissued, consumed, or high-water-stale receipts never rebuild or
  dispatch; only a genuine later press receives a new receipt.
- Controller disconnect/focus loss: clear every held/repeat edge and return visible help to keyboard.
- Accessibility Press from a cached stale origin tuple: consume the fresh receipt, dispatch nothing,
  invalidate/rebuild at most once, and require a newly fetched element and fresh Press.

## 12. Dependency-ordered build contract

0. **Close the expected-old-player-row CAS prerequisite without generic widening**
   - Phase 2.0B and the safe-deferral storage implementation have independent Security code and
     Tester PASS; current section-0 hashes remain their frozen input evidence.
   - Renew Security plan review, then the storage-amendment Builder adds only
     exact checked snapshot/CAS Core and concrete storage symbols, keeps serialized compatibility
     `putPlayer`, and updates reviewed API/capability/scanner/verifier evidence. Independent
     Security code and Tester PASS then freeze the new implementation hashes. No UI Builder edits a
     storage file or anticipates those hashes.
   - Until that gate closes, no path may mark a legacy envelope omittable or persist a slot-free
     player candidate. Raw ElysiumCore SQL, direct generic storage, or compatibility `putPlayer`
     is never an interim omission implementation.
   - Client checkpoint acquisition/semantic decoding, host writers, and `.lanV6` production
     persistence remain absent. A v5 client has no synthesizable v6 preference scope and publishes no
     slot edit or authoritative RPG operation.
1. **Pure foundations only**
   - Add the canonical evaluator/effect evidence, local-preference values/reducers/codecs, creation/
     sheet/layout/tutorial models, chord parser/resolver model, controller reducer, and semantic
     command/capture value types. Make `rpgLearnSkill` consume the evaluator.
   - This step has no AppKit event dispatch and no production actionable renderer. A temporary passive
     renderer is allowed only when every descriptor has no action command, hit testing cannot invoke a
     closure, and keyboard/controller/accessibility Press dispatch is absent.
2. **Mandatory pre-actionability Security boundary**
   - In `GameCore`, install the closed authority/scope gate first: an eligible exact local-world
     session may project `.localReady`; a protocol-5 LAN client always projects `.unavailable`, has no
     writable scope, retains its legacy envelope, and rejects every slot and authoritative operation.
   - In `LANTransport.swift`, reject new RPG semantic operations before `lanRPGIntentHandler` and
     prove zero player/inventory/world mutation, zero local/client storage call or row, and zero
     `LANRPGIntent`. Do not add a client adapter, host writer, or v6 placeholder.
   - Implement the section-6.4 semantic activation dispatcher with checked receipts, consume-before-
     revalidation, exact origin fingerprints, and independent routing serial. Route a synthetic
     command only through this guard/dispatcher and prove all stale/replay/scope/LAN denial cases.
   - Focused authority/scope, `LANClientRoutingTests`, and semantic-activation suites must PASS before
     any mouse hit, key event, controller edge, or accessibility Press can reach an actionable
     descriptor. This is a blocking build-order gate, not a test deferred until after the renderer.
3. **Local preference lifecycle with session provenance**
   - On exact local-world entry, when a retained legacy envelope exists call
     `materializeLegacyRPGQuickSlotPreferences`; otherwise call
     `loadRPGQuickSlotPreferences` and, only if absent, materialize stable defaults through
     `materializeRPGQuickSlotPreferences`. A later edit derives a candidate from the last published
     snapshot and calls `compareAndSwapRPGQuickSlotPreferences`.
   - Every request/completion carries section-4.2 scope, checked world-entry generation, and expected
     live revision. Publish only after current-session/revision revalidation; migration also matches
     envelope version/source digest and immutable origin. Keep the live envelope non-omittable,
     checked-read the durable row and persist an explicit slot-free candidate through exact CAS in a
     non-suspending main-actor segment, revalidate again, and only
     then publish omission. Only after this proof remove slots from ordinary player encoding; remove
     implicit selection on assign/use independently.
   - Track C alone may add the missing semantic adapter over the dormant client checkpoint aggregate,
     enable scoped LAN slot edits, add a coherent host writer, or publish nonfixture authority phases.
4. **Bounded local settings publication**
   - Add `LocalSettingsStore`, exact settings/keybind caps, independent known-field decoding, atomic
     Result writes, tutorial-version sanitization, and all three named candidate-copy publication
     APIs. Pass every write-stage integration fault test before Controls/Tutorial can publish.
5. **Passive production renderer and semantic snapshots**
   - Rewrite `RPGScreensM.swift` against only the pure model and add HUD/Inventory/Creative layout,
     but keep operation descriptors nonactionable and all input/Press dispatch disconnected until
     steps 2 through 4 pass. Drawing, focus, and semantic inspection must be mutation-free.
6. **Enable the single actionable UI path**
   - Only now attach explicit operation commands to descriptors; connect mouse, shared AppKit router,
     virtualized Controls, configured keybinds, tutorial controls, HUD/entry points, and the sole
     guard/revalidating dispatcher. Delete raw GameCore key fan-out and independent closures.
7. **Controller adapter**
   - Link GameController and adapt physical input to the already-passed reducer/semantic dispatcher.
8. **Accessibility origin-bound bridge**
   - Add Screen/UIManager semantics and the GameView AppKit bridge. Each press-capable cache element
     captures the complete committed origin tuple; stale same-ID/replacement/offscreen Press tests
     pass before the Press action ships.
9. **Isolated tutorial/harness/docs**
   - Remove shipping RPG autocreate, add pre-bootstrap isolated fixtures/semantic summary, use the
     exact neutral ready/contextual Review copy, and update durable docs.
   - **Builder remediation and renewed review PASS (2026-07-11):** exact allowlist/limits/closed registries, canonical selector
     profiles, status/error identity and icon projection, first-decision app routing, dependency-free
     passive AppKit/VoiceOver fixture, fd-relative exclusive screenshot output, retired autocreate
     removal, durable docs, focused regression and canonical-number executable rejection, and the
     complete 24-shot compact/wrapped screenshot matrix passed. Renewed Security code and Tester
     reviews of the actual corrected diff are PASS; a post-remediation warning-free Track B release
     build and `scripts/verify-elysium-storage-release-surface.sh` also pass. These results do not replace
     Step 10 installed Design Sign-off, independent full Test, pipeline, deploy, or installed-world proof.
10. **Stop Track B and run its downstream gates**
    - Source-audit that no client semantic adapter/facade, host writer, v6 activation, or nonfixture
      authority publication entered the diff, then run Security code review and subsequent gates.
11. **Authority integration (Track C only; not authorized in this Build)**
    - Only after new Architecture/Security/Tester PASS, connect reviewed v6 durable state to
      `RPGAuthorityPresentation`, bounded digest-keyed notice inbox, committed-model acknowledgement,
      exact eight-phase non-color/VoiceOver presentation, and the existing sheet-operation
      dispatcher. Do not add a second UI transport callback.
12. **Track B downstream gates**
    - Security code review -> installed Design Sign-off -> independent Test -> full pipeline ->
      deploy -> installed local-world verification. Neo/LAN verification waits for Track C.

Any material fix returns to the earliest affected step and invalidates later review/proof.

## 13. Exact tests and empirical evidence

### 13.1 New test files

1. `Tests/ElysiumCoreTests/RPGSkillPurchaseEvaluationTests.swift`
   - Every failure precedence pair; evaluator/mutator parity; 54 skills x ranks/states; selected vs
     cross gates/costs; authority exhaustion; checked capstone math.
2. `Tests/ElysiumCoreTests/RPGEffectCoverageTests.swift`
   - An exhaustive switch over all 54 `RPGSkillEffectID` cases, looping ranks 1...3, invokes the real
     consumer/action/spell preparation path and records one observable assertion per rank: exactly
     162. It also verifies generated effect text and 17 spell semantics. A new enum case cannot
     compile without evidence.
3. `Tests/ElysiumCoreTests/RPGLocalPreferencesTests.swift`
   - Track B covers exact local record scope, pure 16-byte v6 host/world scope encoding without a
     production adapter, local-table caps, local-only legacy extraction/marker/destination crash cuts
     and omission, load/default/CAS stale and failure paths, delayed cross-world completion rejection,
     immutable-origin preservation, and persist-before-publish byte equality. It explicitly proves a
     protocol-5/LAN scope invokes none of the four local `SaveDB` methods and creates no standalone
     preference or migration row. Whole-client-checkpoint semantic CAS/owner normalization tests are
     Track C; the already-passed primitive storage tests are not reimplemented in this UI suite.
   - Every request and completion asserts exact nonzero world-entry generation plus `.absent`/exact
     expected live revision. Interleavings cover leave/re-enter of the same world ID, A -> B -> A,
     delayed read/default/CAS/migration completion, generation/revision exhaustion, envelope version/
     source-digest replacement, and immutable-origin mismatch; all stale cases retain the legacy key
     and leave live preferences/revisions/semantic notifications byte-identical.
   - Two-phase omission seeds a durable old row with the key; snapshot/CAS conflict/failure retains
     that or a deterministically newer writer row and the non-omittable live envelope. Success reopens
     a slot-free row then publishes omission. Pre-write/post-commit barriers race same-world/A-B-A,
     envelope replacement, ordinary save, saveAndFlush, shutdown, and compatibility putPlayer; no
     stale candidate changes the durable row.
4. `Tests/ElysiumCoreTests/SaveDBPlayerRowCASTests.swift`
   - Exact digest/get/absent-present/CAS/error APIs, full digest mutation and fixed-time comparison,
     compatibility serialization, encode/row failure before rank 12, transaction conflict/fault/
     restart proof, rank 0/12/0 and rank11->12 instrumentation, deterministic barriers, redacted
     errors, exact scanner/capability/API/verifier symbols, and no unconditional/generic widening.
   - Digest 31/32/33; world ID 0/1/cap/cap+1; player JSON cap-1/cap/cap+1; wrong-class/
     oversized/invalid-UTF8 stored rows; incremental bounded digest construction; exact private CAS
     authorizer matrix; exactly-one-world parent; missing-parent conflict; and world-delete-before/
     after absent/present ordering all reject or commit without stale mutation.
5. `Tests/ElysiumCoreTests/LocalSettingsStoreTests.swift`
   - Settings 256-KiB and keybind 16-KiB exact/cap-plus-one, object/root/UTF-8 hostile inputs,
     independent known-field fallback, unknown fields, exactly 25 canonical <=64-byte chords,
     protected/extra/missing binding rejection, candidate-before-publish, and injected temporary
     create/write/file-sync/rename/directory-sync plus restart old-or-new atomicity.
   - Call each named settings/keybind/tutorial publication API across encode/validate/create/partial-
     write/write/file-sync/rename/directory-sync/stale-revision/revision-exhaustion faults and assert
     byte-identical live state, unchanged live+semantic revisions/dirty count, and zero notifications.
     Missing, negative, malformed string/object/fraction, and future tutorial versions load as zero.
6. `Tests/ElysiumCoreTests/RPGScreenModelTests.swift`
   - Four steps; all six exact path icon/role/primary/preset/selection/help contracts; six retained
     drafts; all eighteen Review branches; Foundation derivation; kits/spells/focus/XP copy; five
     tabs; every inspector/rank; caster/non-caster filtering; 3/9/27 each and 6/18/54/162 aggregate.
   - Exact neutral ready help/VoiceOver copy and exact context-aware `.localReady`/`.unavailable`
     Creation Review copy at all viewports; forbidden host-authoritative/internal terms are absent.
7. `Tests/ElysiumCoreTests/RPGScreenLayoutTests.swift`
   - Exact viewports, seeded resize/content transitions, full-control containment, shared scroll
     tuple, virtualization bounds, focus reveal/retention/nearest-preceding-focusable fallback, full
     wrapped card containment, and forward/reverse traversal of all 27 ranks exactly once for all six
     paths at all three viewports with nonactionable activation byte-equality.
8. `Tests/ElysiumCoreTests/RPGPendingPresentationTests.swift`
   - Track B proves every section 4.5 phase's pure fixture icon geometry/title/visible help/disabled-
     control reason/accessibility value+help/VoiceOver announcement, including ready's enabled/no-
     authority-reason assertion, forbidden internal-copy absence, byte-identical no-reannouncement,
     and production construction limited to `.localReady`/`.unavailable`. Digest-keyed durable inbox,
     capacity, replay, coordinator mapping, and committed-storage acknowledgement tests are Track C.
9. `Tests/ElysiumCoreTests/InputChordTests.swift`
   - Canonical terminal/modifier domains, all malformed cases, 25 defaults, recursive equality of
     nonempty shipping-menu chords with the protected set, capture/load/persist rejection for each,
     pairwise conflict winner across definitions/contexts, modified-digit precedence, legacy
     movement compatibility, zero-or-one resolution, routing-serial reuse rejection, and repeats.
10. `Tests/ElysiumCoreTests/AppInputRoutingTests.swift`
   - Shared `performKeyEquivalent`/`keyDown` fingerprint dedupe; F11 then Command+C/V/Z; every
     unconsumed shipping-menu chord (including Command+Q/M) returned to the main menu before
     screen/binding resolution; screen-before-Escape thereafter; physical versus synthesized legacy
     edges; and at most one dispatched command/mutation.
11. `Tests/ElysiumCoreTests/RPGControllerInputTests.swift`
   - Every mapping, enter/exit hysteresis, neutral arming, repeat caps/timing, connect/disconnect/focus/
     context reset, one edge/one command.
12. `Tests/ElysiumCoreTests/RPGSemanticAccessibilityTests.swift`
   - Roles/labels/values/help/actions, offscreen 27 discoverability, exclusion of 135 other-path
     ranks, stable IDs/revisions, notification intent, High Contrast/Reduce Motion model flags, and
     the full cached `(screenInstanceID, semanticRevision, ID, commandFingerprint,
     semanticInputFingerprint)` origin tuple. Retained old elements across same-ID screen replacement,
     same-ID revision/fingerprint change, and offscreen focus/reveal reject with zero dispatch; only a
     newly fetched committed element Press succeeds.
13. `Tests/ElysiumCoreTests/RPGSemanticActivationTests.swift`
    - Exact nonzero activation-receipt/screen-instance/ID/revision/command-fingerprint/semantic-input-
      fingerprint capture through mouse/keyboard/controller/accessibility; a unique receipt for each
      genuine press with byte-identical semantic fingerprints; race interleavings for ack/rule/path/
      tab/scope/equipment/focus/target/offscreen/revision exhaustion; receipt and routing-serial
      exhaustion; consume-before-revalidation; zero/unissued/replay rejection before and after the
      64-entry FIFO/set rolls over; stale rebuild without replay; fresh-press requirement; and one
      valid mutation maximum through the independent routing serial.
14. `Tests/ElysiumCoreTests/RPGUIHarnessTests.swift`
    - Pre-bootstrap exact allowlist, every combined shipping mutation env rejection, bounded
      diagnostics/summary, creation steps/all six drafts/all eighteen reviews/four tutorials/all
      inspectors and ranks/slot profiles/notices/local errors/appearance states; all eight authority
      fixtures' exact plain-language visible icon/title/help/disabled reason and VoiceOver value/help/
      announcement, with no internal authority/storage/protocol terminology in those sinks;
      zero dependency factory calls, unchanged fresh support-home manifest, and no file/database/
      socket/listener/task.

### 13.2 Existing tests to update

- `RPGActionTests.swift`, `RPGActionHardeningTests.swift`, `RPGActionTransactionTests.swift`: pass
  local preferences explicitly and prove quick-slot execution does not select.
- `RPGCharacterStateTests.swift`, `RPGCoreV2Tests.swift`, `RPGSecurityRegressionTests.swift`: remove
  authoritative slot expectations, prove old JSON migration and new JSON omission.
- `RPGQuickSlotInputTests.swift`: use configured chords and prove selected action/hotbar/revisions stay
  unchanged.
- `SettingsTests.swift`: optional tutorial compatibility and canonical chord/property fuzz; no
  process-global quick-slot field remains.
- `LANMultiplayerTests.swift` and `LANReplicationTests.swift`: Track B proves the slot-free existing
  protocol-5 compatibility representation and unchanged ordinary replication without adding an RPG
  semantic message or host writer. Whole-client-checkpoint owner/slot normalization suites are Track C;
  the safe-deferral storage primitive suites remain closed prerequisite evidence.
- `LANClientRoutingTests.swift` plus a source audit of `LANTransport.swift`: while protocol 5 is active,
  every sheet/world authoritative RPG semantic command on a LAN client projects `.unavailable`,
  submits zero `LANRPGIntent`, invokes zero local/client storage method, and mutates zero player/
  inventory/world state. Coordinator-boundary behavior after v6 activation is Track C.
- `RPGConsumerHardeningTests.swift`: HUD consumes explicit local preferences and rule-disabled paths
  remain hidden.

Seed structured-input/property tests with a printed fixed seed. Cover malformed chords, slot JSON,
selection IDs, viewport doubles, and semantic commands. No blanket regold is allowed.

### 13.3 Required command order

After focused suites and each remediation loop:

```bash
swift build -c release
swift test
bash scripts/security-scan.sh
swift run -c release elysmoke
bash scripts/pipeline.sh
```

The release build must be warning-free. `elysmoke` must still report 457 unless a separately reviewed
intentional check addition changes that count. Verify each command's exit code and actual test/check
count.

## 14. Risk-to-test map

| Risk/invariant | Closing evidence |
| --- | --- |
| UI and mutator disagree | evaluator precedence + exhaustive evaluator/mutator parity |
| Draw/focus/accessibility mutates live state | before/after byte equality around every model/query path |
| A path is hidden/stranded | six-fixture 3/9/27 and level-one guidance/event tests |
| Rank effect is copy-only | exhaustive 54-case real-consumer switch x 3 ranks = 162 observations |
| Cross spend silently prevents capstone | capstone arithmetic/property tests and inspector snapshots |
| One local world's/player's slots leak to another | exact local scope cross-product and delayed-completion mixup tests |
| Same-world re-entry accepts stale completion | checked world-entry generation and same-ID leave/re-enter ABA matrix |
| Legacy slot migration loses the only copy | transaction/crash-cut tests; marker+destination commit before JSON omission |
| Stale migration clears a changed envelope | envelope-version/source-digest/origin receipt revalidation tests |
| Stale omit candidate overwrites newer player save | full-row digest CAS and compatibility/ordinary/saveAndFlush/shutdown barrier races |
| Player CAS widens/leaks storage | closed errors, exact concrete symbols, rank probes, scanner/capability/API/verifier review |
| CAS recreates deleted-world player | exact parent requirement plus delete-before/delete-after absent/present races |
| Malformed digest/player row crosses rank or allocates | digest/world/JSON cap and wrong-class pre-copy/pre-rank tests |
| Track B accidentally writes LAN slots | protocol-5 zero-storage-call tests; dormant client facade/capability source audit |
| Future LAN slot write splits owner/security state (Track C) | deferred whole-checkpoint CAS fault byte-equality |
| Old local state overwrites slots | local-row precedence, immutable-origin CAS, and new JSON omission tests |
| Slot use selects or consumes revision | action/input before/after state tests |
| Malformed settings exhaust memory or erase peers | exact read caps, independent field decode, hostile seeded inputs |
| Failed settings write publishes/truncates state | every I/O fault injection plus restart old-or-new proof |
| Failed settings/keybind/tutorial write dirties live UI | named publication-API stage faults with byte equality, unchanged revisions, and zero notifications |
| Invalid/future tutorial version suppresses tutorial | missing/negative/malformed/future-to-zero sanitization matrix |
| v5 optimism remains reachable | LAN-client unavailable-boundary test and no v5 fallback assertion |
| Actionable renderer lands before denial guard | dependency-gate source audit plus guard/activation/LAN suites before any action command attaches |
| UI accidentally activates v6 | no protocol/schema/transport-cutover diff; v6 gate tests owned separately |
| Clipped/stale controls mutate | exact/seeded geometry plus same-rect draw/hit/semantic tests |
| Capture acts on changed target/authority | receipt+ID+revision+fingerprint race matrix for all four modalities |
| Stale/replayed activation later dispatches | checked nonzero generation, consume-before-revalidation, 64-receipt FIFO/set rollover plus high-water rejection, and fresh-press tests |
| One accepted activation fans out twice | independent checked routing-serial reuse/exhaustion tests and one-mutation assertion |
| Focus disappears after ack/resize | transition matrix and installed keyboard/VoiceOver proof |
| Authority phase is color-only or unexplained | exact eight-fixture icon/visible help/disabled reason/VO assertions |
| Menu shortcut is captured as gameplay | constructed-menu equality plus per-chord capture/load/persist/dispatch tests |
| Malformed/conflicting chord hijacks controls | protected-chord fuzz, canonical winner, dedupe/one-mutation tests |
| Controller repeats mutations | synthetic hysteresis/neutral/repeat tests plus physical proof |
| Accessibility is only metadata | installed VoiceOver discovery/focus/press and notification observation |
| Cached accessibility element acts on replacement | full origin-tuple same-ID/revision/offscreen stale Press matrix |
| Durable notice spoof/injection/early ack (Track C) | deferred exact ID+digest/status/bounds, dual sanitizers, queue caps, commit receipt tests |
| Tutorial is falsely marked seen | persistence boundary tests and crash/reopen installed proof |
| Harness combines a mutation hook or creates state | pre-bootstrap env rejection, zero factories, manifest/socket proof |
| Rule disables mid-screen | synchronous cleanup/dismiss test and installed probe |

## 15. Installed Design Sign-off and deployment proof

After Security code PASS, build/deploy a fresh `/Applications/Elysium.app`. Use a fresh
`CFFIXED_USER_HOME` for deterministic local settings and the allowlisted harness. For each of
360x224, 520x330, and 700x420 capture creation, all five tabs, tutorial, every one of the eight
authority fixtures, every local error, High Contrast, and Reduce Motion. Collect the sorted semantic
summary and verify each phase's exact icon/title/help/disabled reason/VoiceOver copy, per-fixture
3/9/27, and aggregate 6/18/54/162 with unique IDs.

The Designer must physically inspect and operate:

- all six creation Review states and all eighteen branch/roadmap states;
- all 54 inspectors and their 162 rank cells through deterministic fixtures;
- caster and non-caster Actives/Spells states;
- mouse selection plus separate operation controls;
- Tab/Shift-Tab/arrows/Enter/Space/Escape at all three viewports;
- VoiceOver discovery, offscreen focus/reveal, and press on representative rank/operation/tab/slot;
- every authority phase's non-color shape, visible explanation, disabled-control reason, and exact
  VoiceOver announcement without duplicate reannouncement;
- High Contrast and Reduce Motion;
- one compatible physical controller for sheet and world mappings.

Screenshots, semantic dumps, and synthetic controller tests support but cannot replace those physical
checks. Any unavailable physical surface is unsigned and blocks a claim of full Design Sign-off.

After independent Track B Test PASS, run `bash scripts/pipeline.sh`, deploy a fresh
`/Applications/Elysium.app`, verify the installed executable/signature and local-world UI again, and
prove a protocol-5 LAN client sees `.unavailable` with zero RPG mutation/request fallback. This is a
valid local-production deployment, not full RPG LAN completion.

Only after Track C independently passes Architecture, Security, Design Review, and Test may the final
LAN gate run:

```bash
bash scripts/live-lan-test.sh --deploy --timeout 90
```

That Track C Neo proof must include character creation plus atomic kit, one pending mutation, accepted and
rejected convergence, local-slot assign/use preservation, permission denial, replay, cooldown/fatigue/
upkeep/XP persistence, disconnect/reconnect, and no v5 optimistic state. Installed executable hashes
must match. Any runtime-path code change invalidates and repeats affected Security, Design Sign-off,
Test, pipeline, deploy, installed, and Neo evidence.

## 16. Conditions for Builder

- Phase 2.0B and the safe-deferral storage implementation have the required independent Security code
  and Tester PASS. Architecture authorizes the revised local-production design, but omission and any
  dependent actionable Track B wiring remain persistence-blocked until the exact CAS delta receives
  renewed Security plan/code and Tester PASS.
  Track C still requires all reviewed v6 authority, coherent host writer, and transport prerequisites.
- Treat section-0 hashes as the passed safe-deferral input baseline. Before omission work, the
  separately gated storage Builder adds exactly checked snapshot/CAS Core plus concrete digest/
  expectation/result/CAS storage symbols, preserves serialized compatibility `putPlayer`, and passes
  Security/Tester plus reviewed API/capability/scanner/verifier hashes. The UI Builder must not edit
  storage files, manifests, or verifier; import `ElysiumStorage`; prepare SQL; add a client adapter; or
  add a host writer.
- The storage delta is exactly four public additions and zero package/SPI mirrors, with only the
  frozen `Sendable`/`Equatable` conformances and 32-byte throwing digest initializer in the storage
  plan. Its private CAS scope proves exactly one worlds.id parent and accesses only exact parent/
  player columns; missing parent conflicts and world delete cannot be undone. Digest 31/32/33,
  world-ID boundaries, JSON cap boundaries, and wrong-class/oversized rows reject before copy/rank.
- Use `LANHostInstallationIDV6` and `LANWorldIDV6`, the exact typed identifiers already shipped in
  `LANV6Scalars.swift`; do not introduce alias spellings for UI convenience.
- Treat `Sources/Elysium/LANTransport.swift` and `LANClientRoutingTests.swift` as mandatory v5
  zero-fallback surfaces. Until Track C is installed, a LAN client submits zero authoritative RPG
  UI/world operations and never routes them through `LANRPGIntent`.
- Do not activate v6, edit its wire/version/cutover, or route the new UI through v5.
- Implement in the dependency order above. The GameCore authority/scope guard, protocol-5
  `.unavailable` zero fallback, and semantic activation dispatcher plus focused suites must pass
  before any renderer descriptor carries an action command or any mouse/keyboard/controller/
  accessibility path can dispatch. Earlier renderer work is passive only and has no dispatch seam.
- `rpgEvaluateSkillPurchase` is the only purchase evaluator and `rpgLearnSkill` consumes it.
- Every path projects exactly 3 branches, 9 nodes, and 27 rank cells; aggregate proof is exactly
  6/18/54/162 with unique IDs.
- Every one of 162 ranks has real-consumer evidence and every one of 17 spells has semantic evidence.
- Creation is exactly Path -> Branch -> Attributes -> Review, derives Foundation from branch, sends
  no manual starter spells, and retains per-path drafts.
- The shell is exactly Character, Skills, Actives, Spells, Progression.
- Rows/cards/focus/hover/tab/slot destination never mutate. Rank Up, Prepare, Unprepare, Select,
  Assign, Move, Clear, Create, Spend Attribute, Finish, and Skip are explicit controls.
- Focusability is independent of actionability: every locked/purchased/current/future rank remains
  reachable, while only an enabled explicit operation descriptor carries a command; fallback is the
  nearest preceding focusable ID.
- Quick slots never enter authoritative RPG/owner/public state and never change selection, sequence,
  revisions, inventory, or pending network work.
- Track B quick slots are keyed only by the exact local `WorldRecord.id`; no global/settings/name/
  seed/address fallback exists, and async completions carry that captured scope. Exact typed v6
  host+world scope remains a pure value/fixture until Track C.
- Every local preference request and completion also carries a checked nonzero world-entry generation
  and expected absent/exact live revision. Generation advances on teardown and every entry including
  same-world re-entry, never wraps, and must match before publication. Migration additionally matches
  the current checked envelope version/source digest and receipt immutable origin before omission.
- Only local worlds use `rpg_local_preferences_v1` and legacy markers. Track B LAN paths call none of
  the four local methods and no client checkpoint method. Future Track C assign/move/clear/default/
  owner normalization must use only the complete checkpoint generation CAS, never a standalone row.
- The old player slot key remains encoded until a local-world transaction commits both the
  destination and source/origin-digest-bound migration marker **and** an explicit detached slot-free
  player candidate succeeds through exact expected-old-row CAS. Migration receipt leaves the live
  envelope non-omittable; CAS success plus a second scope/generation/revision/envelope/source/origin check
  alone publishes omission. Every reported encode/storage failure leaves the live and reopened
  durable player row with the key. Normal slot CAS preserves origin; LAN never consumes the envelope.
- Final player snapshot -> prevalidation -> detached candidate -> synchronous CAS -> postvalidation ->
  omission publication is one main-actor non-suspending segment. The CAS compares the full exact
  domain-separated durable-row digest inside one transaction. Any compatibility/ordinary/
  saveAndFlush/shutdown writer ordered before it forces conflict and remains unchanged; any writer
  ordered after it is later. Same-world/A-B-A and envelope replacement cannot interleave on main.
- Settings/keybind reads enforce 256-KiB/16-KiB caps, known fields fail independently, keybind output
  is exactly 25 canonical <=64-byte entries, and every settings/slot/tutorial/chord value publishes
  only after its Result/transaction succeeds.
- Settings, keybinds, and tutorial publish only through the three named `persistAndPublish*Candidate`
  APIs. Every write-stage failure leaves byte-identical live values, unchanged live/semantic
  revisions and dirty count, and zero notifications. Missing, negative, malformed, or future tutorial
  versions sanitize independently to zero.
- `RPGAuthorityPresentation` is the one pending/LAN UI input; no screen inspects transport state.
  Track B production constructs only `.localReady` and protocol-5 `.unavailable`; all other phases
  are pure harness/model fixtures until Track C.
- Every authority phase uses the exact section 4.5 procedural shape, visible title/help,
  disabled-control reason, accessibility value/help, and VoiceOver announcement; all eight harness
  fixtures assert the exact plain-language mapping and localReady contributes no false authority-
  disable reason. Internal checkpoint/protocol/coordinator terms never enter visible or VoiceOver
  phase copy.
- Ready help is exactly `Character controls are available when their requirements are met.` and its
  announcement is exactly `Ready. Character controls are available when their requirements are met.`
  Creation Review uses the exact context-specific strings in section 5.2; no host-authoritative copy
  is permitted for local production.
- Track B may render bounded immutable durable-notice fixtures but may not decode, persist,
  acknowledge, or publish a production notice. Track C retains the exact 64-lowercase-hex ID/digest,
  closed status, bounds, queue, fail-closed, dual-sanitizer, and committed-model/storage-ack contract.
- All offsets use the one clamp; no partially clipped control is actionable at required viewports.
- Keyboard, controller, and accessibility emit the same semantic commands and share one focus ID.
- Mouse, keyboard, controller, and accessibility activation all capture exact
  `(activationReceipt, screenInstanceID, ID, semanticRevision, commandFingerprint,
  semanticInputFingerprint)` and use one revalidating dispatcher. Each genuine fresh press receives
  a unique checked nonzero `UInt64` receipt without changing either fingerprint. The dispatcher
  consumes an issued receipt before semantic revalidation; its 64-entry FIFO/set and permanent
  high-water mark reject zero, unissued, stale, or replayed receipts even after eviction. Mismatch
  rebuilds without replay and requires a newly receipted fresh activation. The independently checked
  routing serial permits at most one mutation/authority request after successful revalidation; either
  counter's exhaustion fails closed without wrap or reuse.
- Every press-capable cached accessibility element retains the full committed
  `(screenInstanceID, semanticRevision, ID, commandFingerprint, semanticInputFingerprint)` origin
  tuple. Press uses that tuple plus a fresh receipt, never current reconstructed values; stale same-ID
  screen replacement, revision/fingerprint change, and offscreen reveal all reject without dispatch.
- Controls persists canonical chords, preserves old one-key settings, confirms conflicts, and keeps
  every binding reachable at 360x224.
- F11 and Command+Q/C/V/M/Z are protected from capture/load/persist/dispatch. Protection is derived
  from every nonempty shipping-menu key equivalent plus F11/undo; unconsumed menu chords return to
  the main menu before screen/binding resolution. One canonical resolver returns at most one command,
  and both AppKit event callbacks share the same dedupe/router.
- Controller support remains explicitly RPG-scoped and neutral/repeat state is cleared at every
  lifecycle/context boundary.
- The AppKit accessibility tree is real, main-thread, revision-cached, and physically verified with
  VoiceOver; the 27 current-path rank cells remain discoverable offscreen.
- Tutorial version is local and publishes only after a successful Finish/Skip persistence write.
- Harness parsing occurs before GameCore/storage/settings/player/network construction, rejects every
  non-harness `ELYSIUM_` key, removes shipping `ELYSIUM_RPG_AUTOCREATE`, contains no secrets/private
  owner data, and creates no save/settings/database/network state.
- Update README/architecture/security copy to match only proven behavior.
- Security code PASS precedes installed Design Sign-off; Design Sign-off precedes independent Test;
  Test precedes deploy.
- Preserve registration order, saved IDs, ordinary hotbar/movement, non-RPG UI, old saves/settings,
  and all existing gameplay/LAN contracts.

**Architecture verdict: PASS for the expected-old-player-row CAS Track B amendment.** The
authority/scope and activation gates now precede every actionable surface; local completions are
world-generation/revision/envelope-bound; accessibility Press is origin-tuple-bound; ready/Review
copy is exact and context-truthful; and settings/keybind/tutorial publication has named candidate-copy
APIs with complete no-publication fault evidence. Legacy omission now additionally requires checked
snapshot, full-row digest CAS, durable slot-free save, and second provenance validation. The exact files,
APIs, order, failure semantics, tests, and deployment boundary leave no Builder ambiguity. The
CAS storage delta must receive renewed Security plan/code and Tester PASS before omission/actionable
Track B resumes. This PASS authorizes no client adapter, v6 activation, host writer, or Track C work.

## 17. Designer gate record (2026-07-10)

### 17.1 Design Mock audit

The existing RPG surface establishes a useful Elysium visual baseline but is not the requested
product. `RPGScreensM.swift` currently uses Elysium's dimmed-world modal, beveled gray panel, pixel
font, procedural 16/24/32-unit RPG icons, compact widget buttons, fixed footer Close action, and a
nine-cell strip that visually relates to the HUD. Inventory and Creative already expose a visible
`Character` entry point. Those conventions remain the visual language for the replacement.

The current interaction is a prototype and must not survive behind the new renderer: creation is one
dense screen with previous/next path and starter controls; starter spells are manually selectable;
the sheet has only Overview/Skills/Spells/Progress; row clicks mutate rank/preparation/slot state;
the Skills legality label mutates a copy to guess whether learning is possible; Spells displays all
seventeen entries regardless of path; drawing repairs the live player; scroll offsets are not fully
clamped; status is truncated inline copy; quick slots are authoritative state; K/O/L and Shift-digit
handling are hard-coded; Controls is a fixed list; and there is no semantic focus, AppKit
accessibility tree, tutorial, or RPG-scoped controller surface. Color currently carries too much of
the learned/prepared/available distinction.

The approved design direction is therefore a progressive-disclosure character workspace rather
than a larger version of the list prototype: a four-step reversible creator, then a stable five-tab
shell with explicit inspectors and explicit operation controls. The registry and canonical
evaluators supply content and truth; the renderer supplies hierarchy, focus, and feedback only.

### 17.2 Visual and interaction token amendment

The implementation uses these existing Elysium conventions as fixed design tokens:

- The outer surface uses `UIManager.drawDarkBg` plus the existing beveled `drawPanel` treatment.
  Shipping widget strips remain the default button treatment where available; the procedural
  fallback must preserve the same raised/disabled geometry. No new raster dependency is required.
- The existing Elysium pixel font and text metrics are canonical. Path, branch, skill, spell, action,
  authority, and status imagery comes from the RPG asset manifest or the procedural IDs frozen in
  this plan. State-specific color may supplement, but never replace, the required icon, text,
  border/pattern, and accessibility value.
- Keyboard/controller/VoiceOver focus uses one non-animated geometric treatment: a one-unit light
  outer ring plus a one-unit dark inner separation in standard appearance. High Contrast uses a
  two-unit light outer ring plus the dark separation. The ring is clipped to the fully visible
  semantic frame and is never inferred from hover color.
- Header, step/tab bar, status band, contextual help panel, content pane, and footer are visually
  distinct regions. Only the content pane scrolls. Back/Next/Create/Close and a currently focused
  operation never move because a list grows, an inspector expands, or authority help appears.
- Visible labels for steps, tabs, explicit operations, costs, gates, canonical failure reasons,
  authority phase, and status leading text are never ellipsized. Long summaries may wrap in their
  bounded virtualized card/inspector; their full copy remains accessibility help. No clipped or
  partially visible operation is actionable.
- Selection is reversible presentation until an explicit operation is activated. Selected cards
  retain the specified check, literal state, and double border. Purchased/prepared/selected/slotted,
  locked, pending, failure, and success states each retain literal non-color copy.

These rules specialize the renderer without changing any core, authority, persistence, or input
contract elsewhere in the plan.

### 17.3 Checkable Designer acceptance criteria

Design Sign-off requires all of the following on the fresh installed app:

1. Creation is visibly and semantically Path -> Branch -> Attributes -> Review. All six path cards
   expose the exact role, primary attributes, preset, icon, and non-color selected state; all three
   branch choices expose their Foundation benefit and automatic spell unlocks; per-path edits survive
   navigation; Review contains kit, first-XP guidance, input help, and capacity/authority caveats.
2. The created sheet exposes exactly Character, Skills, Actives, Spells, Progression. Every path has
   a clear level-1-to-20 route: the selected branch roadmap, costs/gates, next legal milestone,
   banked points, completion impact, the two-point utility budget, and truthful level-22 unreachable
   cross-branch capstone are visible without requiring external documentation.
3. Each live path exposes 3 branches, 9 nodes, and 27 rank cells; other paths' 135 cells are absent.
   Node/rank selection never purchases. Rank Up, Prepare, Unprepare, Select, Assign, Move, Clear,
   Spend Attribute, Create, Finish, and Skip are separately labeled controls with adjacent feedback.
4. Caster paths show only reachable spells and exact unlock sources. Non-casters get a plain-language
   empty state. Actives likewise remain path-scoped and link unknown actions to Skills.
5. At 360x224, 520x330, and 700x420, fixed bands and footer remain fully visible, all content and
   focus reveal use the one clamp, no text/control overlaps, and no clipped control accepts mouse,
   keyboard, controller, or accessibility activation.
6. Mouse, Tab/Shift-Tab, arrows, Enter/Space/Escape, VoiceOver, and the compatible physical controller
   share one visible focus ID and reach the same explicit controls. All 27 rank cells are discoverable
   by keyboard and VoiceOver even when locked or offscreen, and activating an informational cell does
   not mutate state.
7. Standard, High Contrast, and Reduce Motion appearances preserve hierarchy and feedback. High
   Contrast changes geometry/pattern as specified; Reduce Motion removes interpolation without
   removing focus or state changes. No required distinction is color-only.
8. All eight authority phases display the exact frozen icon/shape, title, visible explanation,
   disabled-operation reason, accessibility help, and single announcement. Local quick-slot controls
   remain available exactly as the phase matrix permits and never appear to submit host work.
9. The four-page tutorial is operable by every modality, does not obscure required controls, and is
   persisted only by Finish or Skip. Keyboard help remains visible after controller use; controller
   copy says only `RPG menus and actions`.
10. Status and error feedback stays beside the attempted operation or in the fixed status/help
    regions, survives close/reopen where specified, uses the frozen non-color icon/text mapping, and
    never exposes checkpoint, protocol, request, coordinator, or other internal terminology.

### 17.4 Design Review/Revision verdict

**PASS.** Sections 5 through 10, the failure matrix, exact tests, and installed proof preserve the
approved design intent and now include an explicit renderer-token contract. The Builder may proceed
in section 12 dependency order. This is a plan approval, not Design Sign-off: the current prototype
fails criteria 1 through 10, and no human-visible task is complete until the actual installed
surface, VoiceOver behavior, and physical controller behavior pass section 15.

### 17.5 Track B local-production re-review

**PASS with one binding copy correction.** The section-0 boundary does not regress the designed
surface: Track B still delivers the complete four-step creator, five-tab sheet, explicit operation
controls with nonactionable rows/cards, path-scoped progression guidance, local quick-slot editor,
configurable Controls, four-page tutorial, all three required viewports, High Contrast, Reduce
Motion, shared semantic focus, the AppKit accessibility tree, isolated installed harness, and
physical RPG-scoped controller proof. Deferring Track C changes which authority states production
can reach; it does not remove any Track B screen, fixture, semantic descriptor, or installed design
criterion. The protocol-5 `.unavailable` title/help remains plain-language and correctly leaves the
sheet inspectable while explaining that quick-slot editing needs a compatible host session.

Because `.localReady` is now a production state for a single-player local world, the section-4.5
`ready` help must not falsely describe that world as host-authoritative. The binding Track B visible
help is `Character controls are available when their requirements are met.` and its VoiceOver
announcement is `Ready. Character controls are available when their requirements are met.` The
ready harness, semantic-summary assertions, focused-help output, accessibility help, and installed
proof use that neutral copy. A future Track C host uses the same truthful wording, so no mode-specific
fork is needed.

Creation Review also makes its authority caveat contextual with the exact binding strings from
section 5.2: `.localReady` uses `Create saves this character and starter kit to this world.` and
`.unavailable` uses `This LAN host does not support character creation. Your draft will not be
submitted.` Both are visible and accessibility help, with no protocol/version/coordinator
terminology. This clarifies copy only and does not change operation legality, persistence, authority,
or the section-0 build boundary.

Track B Design Sign-off remains blocked until the actual installed surface passes all ten criteria
in section 17.3, including physical VoiceOver and compatible-controller operation. Pending,
commit/reconnect/disposition, exhaustion, durable notice, and Neo behavior remain fixture-only or
unsigned until Track C passes its own ordered gates.

### 17.7 Typed status and harness-remediation binding amendment (2026-07-11)

Local quick-slot persistence failure is one validated `RPGStatusPresentation`, never a Boolean/text
overlay. GameCore issues a checked nonzero local identity for operation `saveQuickSlots`, target
`character`, kind `persistenceFailure`, and local-until-replaced persistence. A successful refresh or
session reset clears that whole value. Counter exhaustion fails closed without wrapping or reusing an
identity. When a local disk failure and an authority-phase status coexist, the local failure has
explicit precedence because it is the immediate actionable condition; text, icon, identity,
accessibility value/help, and semantic snapshot all consume that same effective status. Clearing it
atomically reveals the still-current authority status. The legacy
`rpgLocalPreferencePersistenceFailed` API is computed from the typed status only.

Authority and status band allocation and both installed renderers use the same bounded token-splitting
`rpgWrappedPresentationLines` result. Its conservative measure charges 6.5 logical units per UTF-8
byte and splits only at valid text boundaries, so CJK and emoji receive three- and four-byte width
budgets. The installed AppKit harness draws those exact lines in 9-point monospaced text at a 12-unit
stride with no secondary wrapping and four measured units of bottom glyph padding, including
unbroken wide ASCII and Unicode. The real glyph box of the final line must remain inside the model's
authority frame at every phase and viewport; the frame and content remain disjoint. Disabled
Assign/Move/Clear controls use
the exact sentence `Quick-slot editing requires writable local storage or a compatible host session.`
when no writable destination exists. `.authorityExhausted` Assign controls instead retain the exact
authority-phase sentence because that phase deliberately allows only moving or clearing already-valid
local slots.

This amendment also closes status kind/operation/identity combinations: action execution errors are
limited to selected/quick-slot use, persistence failures to quick-slot save or character creation,
authority pending/terminal statuses to their matching phases, and durable statuses to their durable
notice disposition. Selector parse/build failure is fatal with exit 64; it never falls back to an
ordinary or status-free fixture.

### 17.6 Security-remediation Design Review renewal

**PASS.** The Security-driven Architecture amendments preserve every Design Mock and section-17.3
acceptance criterion and improve the safety of reaching them without weakening the visible product.

- Reordering the work into pure foundations, a mandatory authority/scope/activation boundary, a
  passive renderer, and only then one actionable path does not remove or defer any Track B screen or
  operation. The passive phase is not a shippable intermediate state; installed Design Sign-off still
  requires every explicit operation and modality to be connected through the sole dispatcher.
- The neutral `.localReady` help and exact context-aware Creation Review strings remain binding in
  sections 4.5 and 5.2. Local worlds do not receive false host-authority language, while an
  unsupported LAN session remains inspectable and explains in plain language that its draft is not
  submitted.
- The checked world-entry generation and expected live revision preserve the player's current
  context during delayed completion. A stale same-world or A -> B -> A completion is correctly
  silent: it changes no visible value, selection, focus, status, revision, dirty state, or
  accessibility notification in the newly entered session. A real persistence failure for the
  current session retains the prior visible value and presents the specified `Could not save`
  status, so silence is limited to work that no longer belongs to the visible session.
- Origin-binding each cached accessibility element to the full committed
  `(screenInstanceID, semanticRevision, ID, commandFingerprint, semanticInputFingerprint)` tuple
  preserves the one-focus-system contract. A stale VoiceOver Press cannot act on a replacement; it
  receives the same fresh-activation-required feedback as other stale modalities, and a newly fetched
  element remains operable with one ordinary Press.
- Candidate-copy settings, keybind, and tutorial publication preserves the designed failure UX:
  failed persistence never makes a control appear changed, never marks the tutorial complete, never
  moves focus or rebuilds semantics, and exposes the bounded persistence-failure status adjacent to
  the attempted operation. Successful publication still produces the normal value/layout
  notification after commit.

No new design acceptance criterion is required. Design Sign-off remains conditioned on the complete
installed evidence in sections 15 and 17.3; the reordered build phases, unit/model evidence, and
passive renderer cannot substitute for the required visual, keyboard, VoiceOver, High Contrast,
Reduce Motion, viewport, and physical-controller inspection.

## 18. Security plan gate record (2026-07-10)

**Reviewed plan SHA-256:**
`68b949e262ea713f83e319d953aa45807a91bc4653b7409191df298a50e84147`

**Reviewed scope:** local-production Track B only. The review covered the mandatory pre-actionability
authority/scope, protocol-5 zero-fallback, and semantic-activation boundary; local preference
request/completion provenance, same-world and A -> B -> A ABA rejection, migration-envelope omission,
and persist-before-publish behavior; settings/keybind/tutorial candidate-copy publication; origin-bound
AppKit accessibility Press; menu-shortcut protection and AppKit event deduplication; controller
lifecycle/generation handling; pre-bootstrap harness isolation; exact visible/accessibility copy; and
the Track C exclusion boundary.

**Findings:** none. The five findings from the prior Security plan review are closed in the binding
architecture, dependency order, failure behavior, test matrix, risk map, and Conditions for Builder.
In particular, no actionable renderer or input path precedes the GameCore/LAN/activation gates; every
local completion is scope, world-entry-generation, expected-live-revision, and operation-postcondition
bound; legacy omission additionally revalidates envelope version/source and immutable origin; cached
accessibility elements retain the complete committed origin tuple; local-ready and Creation Review copy
is exact and context-truthful; and every settings/keybind/tutorial write-stage failure has caller-level
no-publication evidence.

**Verdict: PASS.** Build is authorized only for the closed Track B scope and only in section 12 order.
Security code review remains mandatory before installed Design Sign-off. This PASS does not authorize a
client checkpoint semantic adapter/facade, host writer, protocol-v6 activation/cutover, production
pending/terminal authority state, durable-notice acknowledgement, Neo proof, or any other Track C work.

## 19. Installed Design FAIL remediation Architecture renewal (2026-07-11)

### 19.1 Gate input and verdict

The fresh installed `/Applications/Elysium.app` Design Sign-off inspected 122 PNGs, 120 semantic
summaries, and 42 renewed three-frame captures across all three required viewports, creation,
tutorial, five tabs, eight authority phases, appearance variants, eighteen branch progression
fixtures, and representative rank/action/spell/slot states. That gate returned **FAIL** for seven
binding defects:

1. footer help overlapped Back/Close, Review Create scrolled out of view, and the created sheet had
   no explicit fixed Close descriptor;
2. Path and tutorial were unusable at `360x224`;
3. path/branch cards omitted visible product information, icons, and non-color selected geometry;
4. operation labels clipped and visible/accessibility values exposed registry IDs;
5. Actives placed all nine quick slots before path actions;
6. Progression omitted the complete 17-point route, two-point utility allowance, completion impact,
   and level-22 cross-branch constraint;
7. High Contrast did not use the approved two-unit light ring plus dark separation.

Architecture verdict: **PASS for remediation only.** The dependency order and contracts below are
binding. The prior installed Design Sign-off remains FAIL until all seven steps are implemented and
the complete fresh installed gate passes. Renewed Design Review inspected the complete amended
section at SHA-256
`593a9b5b9436f15896a643e8bbaf3e1273b8b39bf6ab330598e35e1b328ecf00` and returned **PASS**.
Security(plan) then reviewed the complete Builder contract at plan SHA-256
`ddbea2976ce5b05e61c924467538c34560e9682b34bb0d7444798182feb40724` and returned **PASS**.
This renewal authorizes no Track C
or protocol-v6 work.

### 19.2 Step 1 — one pure fixed-band layout contract

Primary files:

- `Sources/ElysiumCore/Game/RPGScreenModel.swift`;
- `Sources/ElysiumCore/Game/RPGScreenInteraction.swift`;
- `Sources/Elysium/RPGScreensM.swift`;
- `Sources/Elysium/RPGUIHarnessM.swift`.

Add `RPGScreenLayout` with `panelFrame`, `headerFrame`, `authorityChipFrame`, optional
`statusChipFrame`, optional shared `contextualDetailFrame`, `stepOrTabFrame`, `contentFrame`,
`commandFrame`, and `footerHelpFrame`. Add `RPGSemanticLayoutRegion` with `.fixed` and
`.scrollingContent`, and store it on every `RPGSemanticDescriptor`.

The exact fixed geometry is:

- outer margin 6;
- panel `min(700, viewportWidth - 12)` by `min(420, viewportHeight - 12)`, centered;
- header 24;
- authority chip 18;
- optional status chip 18 whenever a status exists;
- one shared contextual-detail allocation whose exact measured height is
  `max(18, lineCount * 12 + 4)` and whose cap is
  `min(72, panelHeight - headerHeight - chipHeights - stepTabHeight - commandHeight -
  footerHelpHeight - minimumVisibleContentRowHeight)`;
- step/tab bar 20;
- command bar 26;
- footer-help band 18.

`lineCount` is the exact `rpgWrappedPresentationLines` result at the detail frame's inner width;
`minimumVisibleContentRowHeight` is 20. The frozen 160-byte copy bounds and conservative wrapper must
prove that the chosen detail fits that cap at every required viewport; no secondary wrapping,
ellipsis, or overlap is permitted.

The authority and status chips are always visible, independently focusable, and retain their full
value/help in accessibility even when their detail is not expanded. At most one contextual detail
is visible. Precedence is exact: a focused status chip presents the status detail first; otherwise a
focused authority-disabled operation presents its exact authority reason; otherwise a focused
authority chip presents authority help; otherwise the shared detail frame is absent. A hidden
detail never removes the other chip or its accessible help. At `360x224`, ready/no-status content is
exactly 106 units high; every authority-by-status-by-focus combination retains at least one complete
20-unit content row.

Only
`.scrollingContent` descriptors may be translated by an offset or focus reveal. Replace the current
coordinate/role/ID exceptions in content shifting and `rpgRevealInteractionFocus` with
`layoutRegion`. Focusing a fixed descriptor never changes scroll.

Add `rpgAnchoredScrollOffset(previousFocusedFrame:newUnscrolledFocusedFrame:currentOffset:
contentHeight:viewportHeight:)`. When contextual detail expands or collapses while the focused
operation belongs to `.scrollingContent`, calculate the candidate offset as
`currentOffset + (newUnscrolledFocusedFrame.y - previousFocusedFrame.y)` before the one clamp. If the
candidate is in range, the focused operation's screen-space frame is exactly unchanged. If a bound
makes equality impossible, choose the clamped offset with the smallest absolute displacement and
then apply only the smallest necessary nearest-edge delta that makes the full focused frame visible;
ties choose the lower offset. Missing/invalid prior geometry uses the ordinary single clamp. No
second anchoring or renderer-local correction is allowed.

The command bar owns these stable controls:

- Creation Path: `Close` left, `Next` right;
- Branch/Attributes: `Back` left, `Next` right;
- Review: `Back` left, `Create Character` right;
- Tutorial: `Close`, applicable `Back`, `Skip`, and `Next` or `Finish`;
- every created-sheet tab: `Close` in the left slot, dispatching `.back`.

Review always publishes a fixed Create descriptor. Invalid budget, unmet Foundation requirement,
inventory capacity, and authority states disable it, remove its command, and retain the exact
canonical visible/accessibility reason. Footer help draws only in `footerHelpFrame`; it never shares
pixels with any command.

### 19.3 Step 2 — usable compact creator and tutorial

In `RPGScreenModel.swift`, replace the obsolete compact two-column Path assumption. If width is
below 520 or height below 330, Path is one full-width virtualized card per row; medium/large remains
a three-by-two grid. Compact Branch remains one full-width card per row; medium/large remains three
columns. Compact card text stride is 9, icons are 24 by 24, and the operation row is 20. Card height
is calculated from the exact wrapped lines; the frozen registry must prove that every compact Path
card is at most the 106-unit ready content height.

Tutorial content is an adaptive group wholly contained by `contentFrame`; tutorial operations live
only in `commandFrame`. `stepOrTabFrame` visibly and semantically identifies Path, Branch,
Attributes, Review, or `Tutorial n of 4`. At initial compact presentation, one complete Path/Branch
card or the complete tutorial panel is visible. Focusing the first, last, or an offscreen card uses
the existing one clamp and minimum reveal delta. No partially visible card operation is actionable.

### 19.4 Step 3 — visible card content, icons, and selected geometry

In `RPGScreenModel.swift`, extend the bounded descriptor presentation with:

- `iconAssetID: String?`;
- `visualLines: [String]`;
- `RPGDescriptorAdornment` cases `.none`, `.selectedCheckDoubleBorder`, `.moveLeft`, and
  `.moveRight`.

Path cards render in this order: `rpgAssetIDForPath(path.id)` at 24 by 24, display name, full wrapped
`Role`, full `Primary`, full wrapped `Preset`, then literal `Selected` or explicit
`Choose <Path>`. A selected card draws all three non-color cues: a check, literal `Selected`, and two
nested borders.

Branch cards render the Foundation starter icon from
`rpgAssetIDForSkill(branch.skillIDs[0])`, branch display name, `Active Foundation` or
`Passive Foundation`, the full rank-one Foundation benefit, and rank-one automatic spell unlock
display names or `Automatic unlocks: None`. They use the same selected check/literal/double-border
contract. Registry/asset mismatch fails the fixture/model; it never invents an alias or per-branch
asset.

`RPGScreensM.swift` consumes `UICanvas.drawRPGIcon`; `RPGUIHarnessM.swift` renders the pixels returned
by `rpgIconPixels(assetID:)`. Both renderers consume the model's exact lines and adornments rather
than reconstructing or clipping card content.

### 19.5 Step 4 — complete display names, labels, and directional affordances

Add these pure helpers in `RPGScreenModel.swift`:

- `rpgPreparedActionDisplayName(_ token: String?)`;
- `rpgWrappedControlLines(_ text: String, width: Double)`;
- `rpgControlHeight(lines:)`.

Add typed `RPGCreationReviewItemProjection` and `RPGCreationReviewChordProjection` values to
`RPGCreationReviewProjection`. Item projections resolve each starter-kit item and optional potion
through the canonical item/potion registries and contain only display name, count, and optional
display-name detail. A missing registry display name fails the Review projection; it never falls
back to `itemID` or `potionID`. Chord projections use one closed action-display switch:
`Character`, `Cycle Prepared Action`, `Use Selected Action`, and `Quick Slot 1` through
`Quick Slot 9`, paired with the sanitized chord. They never render `rpgCharacter`,
`rpgCycleAction`, `rpgUseAction`, or `rpgQuickSlotN`.

All visible values, labels, canonical reasons, and accessibility help resolve registered display
names. Registry IDs remain only in stable semantic IDs and commands. An unknown normalized token
renders a bounded `Unavailable action`, never its raw token.

Every operation frame grows to contain the complete precomputed label lines. Row stride is
`max(baseStride, operationHeight + padding)`, so an operation cannot overlap its owner row. Required
visible labels include complete `Rank Up <Display Name>`, `Prepare`, `Unprepare`, and `Select`
variants. Slot values use display names such as `Frost Ray`, never `spell:frost_ray`.
Move controls visibly render `← Move Left` and `Move Right →`, carry distinct `.moveLeft` and
`.moveRight` geometry, and expose accessibility labels `Move Quick Slot N Left/Right`.

Both renderers draw the precomputed lines. Their descriptor render paths may not call
`clipped(descriptor.label, ...)`, ellipsize an operation, or make a clipped frame actionable.
Creation Review visible text, descriptor label/value/help, accessibility label/value/help, and
VoiceOver announcements contain no raw item/action ID, prepared-action token, underscore-bearing
registry spelling, or semantic tag. Stable descriptor IDs and commands remain internal identity and
are not Review copy sinks.

### 19.6 Step 5 — Actives-first hierarchy

Rebuild the Actives descriptor order in `RPGScreenModel.swift` as:

1. `Path Actions` section heading;
2. every current-path active summary card in frozen skill-registry order;
3. one `Selected Action` inspector for `RPGScreenSelection.inspectorItemID`, containing the exact
   Prepare/Unprepare, Select, and Assign operations;
4. `Local Quick Slots` section heading;
5. slots 1 through 9 with Clear and Move operations.

No prepared action expands inline ahead of later action summaries. At `360x224` and `520x330`, the
heading and first complete path action are initially visible. The prepared Heavy Cut installed
fixture must visibly expose Heavy Cut without scrolling past slots. This is presentation reordering
only; commands and local/authoritative ownership do not change.

### 19.7 Step 6 — complete progression route

Add `RPGProgressionPlanProjection` to `RPGProgressionSummaryProjection` in
`RPGScreenModel.swift`. It contains `selectedBranchDisplayName`, nine registry-derived
`routeMilestones`, `completionCost`, `levelCapEarnedSkillPoints`, `utilityAllowance`,
`completionImpactText`, and `crossBranchCapstoneText`.

All values derive from `rpgSpecializationRoadmap`, `rpgSkillPointCost`, `rpgMinimumLevel`,
`rpgEarnedSkillPoints`, and the repaired state. The canonical route is:

- free Foundation I at level 1, 0 SP;
- Foundation II at level 4, 2 SP;
- Technique I at level 5, 1 SP;
- Foundation III at level 8, 3 SP;
- Technique II at level 10, 2 SP;
- Mastery I at level 12, 1 SP;
- Technique III at level 14, 3 SP;
- Mastery II at level 16, 2 SP;
- Mastery III at level 20, 3 SP.

The model visibly and semantically states the 17-earned-SP completion cost, 19 SP earned by level
20, the two-SP utility allowance equal to one cross-branch Foundation I, and current truthful
completion impact. The exact constraint sentence is:
`Cross-branch Mastery III requires level 22; the level cap is 20, so it is unreachable.`

Progression ordering is selected branch/route, completion cost, utility allowance, completion
impact/divergence, cross-branch constraint, then levels 1 through 20 and existing detail. All copy is
visible through the shared scroll path and present in semantic value/help for every one of the
eighteen branches.

### 19.8 Step 7 — one shared focus-ring token

Add `RPGFocusRingToken`, `rpgFocusRingToken(highContrast:)`, and
`rpgFocusRingGeometry(frame:token:)` to `RPGScreenModel.swift`.

- Standard is a one-unit light outer ring plus one-unit dark inner separation.
- High Contrast is a two-unit light outer ring plus one-unit dark inner separation.
- Both rectangles remain wholly inside `visibleFrame`.

`RPGScreensM.swift` and `RPGUIHarnessM.swift` consume this exact API for every ordinary descriptor,
authority chip, and status descriptor. Remove `systemOrange`, renderer-local focused widths, and
one-off authority/status focus rectangles. Hover color is never a focus substitute.

### 19.9 Test contract and risk-to-test map

Update `RPGScreenModelTests.swift`, `RPGScreenInteractionTests.swift`,
`RPGSemanticAccessibilityTests.swift`, `RPGUIHarnessTests.swift`, and
`RPGUIHarnessSourceTests.swift`.

| Risk | Required closing evidence |
| --- | --- |
| Fixed/footer collision or scrolling command | pairwise-disjoint, panel-contained bands at all three viewports and every authority/status height; fixed focus and arbitrary scroll leave command frames unchanged |
| Competing authority/status detail starves content | exhaustive eight-authority-phase by status-absent/present by focus-none/status/authority/authority-disabled-operation matrix at all three viewports; assert chip persistence, exact status-first precedence, one detail maximum, exact measured height, disjoint bands, full untruncated detail, and at least one complete visible content row |
| Context detail reflow jumps focused operation | expansion and collapse tests at top/middle/bottom offsets prove exact screen-space focused-frame equality whenever the candidate offset is in range; clamped cases prove minimum absolute displacement, smallest necessary edge reveal, deterministic lower-offset tie, and one clamp only |
| Hidden or falsely enabled Create/Close | every creation profile and authority phase has visible fixed Create with exact command/reason; every created tab/tutorial has visible Close; tutorial Close writes no completion |
| Compact blank/partial surface | every Path/Branch and all four tutorials initially expose one complete panel at `360x224`; first/last/offscreen focus uses one clamp and no partial action |
| Card information remains accessibility-only | all six Path and eighteen Branch fixtures compare exact icon, visible lines, benefit/unlocks, help, and check/literal/double-border state |
| IDs or clipped operation copy leak | all nineteen actives, seventeen spells, and slot profiles contain display names in visible/accessibility sinks; joined control lines equal the complete label and fit their frames; raw tokens are absent |
| Review leaks implementation identifiers | all six path Review fixtures compare every kit item/potion and all twelve chord actions against canonical display names in visible and accessibility sinks; reject raw item/action IDs, tokens, underscores, and semantic tags |
| Move controls remain indistinguishable | distinct left/right labels, adornments, frames, commands, and accessibility names |
| Actions remain buried | every current-path active precedes `Local Quick Slots`; compact/medium prepared fixtures show the target action initially |
| Progression remains incomplete or hard-coded incorrectly | all eighteen branches prove nine ordered milestones, total 17, level-cap 19, utility 2, current completion impact, and exact level-22 sentence from canonical evaluators |
| Renderer focus divergence | pure token tests prove standard 1+1 and High Contrast 2+1 geometry; source tests prove both renderers use the shared API and contain no `systemOrange`/local focused width |
| Geometry broadens activation | hit tests reject every partial frame; passive-model copying preserves presentation/region fields while stripping every command; stale accessibility-origin suites remain green |

Run the focused model/interaction/accessibility/harness suites after each material correction, then
the complete Track B focused group. No visual golden is moved merely to accept a collision or clip.

### 19.10 Installed acceptance

After renewed Security code PASS, build and install a fresh `/Applications/Elysium.app` and repeat the
entire section-15/17.3 Design Sign-off. At minimum renew:

- every creation step/profile at `360x224`, `520x330`, and `700x420`;
- all six Path and eighteen Branch cards;
- all six Review fixtures with canonical starter-kit and twelve configured-action display names in
  visible and VoiceOver copy and no raw identifiers;
- all four tutorial pages at compact size;
- Review valid, invalid-budget, unmet-requirement, capacity, and authority states with fixed Create;
- all five tabs, including prepared Heavy Cut, compact Skills, selected Frost Ray, and maximal slots;
- all eighteen progression summaries;
- the exhaustive authority/status/focus contextual-detail matrix, including visible chip precedence,
  one retained content row, and expansion/collapse focus anchoring;
- Standard and High Contrast pixel inspection of the shared ring;
- physical keyboard focus/reveal/activation, VoiceOver discovery/offscreen reveal/Press and
  announcement deduplication, and a compatible physical controller for sheet/world mappings.

The full 6/18/54/162 registry coverage and every prior authority/status/appearance condition remain
binding. Screenshots and semantic summaries support but do not replace physical operation. Any
unavailable physical surface remains unsigned and blocks full Design Sign-off.

### 19.11 Security impact

The remediation changes no persistence format, authority decision, LAN route, registry order, or
gameplay mutator. It still requires renewed Security plan confirmation and Security code review
because descriptor ordering, fixed commands, hit rectangles, focus reveal, accessibility origins,
and token display parsing change the activation surface. Security must verify:

- no overlapping or partially visible actionable frame;
- fixed Close/Create commands are exact and receipt-bound;
- passive copying retains new presentation/region fields while stripping commands;
- display-name formatting accepts no new token grammar and has no raw-ID fallback;
- all layout arithmetic remains finite, bounded, and registry-capped;
- contextual-detail precedence cannot obscure a higher-priority status or create overlapping hit
  regions, and reflow anchoring cannot move a fixed command or bypass the one clamp;
- cached accessibility Press retains the complete origin tuple and stale rejection behavior.

### 19.12 Conditions for Builder

- Implement sections 19.2 through 19.8 strictly in order; a material geometry/API change returns to
  Architecture and Design Review before later work continues.
- Update only durable docs whose claims change, and use the exact RPG domain language above.
- `RPGScreenModel` remains the sole source of rectangles, visible lines, adornments, display names,
  and focus geometry; renderers perform no alternate layout or label reconstruction.
- Fixed and scrolling descriptors are explicit, and the one clamp is the only offset/reveal path.
- Authority and status chips are always present when applicable; their shared detail follows the
  exact status-first precedence and measured cap, leaves one visible content row, and preserves all
  non-expanded help through accessibility.
- Context-detail expansion/collapse anchors the focused scrolling operation with
  `rpgAnchoredScrollOffset`; exact equality is required when representable, otherwise only the
  deterministic smallest clamped edge displacement is allowed.
- Create and Close are always present in their required fixed states; disabling removes capability,
  never the explanation.
- Card selection retains check, literal state, and double border; High Contrast retains 2+1 focus
  geometry; no required distinction is color-only.
- Registry IDs remain valid semantic identity only and never leak into visible/accessibility copy;
  every Review item, potion, and configured action uses its typed canonical display projection with
  no fallback spelling.
- Actives reordering and progression projection do not alter authoritative selection, quick-slot
  ownership, point costs, gates, or mutation commands.
- Renewed Design Review and Security(plan) are PASS at the section-19 hashes recorded above. Builder
  implementation still requires renewed Security code review before installed Design Sign-off. After the
  final code change, renew Security code PASS, fresh installed Design Sign-off, independent Test,
  `scripts/pipeline.sh`, deploy, and installed local-world proof. Any later renderer/runtime change
  invalidates and repeats affected evidence.

### 19.13 Builder implementation record (2026-07-11)

**Builder verdict: PASS. Downstream gates remain pending.** The approved section-19 implementation
was completed in dependency order through sections 19.2...19.8. `RPGScreenModel` now owns the nine
layout bands, fixed/scrolled region identity, contextual-detail precedence and anchoring inputs,
complete wrapped labels, typed Review display projections, Actives selection/ordering, progression
plan projection, card adornments, and shared focus-ring geometry. Both production and harness
renderers consume those projections without reconstructing RPG labels or focus widths.

Initial Builder closing evidence before Security(code) review:

- the combined affected debug group executed **170 tests with 0 failures** in 65.002 seconds:
  screen model, interaction, semantic accessibility, harness, harness source, controller/input,
  local preferences, quick-slot input, and passive/accessibility/source guards;
- the repository debug executable completed a clean-environment compact High Contrast Progression
  harness smoke for `tab:warden:warden_guardian:progression` with exit 0 and 48 semantic-summary
  lines, including the Ready authority projection, nine selected-branch milestones, 17-SP completion,
  19-SP level-cap earnings, and the exact level-22 unreachable sentence;
- no persistence format, LAN protocol/route, registry ordering, authority decision, or release pin
  changed in this Builder pass.

This record is Builder evidence only. It does not claim renewed Security(code), installed Design
Sign-off, independent full Test, release pipeline, deploy, or installed local-world proof; those
ordered gates remain required before section 19 or Track B can be called complete.

### 19.14 Security(code) finding remediation record (2026-07-11)

**Builder remediation verdict: PASS; Security(code) re-review remains pending.** The first
Security(code) review returned FAIL with three activation/presentation findings and one low-severity
canonical-name drift risk. Builder corrected each finding without changing persistence, LAN,
authority decisions, registry order, or release pins:

- every descriptor now passes one shared complete-line width/height contract before retaining a
  command; an overflow fails closed by removing the command and enabled hit capability, the 22x20
  attribute controls publish complete `-`/`+` visual lines, and both renderers guard the whole
  descriptor instead of silently breaking a partial line loop;
- authority-operation detail now comes only from an exact otherwise-legal semantic command whose
  `requiresAuthority` contract is true and which authority disables. Status focus remains first;
  fixed Close/Back and tutorial commands never qualify;
- interaction state retains the prior focused absolute screen frame. Expansion/collapse rebuilds
  anchor the next unscrolled frame against that prior frame while using the new content origin for
  deterministic visibility clamps;
- starter-kit Review and `registerItem` now consume one closed pre-bootstrap display-name source;
  unknown IDs have no fallback and a parity test compares every reachable starter item with the
  live registered definition.

After the final remediation source change, `swift build` passed and the expanded affected debug
group executed **174 tests with 0 failures** in 64.462 seconds. Added evidence exhaustively covers
enabled-action visual fit across every path/branch/tab/creation step, three viewports and tutorial
pages; exact status/authority/legality precedence; real reducer expansion and collapse with changed
`contentFrame.y`; both renderer source guards; and complete starter-kit registry parity. This is
remediation evidence for renewed Security(code), not a self-issued Security PASS.

### 19.15 Security(code) re-review anchoring remediation (2026-07-11)

**Builder remediation verdict: PASS; final Security(code) disposition remains pending.** Re-review
found that reducer anchoring alone allowed production to publish one provisional expanded model
before the next input reconciled it, and that explicit focused scrolling retained a stale screen
anchor capable of snapping a later scroll backward.

Production now builds a provisional pure model, reconciles its focused absolute screen frame with
`rpgReconcileProvisionalScreenModel`, rebuilds only when the anchored offset changed, and performs
the existing semantic commit exactly once with the final model. Thus no provisional geometry or
semantic revision is observable. Explicit `.scrollRows` clears `focusedScreenFrame` immediately;
the next rebuild preserves the user-selected offset without resurrecting the pre-scroll anchor.

Closing Builder evidence after this source change:

- `swift build`: PASS, exit 0;
- focused model/interaction/production-source/harness-source group: **68 tests, 0 failures**;
- expanded affected debug group: **175 tests, 0 failures**, exit 0, in 64.489 seconds;
- integration coverage proves expansion and collapse reconcile before the single final commit and
  two consecutive focused scroll events advance 40 -> 68 -> 96 without snapback;
- source coverage proves provisional build, reconciliation, conditional final build, and the sole
  `commitRPGSemanticModel` occur in that order.

No persistence, LAN, registry-order, authority-decision, release-pin, or deploy behavior changed.

## 20. Fresh installed Design FAIL four-finding remediation Architecture (2026-07-11)

### 20.1 Gate input, scope, and verdict

Fresh installed Design Sign-off inspected executable SHA-256
`0a4f1c3e6d0e8da7ff4e6526d77e191df0b3c0757c93ccdd807a712f804ca90e` through 486 PNGs
and 662 semantic summaries and returned **FAIL** for exactly four code-visible defects: blank
creation/tutorial step bands, a missing compact Progression tab, authority help that remained
accessibility-only under default focus, and rank selectors whose requested offscreen cell was not
revealed. Architecture verdict: **PASS for this four-finding remediation only.** The work below is
dependency ordered; it changes no RPG rules, persistence, authority decision, LAN route, registry
order, or Track C contract. Installed Design Sign-off remains FAIL until all four corrections pass a
fresh installed renewal.

### 20.2 Step 1 - make step and tutorial lines model-owned

In `Sources/ElysiumCore/Game/RPGScreenModel.swift`, the existing `creation-step:<step>` and
`tutorial-step` descriptors must publish their complete `Path`, `Branch`, `Attributes`, `Review`, or
`Tutorial N of 4` text in `visualLines`, using the same bounded model-owned wrapping and complete-fit
contract as every other descriptor. `label`, `value`, accessibility help, `stepOrTabText`, and
`visualLines` must agree. `Sources/Elysium/RPGScreensM.swift` and
`Sources/Elysium/RPGUIHarnessM.swift` continue to use only the generic descriptor renderer; neither
may reconstruct or special-case step text. Empty lines, ellipsis, or accessibility-only fallback are
invalid.

### 20.3 Step 2 - allocate five complete compact tabs

Add a pure `rpgCharacterTabFrames(in:)` projection in `RPGScreenModel.swift`. It returns all five
tabs in frozen `RPGCharacterTab.allCases` order with one complete model-owned visual line each.
For label `i`, minimum width is exactly
`ceil(sharedConservativeTextWidth(label_i)) + 8`. Sum the five finite positive minimums with checked
arithmetic, compute `remaining = frame.width - minimumSum`, and distribute exactly `remaining / 5`
to each tab. Construct each `x` from the previous tab's `maxX`; the first begins exactly at
`stepOrTabFrame.x`, and the fifth receives the residual final width so it ends exactly at
`stepOrTabFrame.maxX`. No integral rounding is performed after the minimum-width `ceil`. The function
returns `nil` if any input/intermediate is non-finite, non-positive, overflows, or the five minimums
do not fit. A `nil` projection fails the entire screen build to the existing bounded command-free
error model; it may not omit one tab while leaving the sheet or another tab actionable. At the
supported 360-point viewport the complete labels `Character`, `Skills`,
`Actives`, `Spells`, and `Progression` must fit on one line. Frames are positive, pairwise disjoint,
wholly contained by `stepOrTabFrame`, and remain the sole draw, focus, accessibility, and half-open
hit-test geometry. Equal-width reconstruction, clipping, abbreviation, overlap, or an off-frame
semantic tab is forbidden in both renderers.

### 20.4 Step 3 - resolve focus before final contextual layout

Refactor `rpgBuildScreenModel` in `RPGScreenModel.swift` into an uncommitted candidate/final pass.
The candidate establishes the actual focusable descriptor order without contextual detail. Resolve
the requested focus only if it exists and is focusable; otherwise choose the first focusable
descriptor, which is the authority chip. Derive the one contextual-detail value from that resolved
focus with the existing exact precedence: focused status, otherwise an otherwise-legal
authority-disabled operation, otherwise focused authority, otherwise none. Build and return only the
final layout/model with that value and the same resolved focus. No candidate geometry, summary, or
semantic revision may escape, and no recursive renderer correction is allowed. The candidate is a
private pure value only: it is never wrapped in a passive/committed snapshot, never receives semantic
inputs, never reaches a callback/renderer/accessibility builder, and never supplies a capture or hit
test. Before return, re-fetch the resolved ID in the final descriptors and require the same
focusability plus the exact same command fingerprint and authority-requirement classification as the
candidate. Missing or changed final identity fails to the bounded command-free error model instead of
falling back to another focus or publishing the candidate. Thus an ordinary
authority fixture with no requested focus visibly allocates the complete frozen authority help
before `contentFrame` is finalized, while explicit status and scrolling focus retain their existing
meaning and at least one complete content row remains at 360x224.

The final pass must also preserve the section-19 compact-surface acceptance that the candidate pass
previously satisfied: with the complete default `Ready` help allocated at `360x224`, the selected
Path or Branch card, or the complete adaptive tutorial panel, remains wholly visible inside the
final `contentFrame`, and every command remains wholly visible in `commandFrame`. Compact card and
tutorial height may remove unused vertical space but may not omit, tighten below the frozen text
stride, clip, or overlap any required icon, visual line, selected adornment, or control. If the exact
measured help and exact required content cannot fit, model construction fails closed and returns to
Architecture; it may not hide the authority explanation or publish a partial card/tutorial as the
remedy.

### 20.5 Step 4 - reveal selector-requested focus before harness publication

Expose one pure shared reveal calculation from
`Sources/ElysiumCore/Game/RPGScreenInteraction.swift` and use it both from
`rpgRevealInteractionFocus` and `Sources/ElysiumCore/Game/RPGUIHarness.swift`. For a harness selector
that requests focus, build an uncommitted model, verify that the exact requested ID exists and is
focusable, apply the shared one-clamp nearest-edge reveal to that ID, then rebuild the final
`RPGScreenModelInput` and model at the revealed offset. Only that final input/model may enter
`RPGUIHarnessFixture`, its summary, accessibility tree, or PNG renderer. A missing selector target,
partial target, non-finite offset, or target still not wholly visible fails fixture construction;
fixed targets retain zero reveal. The helper returns an optional checked offset and validates finite
positive content/viewport geometry, finite descriptor geometry, explicit fixed-versus-scrolling
region, `descriptor.height <= viewport.height`, checked offset/delta intermediates, and final
half-open containment. Invalid or impossible geometry returns `nil`; production performs no focus
change or activation, while the harness fails fixture construction. After the final harness rebuild,
re-fetch the requested ID and require matching focusability, layout region, command fingerprint, and
full visibility before constructing any fixture output. The helper may not synthesize semantic
revisions, dispatch input, or duplicate the reducer's reveal arithmetic.

### 20.6 Risk-to-test map

Update `RPGScreenModelTests.swift`, `RPGScreenInteractionTests.swift`,
`RPGUIHarnessTests.swift`, and `RPGUIHarnessSourceTests.swift`.

| Risk | Required closing evidence |
| --- | --- |
| Step/tutorial remains semantic-only | every creation step and all four tutorial pages at all three viewports have exact nonempty fitting `visualLines`; both renderers consume the generic model-owned line path only |
| Compact tab disappears or overlaps | at 360x224 and both larger viewports, five full one-line labels fit; frames are finite, positive, contained, pairwise disjoint, cover the ordered strip, and boundary hit tests select exactly one tab |
| Default authority help is omitted or wrong detail wins | all eight authority phases at all three viewports with no requested focus resolve authority focus and exact visible wrapped help; explicit status and authority-disabled-operation cases retain precedence, disjoint bands, and a complete content row |
| Authority detail re-breaks compact creation/tutorial | every creation step and all four tutorial pages at `360x224` allocate complete default `Ready` help while retaining one wholly visible selected Path/Branch card or complete tutorial panel, all required visual lines/adornments, and every fixed command; assert no hidden help, partial descriptor, reduced text stride, or overlap |
| Selector focus is semantic but offscreen | every accepted one of the 162 rank fixtures at all three viewports has the exact requested focused rank wholly inside `contentFrame`; final input/model offsets agree, fixed focus does not scroll, and invalid selectors fail closed |
| A provisional surface leaks | behavior/source tests prove candidate -> resolved focus/detail -> final model and candidate -> requested reveal -> final harness model ordering, with summary/accessibility/PNG consuming only the final value |
| Hit surface broadens | tab and revealed-rank hit tests retain complete visible-frame activation, passive copies strip commands, and stale accessibility-origin tests remain green |
| Failed projection/reveal leaves partial capability | non-finite/undersized tab frames, over-tall reveal targets, overflowed deltas, final-pass descriptor removal, command-fingerprint/classification drift, and final harness ID/region/focusability drift all produce the bounded command-free error model or a rejected fixture with zero snapshot, semantic input, accessibility element, hit result, or activation capture |

Run the focused model/interaction/harness/source suites after each step, then the complete Track B
focused group. No golden may move merely to accept blank, clipped, overlapping, or unrevealed UI.

### 20.7 Installed renewal and Security impact

After renewed Security(code) PASS, rebuild and install a fresh `/Applications/Elysium.app`; prior
release hashes and screenshots are stale. Repeat the complete section-19 installed matrix, with
explicit pixel and semantic checks for all creation/tutorial step bands, all five compact tabs, all
eight authority explanations, and all 162 requested rank cells visibly revealed. Renew keyboard,
VoiceOver, controller, and ordinary installed-world evidence where the required physical surfaces
are available; unavailable physical evidence remains unsigned and cannot be converted into a code
PASS.

Security(code) must verify finite/bounded tab and reveal arithmetic, disjoint half-open hit frames,
complete visible labels before capability, exact authority/status precedence, no provisional
semantic publication, fail-closed missing selector IDs, passive command stripping, and unchanged
receipt/origin validation. Any material correction repeats the affected gate.

### 20.8 Conditions for Builder

- Implement sections 20.2 through 20.5 strictly in order and do not broaden beyond the four
  installed findings.
- `RPGScreenModel` remains the sole source of step/tab text and geometry; renderers do not measure,
  wrap, abbreviate, reposition, or recover it.
- Focus is resolved before final contextual layout, and selector reveal is applied before the sole
  harness model publication; intermediate candidates are never observable.
- Candidate/final descriptor identity, focusability, command fingerprint, authority classification,
  and requested harness layout region are revalidated exactly. Any drift fails closed without a
  partial actionable model, automatic alternate focus, or fixture output.
- Default authority-detail allocation must retain the complete compact selected card/tutorial and
  fixed commands; it may reclaim only unused vertical space and may not trade away visible hierarchy
  to make the help fit.
- Use the one shared clamp/reveal calculation. All complete-label, containment, disjointness,
  visibility, authority precedence, and fail-closed invariants above are mandatory.
- Tab partition and reveal arithmetic use the exact checked formulas above. Projection/reveal failure
  returns the bounded command-free model or no fixture; it never omits a control while retaining
  adjacent capability.
- Preserve RPG rules, persistence, authority decisions, LAN/protocol behavior, registry order,
  semantic receipt/origin validation, and existing user changes.
- After the final source change: renewed Security(code), fresh installed Design Sign-off,
  independent full Test, `scripts/pipeline.sh`, deploy, and installed proof are required before this
  remediation or Track B is complete.

### 20.9 Security(plan) renewal record (2026-07-11)

Security reviewed the Architecture input at SHA-256
`c64fd0f5cf61ea4226ad4bf55c69d7a8c6845d38f83f8534b9a9ccc5d1f3da9e` against the four installed
failures and the existing semantic receipt, accessibility-origin, full-frame hit, passive-copy, and
pre-commit anchoring contracts. Three underspecified fail-closed boundaries were made binding above:
exact cumulative tab arithmetic and whole-model failure, candidate/final descriptor identity and
command-classification revalidation, and optional checked reveal plus final harness-target
revalidation. With those amendments, no candidate can publish semantic capability, no failed tab can
leave an adjacent actionable sheet, and no invalid selector/reveal can produce a fixture, hit target,
accessibility element, or activation capture.

**Security(plan) verdict: PASS for Section 20 only.** Build is authorized only in sections 20.2
through 20.5 order. This PASS does not authorize persistence, RPG-rule, LAN/protocol, registry-order,
receipt/origin, Track C, or deployment changes. The actual diff still requires renewed
Security(code) PASS before installed Design Sign-off.

### 20.10 Builder implementation record (2026-07-11)

**Builder verdict: PASS; downstream gates remain pending.** Sections 20.2 through 20.5 were
implemented in dependency order:

- creation and tutorial step descriptors now own exact nonempty fitting `visualLines` that agree
  with their label, value, help, and `stepOrTabText`;
- `rpgCharacterTabFrames(in:)` performs the checked five-label minimum-width partition, closes the
  strip with the fifth residual frame, and causes a whole-model command-free failure if projection
  is impossible;
- `rpgBuildScreenModel` now keeps its no-detail candidate private, resolves the actual focus,
  derives exact status/authority detail, builds only the final return value, and revalidates final
  focus identity, focusability, command fingerprint, and authority classification. Compact selected
  cards are deterministically first and exact-height; tutorials use complete adaptive model lines;
- `rpgRevealScrollOffset` is the one optional finite nearest-edge calculation used by reducer and
  harness. Harness candidate targets are revalidated after the revealed final rebuild for exact ID,
  focusability, region, command fingerprint, offset agreement, and whole-frame visibility before
  summary or fixture publication.

Closing Builder evidence after the final source change:

- per-step checkpoints: 20.2 model/renderer 2 tests passed; 20.3 checked-tab tests passed; 20.4 full
  model suite 40 tests passed; 20.5 reveal/harness/source checkpoint 3 tests passed;
- complete Section-20 model/interaction/harness/source group: **85 tests, 0 failures**;
- expanded affected Track-B debug group: **180 tests, 0 failures**, exit 0, in 70.370 seconds;
- all 162 rank cells at all three installed viewports produced 486 final fixtures whose requested
  rank was wholly visible and whose final input/model offsets agreed;
- `swift build`: PASS, exit 0.

No RPG rule, persistence, authority decision, LAN/protocol route, registry order, semantic
receipt/origin contract, release pin, installation, deployment, or commit changed in this Builder
pass. Renewed Security(code), installed Design Sign-off, independent full Test, pipeline, and deploy
remain mandatory.

### 20.11 Security(code) finding remediation record (2026-07-11)

**Builder remediation verdict: PASS; Security(code) re-review remains pending.** Builder corrected
the three findings from the first Section-20 Security(code) review in order:

1. Rank rows now size from the complete model-owned rank label/value lines and the adjacent operation
   height. Final harness validation also requires the shared complete-line fit contract. The 162-rank
   by three-viewport fixture matrix verifies exact visible frames, full line fit, visible-descriptor
   membership, and midpoint hit identity. `skill:safe_fuse:3:current` at 360x224 was rendered through
   the real debug harness and visually inspected with `Safe Fuse, rank 3` plus `Current rank` wholly
   visible and focused; it is not a Blast Shape-only row.
2. Fixed-target reveal now requires finite derived edges, exact `visibleFrame == frame`, and whole
   panel containment before returning the unchanged clamped offset. An out-of-panel fixed target
   returns nil and the reducer preserves focus and scroll byte-for-byte.
3. The five-tab projection now validates input and derived `maxX`/`maxY`, every constructed tab edge,
   and each cumulative next `x` for finiteness. Greatest-finite origin/extent overflow fixtures
   return nil rather than publishing partial tab capability.

Fresh debug-render preview evidence consists of four 720x448 RGBA PNGs produced by the repository
debug executable at compact viewport: Safe Fuse rank 3
`ef724660cc0ab346f326ffb2e560c8b5298a45537dc19cb633990eb713a73cf8`, five tabs
`31dd9b5054c8989413bfe303de274526d47d647b94c0dfbcffaa85f319f7457b`, creation
`5e22a718d50569353c23eb9c06484e1d1e36dcf70869d4a8f290f25f6878e988`, and tutorial
`e9eb1667345d04a8e70311397b7494e5d3558dec6df32878a3f7e99b2edf5e5c`.

After the final source change, the focused Section-20 group passed **85 tests with 0 failures** in
25.618 seconds, the expanded affected Track-B group passed **180 tests with 0 failures** in 74.535
seconds, `swift build` passed, and `git diff --check` passed. This is Builder evidence only and does
not claim Security(code), installed Design Sign-off, independent full Test, release, install,
deployment, or commit completion.

### 20.12 Security(code) re-review record (2026-07-11)

**Security(code) verdict: PASS for Section 20.** Security re-reviewed the actual remediation against
the binding sections 20.2...20.8 contract and the first review's three findings. Reviewed source
SHA-256 values were `0c26dcacde9e8cc9be7c5efa45224ef202aaf3d9ba713cb91670cf9f51437de1`
for `RPGScreenModel.swift`, `f09799f858a18465fba0f10ad589310d18f5ec409c337d6cf3834e78339bfe97`
for `RPGScreenInteraction.swift`, and
`9bc6aff4e7861f94f9413c635ef33b07ad2a155f6c7a0cbf0e54d06e02a30b79` for
`RPGUIHarness.swift`. Both renderer hashes remained unchanged at
`839429a5fd3f4993c3155c816b9a93d888cdecea3c0a0d72a9c7797a82edf29e` and
`738df0be6ce4532d142b8c06460dc6c73ff39ee69226e4f38929821660e293e5`; semantic
accessibility and the app accessibility adapter likewise remained unchanged at
`11cc8ce2c76c9405f1c9cb1aad5704599256ca71308ecc0c1cd1f66abac43865` and
`32036ded457475c97d719628f0b544e6c08ebef9ae8420e144e6bc357572e539`.

Independent evidence closed each former finding:

- the real compact debug harness for `skill:safe_fuse:3:current` rendered the exact focused Safe Fuse
  rank-3 row with both model-owned lines; its 720x448 RGBA PNG SHA-256 was
  `ef724660cc0ab346f326ffb2e560c8b5298a45537dc19cb633990eb713a73cf8`. A linked
  adversarial probe independently confirmed exact focus, `visibleFrame == frame`, complete-line fit,
  and midpoint half-open hit identity;
- an out-of-panel fixed descriptor with no visible frame returned `nil` from the shared reveal
  helper, and the reducer regression proves focus and scroll remain unchanged;
- greatest-finite `x + width` and `y + height` overflow projections both returned `nil`; a huge but
  finite-edge projection remained valid, preserving the exact checked contract without an arbitrary
  size rejection;
- the focused model/interaction/harness/source/passive-renderer command independently executed
  **89 tests with 0 failures** in 25.012 seconds, and `git diff --check` passed.

The re-review also confirmed candidate/final focus identity, command fingerprint and authority
classification checks; final harness ID/focusability/region/fingerprint/fit/visibility checks; shared
half-open hit geometry; complete compact step, tutorial, tab, rank, and authority lines before
capability; command-free whole-model failure; passive command stripping; sole final publication; and
unchanged receipt/origin validation. No findings remain in the reviewed Section-20 scope. This PASS
does not approve installed Design Sign-off, independent full Test, release pins, pipeline, install,
deployment, or commit completion; those downstream gates remain mandatory.

### 20.13 Post-release pin and installed-binary Security audit (2026-07-11)

**Security(code) remains PASS.** A warning-free `swift build -c release` completed with exit 0 and
no warning output. The rebuilt release artifacts exactly matched the three reviewed updated pins:

- `ElysiumCore.o`:
  `54d3d01f7dc1cd3c5ecbb9e293ad104012c25a835c1b05a8f6b050819fb1f23c`;
- `Elysium`:
  `33a93cba6aacd2b46e7547556ea0b95b3044b9f399344e67c1ad6018ee900502`;
- `elysmoke`:
  `fe5908db8c3c54fd5cd82e0a451b6bc474e30444aa7b8f886d7bf446d4bbf053`.

The independently invoked release-surface verifier returned `Elysium storage release surface
verified.` with exit 0. Its frozen inputs remained exact: `ElysiumStorage.o`
`b1883c34e94f191d15309738d6fab4a264809b9c638c207fafcb3ae871c6cd6a`, storage source
`4688f3326280ebcec940e98f0db77bb63d2afdd65fc92ec621223134ffaee527`, storage API manifest
`01e80eb490ab7c7ccd8837f21d08ceff82f47822972f9ea70f160fc316517163`, and Core capability
manifest `a3fdb7c1048975677ad4140aa1d27a6bda7d85524214472f41fa72ae39f90194`. The reviewed
Section-20 model, interaction, and harness source hashes likewise remained
`0c26dcacde9e8cc9be7c5efa45224ef202aaf3d9ba713cb91670cf9f51437de1`,
`f09799f858a18465fba0f10ad589310d18f5ec409c337d6cf3834e78339bfe97`, and
`9bc6aff4e7861f94f9413c635ef33b07ad2a155f6c7a0cbf0e54d06e02a30b79`.

The installed `/Applications/Elysium.app` passed independent deep strict `codesign` verification,
including its Designated Requirement. `scripts/security-check-binary.sh` then passed its bundle ID,
Info.plist, linked-library, network-symbol, network-string, and URL checks against the installed
executable. The signed installed executable SHA-256 was
`2a1c1ed12d33c868742d0e52b77e62b0c927c480216fffed8fe0ba3f34fee313`. `git diff --check`
also passed. No artifact, source, capability, signature, or installed-binary drift invalidates the
Section-20 Security(code) PASS.
