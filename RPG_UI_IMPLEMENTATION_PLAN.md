# RPG Progression UI Implementation Plan

**Gate:** Architecture  
**Status:** Architect final copy amendment PASS; Security plan re-review PASS preserved; awaiting Design Review/Revision re-review  
**Human-visible change:** yes; Design Mock, Design Review/Revision, and installed Design Sign-off are mandatory  
**Authoritative contract:** `RPG_CLASSES_PROGRESSION_DESIGN.md`  
**Network contract:** `LAN_RPG_PROTOCOL_V6.md`; this plan consumes its client presentation boundary but does not activate protocol v6

## 1. Purpose and release boundary

This plan replaces the current prototype RPG screen with the complete four-step creation flow and
five-tab progression shell required by the approved design contract. It also separates local quick
slots from authoritative RPG state, makes key chords configurable, adds RPG-scoped controller input,
and exposes the custom Metal UI through a real AppKit accessibility tree.

The implementation is not allowed to make dormant v6 code callable. In particular, this UI change
must not change `LAN_MULTIPLAYER_PROTOCOL_VERSION`, a v6 ready marker, schema cutover, credential
promotion, admission publication, socket routing, v5 quarantine, or any file under
`Sources/PebbleCore/Net/LANV6*`. The transport/authority phase owns that cutover. The UI consumes one
read-only `RPGAuthorityPresentation` snapshot supplied by the authority layer after that layer has
passed its own gates. If an active LAN client has no installed v6 authority coordinator, the snapshot
is `.unavailable`; the sheet remains inspectable and local slots remain usable, but every
authoritative operation is disabled. It must never fall back to the current optimistic v5 mutation
path.

Final UI mutation wiring, installed Design Sign-off, Test, and Deploy are blocked until the v6
authority implementation has independently proven:

- client requests are read-only locally and at most one canonical request is pending;
- creation and its starter kit commit atomically on the host;
- owner accept/reject bundles durably commit complete owner state before main-thread publication;
- quick slots are absent from host authority and preserved by client owner apply;
- durable pending/disposition/notification state can supply the presentation cases defined below.

Pure evaluators, models, layout, semantics, key chords, settings migration, and synthetic controller
logic may be built earlier, but no earlier build may claim the LAN states complete or activate v6.

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

### 3.1 New PebbleCore files

1. `Sources/PebbleCore/Game/RPGProgressionEvaluation.swift`
   - Owns `RPGSkillPurchaseEvaluation`, `RPGSkillPurchaseFailure`,
     `rpgEvaluateSkillPurchase`, specialization completion math, and level-one guidance.
   - Contains no `Player`, `World`, UI, AppKit, transport, or persistence mutation.

2. `Sources/PebbleCore/Game/RPGLocalPreferences.swift`
   - Owns bounded `RPGLocalPreferenceScope`, `RPGQuickSlotPreferences`, syntactic/semantic
     normalization, assign/move/clear reducers, and bounded legacy `actionQuickSlots` extraction
     from raw player JSON.
   - Owns no authoritative revision, action sequence, selected action, or LAN message.

3. `Sources/PebbleCore/Game/RPGScreenModel.swift`
   - Owns all app-independent creation/sheet projections, stable semantic IDs, semantic
     descriptors, bounded geometry/virtualization, focus navigation, tutorial model, installed
     fixtures, and the sole LAN presentation input.

4. `Sources/PebbleCore/Game/InputChords.swift`
   - Owns canonical chord parsing/formatting, modifier/key domains, binding definitions, conflict
     detection, zero-or-one command resolution, and the pure routing/dedupe state exercised with
     synthetic `performKeyEquivalent`/`keyDown` sources.

5. `Sources/PebbleCore/Game/RPGControllerInput.swift`
   - Owns the platform-independent controller reducer, thresholds, hysteresis, neutral arming,
     repeat timing, and emitted `RPGSemanticCommand` values. It imports no GameController framework.

6. `Sources/PebbleCore/Game/LocalSettingsStore.swift`
   - Owns byte-capped, known-field-tolerant settings/keybind decoding and Result-returning atomic
     persistence. No UI mutates published Settings/keybind values before this store succeeds.

### 3.2 Modified PebbleCore files

1. `Sources/PebbleCore/Game/CharacterProgression.swift`
   - Removes quick slots from `RPGCharacterState` authority/encoding.
   - Makes `rpgLearnSkill` consume `rpgEvaluateSkillPurchase`.
   - Removes quick-slot helpers that accept/mutate `RPGCharacterState` and replaces action lookup
     helpers with `(state, RPGQuickSlotPreferences)` inputs.
   - Removes implicit selection from action-slot assignment.
   - Keeps registration IDs/order and schema-v2 gameplay fields unchanged.

2. `Sources/PebbleCore/Systems/RPGActions.swift`
   - Removes selection writes from generic action execution.
   - Replaces `rpgUseActionQuickSlot(_:slot:)` with
     `rpgUseActionQuickSlot(_:slot:preferences:)`, resolving an explicit kind/ID and executing it
     without changing authoritative selection.

