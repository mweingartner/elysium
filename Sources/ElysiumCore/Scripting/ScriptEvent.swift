// ScriptEvent.swift — event-bus (change 1b). design.md §7.1. One typed, ordered
// record raised by the engine, a player command, or (in 1c) a script/the AI.
// `seq` is assigned at enqueue (monotonic per world session — never persisted,
// never compared across sessions); delivery order is `seq` order (§7.4).

import Foundation

/// Who raised an event (design.md §7.1's `EventSource`). `.script`/`.ai` are
/// reserved for 1c/phase 2 — nothing in this change ever constructs one, but
/// the shape is fixed now so those funnels don't need a payload/schema change
/// later.
public enum EventSource: Hashable, Sendable {
    case engine
    case player
    /// Reserved for 1c: a script raised this (`emit()`/verb side effect).
    case script(owner: ObjectRef, name: String)
    /// Reserved for phase 2: the AI raised this via a tool call.
    case ai(model: String)
    /// Reserved for phase 3/4: a LAN guest raised this.
    case lan(peerID: String)
}

/// One typed, ordered event (design.md §7.1). Immutable once constructed —
/// `EventBus` is the only thing that assigns `seq`/`cascadeDepth`.
public struct ScriptEvent: Sendable {
    /// Monotonic per world session, assigned at enqueue. The sort key for
    /// delivery order (§7.4) and the display/`recent` id.
    public let seq: UInt64
    /// `rpgSimulationTick` at enqueue — the one clock the Lua API exposes.
    public let tick: Int64
    public let kind: EventKind
    public let subject: ObjectRef
    public let payload: [String: AttrValue]
    public let source: EventSource
    /// 0 for a top-level (funnel/command/AI) event; `parent.cascadeDepth + 1`
    /// for an event raised while delivering another (§7.6's cascade depth).
    /// Not part of the design's own `ScriptEvent` struct — `EventBus`'s own
    /// bookkeeping for the depth-8 cap, kept on the event so the cap survives
    /// a raise that outlives the delivery call that caused it.
    public let cascadeDepth: Int
    /// The subject's "family" name at raise time — a block's registry name,
    /// an entity's `type` string, or `nil` for kinds with no type concept
    /// (world/dimension/player). Not part of the design's own `ScriptEvent`
    /// struct either; carried so `EventBus` can match a `.kind(.block,
    /// typeFilter)`/`.kind(.entity, typeFilter)` subscription without going
    /// back to live game state (which may already be gone — e.g.
    /// `entity.removed`).
    public let subjectType: String?

    public init(
        seq: UInt64, tick: Int64, kind: EventKind, subject: ObjectRef,
        payload: [String: AttrValue], source: EventSource, cascadeDepth: Int = 0,
        subjectType: String? = nil
    ) {
        self.seq = seq
        self.tick = tick
        self.kind = kind
        self.subject = subject
        self.payload = payload
        self.source = source
        self.cascadeDepth = cascadeDepth
        self.subjectType = subjectType
    }
}
