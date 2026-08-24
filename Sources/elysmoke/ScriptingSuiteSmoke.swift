// ScriptingSuiteSmoke.swift — script-runtime (change 1c). design.md §16 row
// 1c's exit criterion: "the appendix scripts run headlessly" — this file
// runs Appendix A's four scripts (plus 1b's module-mode variant) verbatim
// against a bare `World` + a minimal `ObjectGraphHost` double (never a full
// persisted `GameCore` — the same "never through a full GameCore/World
// tick" discipline `EventBusSmoke.swift` documents for itself; the
// `GameCore`-level integration lives in XCTest's
// `Tests/ElysiumCoreTests/ScriptRuntimeTests.swift`), then hashes a trace of
// what happened and compares against `goldens/scripting-goldens.json`
// (`ELYSIUM_REGOLD=1` regenerates it, exactly like `EventBusSmoke.swift`).
//
// Determinism: every scenario uses a fresh `World`/`ScriptRuntime`, fixed
// coordinates/seeds, and a fixed AI stub responder — no wall clock, no
// process-order dependence.

import ElysiumCore
import Foundation

// MARK: - minimal ObjectGraphHost double (mirrors Tests/ElysiumCoreTests
// /ObjectGraphTests.swift's `FakeObjectGraphHost`, duplicated here because
// elysmoke cannot `@testable import` or reach `Tests/`)

final class ElysmokeScriptHost: ObjectGraphHost {
    var currentDimension: Dim = .overworld
    var worldsByDim: [Dim: World] = [:]
    var localPlayer: Player?
    var isLANClient = false
    var currentTick: Int64 = 0
    var scriptsEnabled = true
    var worldRecords: [String: ObjectRecord] = [:]

    func world(for dim: Dim) -> World? { worldsByDim[dim] }
    func worldObjectRecord(for ref: ObjectRef) -> ObjectRecord { worldRecords[ref.canonical] ?? ObjectRecord() }
    func setWorldObjectRecord(_ record: ObjectRecord, for ref: ObjectRef) {
        if record.isEmpty { worldRecords.removeValue(forKey: ref.canonical) } else { worldRecords[ref.canonical] = record }
    }
    func setDifficulty(_ d: Int) {}
    func setGameRule(_ name: String, _ value: Double) { worldsByDim[currentDimension]?.gameRules[name] = value }
}

private func elysmokeMakeWorld(seed: UInt32 = 7) -> World {
    let w = World(dim: .overworld, seed: seed, generationSettings: WorldGenerationSettings())
    let chunk = Chunk(cx: 0, cz: 0, minY: w.info.minY, height: w.info.height)
    chunk.status = .generated
    w.setChunk(chunk)
    return w
}

private func elysmokeMakeHost(_ w: World) -> ElysmokeScriptHost {
    let host = ElysmokeScriptHost()
    host.worldsByDim[.overworld] = w
    return host
}

/// Reference-type box (used for `say()` capture) — `elysmokeAppendixTwo`
/// needs to read what a script said *after* the phase steps run, and a
/// closure cannot safely capture an `inout`/`&` pointer across calls (the
/// implicit pointer Swift forms for `&x` at a call site is only valid for
/// that one call).
final class ElysmokeBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

private func elysmokeMakeRuntime(
    _ host: ElysmokeScriptHost, said: ElysmokeBox<[String]>? = nil,
    aiResponder: @escaping (String) -> String? = { _ in nil }
) -> (ScriptRuntime, GameScriptingState) {
    let state = GameScriptingState()
    let runtime = try! ScriptRuntime(
        host: host, state: state,
        say: { line in said?.value.append(line) }, aiResponder: aiResponder
    )
    state.eventBus.delivery = { [weak runtime] event, targets in runtime?.deliver(event, targets) }
    return (runtime, state)
}

/// Replicates `GameCore+Scripting.runEventBusPhase()`'s step order without a
/// `GameCore` — loads, AI inbox, resumptions (incl. durable timers),
/// deliveries, RNG persistence. The observable-built-in diff step is 1b's
/// own concern (`EventBusSmoke.swift` already covers it) and is not needed
/// by anything in this corpus.
private func elysmokeStepScriptPhase(_ runtime: ScriptRuntime, _ state: GameScriptingState, host: ElysmokeScriptHost, tick: Int64) {
    host.currentTick = tick
    // This corpus attaches scripts directly through `ScriptStore` (never
    // through a command/UI path that would flip the flag itself, per
    // `ScriptingCommandContext.markScriptAttached`'s own doc comment) — force
    // it so every scenario's bounded scan actually runs; the zero-cost fast
    // path itself is exercised separately (nothing in this file measures it).
    state.anyScriptsAttached = true
    runtime.resetPerTickCounters()
    runtime.runLoads()
    runtime.runAIInbox()
    runtime.runResumptions()
    state.eventBus.runDeliveryPhase(tick: tick)
    runtime.persistRNGState()
}