3. `Sources/PebbleCore/Game/Settings.swift`
   - Adds the optional, backward-compatible `rpgTutorialVersion` field; quick slots are not a
     process-global setting and never live in this type.
   - Adds the 12 RPG default chords and uses the canonical chord sanitizer for every known action.

4. `Sources/PebbleCore/Game/GameCore.swift`
   - Owns the current local quick-slot value and its local persistence mode.
   - Owns the current `RPGAuthorityPresentation` snapshot and explicit sheet-operation dispatch.
   - Routes configured chords instead of K/O/L/Shift-digit literals.
   - Migrates old raw player `actionQuickSlots` only after entering its exact local-world scope,
     before saving a slot-free RPG state; LAN entry never consumes or clears that envelope.
   - Dismisses the RPG screen through `GameHost` when `rpgClasses` is disabled.

5. `Sources/PebbleCore/Entity/Player.swift`
   - New saves with no pending legacy migration encode the slot-free repaired RPG state.
   - A bounded internal `RPGLegacyQuickSlotEnvelope` retains and re-encodes an old
     `actionQuickSlots` value until its local-world destination and migration marker commit. It is
     cleared only after that commit, so LAN entry or failed migration cannot silently delete it.

6. `Sources/PebbleCore/Net/LANMultiplayer.swift` and the reviewed v6 owner DTO source created by the
   authority phase
   - Delete quick slots from every authoritative/public/owner payload and equality/hash fixture.
   - This is a compatibility cleanup owned by the authority phase, not permission for this UI phase
     to edit dormant v6 transport or activate it.

7. `Sources/PebbleCore/Game/Saves.swift` and `Sources/PebbleStorage/StorageEngine.swift`
   - Add only the typed non-authoritative local-world RPG-preference row and local-world-only atomic
     legacy-slot marker/destination operation described below.
   - For `.lanV6`, consume only the frozen `LANClientOwnerCheckpointRowV1` aggregate/CAS API; do not
     add, read, or write a standalone RPG-local-preference or migration-marker row.

### 3.3 New macOS app files

1. `Sources/Pebble/RPGControllerM.swift`
   - Imports `GameController` and adapts compatible physical controller callbacks to the pure
     `RPGControllerInput` reducer.

2. `Sources/Pebble/RPGAccessibilityM.swift`
   - Owns `PebbleAccessibilityElement`, GUI-to-screen frame conversion, semantic snapshot caching,
     AppKit activation/focus callbacks, and accessibility notifications.

3. `Sources/Pebble/RPGUIHarnessM.swift`
   - Parses only the allowlisted installed-harness environment values, constructs deterministic
     fixtures, and emits bounded sorted semantic summaries. It never edits a world/save.

4. `Sources/Pebble/AppInputRouterM.swift`
   - Is the thin `NSEvent` adapter into the sole pure routing/deduplication path shared by
     `performKeyEquivalent(with:)` and `keyDown(with:)`; neither override contains an independent
     shortcut or screen-routing ladder.

### 3.4 Modified macOS app files

1. `Sources/Pebble/RPGScreensM.swift`
   - Replace the prototype implementation. This file becomes a thin renderer/controller for
     `RPGScreenModel`; it owns no legality, registry filtering, quick-slot authority, or LAN state.

2. `Sources/Pebble/UIManagerM.swift`
   - Add structured key events, semantic snapshot/activation defaults on `Screen`, shared semantic
     revision ownership, focus routing, and dirty notifications.

3. `Sources/Pebble/main.swift`
   - Parse/validate harness mode before constructing GameCore, settings, SaveDB, player, or network
     services; in ordinary mode construct structured modifier-aware key events.
   - Delegate both AppKit keyboard entry points to `AppInputRouter`; preserve only lifecycle wiring
     in `GameView`.
   - Build every nonempty main-menu key equivalent from the shared shipping shortcut catalog, so the
     menu and binding-protection set cannot drift.
   - Own `RPGControllerAdapter` and `RPGAccessibilityBridge` lifetimes.
   - Forward app resign/focus/screen-context transitions to clear controller held state.
   - Delete the shipping `PEBBLE_RPG_AUTOCREATE` path and replace its proof cases with pure harness
     fixtures; do not broaden ordinary screenshot paths.

4. `Sources/Pebble/MenusM.swift`
   - Replace the Controls fixed list/capture with the virtualized chord editor.

5. `Sources/Pebble/HudM.swift`
   - Resolve the nine displayed actions from `game.rpgQuickSlotPreferences` plus repaired
     authoritative state; no HUD method reads slots from `RPGCharacterState`.

6. `Sources/Pebble/ScreensM.swift`
   - Keep Inventory/Creative Character entry points, but route through one rule/presentation-aware
     open helper and preserve focus when returning.

7. `Sources/Pebble/MenusM.swift`, `Sources/Pebble/HudM.swift`, and
   `Sources/Pebble/RPGScreensM.swift`
   - Use High Contrast and Reduce Motion from `Settings`; no state is conveyed by color alone.

