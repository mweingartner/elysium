#!/bin/bash
set -euo pipefail

fail() {
    printf 'Elysium storage release-surface verification failed: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 0 ] || fail "arguments are not accepted"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCRUN="$(command -v xcrun)" || fail "xcrun not found"
[ -x "$XCRUN" ] || fail "xcrun is not executable"
NM="$($XCRUN --find nm)" || fail "nm not found through xcrun"
STRINGS="$($XCRUN --find strings)" || fail "strings not found through xcrun"
STRIP="$($XCRUN --find strip)" || fail "strip not found through xcrun"
SWIFT_DEMANGLE="$($XCRUN --find swift-demangle)" || fail "swift-demangle not found through xcrun"
SHASUM="$(command -v shasum)" || fail "shasum not found"
for tool in "$NM" "$STRINGS" "$STRIP" "$SWIFT_DEMANGLE" "$SHASUM"; do
    [ -n "$tool" ] && [ -x "$tool" ] || fail "required artifact tool is unavailable"
done

file_sha256() {
    "$SHASUM" -a 256 "$1" | awk '{print $1}'
}

TMP_ROOT="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_ROOT/elysium-storage-release-surface.XXXXXX")" \
    || fail "could not create a temporary directory"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

artifact_sha256() {
    local source="$1" label="$2" normalized
    normalized="$TMP_DIR/$label"
    /bin/cp "$source" "$normalized" || fail "could not copy $label for hashing"
    /bin/chmod u+w "$normalized" || fail "could not make hash copy writable: $label"
    "$STRIP" -S -x "$normalized" || fail "could not normalize debug/local symbols: $label"
    file_sha256 "$normalized"
}