private func fnv(_ s: String, _ h0: UInt32 = 2_166_136_261) -> UInt32 {
    var h = h0
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return h
}

// MARK: - Appendix A #1 — handler-mode attach: the beacon lamp

private func elysmokeAppendixOneHandler() -> (ok: Bool, trace: String) {
    let w = elysmokeMakeWorld()
    let host = elysmokeMakeHost(w)
    let player = Player(world: w)
    player.setPos(0.5, 65, 0.5)
    w.addEntity(player)
    host.localPlayer = player
    _ = w.setBlock(2, 65, 2, Int(cell(bidOpt("sea_lantern")!, 0)), SET_SILENT)
    let lamp = ObjectRef.block(dim: .overworld, x: 2, y: 65, z: 2)
    let (runtime, state) = elysmokeMakeRuntime(host)

    let source = """
    local low = ev.new / ev.subject.maxHealth < 0.3
    self:setBlock(low and "glowstone" or "sea_lantern")
    self.attrs.lastHealth = ev.new
    """
    let store = ScriptStore(graph: ObjectGraph(host: host))
    guard case .success = store.attach(
        lamp, name: "pulse", source: source, mode: .handler,
        triggers: [Trigger(event: .attributeChanged, attribute: "health", target: .object(.player))],
        by: .player, tick: 0
    ) else { return (false, "attach failed") }

    elysmokeStepScriptPhase(runtime, state, host: host, tick: 1) // load
    // Drop the player's health to trigger the trigger.
    let attrStore = AttributeStore(graph: ObjectGraph(host: host), onChange: { ref, name, old, new, rev, author in
        let source: EventSource = { if case .script(let o, let n) = author { return .script(owner: o, name: n) }; return .player }()
        state.eventBus.raise(kind: .attributeChanged, subject: ref, payload: ["key": .string(name), "old": old ?? .null, "new": new ?? .null], source: source, tick: host.currentTick)
    })
    player.health = 6 // 6/20 = 0.3, not < 0.3; use 5 to be safely under 30%
    player.health = 5
    state.eventBus.raise(kind: .attributeChanged, subject: .player, payload: ["key": .string("health"), "old": .number(20), "new": .number(5)], source: .player, tick: 1)
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 2)
    _ = attrStore

    let cellAfter = Int(w.getBlock(2, 65, 2))
    let idAfter = cellAfter >> 4
    let nameAfter = (idAfter >= 0 && idAfter < blockDefs.count) ? blockDefs[idAfter].name : "?"
    let lastHealth = store.get(lamp, "pulse")?.lastError ?? ""
    // `self.attrs.lastHealth` is normalized to "lasthealth" (§6.1's
    // AI-normalization leniency, extended to every script author — see
    // `ScriptRuntimeAPI.normalizedCustomAttributeName`) since "lastHealth"
    // itself does not fit the `[a-z][a-z0-9_]{0,31}` custom-name grammar.
    let attr = AttributeStore(graph: ObjectGraph(host: host)).get(lamp, "lasthealth")
    let ok = nameAfter == "glowstone" && attr == .number(5)
    return (ok, "block=\(nameAfter) attr=\(String(describing: attr)) err=\(lastHealth)")
}

// MARK: - Appendix A #1b — module-mode subscribe: the same lamp

private func elysmokeAppendixOneModule() -> (ok: Bool, trace: String) {
    let w = elysmokeMakeWorld()
    let host = elysmokeMakeHost(w)
    let player = Player(world: w)
    player.setPos(0.5, 65, 0.5)
    w.addEntity(player)
    host.localPlayer = player
    _ = w.setBlock(3, 65, 3, Int(cell(bidOpt("sea_lantern")!, 0)), SET_SILENT)
    let lamp = ObjectRef.block(dim: .overworld, x: 3, y: 65, z: 3)
    let (runtime, state) = elysmokeMakeRuntime(host)

    let source = """
    subscribe(player, "attribute.changed", {attr = "health"}, function(ev)
      self:setBlock(ev.new / player.maxHealth < 0.3 and "glowstone" or "sea_lantern")
    end)
    """
    let store = ScriptStore(graph: ObjectGraph(host: host))
    guard case .success = store.attach(lamp, name: "brain", source: source, mode: .module, triggers: [], by: .player, tick: 0)
    else { return (false, "attach failed") }

    elysmokeStepScriptPhase(runtime, state, host: host, tick: 1) // load registers the subscribe closure
    state.eventBus.raise(kind: .attributeChanged, subject: .player, payload: ["key": .string("health"), "old": .number(20), "new": .number(4)], source: .player, tick: 1)
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 2)

    let cellAfter = Int(w.getBlock(3, 65, 3))
    let idAfter = cellAfter >> 4
    let nameAfter = (idAfter >= 0 && idAfter < blockDefs.count) ? blockDefs[idAfter].name : "?"
    return (nameAfter == "glowstone", "block=\(nameAfter)")
}