8. `Package.swift`
   - Add `.linkedFramework("GameController")` to the Pebble executable only. PebbleCore remains
     headless and AppKit/GameController-free.

### 3.5 Durable documentation and scripts

- Update `README.md`, `ARCHITECTURE.md`, and `SECURITY.md` in the same logical change.
- Update `RPG_CLASSES_PROGRESSION_DESIGN.md` only to record verified implementation status or an
  explicitly reviewed contract correction; do not weaken its acceptance criteria.
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
    case lanV6(hostInstallationID: LANV6HostInstallationID,
               worldLANID: LANV6WorldID)
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

Only `.localWorld` may address `rpg_local_preferences_v1`. That standalone non-authoritative table
allows one row per exact local world, 256 rows total, 4,096 encoded bytes per row, and 1 MiB aggregate.
Each row contains schema version, exactly nine normalized tokens, a checked local revision, and a
payload digest. Its separate legacy-migration marker table is likewise local-world-only and bounded
to one marker per local row under the same aggregate quota. A `.lanV6` scope passed to either table
API is a typed error before SQL is prepared. Reads exceeding any bound fail closed without publishing
a partial value.

`.lanV6` quick slots are backed exclusively by the frozen `LANClientOwnerCheckpointRowV1` selected by
the exact typed host installation ID plus world LAN ID. That one checkpoint generation atomically
contains the acknowledged owner snapshot, local nine-slot value, credentials/counters, durable
pending/disposition state, and bounded notice inbox. No parallel `rpg_local_preferences_v1` row,
marker, settings fallback, or slot-only transaction exists for LAN.

LAN assign/move/clear and owner-apply normalization each load one complete checkpoint generation,
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
LAN scope uses its checkpoint slot value, or materializes defaults inside the whole-checkpoint CAS
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
   source digest, chosen destination digest, and schema version. Destination plus marker commit in
   the same transaction. If a destination already exists, it wins; the marker binds its digest and
   the legacy value is not allowed to overwrite it.
3. Only after the transaction returns committed does `GameCore` publish the destination and mark the
   in-memory envelope omittable. The next successful player save may omit `actionQuickSlots`.
   Transaction failure, disk-full, cancellation, or process death before commit retains/re-emits the
   legacy key and publishes no candidate.
4. A crash after database commit but before player save is idempotent: on restart the exact marker,
   scope, source digest, and destination digest must match before the envelope may be omitted. A
   mismatch, cross-world marker, or changed destination fails closed and retains the legacy key.

Local assign/move/clear/migration/default materialization follow candidate -> validate -> one
local-world row transaction -> publish. LAN assign/move/clear/default materialization/owner
normalization follow complete checkpoint candidate -> generation CAS -> publish. A failure preserves
the prior live value/revision and projects `persistenceFailure`; no UI may imply success. Tests cover
two local worlds with equal names/different IDs, local migration crash cuts, every LAN host/world
cross-product, rapid-scope delayed-completion mixups, and assert both that no standalone preference or
migration row is ever created for LAN and that injected checkpoint encode/disk/transaction/CAS/
postcondition failure byte-preserves owner, slots, credentials, pending/disposition, inbox, digest,
and generation together.

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

The reader consumes at most 262,145 bytes for settings and 16,385 bytes for keybinds and rejects the
cap-plus-one sentinel before JSON parsing; accepted documents are at most 256 KiB and 16 KiB. The
root must be a JSON object. Each known settings field is decoded independently from its bounded JSON
value: one malformed known field falls back only that field and records a bounded diagnostic;
missing fields use defaults; unknown fields are ignored. A malformed root or over-cap document
returns failure and is never silently overwritten during load.

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