# These reviewed hashes bind the release artifact gate to the exact storage
# implementation and externally reachable API admitted by the source scanner.
# Artifact hashes are taken from disposable copies with DWARF and local symbols
# removed so the reviewed gate is independent of the physical worktree path.
# SwiftPM's package identity remains intentionally significant because it is an
# ABI input for package-access declarations.
#
# scripting-ui-and-replication (change 3): EXPECTED_CORE_OBJECT_SHA256/
# EXPECTED_ELYSIUM_PRODUCT_SHA256/EXPECTED_SMOKE_PRODUCT_SHA256 renewed — ElysiumCore.o's
# hash necessarily moves whenever any source file in that target changes (this change added
# real code to Sources/ElysiumCore/Scripting and Sources/ElysiumCore/Net), and the Elysium/
# elysmoke product hashes follow transitively since both link ElysiumCore.o. The five reviewed
# *source* hashes above/below (StorageEngine.swift, Saves.swift, GameCore.swift, Player.swift,
# ElysiumTextInput.swift) and the ElysiumStorage.o/ElysiumTextInput.o object hashes are
# untouched and still byte-identical — this change never wrote to any of those files or
# targets, only to Sources/ElysiumCore/Scripting, Sources/ElysiumCore/Net, and Sources/Elysium.
#
# pickaxe-uprighting: the pickaxe moved from the retired procedural rasteriser to a baked
# upright PNG in Sources/Elysium (HeldItemAssets.swift), so only EXPECTED_ELYSIUM_PRODUCT_SHA256
# moves — ElysiumCore.o, the smoke product, and every source/storage pin are byte-identical.
#
# off-hand/tool-hand polish: GameCore gained the shield-raise tick + off-hand toggle handlers
# and Player gained toggleOffhandItem + the shield-block logic, moving their reviewed source
# pins; ElysiumCore.o and the Elysium/elysmoke products follow. The storage surface
# (StorageEngine, Saves, manifests, ElysiumStorage.o, text-input) is untouched and byte-identical
# — these edits are gameplay/HUD only, never storage-reachable.
#
# native-script-editor + combat/HUD polish: EXPECTED_GAME_CORE_SOURCE_SHA256 and
# EXPECTED_PLAYER_SOURCE_SHA256 renewed — GameCore.swift gained a scriptEditorWindowOpen
# pause flag and Player.swift a doubled attack-recovery constant. EXPECTED_CORE_OBJECT_SHA256
# follows (Player/Living/GameCore all live in ElysiumCore), and the Elysium/elysmoke product
# hashes follow transitively. The storage surface (StorageEngine.swift, Saves.swift, the two
# manifests, ElysiumStorage.o/ElysiumTextInput.o and TEXT_INPUT source) is untouched and still
# byte-identical: the checked-player getter/CAS declarations, caller counts, and approved-owner
# set below all still hold — these edits are gameplay/UI only, never storage-reachable.
#
# lua-editor-2: EXPECTED_GAME_CORE_SOURCE_SHA256 renewed after GameCore gained only a read-only
# world-session generation accessor plus synchronous pre-teardown notifications used to fence
# native editor drafts. The checked-player getter/CAS declarations, both caller spans, counts, and
# approved-owner set below remain unchanged. EXPECTED_CORE_OBJECT_SHA256 moves for those additions
# and the scripting schema/runtime work in ElysiumCore; the Elysium and elysmoke product hashes
# follow transitively. StorageEngine.swift, Saves.swift, both storage manifests,
# ElysiumStorage.o, ElysiumTextInput.swift, and ElysiumTextInput.o remain byte-identical.
#
# lua-editor-native-toolbar: EXPECTED_ELYSIUM_PRODUCT_SHA256 renewed after the native AppKit
# toolbar, completion-panel lifecycle, and injectable editor proposal boundary changed only the
# Elysium application target. ElysiumCore.o, elysmoke, and every reviewed storage/text-input source
# and object pin remain byte-identical.
#
# lua-editor-handler-check: EXPECTED_CORE_OBJECT_SHA256 renewed after dry-run Check began creating
# registry-shaped synthetic events for known handler triggers; the Elysium and elysmoke products
# follow transitively. This changes only scripting validation in ElysiumCore. GameCore.swift and
# every reviewed storage/text-input source, manifest, and object pin remain byte-identical.
#
# model-rendered-pickaxes: EXPECTED_ELYSIUM_PRODUCT_SHA256 renewed from
# bf67591da69f4974fd6c37c3cfa90cf8ebdab7256194e929bb234fccab922f8a to
# b46cda7a0cc807b04c61a555ed64ad5588bfe4a25b33c9d4acf9fd97953869bf after the
# Elysium application target gained manifest-bound CC0 pickaxe renders and rigid held-item
# animation. ElysiumCore.o, elysmoke, and every reviewed storage/text-input source, manifest,
# and object pin remain byte-identical. Assets/Elysium/HeldPickaxe3D/build.md records the
# normalization command and complete renewal evidence.
#
# extensible-object-events: EXPECTED_GAME_CORE_SOURCE_SHA256 and
# EXPECTED_PLAYER_SOURCE_SHA256 renewed for the reviewed standard-event producer funnels,
# tool-strike/LAN gesture routing, object-record hydration, lifecycle delivery, and canonical
# actor provenance. EXPECTED_CORE_OBJECT_SHA256 follows those changes plus the bounded custom
# event/attribute runtime; the Elysium and elysmoke products follow transitively, with Elysium
# also containing the schema-driven editor and optional Ollama UI. The smoke product additionally
# carries the reviewed Appendix A fixture update that verifies camelCase Lua attribute sugar is
# persisted and queried through its canonical snake_case spelling. StorageEngine.swift,
# Saves.swift, both capability manifests, ElysiumStorage.o, ElysiumTextInput.swift, and
# ElysiumTextInput.o remain byte-identical. docs/extensible-object-events/build.md records every
# old/new pin and the clean-build normalization evidence.
#
# scriptable-furnace-output: EXPECTED_GAME_CORE_SOURCE_SHA256 renewed from
# 23d2f5a04f2c5e1cd5981a2cf8394159c40e86670b4ffb7e3348cdb12f71e574 to
# ee9913866cf2c06e81e187735cf2c8aad01e183254b6f2028d6d94eed8c3973c after GameCore
# gained only the host-authoritative, read-only scripted-furnace-output hook. The checked-player
# getter/CAS declarations, callers, counts, and protected spans below are unchanged.
# EXPECTED_CORE_OBJECT_SHA256 moves from b62b17e26f7edb876771a70a45008e51ed725e3176a869ead4eba75e25cf6f4f
# to 6f2c08d5d9f5b1371fcaa08eaa588b18bb7c311e7943f66f31e57753bf4eb809 for that hook and the
# reviewed scripting/furnace implementation. EXPECTED_ELYSIUM_PRODUCT_SHA256 moves from
# 9f84be3823ec9cc8b658ee0cd74d99ab81c5fa6f051fb58da0ad596f5d39eaea to
# 78a1d49fc33e00b0382f42ba9b837e04134f66cb2bdc11c5850ce9b810565de5, and
# EXPECTED_SMOKE_PRODUCT_SHA256 moves from
# 0bc8236305b9619cfdd3e1e1dd95362ec3a1b93b37ec20c7469684466b5c22d0 to
# 71680aec7314a60713b192f253b3e7cf6b379f265221826a6838354a6e88f3e8. StorageEngine.swift,
# Saves.swift, both capability manifests, ElysiumStorage.o, ElysiumTextInput.swift,
# ElysiumTextInput.o, and Player.swift remain byte-identical.
#
# script-ai-model-preload: EXPECTED_ELYSIUM_PRODUCT_SHA256 renewed from
# 78a1d49fc33e00b0382f42ba9b837e04134f66cb2bdc11c5850ce9b810565de5 to
# 5fece49d480bd5e9b6b84ef5a37ba1ea8fa60d20760ff9297e37854986e7d075 after the
# Elysium application target gained visibility-scoped local-model discovery, exact saved-model
# preload, retry/cancellation state, and its focused SwiftUI regression seam. ElysiumCore.o,
# elysmoke, and every reviewed storage/text-input source, manifest, and object pin remain
# byte-identical. docs/script-ai-model-preload/build.md records the normalization evidence.
# toolchain bump (Xcode-beta MacOSX27.0 SDK): the updated compiler re-emits every object and
# product to different stripped bytes, and its clang -extract-api serialises the ElysiumStorage
# symbol graph differently, so the binary/object pins, both product pins, and the API-manifest
# symbolGraphSHA256 all move together. Every reviewed *source* pin (StorageEngine.swift,
# Saves.swift, GameCore.swift, Player.swift, ElysiumTextInput.swift, both capability manifests'
# source) is unchanged, and the storage boundary scan's public-declaration lists still match —
# so the reachable storage API is identical; only the compiler's output bytes changed.
# scripting-player-give + ai-prose-salvage: EXPECTED_CORE_OBJECT_SHA256 renewed from
# b0a3bcf30a27c1e6f97a28bc6a3f641095e3ba8f57371b6803400abef797a807 to
# 339c84fad017900f7585fffdb58f2e8a0e957deb67f77e5b8730bcb38f97eb90, EXPECTED_ELYSIUM_PRODUCT_SHA256
# from c1c90e38bcefa71eb21d1306c2be603e44d5f9b3e0016738ae8646b11ff73c26 to
# 7fc5d168f74ea1f0ea4a0ee430c642b3a2da33d58d03bdf4893278345f891504, and EXPECTED_SMOKE_PRODUCT_SHA256
# from ef4e14f873d5c30861495460e7a1d85470b50d49cfce888fcd86151ede161bfe to
# 9f09f4158d115363df0771a4b0271225e15c6484db09807c2cb3a7d1444a552d after the
# player:give(item[, count]) scripting verb (ScriptRuntimeAPI/ScriptLanguageSchema/
# ScriptAIAuthoringGuide) plus the LAN grantScriptItem guest-delivery path re-emitted ElysiumCore.o,
# and both linked products followed (the Script-AI insertion-salvage fix touches only the Elysium
# app target). Every reviewed storage/game/player/text-input *source* pin, both capability
# manifests, ElysiumStorage.o, and ElysiumTextInput.o are byte-identical — only ElysiumCore.o and
# the products' output bytes moved.
#
# native-class-workspace: EXPECTED_GAME_CORE_SOURCE_SHA256 renewed from
# ee9913866cf2c06e81e187735cf2c8aad01e183254b6f2028d6d94eed8c3973c to
# dcd46910fd7a693fcd26fe1991029deebde59fc42624032632c88abfa20d44ef after the first-entry
# guidance changed only from the retired inventory route to the native Game > Character route.
# Both checked-player caller spans, getter/CAS counts, and approved owners remain byte-identical.
# EXPECTED_CORE_OBJECT_SHA256 moves from
# 339c84fad017900f7585fffdb58f2e8a0e957deb67f77e5b8730bcb38f97eb90 to
# 426fc12b74e7cf55ac23c7f85adfff6094d7d97955f5139cb5b0b1c07224ea3a for the reviewed class,
# progression, action, and GameCore changes. EXPECTED_ELYSIUM_PRODUCT_SHA256 moves from
# 7fc5d168f74ea1f0ea4a0ee430c642b3a2da33d58d03bdf4893278345f891504 to
# 8c94c8eaf361a1a1e07a4dde7acdc53de6485a25574a741a69ec6a3db6e23a3e for the native AppKit/
# SwiftUI character workspace, and EXPECTED_SMOKE_PRODUCT_SHA256 moves from
# 9f09f4158d115363df0771a4b0271225e15c6484db09807c2cb3a7d1444a552d to
# 53c8155cf583e877ecb1d9df8794fe900d3e0b7e0958685772c939926189f9d3 transitively. The storage,
# Saves, Player, text-input, capability-manifest, ElysiumStorage.o, and ElysiumTextInput.o pins
# remain byte-identical.
#
# script-ai-editor-readiness-and-insertion: EXPECTED_CORE_OBJECT_SHA256 renewed from
# 426fc12b74e7cf55ac23c7f85adfff6094d7d97955f5139cb5b0b1c07224ea3a to
# 450a1c3cf1602cdbb793ecd48d1e56722539508ac3f626f566c7971a18528a36 after mutation-free
# editor validation stopped consuming the live scheduler/RNG ordinal. EXPECTED_ELYSIUM_PRODUCT_SHA256
# moves from 8c94c8eaf361a1a1e07a4dde7acdc53de6485a25574a741a69ec6a3db6e23a3e to
# 3d12ad0a93d87227e7585c0a40c82d3aea55dde09a07f3894ebf11c92f4ee7ad for editor-open exact-model
# readiness, first-request retry, explicit Write Code/Ask routing, identity-bound native insertion,
# local-model provenance checks, and fail-closed generated-Lua validation. EXPECTED_SMOKE_PRODUCT_SHA256
# moves transitively from 53c8155cf583e877ecb1d9df8794fe900d3e0b7e0958685772c939926189f9d3 to
# 61edb5e5e7a935375307277ad71b6b0f10358021389fc6daef0eff883193ffe2. Reviewed storage,
# Saves, GameCore, Player, text-input, capability-manifest, ElysiumStorage.o, and
# ElysiumTextInput.o pins remain byte-identical.
#
# ai-script-authoring-protocol: EXPECTED_ELYSIUM_PRODUCT_SHA256 renewed from
# 3d12ad0a93d87227e7585c0a40c82d3aea55dde09a07f3894ebf11c92f4ee7ad to
# 1e75abe9fa1e3e959b6ca2c31e5a45cccea458aabf1f8288f89af233f7a898e5 after the Elysium app
# added the built-in /ai Lua creation protocol, nonce-fenced world/editor prompt data, complete-
# selection enforcement, target-member prompt priority, furnace-specific authoring facts, and the
# explicit single-turn panel notice. No ElysiumCore, storage, save, player, text-input, capability,
# or elysmoke source changed; all of their reviewed source/object/product pins remain byte-identical.
#
# held-item-choreography: EXPECTED_GAME_CORE_SOURCE_SHA256 renewed from
# dcd46910fd7a693fcd26fe1991029deebde59fc42624032632c88abfa20d44ef to
# a08cad717b4a61c6d45d933652bd6694d3b0a8a6b0556dc51394da048d319092 after GameCore gained
# only the cosmetic mining re-swing (restartMiningSwing) and the read-only heldItemBob(partial:)
# walk-bob accessor for the first-person hands. Both checked-player caller spans, getter/CAS
# counts, and approved owners remain byte-identical. EXPECTED_CORE_OBJECT_SHA256 moves from
# 450a1c3cf1602cdbb793ecd48d1e56722539508ac3f626f566c7971a18528a36 to
# 3798ee8676de1511cbe883a1ce17f087c70b8cd0125faf0a26eee3c145f20741 for those two GameCore
# additions. EXPECTED_ELYSIUM_PRODUCT_SHA256 moves from
# 1e75abe9fa1e3e959b6ca2c31e5a45cccea458aabf1f8288f89af233f7a898e5 to
# 887c7abe4be31a97dc9498b04747da39b65df7c45c3bf6ce2cf1d995fea49ec0 for the HUD held-item
# choreography (wall-clock swing state, lower/raise hand-off, partial-tick smoothing, walk-bob,
# eased shield/bow release) and the render partial reaching hud.draw, and
# EXPECTED_SMOKE_PRODUCT_SHA256 moves transitively from
# 61edb5e5e7a935375307277ad71b6b0f10358021389fc6daef0eff883193ffe2 to
# 1d045b5c1944236712112658aea5619cd7231a6e953685d3159b8b260d2f2479. The storage, Saves,
# Player, text-input, capability-manifest, ElysiumStorage.o, and ElysiumTextInput.o pins remain
# byte-identical.
#
# universal-interaction-and-script-sounds: EXPECTED_SAVES_SOURCE_SHA256 renewed from
# 104564ee02dd009085cc5bf2f1d09fb6e893915283bef1cc09a3e5f7ab884dec to
# 4018f336ad76cdbf1e9801c40211fb60c79bb24aecee952ce46f3cf5ef21c36c for the 1.1.1
# compatibility boundary and bounded LAN sound-catalog summary. EXPECTED_GAME_CORE_SOURCE_SHA256
# moves from a08cad717b4a61c6d45d933652bd6694d3b0a8a6b0556dc51394da048d319092 to
# d21afda791c66a30597a9e37b572a530c5d977d691506a0d16c9bc0f7eabccce for universal,
# exactly-once semantic interaction targeting plus host-authoritative LAN interaction routing and
# script sound dispatch. The Saves parse-AST capability entry and consequently
# EXPECTED_CORE_CAPABILITY_SHA256 move for the reviewed Saves declarations. ElysiumCore.o follows
# those changes and the scripting/LAN protocol implementation; Elysium and elysmoke follow that
# linked Core object, while Elysium additionally contains the bounded WAV library, macOS system
# sound discovery/playback, Options management UI, and sound-name editor completion. The storage
# source/API/object, Player source, ElysiumTextInput source/object, storage capability symbol graph,
# and LegacySaveMigration parse-AST entry remain byte-identical. Full old/new evidence is recorded
# in docs/script-interaction-sounds/build.md.
#
# grounded-spawns + ore/animal/lava worldgen: EXPECTED_GAME_CORE_SOURCE_SHA256 renewed from
# d21afda791c66a30597a9e37b572a530c5d977d691506a0d16c9bc0f7eabccce to
# c1ea09663131500c4e546c6d2d34fd49b6b49ded4e383aeb5efa8c0df169ea75 after GameCore gained the
# groundedSpawn helper (dry-ground column search on first entry, bed-less respawn, and the End
# return, re-recording the world spawn through the existing putWorld path) and the inland
# spawn-candidate filter. Both checked-player caller spans, getter/CAS counts, and approved
# owners remain byte-identical. EXPECTED_CORE_OBJECT_SHA256 moves from
# 3810b3aee479d2533277afdfb44ef9637f2fd5ee820ecf7c076b952b68dde737 to
# ec805bc9ae4efa724f6ce08caf58a35089b3bf92eaac227cc2443095d586711c for that GameCore change plus
# the coal/iron hill bands and lava-region cave density in Terrain, the World dryGroundY /
# groundedSpawnColumn lookups, and land-animal water avoidance in Animals.
# EXPECTED_ELYSIUM_PRODUCT_SHA256 moves from
# 193425557606069d54a33bc1349bea5f931dbd7ac36a771c8802265d88f445d9 to
# 4be891cd6d31200b9e122b0341b81aa300fc73dd7d9aaf48003775e8f56240c6 for those ElysiumCore changes
# and the re-embedded premultiplied-alpha held-tool sprites, and EXPECTED_SMOKE_PRODUCT_SHA256
# moves transitively from 7846fc13cd37b933b685617a44600bae23ed90d6a44465c5f609d096e1be75db to
# 90a9fa30f8941ef7da1991d8ad1a8420597f12a963f4e2a04d230d2d8316692e. The storage, Saves, Player,
# text-input, capability-manifest, ElysiumStorage.o, and ElysiumTextInput.o pins remain
# byte-identical.
#
EXPECTED_STORAGE_SOURCE_SHA256='4d4bf5756df15ed9f50ef550fa93e08c2f5c99f0ebdf5fdf96154807f08c98ba'
EXPECTED_STORAGE_API_SHA256='08acf52a794de902a69658a0926181918c62a30f7975cd0d685d3d3baa7c745b'
EXPECTED_STORAGE_OBJECT_SHA256='43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8'
# prehistoric-worlds 1.3.0: Saves now rejects unknown/future prehistoric
# profile IDs at the persistence boundary, and GameCore/LAN content changes
# relink the Core object and both production consumers. The reviewed AST
# inventory hash moves with Saves; storage/text-input surfaces remain pinned.
EXPECTED_SAVES_SOURCE_SHA256='5efd5a22b43aeb04760462c8a3fd3dfae5c49ff61b7271cc30ec981b86b9786f'
EXPECTED_PLAYER_SOURCE_SHA256='1f4dff72450f80e20d675bf645c01700ac6962375b331d0cd69d2764b50eaf08'
EXPECTED_CORE_CAPABILITY_SHA256='2c14c21b1045d414dd7b4931c63db6074df16ffe0cdbf2f29b1c6cd5abcd169e'
EXPECTED_TEXT_INPUT_SOURCE_SHA256='dda602f2008afa7914f471217848e1d6a2e701aced3d6a1ed304fdfc3c6f868e'
EXPECTED_TEXT_INPUT_OBJECT_SHA256='0fcd8840b58e2db50fc3556144417b4615d99f1e7bb75344dd259149dd705bf3'
# land-animal shore escape: AI.swift, Animals.swift and Entity.swift add footprint-aware
# water avoidance, bounded deterministic shore search, and bat surface avoidance. The Core
# object and its two linked products therefore change. Reviewed with 26 focused regressions,
# 491 smoke checks (only intentional zooStages updated), and a rendered debug-app pond test.
# StorageEngine, Saves, GameCore, Player, both storage manifests, ElysiumTextInput and the
# storage/text-input objects remain byte-identical; no persistence API or authority changed.
# target-aware first-person geometry + upright bats: only Render/BatModel.swift and
# Render/EntityModels2.swift change in Core (model geometry/UVs, not simulation or storage).
# The native first-person Metal renderer, rig/target math and asset streams change Elysium;
# elysmoke follows the relinked Core. Normalized with the same disposable-copy strip -S -x
# path above. The seven reviewed source/manifest hashes and both Storage/TextInput object
# hashes were independently compared and remain byte-identical. No capability pin changes.
# Renewed from Core fd850d2013fc8e293e9805dc6562b2d5e494ffba4d100d289bcc65ba20fd0cdb,
# Elysium 26a9d506fdb3db4d8254bc9ca20e573cee1d863a04b66891420fdfec3abf47f9,
# smoke e51eed27df113faaa10ea1872f228a5fde806fcbb65e29e3725d659fbfdcc130.
# Tool-family action audio changes only cosmetic local/LAN mining and melee
# presentation routing plus a closed ItemDefs map. The swing cadence now owns
# its four-tick timer in GameCore so audible strokes continue while chunk
# readiness temporarily pauses the player's entity tick. Checked-player caller
# spans/counts and storage/capability surfaces remain byte-identical.
# release-1.2.1: `Saves.swift` owns the exact LAN compatibility version, so its
# source and compiler parse-AST inventory pins move for the 1.2.1 release. That
# source change relinks ElysiumCore.o, Elysium, and elysmoke. It does not alter
# the storage API, SaveDB behavior, checked-player callers, Player, or text input.
# rich-resources-communities: exact-terrain structures, populated villages,
# and witch behavior change Core gameplay. `WorldRecord` additionally persists
# a normalized village-density integer; missing or malformed legacy values use
# Normal. That changes Saves.swift, GameCore.swift, and the Saves compiler-AST
# capability inventory, then relinks Core and its two production consumers.
# The SQLite schema/API, StorageEngine, Player, and text-input surfaces remain
# byte-identical because the existing worlds JSON column carries this field.
# rich-resources-final-closeout: village density persistence, exact-terrain
# structure admission, populated communities, witch behavior, and the final
# dungeon water-envelope cap update change Saves.swift, GameCore.swift, and
# the reviewed Saves compiler-AST capability inventory. The warning-free
# release build below was normalized through the disposable-copy strip path.
# usage-skill-trees: 1.2.2 adds migration-backed, usage-based Mining, Melee,
# Ranged, and Crafting progression, authoritative LAN bow release handling,
# aligned chest placement, and denser village planning. Saves.swift, GameCore,
# and Player now participate in the reviewed state/migration boundary. The
# storage API, Storage/TextInput source, and their object pins remain unchanged.
# The compiler-AST inventory renews because Saves.swift owns exact LAN-version
# compatibility. docs/release-1.2.2-build.md records the renewed hashes.
# prehistoric-worlds 1.3.0: the four opt-in profiles add a strict generated
# entity boundary and make retained legacy spawners inert before any timer/RNG
# side effect. The roster's bounded ambient cooldown is saved with its private
# controller stream, preventing a reload from introducing an early controller
# draw. These GameCore/Entity/Core changes relink both production consumers;
# Saves, storage/capability, Player, and text-input reviewed surfaces are unchanged.
# prehistoric-ecosystem-starter-shelter: GameCore now selects the deterministic
# v2 shelter spawn only after checking its saved floor/body space, with a
# bounded dry fallback for modified huts, and makes first entry/respawn/End
# return use that same physical contract. The checked-player getter/CAS
# declarations, callers, counts, approved owners, and protected spans below
# remain unchanged; this gameplay-only source renewal was checked before these
# release pins were regenerated from a warning-free production build.
EXPECTED_GAME_CORE_SOURCE_SHA256='2f5ad0d1f44691e61b0cd1d528d242fbb30f9a658d486ef5f1c5fabdd183a113'
# worldgen-form-integrity: the final structure pass adds terrain-backed surface
# plans, deterministic realized-piece collision resolution, and supported routes
# through villages, dungeons, mineshafts, strongholds, Ancient Cities, and the
# large landmark families.  It changes ElysiumCore.o and both linked production
# consumers, but does not further change the reviewed Saves/GameCore source,
# storage API, Player, text-input, or capability-manifest surfaces above.
# Normalized disposable-copy hashes renew from Core
# 5ea20c16d0c9eb828514102c8d6411a24c01be26d466782186363aec330a2721,
# Elysium 88b4cfa3009b6fa8f474b404af98f8b8b50f8daae92a782ca249c9cd6d9a854d,
# and elysmoke 710e4462b3f1ecf21ee6c1d5c65722e1fc5f75faf7c498a4b1294509600914c9.
# prehistoric-model-gallery: the rigid prehistoric renderer gains validated,
# source-authored faceted mesh geometry and profile-safe pose routing.  It
# changes presentation-only Core and AppKit renderer sources, so ElysiumCore.o
# and both linked products renew.  The reviewed Saves/GameCore/Player,
# storage/capability, and text-input source/object pins remain byte-identical.
# Normalized through the disposable-copy strip -S -x path from a warning-free
# release build; docs/prehistoric-model-gallery/build.md records the old/new
# values and verification evidence.
# prehistoric-audio-xp: per-species lifecycle/action/movement sound routing and
# combat-scaled ordinary XP change only PrehistoricCreatures.swift and AI.swift
# in ElysiumCore, plus the application-owned procedural Audio.swift recipes.
# Core and both linked products renew; storage, Saves, GameCore, Player,
# capabilities, and text-input source/object pins remain byte-identical.
# Normalized disposable-copy evidence is in docs/prehistoric-audio-xp/build.md.
# The v2 ecosystem, deterministic starter shelter, and safe GameCore spawn
# paths recompile ElysiumCore and its two production consumers. The normalized
# disposable-copy hashes below were renewed together with the GameCore source
# pin above; storage, Saves, Player, text-input, and capability surfaces are
# still protected by their independent unchanged pins.
# Fence-gate geometry and LAN session teardown renew the stripped Core object
# and linked products from the warning-free build.
EXPECTED_CORE_OBJECT_SHA256='49d23f2ae571ff4436476a55067d44360ef426fd75acf858852182a85c2c2340'
# Minecraft-reference ordinary item presentation: only app-side renderer, placement,
# rig and animation sources change the product. Renewed from
# 81e28db71efc533cb1e2dfb10cacd393689d3422f0db7abb528fc37bfad32b72 after a warning-free
# release build, 73 affected tests, and native pose/swing/trident inspection.
# Disposable-copy strip -S -x verification confirms Core, Storage, TextInput and
# elysmoke remain byte-identical. No runtime mesh stream, simulation, storage,
# input or capability source changed. See docs/first-person-minecraft-comparison.md.
# Tool-family action audio additionally changes the procedural app recipes, so
# the linked Elysium and elysmoke stripped-product pins renew transitively.
# restore-local-world-persistence: the native app no longer opts into a
# automatic local-world deletion policy, and its LAN adapter refuses a join from an
# active local world until the player uses Save & Quit to Title. This is
# app-target lifecycle/UI behavior only: Core, elysmoke, and the reviewed
# storage/text-input surfaces remain byte-identical. The stripped Elysium
# product pin renews from 17f963e3512e40f14a298b7fcee90512ba94cc667f47a4e8dcf1c72718520b9c.
EXPECTED_ELYSIUM_PRODUCT_SHA256='1915b02a8ebf355566cda4d91121672eb92f5241230b758ac2b7956f9ce2275f'
EXPECTED_SMOKE_PRODUCT_SHA256='6332cd84b934cd6900548ff619aefd3e764a68f447b2de574c80cb934fd988ac'
STORAGE_SOURCE='Sources/ElysiumStorage/StorageEngine.swift'
STORAGE_API_MANIFEST='scripts/elysium-storage-api-v1.json'
SAVES_SOURCE='Sources/ElysiumCore/Game/Saves.swift'
GAME_CORE_SOURCE='Sources/ElysiumCore/Game/GameCore.swift'
PLAYER_SOURCE='Sources/ElysiumCore/Entity/Player.swift'
CORE_CAPABILITY_MANIFEST='scripts/elysium-core-storage-capability-v1.json'
TEXT_INPUT_SOURCE='Sources/ElysiumTextInput/ElysiumTextInput.swift'
[ "$(file_sha256 "$STORAGE_SOURCE")" = "$EXPECTED_STORAGE_SOURCE_SHA256" ] \
    || fail "reviewed storage source hash drift"
