// EventBusSmoke.swift — event-bus (change 1b). A fixed corpus run entirely
// through the public `EventBus` API (never through a full `GameCore`/`World`
// tick — the funnel wiring itself is XCTest's job,
// `Tests/ElysiumCoreTests/EventBusFunnelTests.swift`), hashed with this
// package's existing FNV-1a convention and compared against
// `goldens/event-bus-goldens.json`. `main.swift` calls `runEventBusSmoke()`
// right after the script-runtime section; this file owns everything else,
// reusing `check`/`section`/`loadJSON`/`goldenPaths` from `main.swift`.
//
// Determinism: every corpus below uses fixed refs/kinds/payloads and a fresh
// `EventBus` per check — no wall clock, no process-order dependence. Checks
// 2-4 deliberately do NOT sort before hashing (delivery order — ascending
// seq / ascending subscription id — IS the property under test); every
// other trace that touches a `Dictionary` (none do here — `EventBus` itself
// never iterates one on a delivery path) would need to sort first, but
// nothing in this corpus does.

import ElysiumCore
import Foundation

// MARK: - corpus result

struct EventBusCorpusResult: Equatable {
    var deliveryOrderHash: UInt32
    var coalescingHash: UInt32
    var queueFullDropCount: Int
    var queueFullOverBudgetCount: Int
    var cascadeDepthAllowedCount: Int
    var handlerBudgetAllowedCount: Int
    var subscriptionRoundTripHash: UInt32
    var zeroSubscriptionPendingCountAfterFunnel: Int
}

// MARK: - small local helpers (this file's own — main.swift's/
// ScriptRuntimeSmoke.swift's are not reachable here)

private func fnvHashString(_ s: String) -> UInt32 {
    var h: UInt32 = 2_166_136_261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return h
}

private func eventTrace(_ e: ScriptEvent) -> String {
    "\(e.seq)|\(e.kind.rawValue)|\(e.subject.canonical)"
}

// MARK: - golden I/O

private struct EventBusGolden {
    let deliveryOrderHash: UInt32
    let coalescingHash: UInt32
    let queueFullDropCount: Int
    let queueFullOverBudgetCount: Int
    let cascadeDepthAllowedCount: Int
    let handlerBudgetAllowedCount: Int
    let subscriptionRoundTripHash: UInt32
}

private func loadEventBusGolden() -> EventBusGolden? {
    guard let g = loadJSON("event-bus-goldens.json") else { return nil }
    guard
        let deliveryOrderHash = (g["deliveryOrderHash"] as? NSNumber)?.uint32Value,
        let coalescingHash = (g["coalescingHash"] as? NSNumber)?.uint32Value,
        let queueFullDropCount = (g["queueFullDropCount"] as? NSNumber)?.intValue,
        let queueFullOverBudgetCount = (g["queueFullOverBudgetCount"] as? NSNumber)?.intValue,
        let cascadeDepthAllowedCount = (g["cascadeDepthAllowedCount"] as? NSNumber)?.intValue,
        let handlerBudgetAllowedCount = (g["handlerBudgetAllowedCount"] as? NSNumber)?.intValue,
        let subscriptionRoundTripHash = (g["subscriptionRoundTripHash"] as? NSNumber)?.uint32Value
    else { return nil }
    return EventBusGolden(
        deliveryOrderHash: deliveryOrderHash, coalescingHash: coalescingHash,
        queueFullDropCount: queueFullDropCount, queueFullOverBudgetCount: queueFullOverBudgetCount,
        cascadeDepthAllowedCount: cascadeDepthAllowedCount, handlerBudgetAllowedCount: handlerBudgetAllowedCount,
        subscriptionRoundTripHash: subscriptionRoundTripHash
    )
}

private func writeEventBusGolden(_ r: EventBusCorpusResult) {
    let obj: [String: Any] = [
        "deliveryOrderHash": NSNumber(value: r.deliveryOrderHash),
        "coalescingHash": NSNumber(value: r.coalescingHash),
        "queueFullDropCount": NSNumber(value: r.queueFullDropCount),
        "queueFullOverBudgetCount": NSNumber(value: r.queueFullOverBudgetCount),
        "cascadeDepthAllowedCount": NSNumber(value: r.cascadeDepthAllowedCount),
        "handlerBudgetAllowedCount": NSNumber(value: r.handlerBudgetAllowedCount),
        "subscriptionRoundTripHash": NSNumber(value: r.subscriptionRoundTripHash),
    ]
    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
        print("    FAILED to encode event-bus-goldens.json")
        return
    }
    let path = goldenPaths("event-bus-goldens.json")[0]
    do {
        try out.write(to: URL(fileURLWithPath: path))
        print("    REGENERATED \(path)")
    } catch {
        print("    FAILED to write \(path): \(error)")
    }
}