Tests cover empty/missing files, exact caps and cap-plus-one, malformed/non-object roots, unknown
fields, one bad known field among valid peers, hostile nesting/arrays/numbers, invalid UTF-8,
overlong chords, protected chords, all 25 defaults, stable canonical output, and injected temporary
create/write/file-sync/rename/directory-sync failures. Restart tests require either the complete old
document or complete new document, never a truncated/mixed value, and prove failed persistence does
not publish slots, tutorial version, or chords.

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
    public let operation: RPGSheetAuthoritativeOperation?
    public let status: RPGStatusPresentation?
    public let semanticRevision: UInt64
}
```

This value, including its optional status, is the sole pending/LAN/terminal-notice input to
`RPGScreenModel`. The screen must not inspect sockets,
transport state, request IDs, checkpoints, replay caches, peer records, or v5/v6 types. The authority
coordinator maps its durable state to this snapshot:

| Authority state | Presentation phase | Authoritative controls | Local slots |
| --- | --- | --- | --- |
| single-player/host ready | `localReady` | enabled by semantic legality | enabled |
| request durably pending | `awaitingHost` | all disabled | enabled |
| accepted bundle validating/committing | `committingAcceptedOwnerCheckpoint` | all disabled | enabled |
| rejected bundle/resync validating/committing | `committingRejectedOwnerCheckpoint` | all disabled | enabled |
| disconnected with durable pending | `reconnecting` | all disabled | enabled |
| disposition-only/evicted awaiting request-zero | `awaitingDispositionCheckpoint` | all disabled | enabled |
| terminal revision/counter exhaustion | `authorityExhausted` | permanently disabled | move/clear already-valid tokens only |
| LAN client without reviewed coordinator | `unavailable` | disabled; no v5 fallback | enabled |

`rpgAuthorityPhasePresentation` is an exhaustive switch over all eight phases and returns one frozen
`RPGAuthorityPhasePresentation` containing `proceduralIconID`, `visibleTitle`, `visibleHelp`, optional
`disabledControlExplanation`, and `voiceOverAnnouncement`. The authority phase chip remains visible
even when an operation status/notice is also present. These are the exact non-color mappings:

| Harness selector / phase | Procedural non-color icon and shape | Exact visible title | Exact visible help and authority-disabled-control explanation | Exact VoiceOver announcement |
| --- | --- | --- | --- | --- |
| `ready` / `localReady` | `authority.ready` (outlined check) | `Ready` | `Host-authoritative RPG controls are available when their requirements are met.` Authority supplies no disabled-control explanation; a disabled operation shows only its exact canonical evaluator reason. | `Ready. Host-authoritative RPG controls are available when their requirements are met.` |
| `pending` / `awaitingHost` | `authority.awaitingHost` (outlined hourglass) | `Awaiting host` | `Character changes are disabled until the host responds. Local quick slots remain available.` | `Awaiting host. Character changes are disabled until the host responds. Local quick slots remain available.` |
| `acceptedCommit` / `committingAcceptedOwnerCheckpoint` | `authority.savingAccepted` (disk outline with check) | `Saving accepted update` | `Character changes are disabled while Pebble saves the accepted host update. Local quick slots remain available.` | `Saving accepted update. Character changes are disabled while Pebble saves the accepted host update. Local quick slots remain available.` |
| `rejectedCommit` / `committingRejectedOwnerCheckpoint` | `authority.savingRejected` (disk outline with cross) | `Restoring host state` | `Character changes are disabled while Pebble restores the host’s character state. Local quick slots remain available.` | `Restoring host state. Character changes are disabled while Pebble restores the host’s character state. Local quick slots remain available.` |
| `reconnecting` / `reconnecting` | `authority.reconnecting` (two opposed circular arrows) | `Reconnecting` | `Character changes are disabled until the connection and pending request recover. Local quick slots remain available.` | `Reconnecting. Character changes are disabled until the connection and pending request recover. Local quick slots remain available.` |
| `disposition` / `awaitingDispositionCheckpoint` | `authority.finalizing` (inbox outline with solid dot) | `Finalizing host response` | `Character changes are disabled while Pebble finishes processing the host response. Local quick slots remain available.` | `Finalizing host response. Character changes are disabled while Pebble finishes processing the host response. Local quick slots remain available.` |
| `exhausted` / `authorityExhausted` | `authority.exhausted` (octagonal stop outline) | `Authority exhausted` | `Character changes are permanently disabled for this character session. Valid local quick slots may still be moved or cleared.` | `Authority exhausted. Character changes are permanently disabled for this character session. Valid local quick slots may still be moved or cleared.` |
| `unavailable` / `unavailable` | `authority.unavailable` (closed padlock outline) | `Character changes unavailable` | `Character changes are unavailable in this LAN session. Local quick slots remain available.` | `Character changes unavailable. Character changes are unavailable in this LAN session. Local quick slots remain available.` |

The presentation switch and all visible/accessibility assertions reject internal implementation
terms in these sinks. In particular, visible title/help, disabled reasons, accessibility value/help,
and VoiceOver announcements may not contain `owner checkpoint`, `request-zero checkpoint`,
`reviewed v6 coordinator`, `v5 fallback`, or `owner session`; those terms remain internal-only.

For every non-ready phase, every otherwise-legal authoritative descriptor copies the table's exact
help sentence into its visible focused/hovered reason and its accessibility help; it is not
tooltip-only. The phase title precedes that reason in the fixed status band. Local slot controls do
not inherit an authority-disabled reason and retain their separate local legality, except the
documented exhaustion restriction. For `localReady`, the harness uses an otherwise-legal operation
and asserts it is enabled; if another operation is disabled by gameplay legality, only the canonical
evaluator reason appears.

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
- `RPGScreenModelInput`: repaired authoritative state, local quick slots, authority presentation,
  creation session, tutorial state, viewport, tab, selection, offsets, High Contrast, Reduce Motion.
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
    public let id: RPGUIElementID
    public let semanticRevision: UInt64
    public let commandFingerprint: String
}

UIManager.dispatchSemanticActivation(
    _ capture: RPGSemanticActivationCapture,
    source: RPGSemanticActivationSource
) -> RPGSemanticActivationResult
```