// MARK: - Appendix A #2 — the AI gatekeeper (ai.await)

private func elysmokeAppendixTwo(reply: String) -> (ok: Bool, trace: String) {
    let w = elysmokeMakeWorld()
    let host = elysmokeMakeHost(w)
    let player = Player(world: w)
    player.setPos(0.5, 65, 0.5)
    player.health = 14
    w.addEntity(player)
    host.localPlayer = player
    _ = w.setBlock(4, 65, 4, Int(cell(bidOpt("oak_trapdoor")!, 0)), SET_SILENT)
    let door = ObjectRef.block(dim: .overworld, x: 4, y: 65, z: 4)
    let gate = Entity(world: w)
    gate.setPos(5, 65, 5)
    w.addEntity(gate)
    let gateRef = ObjectRef.entity(uid: gate.id)
    let said = ElysmokeBox<[String]>([])
    let (runtime, state) = elysmokeMakeRuntime(host, said: said, aiResponder: { _ in reply })

    let source = """
    on("entity.interacted", function(ev)
      if ev.by.kind ~= "player" then return end
      local text, err = ai.await(("A player with %d health asks to pass. Answer YES or NO."):format(math.floor(ev.by.health)), {maxChars = 8})
      if not err and text:upper():find("YES", 1, true) then
        objects.get(self.attrs.doorRef):set("open", true)
        say("Pass, friend.")
      else
        say("Not today.")
      end
    end)
    """
    let store = ScriptStore(graph: ObjectGraph(host: host))
    let attrStore = AttributeStore(graph: ObjectGraph(host: host))
    // "doorref" (not "doorRef" — camelCase does not fit the custom-name
    // grammar; the Lua side's `self.attrs.doorRef` read normalizes to this
    // same lowercase key, same as the write here does going through the
    // player/`/attr define` path in real play).
    let doorDefine = attrStore.define(gateRef, "doorref", .string(door.canonical), readonly: false, by: .player)
    guard case .success = doorDefine else { return (false, "doorref define failed: \(doorDefine)") }
    guard case .success = store.attach(gateRef, name: "gate", source: source, mode: .module, triggers: [], by: .player, tick: 0)
    else { return (false, "attach failed") }

    elysmokeStepScriptPhase(runtime, state, host: host, tick: 1) // load registers the on() closure
    state.eventBus.raise(
        kind: .entityInteracted, subject: gateRef, payload: ["by": .ref(ObjectRef.player.canonical)],
        source: .player, tick: 1
    )
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 2) // delivers entity.interacted -> ai.await yields
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 3) // AI inbox resolves the await

    let doorOpen = attrStore.get(door, "open")
    guard case .live(let live) = ObjectGraph(host: host).resolve(door) else { return (false, "door not live") }
    let builtin = BuiltInAttributes.get(live, name: "open", host: host)
    var openValue: AttrValue = .null
    if case .value(let v) = builtin { openValue = v }
    let wantOpen = reply.uppercased().contains("YES")
    let ok = (openValue == .bool(true)) == wantOpen && !said.value.isEmpty
    return (ok, "open=\(openValue) said=\(said.value) doorOpenAttr=\(String(describing: doorOpen))")
}

// MARK: - Appendix A #3 — world-wide log counting (subscribe on kind)