[ "$(file_sha256 "$STORAGE_API_MANIFEST")" = "$EXPECTED_STORAGE_API_SHA256" ] \
    || fail "reviewed storage API manifest hash drift"
[ "$(file_sha256 "$SAVES_SOURCE")" = "$EXPECTED_SAVES_SOURCE_SHA256" ] \
    || fail "reviewed SaveDB checked-player source hash drift"
[ "$(file_sha256 "$GAME_CORE_SOURCE")" = "$EXPECTED_GAME_CORE_SOURCE_SHA256" ] \
    || fail "reviewed checked-player caller source hash drift"
[ "$(file_sha256 "$PLAYER_SOURCE")" = "$EXPECTED_PLAYER_SOURCE_SHA256" ] \
    || fail "reviewed player omission-candidate source hash drift"
[ "$(file_sha256 "$CORE_CAPABILITY_MANIFEST")" = "$EXPECTED_CORE_CAPABILITY_SHA256" ] \
    || fail "reviewed Core storage capability manifest hash drift"
[ "$(file_sha256 "$TEXT_INPUT_SOURCE")" = "$EXPECTED_TEXT_INPUT_SOURCE_SHA256" ] \
    || fail "reviewed text-input source hash drift"
[ ! -e 'Sources/ElysiumCore/Game/LANV6ClientCheckpointCodec.swift' ] \
    || fail "deferred Core client checkpoint codec unexpectedly exists"