The fingerprint is the 64-lowercase-hex SHA-256 of the descriptor's bounded canonical
`actionCommand` encoding, including operation and target IDs; it is not derived from label/help text.
Mouse captures on button-down and verifies on button-up. Keyboard, controller, and accessibility
capture from the same committed descriptor immediately before dispatch. No modality may call a
screen closure, reducer, `GameCore`, or authority coordinator directly.

On dispatch, `UIManager` re-fetches the current screen and committed descriptor by ID. Semantic
revisions are checked process-global monotonic values and are never reset on screen replacement; the
current screen must still own the captured revision, ID, and command fingerprint. The descriptor must
still be focusable, actionable, enabled, and carry that exact command. It then re-resolves the
registered target, current rule enablement, current prepared/known/equipment/focus prerequisites,
captured local-preference scope, and current `RPGAuthorityPresentation` legality. Authoritative
commands require `localReady`; local slot commands require the exact captured scope and a writable
store. The dispatcher submits the re-resolved command at most once and records one checked dispatch
serial; it never trusts an enabled bit captured from an older model.

Any screen/revision/fingerprint/target/authority/rule mismatch performs at most one bounded model
rebuild, returns `.staleRequiresFreshActivation`, and submits nothing. It never translates the old ID
to a new target and never auto-replays after rebuild. A fresh user press is required. For an offscreen
descriptor, focus/reveal happens first; if that commits a different semantic revision, the original
Press is rejected with the same fresh-activation rule. Normal VoiceOver focus reveals before its
subsequent Press, so the ordinary path remains one Press on a currently committed element.

Tests interleave capture/dispatch with owner acknowledgement, rule disable, path/tab/screen change,
rank purchase, prepare/unprepare, slot scope switch, equipment/focus loss, target removal, offscreen
reveal, and semantic-revision exhaustion. They run every interleaving through mouse, keyboard,
controller, and accessibility and assert identical results, zero mutation for stale captures, and at
most one mutation/authority request for a valid activation.

## 7. Configurable chord and Controls contract

`InputChords.swift` adds `PebbleKeyModifiers` (Command, Control, Option, Shift),
`PebbleTerminalKey`, `PebbleKeyChord`, `PebbleKeyEvent`, and `KEYBIND_DEFINITIONS`. Modifier tokens
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
capture rejects every protected chord with `Reserved by Pebble`; `Use Anyway` is never offered. Load
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
screens, bindings, or gameplay independently. The router sends a full `PebbleKeyEvent` to a new
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
`flagsChanged` updates `PebbleKeyModifiers` and may emit a legacy `ShiftLeft`/`ControlLeft` terminal
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
the sole `UIManager.dispatchSemanticActivation`. `UIManager` caches only the current screen's
revision, layout generation, viewport, and descriptors. It invalidates on explicit model/layout
commits, not on every draw frame.

`RPGAccessibilityBridge` makes `GameView` an accessibility group and publishes main-thread
`PebbleAccessibilityElement` children. GUI top-left frames convert through UI scale, backing scale,
view/window coordinates, then `window.convertPoint(toScreen:)`. Descriptors map to AppKit roles:
buttons, static text, tabs/tab group, groups, rows, and scroll areas. Labels, values, rank,
selected/prepared/slotted, enabled/locked, canonical reason/help, and press action are populated.

All 27 live path rank cells remain children even when offscreen; other paths' 135 cells do not.
Focusing an offscreen element calls the screen's semantic focus/reveal path and rebuilds layout. A
direct Press received before that focus commit follows section 6.4: reveal, reject the stale capture,
and require a fresh Press rather than acting under old geometry/authority. The Skills root announces
current path and `3 branches, 9 skills, 27 ranks`.
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
bounded fatal harness diagnostic. When `PEBBLE_RPG_UI_CASE` is present, the complete allowed
`PEBBLE_` key set is exactly:

- `PEBBLE_RPG_UI_CASE`;
- `PEBBLE_RPG_UI_AUTHORITY`;
- `PEBBLE_RPG_UI_VIEWPORT`;
- `PEBBLE_RPG_UI_APPEARANCE`;
- `PEBBLE_RPG_UI_SEMANTIC_SUMMARY`;
- optional `PEBBLE_SHOT`, solely for an explicitly requested screenshot output.

Any other `PEBBLE_` key, including autoload/new-world/command/LAN/probe/bot/AI/debug/open-screen and
the retired `PEBBLE_RPG_AUTOCREATE` family, rejects the entire harness invocation before side
effects; values are never combined and ordinary mode is not used as fallback. The shipping
`pendingRPGAutoCreate` state, parser, and `runRPGAutoCreateIfNeeded` mutator are removed. Creation
step/review coverage comes only from immutable fixture profiles.

The installed harness accepts one closed case selector of at most 192 UTF-8 bytes:

`PEBBLE_RPG_UI_CASE=<case>`, where `<case>` is exactly one of:

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
`empty` all nil, `sparse` stable slots 0/4, `maximal` every unique prepared path action in registry
order up to nine, and `repairInvalid` a bounded duplicate/unknown input plus its normalized result.

The remaining allowlisted selectors are:

- `PEBBLE_RPG_UI_AUTHORITY=<ready|pending|acceptedCommit|rejectedCommit|reconnecting|disposition|exhausted|unavailable>`;
- `PEBBLE_RPG_UI_VIEWPORT=<360x224|520x330|700x420>`;
- `PEBBLE_RPG_UI_APPEARANCE=<standard|highContrast|reduceMotion|highContrastReduceMotion>`;
- `PEBBLE_RPG_UI_SEMANTIC_SUMMARY=1`.

Each of the eight `PEBBLE_RPG_UI_AUTHORITY` fixtures uses the table in section 4.5 without alternate
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
network tasks are created. Combined-mutation-environment tests cover every shipping `PEBBLE_` family
and must reject before those counters change. Zero-mutation runs omit `PEBBLE_SHOT`; when explicitly
present, `PEBBLE_SHOT` may create only its named screenshot output and still may not create or alter
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
- Any-modality activation with a stale ID/revision/fingerprint: rebuild at most once, announce that
  a fresh activation is required, and submit no command.
- Controller disconnect/focus loss: clear every held/repeat edge and return visible help to keyboard.

## 12. Dependency-ordered build contract

1. **Evaluator and evidence**
   - Add canonical purchase evaluator and exhaustive effect-consumer evidence tests.
   - Make `rpgLearnSkill` consume it; no UI code yet.
2. **Local preference separation**
   - Add canonical local-world/LAN-v6 scopes, the bounded local-world-only table and marker migration,
     and exclusive frozen `LANClientOwnerCheckpointRowV1` whole-generation CAS for LAN slots.
   - Remove slots from authority state/encoding/owner DTOs and remove implicit selection on assign/use.
3. **Bounded local persistence**
   - Add `LocalSettingsStore`, exact settings/keybind caps, independent known-field decoding, atomic
     Result writes, and persist-before-publish for tutorial/chords.
4. **Pure models**
   - Add creation reducer, five-tab projections, progression guidance, geometry, virtualization,
     semantic descriptors/navigation, tutorial, and deterministic fixtures.
5. **Chord/input model**
   - Add parser/defaults/conflicts, menu-derived protected chords, the zero-or-one canonical
     resolver, shared AppKit router/dedupe, and semantic commands; remove raw GameCore key fan-out.
6. **UI renderer**
   - Rewrite `RPGScreensM.swift` against only the model/operation dispatcher.
   - Update HUD and Inventory/Creative entry points.
7. **Revision-bound dispatch and Controls**
   - Add one semantic activation dispatcher for mouse/keyboard/controller/accessibility with exact
     ID/revision/fingerprint revalidation and a one-mutation routing serial.
   - Implement virtualized capture/reset/conflict confirmation.
8. **Controller adapter**
   - Link GameController and adapt physical input to the pure reducer/semantic commands.
9. **Accessibility**
   - Add Screen/UIManager semantics and the GameView AppKit bridge.
10. **Isolated tutorial/harness/docs**
   - Remove shipping RPG autocreate, add pre-bootstrap isolated fixtures/semantic summary, and update
     durable docs.
11. **Authority integration**
    - Only after v6 Security/Test PASS, connect its durable state to
      `RPGAuthorityPresentation`, bounded digest-keyed notice inbox, committed-model acknowledgement,
      exact eight-phase non-color/VoiceOver presentation, and the existing sheet-operation
      dispatcher. Do not add a second UI transport callback.
12. **Downstream gates**
    - Security code review -> installed Design Sign-off -> independent Test -> full pipeline ->
      deploy -> installed verification -> Neo LAN verification.

Any material fix returns to the earliest affected step and invalidates later review/proof.

## 13. Exact tests and empirical evidence

### 13.1 New test files

1. `Tests/PebbleCoreTests/RPGSkillPurchaseEvaluationTests.swift`
   - Every failure precedence pair; evaluator/mutator parity; 54 skills x ranks/states; selected vs
     cross gates/costs; authority exhaustion; checked capstone math.
2. `Tests/PebbleCoreTests/RPGEffectCoverageTests.swift`
   - An exhaustive switch over all 54 `RPGSkillEffectID` cases, looping ranks 1...3, invokes the real
     consumer/action/spell preparation path and records one observable assertion per rank: exactly
     162. It also verifies generated effect text and 17 spell semantics. A new enum case cannot
     compile without evidence.
3. `Tests/PebbleCoreTests/RPGLocalPreferencesTests.swift`
   - Exact local record and 16-byte v6 host/world scope encodings; local-table caps; local-only legacy
     extraction/marker/destination/crash cuts/omission; every LAN host/world cross-product; explicit
     proof that LAN creates no standalone preference or migration row; and whole-checkpoint CAS tests
     for assign/move/clear/default/owner normalization. Every injected encode/disk/transaction/CAS/
     postcondition failure must byte-preserve owner, slots, credentials, pending/disposition, inbox,
     digest, and generation together, with no authority/selection/inventory publication.