private func elysmokeAppendixThree() -> (ok: Bool, trace: String) {
    let w = elysmokeMakeWorld()
    let host = elysmokeMakeHost(w)
    let (runtime, state) = elysmokeMakeRuntime(host)

    let source = """
    subscribe({kind = "block"}, "block.broken", {}, function(ev)
      if ev.oldName:find("_log", 1, true) then
        world.attrs.logsBroken = (world.attrs.logsBroken or 0) + 1
        if world.attrs.logsBroken % 64 == 0 then emit("lumber.milestone", {count = world.attrs.logsBroken}) end
      end
    end)
    """
    let store = ScriptStore(graph: ObjectGraph(host: host))
    guard case .success = store.attach(.world, name: "lumber", source: source, mode: .module, triggers: [], by: .player, tick: 0)
    else { return (false, "attach failed") }
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 1)

    // Count deliveries directly rather than through `recentEvents()`'s
    // capped ring (130 `block.broken` + 130 cascaded `attribute.changed`
    // writes to `world.attrs.logsbroken` alone exceed the ring's 128-entry
    // cap well before the run ends — the ring is a bounded diagnostic feed,
    // not an event log; wrapping the same `delivery` seam
    // `ScriptRuntime.deliver` is already plugged into is the honest way to
    // observe "did this fire" across a run this long).
    let milestones = ElysmokeBox<Int>(0)
    let inner = state.eventBus.delivery
    state.eventBus.delivery = { event, targets in
        if event.kind.rawValue == "lumber.milestone" { milestones.value += 1 }
        inner?(event, targets)
    }

    for i in 0..<130 {
        let tick = Int64(2 + i)
        state.eventBus.raise(
            kind: .blockBroken, subject: .block(dim: .overworld, x: i, y: 65, z: 0),
            payload: ["oldName": .string("oak_log"), "newName": .string("air")], source: .player, tick: tick
        )
        elysmokeStepScriptPhase(runtime, state, host: host, tick: tick)
    }
    // "logsbroken" — the same camelCase normalization as `doorref` above.
    let count = AttributeStore(graph: ObjectGraph(host: host)).get(.world, "logsbroken")
    let ok = count == .int(130) && milestones.value == 2 // milestones at 64 and 128
    return (ok, "count=\(String(describing: count)) milestones=\(milestones.value)")
}

// MARK: - Appendix A #4 — scripts attaching scripts

private func elysmokeAppendixFour() -> (ok: Bool, trace: String) {
    let w = elysmokeMakeWorld()
    let host = elysmokeMakeHost(w)
    let player = Player(world: w)
    player.setPos(0.5, 65, 0.5)
    w.addEntity(player)
    host.localPlayer = player
    let signID = bidOpt("oak_sign") ?? bidOpt("oak_wall_sign")!
    _ = w.setBlock(1, 65, 1, Int(cell(signID, 0)), SET_SILENT)
    _ = w.setBlock(2, 65, 1, Int(cell(signID, 0)), SET_SILENT)
    let (runtime, state) = elysmokeMakeRuntime(host)

    let source = """
    for _, b in ipairs(objects.find{kind = "block", type = "\(blockDefs[Int(signID)].name)", near = self, radius = 8, limit = 8}) do
      if not b.attrs.greeter then
        b:define("owner", self.ref, {readonly = true})
        b:attach("greeter", [[ say("Hello, " .. ev.by.name) ]], {on = "block.used"})
      end
    end
    """
    let store = ScriptStore(graph: ObjectGraph(host: host))
    guard case .success = store.attach(.player, name: "equip", source: source, mode: .module, triggers: [], by: .player, tick: 0)
    else { return (false, "attach failed") }
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 1)
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 2) // scripts attached during load become pending; second load picks them up

    let sign1 = ObjectRef.block(dim: .overworld, x: 1, y: 65, z: 1)
    let sign2 = ObjectRef.block(dim: .overworld, x: 2, y: 65, z: 1)
    let greeter1 = store.get(sign1, "greeter")
    let greeter2 = store.get(sign2, "greeter")
    let owner1 = AttributeStore(graph: ObjectGraph(host: host)).get(sign1, "owner")
    var provenanceOK = false
    if case .some(let g1) = greeter1, case .script(let ownerRef, let ownerName) = g1.author {
        provenanceOK = ownerRef == .player && ownerName == "equip"
    }
    // `self.ref` (§8.5) is documented as the plain canonical-ref *string*,
    // not a handle — `b:define("owner", self.ref, ...)` therefore stores a
    // `.string`, not a `.ref`.
    let ok = greeter1 != nil && greeter2 != nil && owner1 == .string(ObjectRef.player.canonical) && provenanceOK
    return (ok, "greeter1=\(greeter1 != nil) greeter2=\(greeter2 != nil) owner=\(String(describing: owner1)) provenance=\(provenanceOK)")
}

// MARK: - kill switch / trust gate / fault isolation

private func elysmokeKillSwitchSuppresses() -> Bool {
    let w = elysmokeMakeWorld()
    let host = elysmokeMakeHost(w)
    w.gameRules["doScripts"] = 0
    let (runtime, state) = elysmokeMakeRuntime(host)
    let store = ScriptStore(graph: ObjectGraph(host: host))
    _ = store.attach(.world, name: "noop", source: "world.attrs.ran = true", mode: .module, triggers: [], by: .player, tick: 0)
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 1)
    return AttributeStore(graph: ObjectGraph(host: host)).get(.world, "ran") == nil
}