if grep -F 'LANV6ClientAuthoritySaveAdapterV1' Sources/ElysiumCore/Game/Saves.swift >/dev/null; then
    fail "deferred Core client checkpoint adapter unexpectedly exists"
fi

# Freeze the checked Core surface and its only two production consumers. The omission path owns
# exactly one checked read/CAS pair; ordinary persistence owns the other pair. No omission path may
# fall back to the compatibility best-effort writer.
for declaration in \
    'public struct SaveDBPlayerRowDigest: Equatable, Sendable {' \
    'public struct SaveDBPlayerRowSnapshot {' \
    'public enum SaveDBPlayerRowExpectation: Equatable, Sendable {' \
    'public enum SaveDBPlayerRowError: Error, Equatable, Sendable {' \
    '    public func getPlayerChecked(_ worldId: String) throws -> SaveDBPlayerRowSnapshot? {' \
    '    public func compareAndSwapPlayerChecked('; do
    [ "$(grep -Fxc "$declaration" "$SAVES_SOURCE" || true)" -eq 1 ] \
        || fail "checked Core declaration drift: $declaration"
done
for error_case in invalidCandidate invalidStoredRow conflict persistenceFailed; do
    [ "$(grep -Fxc "    case $error_case" "$SAVES_SOURCE" || true)" -eq 1 ] \
        || fail "checked player error surface drift: $error_case"