// MARK: - the corpus itself

/// Runs the whole fixed corpus once and returns every value the checks need.
/// Called twice by `runEventBusSmoke()` for the intra-process determinism
/// check (§14's "run twice" discipline, mirrored inside one process too —
/// `pipeline.sh` covers the cross-process half by running all of elysmoke
/// twice and diffing).
func runEventBusCorpus() -> EventBusCorpusResult {
    // ---- Check 1: delivery order (§7.4) — ascending seq across kinds/subjects, then ascending subscription id ----
    let orderBus = EventBus()
    _ = orderBus.subscribe(
        subscriber: .player, scriptName: "s", handler: "h_late", target: .any, event: .entitySpawned,
        attribute: nil, createdBy: .player, tick: 0
    )
    _ = orderBus.subscribe(
        subscriber: .entity(uid: 1), scriptName: "s", handler: "h_early", target: .any, event: .entitySpawned,
        attribute: nil, createdBy: .player, tick: 0
    )
    var orderTrace: [String] = []
    orderBus.delivery = { event, targets in
        orderTrace.append(eventTrace(event) + "#" + targets.map { String($0.id) }.joined(separator: ","))
    }
    for i in 0..<12 {
        orderBus.raise(kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: Int64(i))
    }
    orderBus.raise(kind: .playerJoined, subject: .player, source: .player, tick: 12)
    orderBus.raise(kind: .explosion, subject: .dimension(.overworld), source: .engine, tick: 13)
    orderBus.runDeliveryPhase(tick: 13)
    let deliveryOrderHash = fnvHashString(orderTrace.joined(separator: "\n"))

    // ---- Check 2: coalescing (§7.6) — first old, last new, last seq ----
    let coalesceBus = EventBus()
    for step in 0..<10 {
        coalesceBus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("mood"), "old": .int(Int64(step)), "new": .int(Int64(step + 1))],
            source: .engine, tick: 0
        )
        coalesceBus.raise(
            kind: .blockChanged, subject: .block(dim: .overworld, x: 0, y: 0, z: 0),
            payload: [
                "oldName": .string("s\(step)"), "newName": .string("s\(step + 1)"),
                "oldMeta": .int(Int64(step)), "newMeta": .int(Int64(step + 1)),
            ], source: .engine, tick: 0
        )
    }
    var coalesceTrace: [String] = []
    coalesceBus.delivery = { event, _ in
        let sortedPayload = event.payload.keys.sorted().map { "\($0)=\(AttrValueCodec.encode(event.payload[$0]!))" }
        coalesceTrace.append(event.kind.rawValue + "|" + sortedPayload.joined(separator: ","))
    }
    coalesceBus.runDeliveryPhase(tick: 0)
    let coalescingHash = fnvHashString(coalesceTrace.sorted().joined(separator: "\n"))

    // ---- Check 3: queue-full cap trips deterministically, exactly one script.overBudget ----
    var queueCaps = EventBus.Caps.defaults
    queueCaps.maxQueueSize = 16
    let queueBus = EventBus(caps: queueCaps)
    var queueFullDropCount = 0
    for i in 0..<40 {
        let outcome = queueBus.raise(kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: 0)
        if outcome == .droppedQueueFull { queueFullDropCount += 1 }
    }
    var queueFullOverBudgetCount = 0
    queueBus.delivery = { event, _ in if event.kind == .scriptOverBudget { queueFullOverBudgetCount += 1 } }
    queueBus.runDeliveryPhase(tick: 0)

    // ---- Check 4: cascade depth caps at exactly 8 (§7.6) ----
    let cascadeBus = EventBus()
    var cascadeDepthAllowedCount = 0
    var causedBy: ScriptEvent?
    for i in 0..<12 {
        let outcome = cascadeBus.raise(
            kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: 0, causedBy: causedBy
        )
        if case .enqueued = outcome {
            cascadeDepthAllowedCount += 1
            causedBy = ScriptEvent(
                seq: 0, tick: 0, kind: .entitySpawned, subject: .entity(uid: i), payload: [:],
                source: .engine, cascadeDepth: (causedBy?.cascadeDepth ?? -1) + 1
            )
        }
    }

    // ---- Check 5: per-handler event budget caps at exactly 256 (§7.6) ----
    let handlerBus = EventBus()
    var handlerBudgetAllowedCount = 0
    handlerBus.withHandlerContext {
        for i in 0..<300 {
            let outcome = handlerBus.raise(kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: 0)
            if case .enqueued = outcome { handlerBudgetAllowedCount += 1 }
        }
    }

    // ---- Check 6: persisted-subscription round trip through the codec ----
    let subsBus = EventBus()
    _ = subsBus.subscribe(
        subscriber: .player, scriptName: "guard", handler: "on_hit", target: .object(.entity(uid: 42)),
        event: .entityDamaged, attribute: nil, createdBy: .player, tick: 3
    )
    _ = subsBus.subscribe(
        subscriber: .entity(uid: 42), scriptName: "farm", handler: "on_grow",
        target: .kind(.block, typeFilter: "wheat"), event: .blockChanged, attribute: nil,
        createdBy: .ai(model: "eval_model"), tick: 4
    )
    let subsText = subsBus.encodePersistedSubscriptions()
    let subsBus2 = EventBus()
    subsBus2.loadPersistedSubscriptions(from: subsText, storageCaps: .defaults)
    let roundTripTrace = subsBus2.listSubscriptions()
        .map { "\($0.id)|\($0.subscriber.canonical)|\($0.scriptName).\($0.handler)|\($0.target.displayText)|\($0.event.rawValue)" }
        .joined(separator: "\n")
    let subscriptionRoundTripHash = fnvHashString(roundTripTrace)

    // ---- Check 7: a zero-subscription block-changed funnel call is a no-op ----
    let zeroBus = EventBus()
    zeroBus.recordBlockChange(
        dim: .overworld, x: 0, y: 0, z: 0,
        oldCell: Int(cell(B.stone)), newCell: Int(cell(B.dirt)),
        hasObjectRecord: false, tick: 0
    )

    return EventBusCorpusResult(
        deliveryOrderHash: deliveryOrderHash, coalescingHash: coalescingHash,
        queueFullDropCount: queueFullDropCount, queueFullOverBudgetCount: queueFullOverBudgetCount,
        cascadeDepthAllowedCount: cascadeDepthAllowedCount, handlerBudgetAllowedCount: handlerBudgetAllowedCount,
        subscriptionRoundTripHash: subscriptionRoundTripHash,
        zeroSubscriptionPendingCountAfterFunnel: zeroBus.pendingCount
    )
}