private func elysmokeTrustGateSuppresses() -> Bool {
    let w = elysmokeMakeWorld()
    let host = elysmokeMakeHost(w)
    host.scriptsEnabled = false
    let (runtime, state) = elysmokeMakeRuntime(host)
    let store = ScriptStore(graph: ObjectGraph(host: host))
    _ = store.attach(.world, name: "noop", source: "world.attrs.ran = true", mode: .module, triggers: [], by: .player, tick: 0)
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 1)
    return AttributeStore(graph: ObjectGraph(host: host)).get(.world, "ran") == nil
}

private func elysmokeFaultIsolation() -> Bool {
    let w = elysmokeMakeWorld()
    let host = elysmokeMakeHost(w)
    let (runtime, state) = elysmokeMakeRuntime(host)
    let store = ScriptStore(graph: ObjectGraph(host: host))
    _ = store.attach(.world, name: "bad", source: "error(\"boom\")", mode: .module, triggers: [], by: .player, tick: 0)
    _ = store.attach(.world, name: "good", source: "world.attrs.ran = true", mode: .module, triggers: [], by: .player, tick: 0)
    elysmokeStepScriptPhase(runtime, state, host: host, tick: 1)
    let badFaulted = store.get(.world, "bad")?.lastError != nil
    let goodRan = AttributeStore(graph: ObjectGraph(host: host)).get(.world, "ran") == .bool(true)
    return badFaulted && goodRan
}

// MARK: - suite entry point

struct ScriptingCorpusResult: Equatable {
    var traceHash: UInt32
}

private func loadScriptingGolden() -> UInt32? {
    guard let g = loadJSON("scripting-goldens.json") else { return nil }
    return (g["traceHash"] as? NSNumber)?.uint32Value
}

private func writeScriptingGolden(_ hash: UInt32) {
    let obj: [String: Any] = ["traceHash": NSNumber(value: hash)]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted]) else { return }
    try? data.write(to: URL(fileURLWithPath: "goldens/scripting-goldens.json"))
}

func runScriptingSuiteSmoke() {
    section("scripting (Appendix A, vs scripting-goldens.json)")

    let one = elysmokeAppendixOneHandler()
    check("appendix A #1 (handler-mode attach): lamp reflects low health", one.ok, one.trace)

    let oneB = elysmokeAppendixOneModule()
    check("appendix A #1b (module-mode subscribe): same lamp behavior", oneB.ok, oneB.trace)

    let twoYes = elysmokeAppendixTwo(reply: "YES, let them through")
    check("appendix A #2 (ai.await): YES opens the door and says a line", twoYes.ok, twoYes.trace)
    let twoNo = elysmokeAppendixTwo(reply: "NO")
    check("appendix A #2 (ai.await): NO keeps the door shut", twoNo.ok, twoNo.trace)

    let three = elysmokeAppendixThree()
    check("appendix A #3 (subscribe on kind): counts logs, milestones at 64/128", three.ok, three.trace)

    let four = elysmokeAppendixFour()
    check("appendix A #4 (scripts attaching scripts): both signs equipped, provenance recorded", four.ok, four.trace)

    check("kill switch (doScripts=0) suppresses script execution", elysmokeKillSwitchSuppresses())
    check("trust gate (scriptsEnabled=false) suppresses script execution", elysmokeTrustGateSuppresses())
    check("fault isolation: a faulting script never blocks its sibling", elysmokeFaultIsolation())

    var trace = ""
    trace += "1:\(one.ok)|1b:\(oneB.ok)|2y:\(twoYes.ok)|2n:\(twoNo.ok)|3:\(three.ok)|4:\(four.ok)"
    trace += "|kill:\(elysmokeKillSwitchSuppresses())|trust:\(elysmokeTrustGateSuppresses())|fault:\(elysmokeFaultIsolation())"
    let hash = fnv(trace)

    if ProcessInfo.processInfo.environment["ELYSIUM_REGOLD"] != nil {
        writeScriptingGolden(hash)
        check("scripting: goldens regenerated (native baseline)", true)
        return
    }
    guard let wantHash = loadScriptingGolden() else {
        check("scripting-goldens.json loadable", false, "not found — run from the repo root (goldens/)")
        return
    }
    check("scripting corpus trace hash matches goldens (two-process determinism)", hash == wantHash, "got \(hash) want \(wantHash)")
}