done
[ "$(grep -Fc 'getPlayerChecked(' "$SAVES_SOURCE" || true)" -eq 1 ] \
    || fail "SaveDB must declare exactly one checked player getter"
[ "$(grep -Fc 'compareAndSwapPlayerChecked(' "$SAVES_SOURCE" || true)" -eq 1 ] \
    || fail "SaveDB must declare exactly one checked player CAS"
[ "$(grep -Fc 'getPlayerChecked(' "$GAME_CORE_SOURCE" || true)" -eq 2 ] \
    || fail "GameCore checked player getter caller count drift"
[ "$(grep -Fc 'compareAndSwapPlayerChecked(' "$GAME_CORE_SOURCE" || true)" -eq 2 ] \
    || fail "GameCore checked player CAS caller count drift"

while IFS= read -r caller; do
    case "$caller" in
        "$SAVES_SOURCE"|"$GAME_CORE_SOURCE") ;;
        *) fail "checked player CAS escaped approved production owners: $caller" ;;
    esac
done < <(grep -R -l --include='*.swift' -F 'compareAndSwapPlayerChecked(' Sources || true)
while IFS= read -r caller; do
    case "$caller" in
        "$SAVES_SOURCE"|"$GAME_CORE_SOURCE") ;;
        *) fail "checked player getter escaped approved production owners: $caller" ;;
    esac