// MARK: - section entry point (called from main.swift right after the script-runtime section)

private let eventBusCheckNames = [
    "corpus hash: delivery order (seq order, ascending subscription id)",
    "corpus hash: coalescing (attribute.changed + block.changed)",
    "queue-full cap trips deterministically",
    "queue-full trips exactly one script.overBudget",
    "cascade depth caps at exactly 8",
    "per-handler event budget caps at exactly 256",
    "persisted-subscription round trip through the codec",
    "the pre-filtered block-changed funnel is a no-op with no interest",
    "second run reproduces identical hashes",
]

func runEventBusSmoke() {
    section("event bus (vs event-bus-goldens.json)")

    let result1 = runEventBusCorpus()
    let result2 = runEventBusCorpus()

    if ProcessInfo.processInfo.environment["ELYSIUM_REGOLD"] != nil {
        writeEventBusGolden(result1)
        check("event bus: goldens regenerated (native baseline)", true)
        return
    }

    guard let g = loadEventBusGolden() else {
        for name in eventBusCheckNames {
            check(name, false, "not found — run from the repo root (goldens/)")
        }
        return
    }

    check("corpus hash: delivery order (seq order, ascending subscription id)", result1.deliveryOrderHash == g.deliveryOrderHash)
    check("corpus hash: coalescing (attribute.changed + block.changed)", result1.coalescingHash == g.coalescingHash)
    check(
        "queue-full cap trips deterministically",
        result1.queueFullDropCount == g.queueFullDropCount,
        "got \(result1.queueFullDropCount) want \(g.queueFullDropCount)"
    )
    check(
        "queue-full trips exactly one script.overBudget",
        result1.queueFullOverBudgetCount == g.queueFullOverBudgetCount,
        "got \(result1.queueFullOverBudgetCount) want \(g.queueFullOverBudgetCount)"
    )
    check(
        "cascade depth caps at exactly 8",
        result1.cascadeDepthAllowedCount == g.cascadeDepthAllowedCount,
        "got \(result1.cascadeDepthAllowedCount) want \(g.cascadeDepthAllowedCount)"
    )
    check(
        "per-handler event budget caps at exactly 256",
        result1.handlerBudgetAllowedCount == g.handlerBudgetAllowedCount,
        "got \(result1.handlerBudgetAllowedCount) want \(g.handlerBudgetAllowedCount)"
    )
    check("persisted-subscription round trip through the codec", result1.subscriptionRoundTripHash == g.subscriptionRoundTripHash)
    check("the pre-filtered block-changed funnel is a no-op with no interest", result1.zeroSubscriptionPendingCountAfterFunnel == 0)
    check("second run reproduces identical hashes", result1 == result2)
}