4. `Tests/PebbleCoreTests/LocalSettingsStoreTests.swift`
   - Settings 256-KiB and keybind 16-KiB exact/cap-plus-one, object/root/UTF-8 hostile inputs,
     independent known-field fallback, unknown fields, exactly 25 canonical <=64-byte chords,
     protected/extra/missing binding rejection, candidate-before-publish, and injected temporary
     create/write/file-sync/rename/directory-sync plus restart old-or-new atomicity.
5. `Tests/PebbleCoreTests/RPGScreenModelTests.swift`
   - Four steps; all six exact path icon/role/primary/preset/selection/help contracts; six retained
     drafts; all eighteen Review branches; Foundation derivation; kits/spells/focus/XP copy; five
     tabs; every inspector/rank; caster/non-caster filtering; 3/9/27 each and 6/18/54/162 aggregate.
6. `Tests/PebbleCoreTests/RPGScreenLayoutTests.swift`
   - Exact viewports, seeded resize/content transitions, full-control containment, shared scroll
     tuple, virtualization bounds, focus reveal/retention/nearest-preceding-focusable fallback, full
     wrapped card containment, and forward/reverse traversal of all 27 ranks exactly once for all six
     paths at all three viewports with nonactionable activation byte-equality.
7. `Tests/PebbleCoreTests/RPGPendingPresentationTests.swift`
   - Every section 4.5 phase's exact icon geometry/title/visible help/disabled-control reason/
     accessibility value+help/VoiceOver announcement, including ready's enabled/no-authority-reason
     assertion, forbidden internal-copy absence in every sink, and byte-identical no-reannouncement;
     exact 64-hex ID/digest and closed status;
     reason/message bounds; separate display/accessibility control+bidi sanitizers; 256-row/1-MiB cap;
     same-ID/same-digest idempotence; same-ID/different-digest fail closed; close/reopen/replay; and
     acknowledgement only after exact committed semantic revision/storage commit.
8. `Tests/PebbleCoreTests/InputChordTests.swift`
   - Canonical terminal/modifier domains, all malformed cases, 25 defaults, recursive equality of
     nonempty shipping-menu chords with the protected set, capture/load/persist rejection for each,
     pairwise conflict winner across definitions/contexts, modified-digit precedence, legacy
     movement compatibility, zero-or-one resolution, routing-serial reuse rejection, and repeats.
9. `Tests/PebbleCoreTests/AppInputRoutingTests.swift`
   - Shared `performKeyEquivalent`/`keyDown` fingerprint dedupe; F11 then Command+C/V/Z; every
     unconsumed shipping-menu chord (including Command+Q/M) returned to the main menu before
     screen/binding resolution; screen-before-Escape thereafter; physical versus synthesized legacy
     edges; and at most one dispatched command/mutation.
10. `Tests/PebbleCoreTests/RPGControllerInputTests.swift`
   - Every mapping, enter/exit hysteresis, neutral arming, repeat caps/timing, connect/disconnect/focus/
     context reset, one edge/one command.
11. `Tests/PebbleCoreTests/RPGSemanticAccessibilityTests.swift`
   - Roles/labels/values/help/actions, offscreen 27 discoverability, exclusion of 135 other-path
     ranks, stable IDs/revisions, notification intent, High Contrast/Reduce Motion model flags.
12. `Tests/PebbleCoreTests/RPGSemanticActivationTests.swift`
    - Exact ID/revision/command-fingerprint capture through mouse/keyboard/controller/accessibility;
      race interleavings for ack/rule/path/tab/scope/equipment/focus/target/offscreen/revision
      exhaustion; stale rebuild without replay; fresh-press requirement; one valid mutation maximum.