done < <(grep -R -l --include='*.swift' -F 'getPlayerChecked(' Sources || true)

OMISSION_START="$(grep -Fn '    private func beginCheckedLegacyPlayerOmission(' \
    "$GAME_CORE_SOURCE" | cut -d: -f1)"
OMISSION_END="$(grep -Fn '    private func completeCheckedLegacyPlayerOmission(' \
    "$GAME_CORE_SOURCE" | cut -d: -f1)"
ORDINARY_START="$(grep -Fn '    private func persistCheckedPlayerCandidate(' \
    "$GAME_CORE_SOURCE" | cut -d: -f1)"
ORDINARY_END="$(grep -Fn '    private func completeRPGPreferenceWrite(' \
    "$GAME_CORE_SOURCE" | cut -d: -f1)"
case "$OMISSION_START:$OMISSION_END:$ORDINARY_START:$ORDINARY_END" in
    *$'\n'*|*[!0-9:]*) fail "checked player caller boundaries are ambiguous" ;;
esac
[ -n "$OMISSION_START" ] && [ "$OMISSION_START" -lt "$OMISSION_END" ] \
    || fail "omission caller boundary drift"
[ -n "$ORDINARY_START" ] && [ "$ORDINARY_START" -lt "$ORDINARY_END" ] \
    || fail "ordinary persistence caller boundary drift"
span_count() {
    sed -n "$2,$(($3 - 1))p" "$1" | awk -v needle="$4" \
        'index($0, needle) { count += 1 } END { print count + 0 }'
}
[ "$(span_count "$GAME_CORE_SOURCE" "$OMISSION_START" "$OMISSION_END" \
    'getPlayerChecked(')" -eq 1 ] \
    || fail "omission consumer must contain exactly one checked getter"
[ "$(span_count "$GAME_CORE_SOURCE" "$OMISSION_START" "$OMISSION_END" \
    'compareAndSwapPlayerChecked(')" -eq 1 ] \
    || fail "omission consumer must contain exactly one checked CAS"
[ "$(span_count "$GAME_CORE_SOURCE" "$ORDINARY_START" "$ORDINARY_END" \
    'getPlayerChecked(')" -eq 1 ] \
    || fail "ordinary persistence must contain exactly one checked getter"
[ "$(span_count "$GAME_CORE_SOURCE" "$ORDINARY_START" "$ORDINARY_END" \
    'compareAndSwapPlayerChecked(')" -eq 1 ] \
    || fail "ordinary persistence must contain exactly one checked CAS"
[ "$(span_count "$GAME_CORE_SOURCE" "$OMISSION_START" "$OMISSION_END" \
    'putPlayer(')" -eq 0 ] \
    || fail "omission path calls compatibility putPlayer"
[ "$(grep -Fc 'putPlayerChecked' "$SAVES_SOURCE" || true)" -eq 0 ] \
    || fail "unconditional checked player writer unexpectedly exists"

RELEASE_OUTPUT="$(swift build -c release --show-bin-path)" \
    || fail "could not resolve the release bin path"