13. `Tests/PebbleCoreTests/RPGUIHarnessTests.swift`
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
- `LANMultiplayerTests.swift`, `LANReplicationTests.swift`, and reviewed v6 owner/checkpoint suites:
  prove public/owner wire authority omits slots, LAN has no standalone preference/marker row, and
  owner/slot normalization commits only through one complete checkpoint generation CAS.
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
swift run -c release pebsmoke
bash scripts/pipeline.sh
```

The release build must be warning-free. `pebsmoke` must still report 457 unless a separately reviewed
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
| One world's/player's slots leak to another | exact local/v6 scope cross-product and delayed-completion mixup tests |
| Legacy slot migration loses the only copy | transaction/crash-cut tests; marker+destination commit before JSON omission |
| LAN slot write splits owner/security state | no standalone LAN row plus whole-checkpoint CAS fault byte-equality |
| Old or owner state overwrites slots | local-row precedence, v6 checkpoint owner normalization, new JSON omission tests |
| Slot use selects or consumes revision | action/input before/after state tests |
| Malformed settings exhaust memory or erase peers | exact read caps, independent field decode, hostile seeded inputs |
| Failed settings write publishes/truncates state | every I/O fault injection plus restart old-or-new proof |
| v5 optimism remains reachable | LAN-client unavailable-boundary test and no v5 fallback assertion |
| UI accidentally activates v6 | no protocol/schema/transport-cutover diff; v6 gate tests owned separately |
| Clipped/stale controls mutate | exact/seeded geometry plus same-rect draw/hit/semantic tests |
| Capture acts on changed target/authority | ID+revision+fingerprint race matrix for all four modalities |
| Focus disappears after ack/resize | transition matrix and installed keyboard/VoiceOver proof |
| Authority phase is color-only or unexplained | exact eight-fixture icon/visible help/disabled reason/VO assertions |
| Menu shortcut is captured as gameplay | constructed-menu equality plus per-chord capture/load/persist/dispatch tests |
| Malformed/conflicting chord hijacks controls | protected-chord fuzz, canonical winner, dedupe/one-mutation tests |
| Controller repeats mutations | synthetic hysteresis/neutral/repeat tests plus physical proof |
| Accessibility is only metadata | installed VoiceOver discovery/focus/press and notification observation |
| Durable notice spoof/injection/early ack | exact ID+digest/status/bounds, dual sanitizers, queue caps, commit receipt tests |
| Tutorial is falsely marked seen | persistence boundary tests and crash/reopen installed proof |
| Harness combines a mutation hook or creates state | pre-bootstrap env rejection, zero factories, manifest/socket proof |
| Rule disables mid-screen | synchronous cleanup/dismiss test and installed probe |

## 15. Installed Design Sign-off and deployment proof

After Security code PASS, build/deploy a fresh `/Applications/Pebble.app`. Use a fresh
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

After independent Test PASS, run `bash scripts/pipeline.sh`, verify the installed executable/signature
and fresh installed UI again, then run:

```bash
bash scripts/live-lan-test.sh --deploy --timeout 90
```

The Neo proof must include character creation plus atomic kit, one pending mutation, accepted and
rejected convergence, local-slot assign/use preservation, permission denial, replay, cooldown/fatigue/
upkeep/XP persistence, disconnect/reconnect, and no v5 optimistic state. Installed executable hashes
must match. Any runtime-path code change invalidates and repeats affected Security, Design Sign-off,
Test, pipeline, deploy, installed, and Neo evidence.

## 16. Conditions for Builder

- Begin only after this plan receives Design Review/Revision PASS and Security plan PASS.
- Do not activate v6, edit its wire/version/cutover, or route the new UI through v5.
- Implement in the dependency order above; do not start renderer mutation wiring before the pure
  evaluator/model/local-preference tests pass.
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
- Quick slots are keyed only by the exact local world record ID or exact typed v6 host+world pair;
  no global/settings/name/seed/address fallback exists, and async completions carry their scope.
- Only local worlds use `rpg_local_preferences_v1` and legacy markers. LAN creates no standalone
  preference/marker row: assign/move/clear/default/owner normalization use only a complete frozen
  `LANClientOwnerCheckpointRowV1` generation CAS, and any failure byte-preserves owner, slots,
  credentials, pending/disposition, inbox, digest, and generation together.
- The old player slot key remains encoded until a local-world transaction commits both the
  destination and digest-bound migration marker; LAN never consumes/clears it, and failure/crash
  cannot omit the last legacy copy.
- Settings/keybind reads enforce 256-KiB/16-KiB caps, known fields fail independently, keybind output
  is exactly 25 canonical <=64-byte entries, and every settings/slot/tutorial/chord value publishes
  only after its Result/transaction succeeds.
- `RPGAuthorityPresentation` is the one pending/LAN UI input; no screen inspects transport state.
- Every authority phase uses the exact section 4.5 procedural shape, visible title/help,
  disabled-control reason, accessibility value/help, and VoiceOver announcement; all eight harness
  fixtures assert the exact plain-language mapping and localReady contributes no false authority-
  disable reason. Internal checkpoint/protocol/coordinator terms never enter visible or VoiceOver
  phase copy.
- Durable notices require exact 64-lowercase-hex ID and digest, a closed status, 256/512-byte raw text
  bounds, 256-row/1-MiB queue bounds, same-ID/different-digest fail-closed behavior, independent
  display/accessibility sanitization, and acknowledgement only after an exact committed model
  revision and storage commit.
- All offsets use the one clamp; no partially clipped control is actionable at required viewports.
- Keyboard, controller, and accessibility emit the same semantic commands and share one focus ID.
- Mouse, keyboard, controller, and accessibility activation all capture exact
  `(ID, semanticRevision, commandFingerprint)` and use one revalidating dispatcher; mismatch rebuilds
  without replay and requires a fresh activation, and one routing serial can mutate at most once.
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
  non-harness `PEBBLE_` key, removes shipping `PEBBLE_RPG_AUTOCREATE`, contains no secrets/private
  owner data, and creates no save/settings/database/network state.
- Update README/architecture/security copy to match only proven behavior.
- Security code PASS precedes installed Design Sign-off; Design Sign-off precedes independent Test;
  Test precedes deploy.
- Preserve registration order, saved IDs, ordinary hotbar/movement, non-RPG UI, old saves/settings,
  and all existing gameplay/LAN contracts.

**Architecture verdict: PASS.** The current code is not release-ready, but this plan is complete
enough for Design Review/Revision and Security plan review without implementation guesswork.