[ -n "$RELEASE_OUTPUT" ] || fail "release bin path was empty"
case "$RELEASE_OUTPUT" in
    *$'\n'*) fail "release bin path produced multiple lines" ;;
    /*) ;;
    *) fail "release bin path was not absolute" ;;
esac
RELEASE_DIR="$RELEASE_OUTPUT"
[ -d "$RELEASE_DIR" ] || fail "release directory is missing"

STORAGE_OBJECT="$RELEASE_DIR/ElysiumStorage.o"
CORE_OBJECT="$RELEASE_DIR/ElysiumCore.o"
TEXT_INPUT_OBJECT="$RELEASE_DIR/ElysiumTextInput.o"
ELYSIUM_PRODUCT="$RELEASE_DIR/Elysium"
SMOKE_PRODUCT="$RELEASE_DIR/elysmoke"
ARTIFACTS=("$STORAGE_OBJECT" "$ELYSIUM_PRODUCT" "$SMOKE_PRODUCT")
for artifact in "$CORE_OBJECT" "$TEXT_INPUT_OBJECT" "${ARTIFACTS[@]}"; do
    [ ! -L "$artifact" ] || fail "artifact is a symlink: $artifact"
    [ -f "$artifact" ] || fail "artifact is missing or not regular: $artifact"
    [ -r "$artifact" ] || fail "artifact is unreadable: $artifact"
    [ -s "$artifact" ] || fail "artifact is empty: $artifact"
done
[ "$(artifact_sha256 "$STORAGE_OBJECT" ElysiumStorage.o)" = "$EXPECTED_STORAGE_OBJECT_SHA256" ] \
    || fail "reviewed ElysiumStorage.o hash drift"
[ "$(artifact_sha256 "$CORE_OBJECT" ElysiumCore.o)" = "$EXPECTED_CORE_OBJECT_SHA256" ] \
    || fail "reviewed ElysiumCore.o hash drift"
[ "$(artifact_sha256 "$TEXT_INPUT_OBJECT" ElysiumTextInput.o)" = "$EXPECTED_TEXT_INPUT_OBJECT_SHA256" ] \
    || fail "reviewed ElysiumTextInput.o hash drift"
[ "$(artifact_sha256 "$ELYSIUM_PRODUCT" Elysium)" = "$EXPECTED_ELYSIUM_PRODUCT_SHA256" ] \
    || fail "reviewed Elysium product hash drift"
[ "$(artifact_sha256 "$SMOKE_PRODUCT" elysmoke)" = "$EXPECTED_SMOKE_PRODUCT_SHA256" ] \
    || fail "reviewed elysmoke product hash drift"

[ ! "$STORAGE_OBJECT" -ot Package.swift ] \
    || fail "ElysiumStorage.o is older than Package.swift"
SOURCE_LIST="$TMP_DIR/storage-sources"
find Sources/ElysiumStorage -type f -print0 > "$SOURCE_LIST" \
    || fail "could not enumerate ElysiumStorage sources"
[ -s "$SOURCE_LIST" ] || fail "ElysiumStorage has no regular source files"
while IFS= read -r -d '' source; do
    [ ! "$STORAGE_OBJECT" -ot "$source" ] \
        || fail "ElysiumStorage.o is older than $source"
done < "$SOURCE_LIST"
CORE_SOURCE_LIST="$TMP_DIR/core-sources"
find Sources/ElysiumCore -type f -print0 > "$CORE_SOURCE_LIST" \
    || fail "could not enumerate ElysiumCore sources"
[ -s "$CORE_SOURCE_LIST" ] || fail "ElysiumCore has no regular source files"
while IFS= read -r -d '' source; do
    [ ! "$CORE_OBJECT" -ot "$source" ] \
        || fail "ElysiumCore.o is older than $source"
done < "$CORE_SOURCE_LIST"
TEXT_INPUT_SOURCE_LIST="$TMP_DIR/text-input-sources"
find Sources/ElysiumTextInput -type f -print0 > "$TEXT_INPUT_SOURCE_LIST" \
    || fail "could not enumerate ElysiumTextInput sources"
[ -s "$TEXT_INPUT_SOURCE_LIST" ] || fail "ElysiumTextInput has no regular source files"
while IFS= read -r -d '' source; do
    [ ! "$TEXT_INPUT_OBJECT" -ot "$source" ] \
        || fail "ElysiumTextInput.o is older than $source"
done < "$TEXT_INPUT_SOURCE_LIST"
for product in "$ELYSIUM_PRODUCT" "$SMOKE_PRODUCT"; do
    [ ! "$product" -ot "$STORAGE_OBJECT" ] \
        || fail "linked product is older than ElysiumStorage.o: $product"
    [ ! "$product" -ot "$CORE_OBJECT" ] \
        || fail "linked product is older than ElysiumCore.o: $product"
    [ ! "$product" -ot "$TEXT_INPUT_OBJECT" ] \
        || fail "linked product is older than ElysiumTextInput.o: $product"
done

TEXT_INPUT_SURFACES=("$TEXT_INPUT_OBJECT" "$ELYSIUM_PRODUCT" "$SMOKE_PRODUCT")
for artifact in "${TEXT_INPUT_SURFACES[@]}"; do
    label="$(basename "$artifact")"
    if "$NM" -a "$artifact" | "$SWIFT_DEMANGLE" | \
        grep -E 'ElysiumTextInputTests|probeLaunchMarker|TextInputTestHook|InjectedPasteboard' >/dev/null; then
        fail "text-input test/probe symbol present in $label"
    fi
    if "$STRINGS" -a "$artifact" | \
        grep -E 'ElysiumTextInputTests|probeLaunchMarker|TextInputTestHook|InjectedPasteboard' >/dev/null; then
        fail "text-input test/probe string present in $label"
    fi
done

DENYLIST="$TMP_DIR/denylist"
cat > "$DENYLIST" <<'DENYLIST'
ElysiumStorageTest
ElysiumStorageDescriptorIdentityProbe
ElysiumStorageFactoryFailurePoint
ElysiumStorageSQLiteLengthLimitProbe
ElysiumStorageLegacyCollectionFailurePoint
ElysiumStorageLegacyImportFailurePoint
ElysiumStorageBarrierFailurePoint
ElysiumStorageSchemaAuditProbe
ElysiumStorageTestDeadlineBoundary
ElysiumStorageTestBodyError
ElysiumStorageRPGLocalTestOperation
SaveDBPlayerCASBarrier
SaveDBPlayerCASBarrierStage
ElysiumStorageRPGLocalFailureStage
testRPGLocalPreferencesWrite
testCoreWorldDeleteWithRPG
testSetRPGLocalFailure
injectActiveRPGLocalFailure
withActiveRPGLocalTestOperation
LANV6ClientCheckpointCodec
LANV6ClientAuthoritySaveAdapterV1
LANV6ClientCheckpointValidatedStateV1
InjectedLocalSettingsFailure
LocalSettingsSystemWriteCut
LocalSettingsFileIO
LocalSettingsStore.init(directoryURL:
faultInjector
encodeFaultInjector
systemWriteCut
StorageLegacyImportFailurePoint
_test
testOpen
testInject
testSet
testArmStage
testAutocommit
testForeignKeysEnabled
testPhysicalIdentityBound
testSameScopeReentry
testEscapedStatementRejects
testReadScopeWriteProbe
testLegacy
testCrossTableMutationProbe
testBootstrapAfterReadinessProbe
testNestedTransactionProbe
testCaughtBindFailureCannotCommit
testForceAuthorizationGenerationBoundary
testLeakRawStatementForClose
testBodyAndFinalizeFailure
testAuthorizationContract
testSchemaAuditDeniedProbe
testSQLiteLengthLimitProbe
testExtendedPrimaryKeyConstraint
testWorldCollectionThreeByteBudget
activeTestStage
observeTestStage
factoryProbe
injectFactoryFailureBeforeBootstrapStatement
injectLegacyImportFailure
injectedFailures
testLeakedRawStatement
authorizationTransitionCoverage
legacyCollectionFailurePoint
legacyImportFailurePoint
barrierFailurePoint
consumeLegacyCollectionFailure
consumeLegacyImportFailure
consumeBarrierFailure
quickCheckBudgetExhausted
afterSQLiteOpen
beforeBootstrapStatement
afterChunkKeyPreflight
afterDurabilitySyncBeforeIdentityProof
externalWait
executorWait
legacyDeviceBitPatternForTesting
DENYLIST

CORE_RAW_NM="$TMP_DIR/ElysiumCore.nm"
CORE_DEMANGLED_NM="$TMP_DIR/ElysiumCore.demangled"
CORE_STRINGS="$TMP_DIR/ElysiumCore.strings"
CORE_UNDEFINED_NM="$TMP_DIR/ElysiumCore.undefined"
"$XCRUN" nm -a "$CORE_OBJECT" > "$CORE_RAW_NM" \
    || fail "nm failed for ElysiumCore.o"
"$SWIFT_DEMANGLE" < "$CORE_RAW_NM" > "$CORE_DEMANGLED_NM" \
    || fail "swift-demangle failed for ElysiumCore.o"
"$XCRUN" strings -a "$CORE_OBJECT" > "$CORE_STRINGS" \
    || fail "strings failed for ElysiumCore.o"
"$XCRUN" nm -u "$CORE_OBJECT" > "$CORE_UNDEFINED_NM" \
    || fail "undefined-symbol scan failed for ElysiumCore.o"
if grep -E '(^|[[:space:]_])sqlite3_' "$CORE_UNDEFINED_NM" >/dev/null; then
    fail "ElysiumCore.o gained a direct SQLite call"
fi
for required_core_surface in \
    'ElysiumCore.SaveDBPlayerRowDigest' \
    'ElysiumCore.SaveDBPlayerRowSnapshot' \
    'ElysiumCore.SaveDBPlayerRowExpectation' \
    'ElysiumCore.SaveDBPlayerRowError' \
    'ElysiumCore.SaveDB.getPlayerChecked' \
    'ElysiumCore.SaveDB.compareAndSwapPlayerChecked'; do
    grep -Fq "$required_core_surface" "$CORE_DEMANGLED_NM" \
        || fail "checked Core surface missing from ElysiumCore.o: $required_core_surface"
done
while IFS= read -r denied; do
    for surface in "$CORE_RAW_NM" "$CORE_DEMANGLED_NM" "$CORE_STRINGS"; do
        if grep -Fq -- "$denied" "$surface"; then
            fail "closed DEBUG surface '$denied' present in ElysiumCore.o"
        fi
    done
done < "$DENYLIST"

SENTINEL='ElysiumStorage.ElysiumStorageCoordinator.open(databaseURL:'
REQUIRED_STORAGE_TYPES="$TMP_DIR/required-storage-types"
cat > "$REQUIRED_STORAGE_TYPES" <<'REQUIRED_STORAGE_TYPES'
ElysiumRPGLocalPreferenceStorageRow
ElysiumRPGLegacyQuickSlotMigrationStorageRow
ElysiumRPGLocalPreferenceMigrationReceipt
ElysiumRPGLocalPreferencesStorage
ElysiumLANClientAuthorityStorageKey
ElysiumLANClientCredentialStorageRow
ElysiumLANClientOwnerCheckpointStorageRow
ElysiumLANClientPendingDispositionStorageRow
ElysiumLANClientNotificationStorageRow
ElysiumLANClientAuthorityCheckpointCandidate
ElysiumLANClientAuthorityCheckpointReceipt
ElysiumClientAuthorityCheckpointV6Storage
ElysiumPlayerJSONRowDigest
ElysiumPlayerJSONExpectedRowState
ElysiumPlayerJSONCompareAndSwapResult
REQUIRED_STORAGE_TYPES
for artifact in "${ARTIFACTS[@]}"; do
    label="$(basename "$artifact")"
    raw_nm="$TMP_DIR/$label.nm"
    demangled_nm="$TMP_DIR/$label.demangled"
    raw_strings="$TMP_DIR/$label.strings"
    undefined_nm="$TMP_DIR/$label.undefined"
    "$XCRUN" nm -a "$artifact" > "$raw_nm" \
        || fail "nm failed for $artifact"
    "$SWIFT_DEMANGLE" < "$raw_nm" > "$demangled_nm" \
        || fail "swift-demangle failed for $artifact"
    "$XCRUN" strings -a "$artifact" > "$raw_strings" \
        || fail "strings failed for $artifact"
    "$XCRUN" nm -u "$artifact" > "$undefined_nm" \
        || fail "undefined-symbol scan failed for $artifact"

    grep -Fq "$SENTINEL" "$demangled_nm" \
        || fail "production storage sentinel missing from $artifact"
    grep -Fq 'ElysiumStorage.ElysiumLegacyCoreStorage.compareAndSwapPlayerJSON' "$demangled_nm" \
        || fail "checked player CAS method missing from $artifact"
    while IFS= read -r required; do
        grep -Fq "ElysiumStorage.$required" "$demangled_nm" \
            || fail "reviewed storage type '$required' missing from $artifact"
    done < "$REQUIRED_STORAGE_TYPES"
    while IFS= read -r denied; do
        for surface in "$raw_nm" "$demangled_nm" "$raw_strings"; do
            if grep -Fq -- "$denied" "$surface"; then
                fail "closed DEBUG surface '$denied' present in $artifact"
            fi
        done
    done < "$DENYLIST"
    if grep -E 'sqlite3_(blob|backup)_' "$undefined_nm" >/dev/null; then
        fail "forbidden SQLite streaming surface present in $artifact"
    fi
    close_v2_count="$(awk '$NF == "_sqlite3_close_v2"{n++} END{print n+0}' \
        "$undefined_nm")"
    [ "$close_v2_count" -eq 1 ] \
        || fail "expected exactly one undefined _sqlite3_close_v2 in $artifact"
    if awk '$NF != "_sqlite3_close_v2" && index($NF,"sqlite3_close_v2"){bad=1} END{exit bad ? 0 : 1}' \
        "$undefined_nm"; then
        fail "adjacent sqlite3_close_v2 symbol present in $artifact"
    fi
done

if grep -E 'sqlite3_(blob|backup)_' "$STORAGE_SOURCE" >/dev/null; then
    fail "forbidden SQLite streaming call present in storage source"
fi
source_close_v2_count="$(awk 'index($0,"sqlite3_close_v2"){n++} END{print n+0}' "$STORAGE_SOURCE")"
[ "$source_close_v2_count" -eq 1 ] \
    || fail "storage source must contain exactly one close_v2 spelling"
exact_cleanup_count="$(grep -Fxc '                let closeRC = sqlite3_close_v2(localHandle)' \
    "$STORAGE_SOURCE" || true)"
[ "$exact_cleanup_count" -eq 1 ] \
    || fail "the sole close_v2 call is not the approved pre-publication cleanup"

printf 'Elysium storage release surface verified.\n'
