// ScriptRuntime.swift — script-runtime (change 1c). design.md §8.2/§7.5. Owns
// the one `LuaState` per open world session, the lifecycle of every attached
// script (pending -> live -> unload), the coroutine scheduler (resumptions,
// preemption, `wait`, `ai.await`), the named-durable-timer registry, and the
// event dispatcher plugged into `EventBus.delivery` (1b's seam). The Lua API
// v1 host-binding tree and handle metamethod bodies live in
// `ScriptRuntimeAPI.swift` — this file is lifecycle/scheduling only.
//
// Invariant (design.md §15): no work proportional to the loaded world when no
// script definition changed. The host carries exact changed refs in a bounded,
// deterministic queue; an empty phase performs only constant-time checks.

import ElysiumScript
import Foundation

/// design.md §12: the kill switch is a `doScripts` gamerule (default
/// enabled; absent == enabled, matching every other implicit-default
/// gamerule read in this package) layered on top of the persisted trust gate
/// (`WorldRecord.scriptsEnabled`, already enforced by `ObjectGraphHost
/// .scriptsEnabled` since change 1a). Attached scripts and ordinary one-off
/// runs never execute when either gate is off. Editor Check is read-only and
/// independent of both gates; its explicit Run Once may bypass only persisted
/// trust and still honors `doScripts`.
public func scriptsEffectivelyEnabled(host: ObjectGraphHost) -> Bool {
    guard host.scriptsEnabled else { return false }
    guard let w = host.world(for: host.currentDimension) else { return false }
    return (w.gameRules["doScripts"] ?? 1) != 0
}

/// `ScriptRuntime.runEphemeral`'s result (a plain enum rather than `Result`
/// — the failure case is a display string, which does not conform to
/// `Error`, and wrapping it just to satisfy `Result` would add nothing).
public enum ScriptRunOutcome {
    case success(String)
    case failure(String)
}

/// Detailed advisory result for editor Check and AI attach preflight. A suspension is valid for an
/// attached script, but explicitly means only the prefix through its first wait was exercised.
public enum ScriptDryRunOutcome: Equatable {
    case completed
    case suspended(String)
    /// The source compiled, but execution was intentionally skipped because a custom event has no
    /// authoritative payload descriptor from which Check can build a representative `ev` value.
    case compiledOnly(String)
    case failure(String)
}

/// scripting-ui-and-replication (change 3): an `ElysiumCore`-native mirror of
/// `ElysiumScript.ScriptValidation` (see `ScriptRuntime.validateSourceForEditor`'s own comment
/// on why a mirror, not a re-export). `stage` is 0-3, `line` is 1-based (0 when the stage has
/// no single-line locus) — exactly `ScriptValidation.refused`'s own documented shape.
/// scripting-ui-and-replication (change 3), design.md §12: "F3 summary". `faultsThisTick`/
/// `eventsPendingThisTick` are read fresh from `EventBus` by the HUD (they are that type's own
/// state, not duplicated here) — this struct carries only what `ScriptRuntime` itself owns.
public struct ScriptRuntimeSummary: Equatable {
    public let liveScripts: Int
    public let suspendedCoroutines: Int
    public let durableTimers: Int
    public let instructionsUsedThisTick: Int
    public let instructionBudgetRemaining: Int
    public let instructionBucketCapacity: Int
}

public struct ScriptValidationResult: Equatable {
    public enum Outcome: Equatable {
        case accepted
        case refused(stage: Int, message: String, hint: String, line: Int)
    }

    public let outcome: Outcome

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

/// The opaque payload carried by a `ScriptOwnedSubscription.token` (event-bus,
/// change 1b reserved the field; this change is the only thing that ever
/// constructs one).
final class ScriptHandlerToken {
    enum Body {
        /// Handler mode: the trigger's own chunk is the handler — resume the
        /// named script instance directly with `ev`.
        case handlerChunk(ref: ObjectRef, name: String)
        /// Module mode: a closure a script passed to `on`/`subscribe` at load.
        case closure(ScriptFunction, owner: ObjectRef, scriptName: String)
    }
    let body: Body
    init(_ body: Body) { self.body = body }
}

public final class ScriptRuntime {
    /// Which world-level execution gates a one-shot run must honor. Keeping this as a named
    /// policy (rather than a Boolean bypass flag) makes the exceptional editor path explicit at
    /// every call site and leaves room for the policies to diverge safely if another gate is
    /// added later.
    private enum EphemeralRunPolicy {
        /// Commands, AI, and LAN-originated requests require both persisted world trust and the
        /// live `doScripts` kill switch.
        case fullyGated
        /// A host user's explicit editor Run Once action may evaluate only the draft they can already
        /// see. It does not trust the world or load any attached script; the kill switch remains
        /// authoritative.
        case editorExplicitRun
    }

    let lua: LuaState
    let host: ObjectGraphHost
    let state: GameScriptingState
    let sayFn: (String) -> Void
    /// Test/production seam for `ai.ask`/`ai.await` (design.md §9.6: "tests
    /// inject a stub broker"; the real Ollama pump is change 2). `nil`
    /// (production default until change 2) means every request times out.
    var aiResponder: (String) -> String?

    // Implicitly-unwrapped: Swift auto-initializes an Optional-shaped stored
    // property to `nil` without needing an `init` assignment, which is what
    // lets `self` become usable (to build `[weak self]` dispatch closures)
    // *before* these two are actually registered a few lines into `init` —
    // `registerHandleKind` needs the closures, and the closures need `self`
    // fully constructed, so this breaks that ordering cycle. Both are always
    // non-nil by the time any script runs (set at the end of `init`, never
    // reassigned after).
    private(set) var objectHandleKind: HandleKind!
    private(set) var attrsHandleKind: HandleKind!

    /// The script currently executing, for provenance (`AttributeStore
    /// .set(by:)`, `ScriptStore.attach(by:)`) and verb-budget accounting.
    /// Set/restored around every `resume`/`call` into a script's code —
    /// never stacked (scripts never synchronously re-enter the runtime from
    /// inside another script's call, §7.6's cascades are queued, not
    /// nested).
    private(set) var currentScript: (owner: ObjectRef, name: String)?

    struct Instance {
        var ref: ObjectRef
        var name: String
        var mode: ScriptMode
        /// The persisted, behavior-defining shape compiled into this environment. `ScriptRecord`
        /// equality deliberately ignores runtime error/RNG bookkeeping, so comparing this value
        /// detects source, mode, trigger, enablement, provenance, and API edits without treating a
        /// deterministic RNG-state writeback as a source edit.
        var definition: ScriptRecord
        /// Timer ids that existed before this load began. A fault rolls back timers created by the
        /// partial module body while preserving restored overdue timers from an earlier session.
        var timerIDsAtLoadStart: Set<UInt64>
        var environment: ScriptEnvironment
        /// Handler-mode chunks compile once when the instance loads. The immutable Lua function
        /// can seed any number of independent coroutines, including overlapping yielded
        /// invocations, and its registry ref is reclaimed with this environment on unload.
        var handlerFunction: ScriptFunction?
        var live: Bool = false
        /// The SAME reference-type adapter handed to `makeEnvironment` —
        /// `math.random`/`randomseed` mutate it in place inside
        /// `LuaState`'s own (inaccessible-to-us) bookkeeping, so this is the
        /// only way this runtime can read the *current* stream state back
        /// out for persistence (`storeRNGWords`, called after every phase).
        var randomAdapter: RandomStreamBoxAdapter
    }
    var instances: [String: Instance] = [:]
    /// One lifecycle-scoped controller per furnace. This is deliberately runtime state rather
    /// than `BlockEntityData`: disabling, editing, detaching, faulting, unloading, or shutting
    /// down the owning script must stop future conversion without leaving a hidden persisted rule.
    struct FurnaceOutputOverride: Equatable {
        let itemName: String
        let scriptName: String
    }
    private var furnaceOutputOverrides: [String: FurnaceOutputOverride] = [:]
    /// A compile/load failure is retried only after the persisted definition changes. This keeps a
    /// bad module from faulting every tick and, more importantly, prevents a partially executed
    /// load from repeatedly accumulating subscriptions or timers.
    private var failedDefinitions: [String: ScriptRecord] = [:]

    struct ScheduledRun {
        var key: String
        var coroutine: ScriptCoroutine
        var wakeTick: Int64
        var ordinal: UInt64
        /// Set while suspended on `.await(token)`; `nil` for `.wait`/
        /// `.preempted` (those are woken by tick alone).
        var awaitToken: UInt64?
        var isLoad: Bool
        /// The event whose handler created this coroutine. Retained across yields so later
        /// resumptions preserve cascade depth instead of becoming new depth-zero roots.
        var causedBy: ScriptEvent?
        /// Cumulative events emitted by this logical handler invocation. Yielding must not reset
        /// the per-handler budget and thereby allow an unbounded slow-motion flood.
        var handlerEventCount: Int
    }
    var scheduled: [ScheduledRun] = []
    private var scheduledCountByScript: [String: Int] = [:]
    private var nextOrdinal: UInt64 = 0
    static let maxScriptLoadsPerTick = 64
    /// CLua's pinned count-hook quantum (`ELYSIUM_HOOK_GRANULARITY`). The exposed cumulative
    /// counter advances only at these boundaries, so a resume that returns before its first hook
    /// is conservatively charged one quantum instead of appearing free.
    static let instructionAccountingQuantum = 1_000

    /// Deterministic global instruction token bucket. It starts with one tick's allowance, refills
    /// once per simulation tick, and never exceeds `perTickBucket`. Every attached-script resume
    /// charges its exact cumulative-instruction delta; editor Run/Check and unload are separate,
    /// explicitly synchronous operations and retain their own fixed slice.
    private var instructionTokens = 0
    private var instructionBudgetTick: Int64?
    private var instructionsUsedThisTick = 0
    /// Earlier scheduler lanes reserve one accounting quantum for each downstream lane. This
    /// prevents a large load backlog from starving AI replies, resumptions, timers, or event
    /// delivery while preserving the documented deterministic phase order.
    private var downstreamInstructionReserve = 0

    var timers: [DurableTimer] = []
    private var nextTimerId: UInt64 = 1

    /// `"<ownerRef>#<scriptName>#<handlerName>"` -> the function a module's
    /// load body registered with `register(name, fn)` (this change's
    /// adaptation for named-handler resolution — see ARCHITECTURE.md).
    /// Re-populated every load; never persisted (functions cannot survive a
    /// restart).
    var namedHandlers: [String: ScriptFunction] = [:]

    enum AIRequestMode {
        /// Fire-and-forget requests publish the documented world-scoped `ai.replied` event.
        case ask
        /// Awaited replies resume only their still-current coroutine and never fall back to an
        /// unrelated fire-and-forget event if that coroutine is later edited or detached.
        case await
    }
    struct AIOutboxEntry { var id: UInt64; var prompt: String }
    private var aiOutbox: [AIOutboxEntry] = []
    private var aiRequestModes: [UInt64: AIRequestMode] = [:]
    private var nextAIRequestID: UInt64 = 1
    /// design.md §8.4: "<= 30 per world per minute" — approximated here as
    /// per-1200-ticks (20 Hz * 60 s), reset opportunistically.
    private var aiRequestsThisWindow = 0
    private var aiWindowStartTick: Int64 = 0
    /// design.md §8.4: "<= 2 in flight per world" — a local constant
    /// (not `ScriptBudgets`, matching this file's own `aiRequestsThisWindow`/
    /// `aiWindowStartTick` precedent for AI-specific numbers change 1c
    /// already kept out of that struct). This is also this subsystem's
    /// "per-tick pump budget": the broker handoff (`outboxHandoff`) only
    /// ever sees requests that already passed this gate, so it can never be
    /// asked to fire more than `aiMaxInFlightPerWorld` concurrent network
    /// requests for one world session.
    static let aiMaxInFlightPerWorld = 2
    private(set) var aiInFlightCount = 0

    /// ai-object-graph (change 2), design.md §9.6: the async production
    /// broker seam. `nil` (default, and every 1c test) means "no broker
    /// attached" — `runAIInbox()` falls back to the synchronous `aiResponder`
    /// stub seam unchanged, so every 1c test keeps passing untouched. When
    /// set (production only, wired by the app layer's per-frame pump), each
    /// newly enqueued `(requestID, prompt)` is handed off here instead of
    /// being answered synchronously; the real reply arrives later via
    /// `submitAIReply`, off the game loop's own call stack, and is drained
    /// into `ai.replied` events / `ai.await` resumptions at the next script
    /// phase — the tick never blocks on the model.
    public var outboxHandoff: ((UInt64, String) -> Void)?
    /// Optional app-layer cancellation endpoint paired with `outboxHandoff`. Core owns the
    /// coroutine/request lifecycle but not the network transport, so detach/edit/unload asks the broker to
    /// cancel the exact session-qualified network task before releasing the in-flight slot.
    public var aiCancellationHandoff: ((UInt64) -> Void)?
    private var incomingAIReplies: [(id: UInt64, text: String?, error: String?)] = []

    /// ai-object-graph (change 2), design.md §9.4 stage 6: set for the
    /// duration of `dryRun` only. Every mutating verb dispatch
    /// (`ScriptRuntimeAPI.swift`) checks this first and turns itself into a
    /// harmless no-op while it is `true` — the "read-only facade" the design
    /// calls for, implemented as a flag rather than a second execution path
    /// so dry-run and real execution can never drift apart on anything but
    /// the flag itself.
    var dryRunActive = false
    /// True only while `/script run` / editor Run Once / AI `run_script` executes its one-shot
    /// chunk. Durable script-lifecycle APIs reject in this scope so the destroyed throwaway
    /// environment can never leave handlers, timers, child scripts, or AI work behind.
    var ephemeralRunActive = false
    /// True only during a module's synchronous unload callback. Unload is a finalization
    /// boundary: scripts may read state and write custom attributes, but every other
    /// lifecycle, world, presentation, timer, event, RNG, and AI capability is refused.
    var unloadActive = false
    /// Throwaway RNG owned by Run/Check. Attached scripts instead use their persisted Instance RNG.
    var transientExecutionRandom: RandomStreamBoxAdapter?

    let budgets: ScriptBudgets

    /// §8.4: "attach/detach <= 2 (world <= 32)". Both counters are charged before a
    /// lifecycle mutation and reset together at the deterministic tick boundary.
    private var attachDetachBudgetTick: Int64?
    var attachDetachCounts: [String: Int] = [:]
    var attachDetachWorldCount = 0
    /// Declarations are a separate metadata operation from script attach/detach. A module can
    /// publish the full per-object contract (16 events) in one load without partially faulting,
    /// while repeated cross-object churn remains bounded per script and tick.
    private var eventDeclarationBudgetTick: Int64?
    var eventDeclarationCounts: [String: Int] = [:]
    /// Presentation effects are non-deterministic host output, but calls still need deterministic
    /// per-tick admission so a tiny script cannot create an unbounded number of audio players.
    private var soundBudgetTick: Int64?
    var soundCounts: [String: Int] = [:]
    var soundWorldCount = 0
    static let maxSoundsPerScriptPerTick = 8
    static let maxSoundsPerWorldPerTick = 64
    /// One phase reconciles only a fixed canonical prefix of the host's exact dirty-ref queue.
    /// Hydration/mutation bursts retain their suffix at the host; no periodic whole-world census is
    /// required. Loading has a separate fixed budget because one ref may own up to eight scripts.
    static let maxDefinitionRefsPerTick = 64
    private(set) var definitionReconciliationCount = 0
    /// Names seen on the last reconciliation of each ref let a removal retire old instances and
    /// failures without scanning the runtime's complete instance dictionaries.
    private var knownDefinitionNamesByRef: [String: Set<String>] = [:]
    /// Newly discovered definitions use their own canonical deduplicating heap. An edit replaces
    /// the value for an already-queued key; unrelated backlog is never discarded by a generation
    /// change, and stale heap entries consume only the fixed candidate budget below.
    private var pendingDefinitionLoads: [String: (ref: ObjectRef, record: ScriptRecord)] = [:]
    private var pendingDefinitionLoadOrder = DeterministicStringWorkQueue()
    /// Dimension bags are hydrated together but only the current one is live. Remember the
    /// dimension observed at runtime construction so a later portal transition requeues the old
    /// and new bags without scanning any chunk/entity collection.
    private var definitionDimension: Dim

    static let scriptAttachedEventKind = EventKind.scriptAttached

    public init(
        host: ObjectGraphHost, state: GameScriptingState, budgets: ScriptBudgets = .defaults,
        say: @escaping (String) -> Void, aiResponder: @escaping (String) -> String? = { _ in nil }
    ) throws {
        self.host = host
        self.state = state
        self.budgets = budgets
        self.sayFn = say
        self.aiResponder = aiResponder
        self.definitionDimension = host.currentDimension
        self.lua = try LuaState(budgets: budgets, math: ScriptHostMath.deterministic, log: ScriptRuntimeLogSink())
        // `self` is fully constructed from here (every other stored property
        // has a value); the dispatch closures built in `ScriptRuntimeAPI.swift`
        // capture it weakly.
        self.objectHandleKind = lua.registerHandleKind(name: "object", dispatch: Self.makeObjectDispatch(self), interned: true)
        self.attrsHandleKind = lua.registerHandleKind(name: "attrs", dispatch: Self.makeAttrsDispatch(self), interned: true)
    }

    // MARK: - handle helpers (shared with ScriptRuntimeAPI.swift)

    /// Registers `ref` as a live handle (idempotent) and returns the marshal-
    /// ready value. `id` is unused by every dispatch closure in this runtime
    /// (they all re-derive identity from `HandleRef.ref`), so a constant is
    /// always correct (design.md Decision 10's `id` is an optimization this
    /// runtime does not need).
    func handleValue(for ref: ObjectRef) -> ScriptValue {
        _ = try? lua.makeHandle(kind: objectHandleKind, ref: ref.canonical, id: 0)
        return .ref(ref.canonical)
    }

    func attrsHandleValue(for ref: ObjectRef) -> ScriptValue {
        let synthetic = "attrs:" + ref.canonical
        _ = try? lua.makeHandle(kind: attrsHandleKind, ref: synthetic, id: 0)
        return .ref(synthetic)
    }

    func ownerRef(fromAttrsRef s: String) -> ObjectRef? {
        guard s.hasPrefix("attrs:") else { return nil }
        return ObjectRef.parse(String(s.dropFirst(6)))
    }

    var graph: ObjectGraph { ObjectGraph(host: host) }
    var attributeStore: AttributeStore {
        AttributeStore(graph: graph, onChange: { [weak self] ref, name, old, new, revision, author in
            self?.raiseAttributeChanged(ref: ref, name: name, old: old, new: new, revision: revision, author: author)
        })
    }
    var scriptStore: ScriptStore { ScriptStore(graph: graph) }
    var customEventStore: CustomEventStore { CustomEventStore(graph: graph) }

    private func raiseAttributeChanged(
        ref: ObjectRef, name: String, old: AttrValue?, new: AttrValue?, revision: UInt64, author: Provenance.Author
    ) {
        let source: EventSource
        switch author {
        case .player: source = .player
        case .ai(let model): source = .ai(model: model)
        case .script(let owner, let scriptName): source = .script(owner: owner, name: scriptName)
        case .lan(let peer): source = .lan(peerID: peer)
        }
        let subjectType: String?
        if case .live(let live) = graph.resolve(ref) {
            subjectType = familyName(live)
        } else {
            subjectType = nil
        }
        state.eventBus.raise(
            kind: .attributeChanged, subject: ref,
            payload: ["key": .string(name), "old": old ?? .null, "new": new ?? .null],
            source: source, tick: host.currentTick, subjectType: subjectType
        )
    }

    // MARK: - per-tick verb budget reset

    public func resetPerTickCounters() {
        refreshInstructionBudget()
        refreshAttachDetachBudget()
        refreshEventDeclarationBudget()
        refreshSoundBudget()
    }

    /// Tick-key the lifecycle budget at the mutation boundary as well as the ordinary phase entry.
    /// This covers direct/test calls and the extra shutdown phase `exitToTitle` may run without
    /// advancing the simulation clock.
    func refreshAttachDetachBudget() {
        let tick = host.currentTick
        guard attachDetachBudgetTick != tick else { return }
        attachDetachBudgetTick = tick
        attachDetachCounts.removeAll()
        attachDetachWorldCount = 0
    }

    /// Declaration mutations are also a per-tick budget. Keep their clock independent from the
    /// lifecycle counters so either API remains safe when called directly outside phase entry.
    func refreshEventDeclarationBudget() {
        let tick = host.currentTick
        guard eventDeclarationBudgetTick != tick else { return }
        eventDeclarationBudgetTick = tick
        eventDeclarationCounts.removeAll()
    }

    func refreshSoundBudget() {
        let tick = host.currentTick
        guard soundBudgetTick != tick else { return }
        soundBudgetTick = tick
        soundCounts.removeAll()
        soundWorldCount = 0
    }

    // MARK: - scheduler helpers (shared with ScriptRuntimeAPI.swift)

    func scheduleOrdinal() -> UInt64 {
        defer { nextOrdinal += 1 }
        return nextOrdinal
    }

    func allocateTimerID() -> UInt64 {
        // The durable-timer cap bounds this search to at most 257 probes. Never rely on a
        // trapping increment: a hostile restore seam or an eventually exhausted counter wraps to
        // one and skips ids that are still live.
        let occupied = Set(timers.map(\.id))
        var candidate = nextTimerId == 0 || nextTimerId > maxScriptingRegistryIdentifier
            ? 1 : nextTimerId
        while occupied.contains(candidate) {
            candidate = scriptingRegistryIdentifierSuccessor(candidate)
        }
        nextTimerId = scriptingRegistryIdentifierSuccessor(candidate)
        return candidate
    }

    /// Script waits and durable timers share one overflow-safe tick arithmetic rule. Extremely
    /// large imported intervals become "at the end of time" rather than trapping the game loop.
    func scheduledTick(after positiveDelta: Int64) -> Int64 {
        let (value, overflow) = host.currentTick.addingReportingOverflow(positiveDelta)
        return overflow ? Int64.max : value
    }

    func restoreDurableTimers(_ restored: [DurableTimer]) {
        timers = restored.sorted { $0.id < $1.id }
        let maxID = timers.map(\.id).max() ?? 0
        nextTimerId = scriptingRegistryIdentifierSuccessor(maxID)
    }

    @discardableResult
    func appendScheduled(key: String, coroutine: ScriptCoroutine, wakeTick: Int64) -> Bool {
        let run = ScheduledRun(
            key: key, coroutine: coroutine, wakeTick: wakeTick, ordinal: scheduleOrdinal(),
            awaitToken: nil, isLoad: false, causedBy: nil, handlerEventCount: 0
        )
        if let refusal = appendSuspendedRun(run) {
            try? lua.close(coroutine)
            signalSchedulerOverBudget(refusal)
            return false
        }
        return true
    }

    /// Refill is tick-keyed so tests or callers that invoke more than one phase at the same
    /// simulation tick cannot mint extra work. A forward jump accrues idle capacity, capped by the
    /// bucket; a backward/reset clock starts a fresh one-tick allowance rather than overflowing.
    private func refreshInstructionBudget() {
        let tick = host.currentTick
        let refill = max(0, budgets.perTickInstructions)
        let capacity = max(0, budgets.perTickBucket)
        guard refill > 0, capacity > 0 else {
            instructionTokens = 0
            instructionsUsedThisTick = 0
            instructionBudgetTick = tick
            return
        }
        guard let previous = instructionBudgetTick else {
            instructionTokens = min(refill, capacity)
            instructionsUsedThisTick = 0
            instructionBudgetTick = tick
            return
        }
        guard tick != previous else { return }
        instructionsUsedThisTick = 0
        if tick < previous {
            instructionTokens = min(refill, capacity)
        } else {
            let elapsed = tick - previous
            let (rawMissing, missingOverflow) = capacity.subtractingReportingOverflow(instructionTokens)
            let missing = missingOverflow ? Int.max : max(0, rawMissing)
            let ticksToFill = missing / refill + (missing % refill == 0 ? 0 : 1)
            if ticksToFill != Int.max && elapsed >= Int64(ticksToFill) {
                instructionTokens = capacity
            } else {
                let elapsedInt = Int(elapsed)
                let (credit, creditOverflow) = elapsedInt.multipliedReportingOverflow(by: refill)
                if creditOverflow {
                    instructionTokens = capacity
                } else {
                    let (refilled, refillOverflow) = instructionTokens.addingReportingOverflow(credit)
                    instructionTokens = refillOverflow ? capacity : min(capacity, refilled)
                }
            }
        }
        instructionBudgetTick = tick
    }

    private var nextInstructionSlice: Int {
        refreshInstructionBudget()
        // Custom/test budgets smaller than five hook quanta cannot reserve one quantum for all
        // five lanes simultaneously. Clamp the reservation so the current lane can still make
        // progress; production defaults have ample capacity for the full reservation.
        let configuredCredit = min(max(0, budgets.perTickInstructions), max(0, budgets.perTickBucket))
        let maximumReserve = max(0, configuredCredit - Self.instructionAccountingQuantum)
        let effectiveReserve = min(maximumReserve, max(0, downstreamInstructionReserve))
        let (rawAvailable, overflow) = instructionTokens.subtractingReportingOverflow(effectiveReserve)
        let available = overflow ? 0 : max(0, rawAvailable)
        return min(max(0, budgets.handlerSliceInstructions), available)
    }

    private func chargeInstructions(_ coroutine: ScriptCoroutine, from before: UInt64) {
        let after = coroutine.instructionsUsed
        let delta = after >= before ? after - before : after
        let observed = delta > UInt64(Int.max) ? Int.max : Int(delta)
        let charged = max(Self.instructionAccountingQuantum, observed)
        // Keep overrun debt: with a sub-quantum remaining slice, CLua may execute through the
        // next 1,000-instruction hook. A signed balance makes later refills repay that debt.
        let (remaining, underflow) = instructionTokens.subtractingReportingOverflow(charged)
        instructionTokens = underflow ? Int.min : remaining
        let (total, overflow) = instructionsUsedThisTick.addingReportingOverflow(charged)
        instructionsUsedThisTick = overflow ? Int.max : total
    }

    private func baseScriptKey(for runKey: String) -> String? {
        guard let parsed = parseKey(runKey) else { return nil }
        return parsed.owner.canonical + "#" + parsed.name
    }

    /// Returns a refusal message, or `nil` after accepting the run. Closure timers surface a
    /// refusal as a catchable host-call error; a coroutine that has already yielded is terminally
    /// faulted because it cannot be safely resumed without retaining it.
    private func appendSuspendedRun(_ run: ScheduledRun) -> String? {
        guard let base = baseScriptKey(for: run.key) else { return "invalid suspended coroutine owner" }
        guard scheduled.count < max(0, budgets.maxSuspendedCoroutinesPerWorld) else {
            return "world suspended coroutine limit exceeded"
        }
        let count = scheduledCountByScript[base, default: 0]
        guard count < max(0, budgets.maxSuspendedCoroutinesPerScript) else {
            return "script suspended coroutine limit exceeded"
        }
        scheduled.append(run)
        scheduledCountByScript[base] = count + 1
        return nil
    }

    @discardableResult
    private func removeScheduledRun(key: String, ordinal: UInt64) -> ScheduledRun? {
        guard let index = scheduled.firstIndex(where: { $0.key == key && $0.ordinal == ordinal }) else {
            return nil
        }
        let run = scheduled.remove(at: index)
        decrementScheduledCount(for: run)
        return run
    }

    @discardableResult
    private func removeScheduledRuns(where shouldRemove: (ScheduledRun) -> Bool) -> [ScheduledRun] {
        var removed: [ScheduledRun] = []
        scheduled.removeAll { run in
            guard shouldRemove(run) else { return false }
            removed.append(run)
            return true
        }
        for run in removed { decrementScheduledCount(for: run) }
        return removed
    }

    private func decrementScheduledCount(for run: ScheduledRun) {
        guard let base = baseScriptKey(for: run.key), let count = scheduledCountByScript[base] else {
            return
        }
        if count <= 1 { scheduledCountByScript.removeValue(forKey: base) }
        else { scheduledCountByScript[base] = count - 1 }
    }

    private func signalSchedulerOverBudget(_ message: String) {
        state.eventBus.signalOverBudget(reason: message, tick: host.currentTick)
    }

    // MARK: - dispatcher (plugged into `EventBus.delivery` by `GameCore
    // +Scripting.swift`)

    /// EventBus asks before advancing its ordered recipient cursor. One-at-a-time admission lets
    /// the exact instruction charge of the preceding handler decide whether another may start;
    /// returning zero retains the untouched recipient and every suffix entry for the next tick.
    public func admittedDeliveryCount(
        for _: ScriptEvent, targets: [EventDeliveryTarget]
    ) -> Int {
        guard !targets.isEmpty else { return 0 }
        // A disabled/untrusted runtime intentionally drains and discards deliveries, preserving
        // the pre-backpressure kill-switch contract: events observed while scripts are off do not
        // replay later. `deliver` itself remains a no-op under the same gate.
        guard scriptsEffectivelyEnabled(host: host) else { return targets.count }
        guard nextInstructionSlice > 0 else { return 0 }
        return 1
    }

    public func deliver(_ event: ScriptEvent, _ targets: [EventDeliveryTarget]) {
        guard scriptsEffectivelyEnabled(host: host), !targets.isEmpty else { return }
        guard nextInstructionSlice > 0 else { return }
        // Materialization walks nested payloads and registers previously unseen refs. Do it once
        // per event, then share the immutable value across every recipient in this delivery slice.
        let marshaledEvent = eventValue(event)
        for target in targets {
            guard nextInstructionSlice > 0 else { break }
            switch target.kind {
            case .persisted(let sub):
                invokeNamed(
                    owner: sub.subscriber, scriptName: sub.scriptName, handlerName: sub.handler,
                    event: event, marshaledEvent: marshaledEvent
                )
            case .scriptOwned(let sub):
                guard let token = sub.token as? ScriptHandlerToken else { continue }
                switch token.body {
                case .handlerChunk(let ref, let name):
                    invokeHandlerChunk(ref: ref, name: name, event: event, marshaledEvent: marshaledEvent)
                case .closure(let fn, let owner, let scriptName):
                    invokeClosure(
                        fn, owner: owner, scriptName: scriptName,
                        event: event, marshaledEvent: marshaledEvent
                    )
                }
            }
        }
    }

    private func invokeNamed(
        owner: ObjectRef, scriptName: String, handlerName: String,
        event: ScriptEvent, marshaledEvent: ScriptValue
    ) {
        let key = owner.canonical + "#" + scriptName + "#" + handlerName
        guard let fn = namedHandlers[key] else { return } // pruned silently (§7.3: dormant, not fatal)
        invokeClosure(
            fn, owner: owner, scriptName: scriptName,
            event: event, marshaledEvent: marshaledEvent
        )
    }

    private func invokeHandlerChunk(
        ref: ObjectRef, name: String, event: ScriptEvent, marshaledEvent: ScriptValue
    ) {
        let key = ref.canonical + "#" + name
        guard let instance = instances[key], instance.live, instance.mode == .handler else { return }
        guard definitionIsCurrent(instance) else { return }
        guard case .live = graph.resolve(ref) else { return }
        guard let compiled = instance.handlerFunction else { return }
        runNew(
            key: key, function: compiled,
            args: [
                handleValue(for: ref), handleValue(for: .world), handleValue(for: .player),
                marshaledEvent,
            ],
            isLoad: false, causedBy: event
        )
    }

    private func invokeClosure(
        _ fn: ScriptFunction, owner: ObjectRef, scriptName: String,
        event: ScriptEvent, marshaledEvent: ScriptValue
    ) {
        let scriptKey = owner.canonical + "#" + scriptName
        guard let instance = instances[scriptKey], instance.live, definitionIsCurrent(instance) else { return }
        guard case .live = graph.resolve(owner) else { return }
        let key = owner.canonical + "#" + scriptName + "#closure#" + String(nextOrdinal)
        runNew(
            key: key, function: fn, args: [marshaledEvent], isLoad: false,
            contextOverride: (owner, scriptName), causedBy: event
        )
    }

    func eventValue(_ event: ScriptEvent) -> ScriptValue {
        var map: [String: ScriptValue] = [:]
        for key in event.payload.keys.sorted() {
            map[key] = materializeEventHandles(in: event.payload[key]!, depth: 1)
        }
        // Envelope fields are authoritative. A custom payload may use the same keys, but it must
        // never spoof the delivered event kind, tick, subject, or provenance seen by Lua.
        map["kind"] = .string(event.kind.rawValue)
        map["tick"] = .int(event.tick)
        map["subject"] = handleValue(for: event.subject)
        if case .script(let owner, _) = event.source { map["source"] = .string("script:" + owner.canonical) }
        else if case .player = event.source { map["source"] = .string("player") }
        else if case .ai = event.source { map["source"] = .string("ai") }
        else if case .lan = event.source { map["source"] = .string("lan") }
        else { map["source"] = .string("engine") }
        return .map(map)
    }

    /// `ScriptValue.ref` is intentionally just a canonical name until its owning `LuaState` has
    /// registered a handle kind for that name. Engine/LAN event producers can introduce refs that
    /// no prior script has touched (attackers, actors, nested custom payloads), so recursively
    /// materialize every valid object ref before the value marshaler pushes the event table.
    private func materializeEventHandles(in value: ScriptValue, depth: Int) -> ScriptValue {
        guard depth <= budgets.valueDepth else { return value }
        switch value {
        case .ref(let canonical):
            guard let ref = ObjectRef.parse(canonical) else { return value }
            return handleValue(for: ref)
        case .list(let values):
            return .list(values.map { materializeEventHandles(in: $0, depth: depth + 1) })
        case .map(let values):
            var result: [String: ScriptValue] = [:]
            for key in values.keys.sorted() {
                result[key] = materializeEventHandles(in: values[key]!, depth: depth + 1)
            }
            return .map(result)
        default:
            return value
        }
    }

    // MARK: - running a fresh coroutine (load, handler, timer, closure)

    private enum RunResult {
        case completed
        case yielded
        /// No global instruction token was available. Callers retain the authoritative source
        /// (persisted script, event cursor, timer, or scheduled run) and retry next tick.
        case deferred
        case faulted
    }

    @discardableResult
    private func runNew(
        key: String, function: ScriptFunction, args: [ScriptValue], isLoad: Bool,
        contextOverride: (owner: ObjectRef, name: String)? = nil,
        causedBy: ScriptEvent? = nil
    ) -> RunResult {
        guard nextInstructionSlice > 0 else { return .deferred }
        guard let coroutine = try? lua.makeCoroutine(function: function) else { return .faulted }
        return resumeAndSchedule(
            key: key, coroutine: coroutine, args: args, isLoad: isLoad,
            context: contextOverride, causedBy: causedBy
        )
    }

    private func resumeAndSchedule(
        key: String, coroutine: ScriptCoroutine, args: [ScriptValue], isLoad: Bool,
        context: (owner: ObjectRef, name: String)?, causedBy: ScriptEvent?,
        handlerEventCount initialHandlerEventCount: Int = 0
    ) -> RunResult {
        let slice = nextInstructionSlice
        guard slice > 0 else { return .deferred }
        let previous = currentScript
        currentScript = context ?? parseKey(key)
        defer { currentScript = previous }
        let outcome: ScriptResumeOutcome
        var handlerEventCount = initialHandlerEventCount
        let instructionsBefore = coroutine.instructionsUsed
        do {
            let resume = {
                try self.lua.resume(coroutine, args: args, slice: slice)
            }
            if isLoad {
                outcome = try resume()
            } else {
                outcome = try state.eventBus.withHandlerContext(
                    causedBy: causedBy, eventCount: &handlerEventCount, resume
                )
            }
        } catch {
            chargeInstructions(coroutine, from: instructionsBefore)
            recordRuntimeFault("script runtime could not resume")
            return .faulted
        }
        chargeInstructions(coroutine, from: instructionsBefore)
        switch outcome {
        case .completed:
            return .completed
        case .yielded(let reason):
            if case .preempted = reason,
               coroutine.consecutivePreemptions >= max(1, budgets.maxConsecutivePreemptions) {
                try? lua.close(coroutine)
                recordRuntimeFault("consecutive instruction-slice limit exceeded")
                signalSchedulerOverBudget("consecutive instruction-slice limit exceeded")
                return .faulted
            }
            let wakeTick: Int64
            var awaitToken: UInt64?
            switch reason {
            case .preempted: wakeTick = scheduledTick(after: 1)
            case .wait(let n): wakeTick = scheduledTick(after: Int64(max(0, n)))
            case .await(let token): wakeTick = host.currentTick; awaitToken = token
            }
            let run = ScheduledRun(
                key: key, coroutine: coroutine, wakeTick: wakeTick, ordinal: nextOrdinal, awaitToken: awaitToken,
                isLoad: isLoad, causedBy: causedBy, handlerEventCount: handlerEventCount
            )
            nextOrdinal += 1
            if let refusal = appendSuspendedRun(run) {
                if let awaitToken { cancelAIRequest(awaitToken) }
                try? lua.close(coroutine)
                recordRuntimeFault(refusal)
                signalSchedulerOverBudget(refusal)
                return .faulted
            }
            return .yielded
        case .faulted(let fault):
            recordRuntimeFault(fault.message)
            return .faulted
        }
    }

    private func recordRuntimeFault(_ message: String) {
        guard let ctx = currentScript else { return }
        // A callback/timer fault does not unload the otherwise-live module, so explicitly revoke
        // any lifecycle capability it registered. Load-time faults also flow through here and are
        // cleared again harmlessly when the failed instance is destroyed.
        _ = clearFurnaceOutputOverride(for: ctx.owner, scriptName: ctx.name)
        scriptStore.storeLastError(ctx.owner, ctx.name, message)
        state.eventBus.raise(
            kind: .scriptFaulted, subject: ctx.owner,
            payload: ["name": .string(ctx.name), "message": .string(message)],
            source: .engine, tick: host.currentTick,
            subjectType: eventSubjectType(for: ctx.owner)
        )
    }

    private func parseKey(_ key: String) -> (owner: ObjectRef, name: String)? {
        let parts = key.split(separator: "#", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let ref = ObjectRef.parse(String(parts[0])) else { return nil }
        return (ref, String(parts[1]))
    }

    // MARK: - phase steps (called from `GameCore+Scripting.runScriptPhase`)

    /// §7.5 step 1: compile+run every pending script (newly attached, or
    /// edited since it last went live). Sorted by ref then name for
    /// determinism.
    public func runLoads() {
        guard scriptsEffectivelyEnabled(host: host) else { return }
        let currentDimension = host.currentDimension
        if currentDimension != definitionDimension {
            host.scriptDefinitionsDidChange(
                for: .dimension(definitionDimension), hasScripts: false
            )
            let currentRef = ObjectRef.dimension(currentDimension)
            host.scriptDefinitionsDidChange(
                for: currentRef,
                hasScripts: host.worldObjectRecord(for: currentRef).hasScriptDefinitions
            )
            definitionDimension = currentDimension
        }
        let previousReserve = downstreamInstructionReserve
        downstreamInstructionReserve = 4 * Self.instructionAccountingQuantum
        defer { downstreamInstructionReserve = previousReserve }
        refreshInstructionBudget()
        let dirtyRefs = host.drainDirtyScriptDefinitionRefs(limit: Self.maxDefinitionRefsPerTick)
        for ref in dirtyRefs {
            reconcileDefinitionRef(ref)
            definitionReconciliationCount += 1
        }
        guard !pendingDefinitionLoadOrder.isEmpty else { return }

        var candidatesExamined = 0
        var loadsStarted = 0
        while candidatesExamined < Self.maxScriptLoadsPerTick,
              loadsStarted < Self.maxScriptLoadsPerTick,
              nextInstructionSlice > 0,
              let key = pendingDefinitionLoadOrder.popFirst() {
            candidatesExamined += 1
            guard let pending = pendingDefinitionLoads.removeValue(forKey: key) else { continue }
            let ref = pending.ref
            let record = pending.record
            // A module loaded earlier in this same phase may attach, edit, or detach a later
            // record. Never compile the stale discovery snapshot after that mutation.
            guard let current = scriptStore.get(ref, record.name), current.enabled, current == record else {
                continue
            }
            loadsStarted += 1
            load(ref: ref, record: record)
        }
    }

    private func reconcileDefinitionRef(_ ref: ObjectRef) {
        let refKey = ref.canonical
        let records = scriptStore.list(ref)
        let currentByName = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) })
        var names = knownDefinitionNamesByRef[refKey] ?? []
        names.formUnion(currentByName.keys)

        for name in names.sorted(by: utf8Less) {
            let key = refKey + "#" + name
            let current = currentByName[name]
            pendingDefinitionLoads.removeValue(forKey: key)

            if let instance = instances[key],
               current == nil || current?.enabled != true
                || current.map({ !sourceUnchanged(instance, $0) }) == true {
                unloadInstance(
                    key: key, runUnloadHandler: instance.live, removeDurableTimers: true,
                    dropSubscriptions: true
                )
            }

            if let failed = failedDefinitions[key],
               current == nil || current?.enabled != true || current != failed {
                timers.removeAll { $0.owner == ref && $0.scriptName == name }
                failedDefinitions.removeValue(forKey: key)
            }

            guard let current, current.enabled else { continue }
            if let instance = instances[key], sourceUnchanged(instance, current) { continue }
            if failedDefinitions[key] == current { continue }
            enqueuePendingDefinitionLoad(ref: ref, record: current)
        }

        if currentByName.isEmpty { knownDefinitionNamesByRef.removeValue(forKey: refKey) }
        else { knownDefinitionNamesByRef[refKey] = Set(currentByName.keys) }
    }

    private func enqueuePendingDefinitionLoad(ref: ObjectRef, record: ScriptRecord) {
        let key = ref.canonical + "#" + record.name
        pendingDefinitionLoads[key] = (ref: ref, record: record)
        pendingDefinitionLoadOrder.insert(key)
    }

    private func sourceUnchanged(_ instance: Instance, _ record: ScriptRecord) -> Bool {
        instance.definition == record
    }

    private func definitionIsCurrent(_ instance: Instance) -> Bool {
        guard let record = scriptStore.get(instance.ref, instance.name), record.enabled else { return false }
        return sourceUnchanged(instance, record)
    }

    /// O(1) simulation-hot-path lookup used by `WorldHooks.scriptedFurnaceOutput`. A definition
    /// edit/disable becomes ineffective immediately, even before the bounded reconciliation phase
    /// reaches it, and both execution gates are re-read rather than cached.
    func effectiveFurnaceOutput(for ref: ObjectRef) -> String? {
        guard scriptsEffectivelyEnabled(host: host),
              let override = furnaceOutputOverrides[ref.canonical]
        else { return nil }
        let key = ref.canonical + "#" + override.scriptName
        guard let instance = instances[key], instance.live, definitionIsCurrent(instance) else {
            return nil
        }
        return override.itemName
    }

    func registerFurnaceOutputOverride(
        _ itemName: String, for ref: ObjectRef, scriptName: String
    ) -> String? {
        if let existing = furnaceOutputOverrides[ref.canonical], existing.scriptName != scriptName {
            let existingKey = ref.canonical + "#" + existing.scriptName
            if let instance = instances[existingKey], definitionIsCurrent(instance) {
                return "furnace output is already controlled by attached script '\(existing.scriptName)'"
            }
        }
        furnaceOutputOverrides[ref.canonical] = FurnaceOutputOverride(
            itemName: itemName, scriptName: scriptName
        )
        return nil
    }

    func clearFurnaceOutputOverride(for ref: ObjectRef, scriptName: String) -> Bool {
        guard furnaceOutputOverrides[ref.canonical]?.scriptName == scriptName else { return false }
        furnaceOutputOverrides.removeValue(forKey: ref.canonical)
        return true
    }

    private func load(ref: ObjectRef, record: ScriptRecord) {
        let key = ref.canonical + "#" + record.name
        let seed = record.rngWords.map { RandomX(stateWords: ($0[0], $0[1], $0[2], $0[3])) }
            ?? RandomX(mix32(hashString(ref.canonical + "#" + record.name))
                ^ UInt32(truncatingIfNeeded: record.createdTick))
        let adapter = RandomStreamBoxAdapter(seed)
        let env = lua.makeEnvironment(name: key, hostBindings: buildHostBindings(), random: adapter)
        var instance = Instance(
            ref: ref, name: record.name, mode: record.mode, definition: record,
            timerIDsAtLoadStart: Set(timers.map(\.id)), environment: env,
            handlerFunction: nil, randomAdapter: adapter
        )
        instances[key] = instance
        let wrapped = record.mode == .module
            ? "local self, world, player = ...\n" + record.source
            : "local self, world, player, ev = ...\n" + record.source
        switch env.compile(source: wrapped, chunkName: record.name) {
        case .failure(let fault):
            scriptStore.storeLastError(ref, record.name, fault.message)
            state.eventBus.raise(
                kind: .scriptFaulted, subject: ref,
                payload: ["name": .string(record.name), "message": .string(fault.message)],
                source: .engine, tick: host.currentTick,
                subjectType: eventSubjectType(for: ref)
            )
            failLoad(key: key, definition: record)
            return
        case .success(let compiled):
            if record.mode == .handler {
                // §8.1: "handler-mode bodies run with ev bound" — only when
                // an actual matching event arrives. Unlike module mode, "load" for a
                // handler-mode script is compile-and-index only: this cached function proved the
                // source is valid and seeds a fresh coroutine for each later delivery;
                // running it now (against a synthetic empty `ev`) would only
                // ever fault on `ev.subject`/`ev.<payload field>` being nil.
                var registeredSubscriptionIDs: [UInt64] = []
                for trigger in record.triggers {
                    let token = ScriptHandlerToken(.handlerChunk(ref: ref, name: record.name))
                    switch state.eventBus.registerScriptOwnedChecked(
                        owner: ref, scriptName: record.name, target: trigger.target, event: trigger.event,
                        attribute: trigger.attribute, token: token
                    ) {
                    case .success(let subscription):
                        registeredSubscriptionIDs.append(subscription.id)
                    case .failure(let error):
                        for id in registeredSubscriptionIDs {
                            state.eventBus.unregisterScriptOwned(id: id)
                        }
                        let message = scriptOwnedSubscriptionErrorMessage(error, owner: ref)
                        scriptStore.storeLastError(ref, record.name, message)
                        state.eventBus.raise(
                            kind: .scriptFaulted, subject: ref,
                            payload: ["name": .string(record.name), "message": .string(message)],
                            source: .engine, tick: host.currentTick,
                            subjectType: eventSubjectType(for: ref)
                        )
                        failLoad(key: key, definition: record)
                        return
                    }
                }
                instance.handlerFunction = compiled
                instance.live = true
                instances[key] = instance
                failedDefinitions.removeValue(forKey: key)
                scriptStore.storeLastError(ref, record.name, nil)
                state.eventBus.raise(
                    kind: .load, subject: ref, payload: ["name": .string(record.name)],
                    source: .engine, tick: host.currentTick,
                    subjectType: eventSubjectType(for: ref)
                )
                return
            }
            let args: [ScriptValue] = [handleValue(for: ref), handleValue(for: .world), handleValue(for: .player)]
            let result = runNew(key: key, function: compiled, args: args, isLoad: true)
            instance = instances[key] ?? instance
            switch result {
            case .completed:
                guard definitionIsCurrent(instance) else {
                    unloadInstance(
                        key: key, runUnloadHandler: false, removeDurableTimers: true,
                        dropSubscriptions: true
                    )
                    return
                }
                instance.live = true
                instances[key] = instance
                failedDefinitions.removeValue(forKey: key)
                scriptStore.storeLastError(ref, record.name, nil)
                state.eventBus.raise(
                    kind: .load, subject: ref, payload: ["name": .string(record.name)],
                    source: .engine, tick: host.currentTick,
                    subjectType: eventSubjectType(for: ref)
                )
            case .yielded:
                break
            case .deferred:
                // The persisted definition remains pending and will compile afresh next tick.
                unloadInstance(
                    key: key, runUnloadHandler: false, removeDurableTimers: false,
                    dropSubscriptions: true
                )
                enqueuePendingDefinitionLoad(ref: ref, record: record)
            case .faulted:
                failLoad(key: key, definition: record)
            }
            // If not completed (yielded/faulted), the instance stays
            // non-live; a yielded load is already tracked in `scheduled`
            // and will be resumed in `runResumptions()`.
        }
    }

    /// §7.5 step 4: resumptions (preempted/`wait` wakeups, `.await` replies)
    /// in ascending `(wakeTick, ordinal)`, then durable timers due this tick
    /// in ascending `(wakeTick, timerId)`.
    public func runResumptions() {
        guard scriptsEffectivelyEnabled(host: host) else { return }
        let previousReserve = downstreamInstructionReserve
        downstreamInstructionReserve = 2 * Self.instructionAccountingQuantum
        defer { downstreamInstructionReserve = previousReserve }
        refreshInstructionBudget()
        let tick = host.currentTick
        let runnable = scheduled.filter { $0.awaitToken == nil && $0.wakeTick <= tick }
            .sorted { $0.wakeTick == $1.wakeTick ? $0.ordinal < $1.ordinal : $0.wakeTick < $1.wakeTick }
        for run in runnable {
            guard nextInstructionSlice > 0 else { break }
            _ = removeScheduledRun(key: run.key, ordinal: run.ordinal)
            guard scheduledRunIsCurrent(run) else {
                try? lua.close(run.coroutine)
                if run.isLoad, instances[run.key] != nil {
                    unloadInstance(
                        key: run.key, runUnloadHandler: false, removeDurableTimers: true,
                        dropSubscriptions: true
                    )
                    failedDefinitions.removeValue(forKey: run.key)
                }
                continue
            }
            let result = resumeScheduledRun(run, args: [])
            if case .deferred = result {
                _ = appendSuspendedRun(run)
                break
            }
            if run.isLoad { finishResumedLoad(key: run.key, result: result, tick: tick) }
        }
        downstreamInstructionReserve = Self.instructionAccountingQuantum
        runDueTimers(tick: tick)
    }

    private func runDueTimers(tick: Int64) {
        guard !timers.isEmpty else { return }
        let due = timers.filter { $0.wakeTick <= tick }.sorted { $0.wakeTick == $1.wakeTick ? $0.id < $1.id : $0.wakeTick < $1.wakeTick }
        for timer in due {
            let handlerKey = timer.owner.canonical + "#" + timer.scriptName + "#" + timer.handlerName
            let scriptKey = timer.owner.canonical + "#" + timer.scriptName
            guard case .live = graph.resolve(timer.owner) else {
                // Unloaded blocks/entities and disconnected LAN players may become live again;
                // their durable timers remain overdue without consuming CPU beyond this bounded
                // 256-entry scan.
                continue
            }
            guard let record = scriptStore.get(timer.owner, timer.scriptName), record.enabled else {
                timers.removeAll { $0.id == timer.id }
                continue
            }
            guard let instance = instances[scriptKey], instance.live, definitionIsCurrent(instance) else {
                // A present enabled script may still be loading or waiting for a retry after an
                // edit; keep its timer until the lifecycle reconciliation reaches a terminal
                // live/absent state.
                continue
            }
            guard let fn = namedHandlers[handlerKey] else {
                // A completed live module that did not register the persisted handler can never
                // satisfy this timer without an edit, and that edit will install a fresh timer.
                timers.removeAll { $0.id == timer.id }
                continue
            }
            guard nextInstructionSlice > 0 else { break }
            let key = timer.owner.canonical + "#" + timer.scriptName + "#timer#\(timer.id)#\(tick)"
            let timerEvent = ScriptEvent(
                seq: 0, tick: tick, kind: .timerFired, subject: timer.owner,
                payload: ["name": .string(timer.handlerName)], source: .engine
            )
            let result = runNew(
                key: key, function: fn, args: [eventValue(timerEvent)], isLoad: false,
                contextOverride: (timer.owner, timer.scriptName), causedBy: timerEvent
            )
            if case .deferred = result { break }
            state.eventBus.raise(
                kind: .timerFired, subject: timer.owner, payload: ["name": .string(timer.handlerName)],
                source: .engine, tick: tick,
                subjectType: eventSubjectType(for: timer.owner)
            )
            if let interval = timer.intervalTicks {
                if let idx = timers.firstIndex(where: { $0.id == timer.id }) {
                    let (next, overflow) = tick.addingReportingOverflow(interval)
                    timers[idx].wakeTick = overflow ? Int64.max : next
                }
            } else {
                timers.removeAll { $0.id == timer.id }
            }
        }
    }

    // MARK: - AI outbox/inbox (design.md §9.6, this change's stub-broker seam)

    /// design.md §8.4's two AI request budgets, checked together before a
    /// request is ever enqueued: the in-flight cap (never queued past it —
    /// refused immediately) and the per-world-per-minute window (reset
    /// opportunistically every ~1200 ticks).
    func aiBudgetAvailable() -> Bool {
        let tick = host.currentTick
        if tick - aiWindowStartTick >= 1_200 {
            aiWindowStartTick = tick
            aiRequestsThisWindow = 0
        }
        return aiInFlightCount < Self.aiMaxInFlightPerWorld && aiRequestsThisWindow < 30
    }

    func enqueueAIRequest(prompt: String, mode: AIRequestMode) -> UInt64 {
        let id = nextAIRequestID
        nextAIRequestID += 1
        aiOutbox.append(AIOutboxEntry(id: id, prompt: prompt))
        aiRequestModes[id] = mode
        aiInFlightCount += 1
        aiRequestsThisWindow += 1
        return id
    }

    /// §7.5 step 3 ("AI inbox"). Two modes, chosen by whether a production
    /// broker is attached (`outboxHandoff != nil`):
    ///   - **No broker** (default; every 1c test): drains the outbox
    ///     synchronously against the injected `aiResponder` stub, exactly as
    ///     1c shipped it — unchanged behavior, unchanged tests.
    ///   - **Broker attached** (production, change 2, §9.6): hands each
    ///     freshly enqueued `(id, prompt)` to the broker (which dispatches
    ///     an async, cancellable Ollama request off the tick's call stack)
    ///     instead of answering it here, then drains whatever real replies
    ///     `submitAIReply` has queued up since the last phase — in
    ///     `requestId` order, per §9.6's own wording.
    public func runAIInbox() {
        let previousReserve = downstreamInstructionReserve
        downstreamInstructionReserve = 3 * Self.instructionAccountingQuantum
        defer { downstreamInstructionReserve = previousReserve }
        refreshInstructionBudget()
        if let handoff = outboxHandoff {
            if !aiOutbox.isEmpty {
                let batch = aiOutbox
                aiOutbox.removeAll()
                for entry in batch where aiRequestModes[entry.id] != nil {
                    handoff(entry.id, entry.prompt)
                }
            }
        } else if !aiOutbox.isEmpty {
            let batch = aiOutbox
            aiOutbox.removeAll()
            for entry in batch where aiRequestModes[entry.id] != nil {
                let reply = aiResponder(entry.prompt)
                incomingAIReplies.append((
                    id: entry.id, text: reply, error: reply == nil ? "timeout" : nil
                ))
            }
        }

        guard !incomingAIReplies.isEmpty else { return }
        let replies = incomingAIReplies.sorted { $0.id < $1.id }
        incomingAIReplies.removeAll()
        for (index, reply) in replies.enumerated() {
            if !deliverAIReply(id: reply.id, text: reply.text, errorText: reply.error) {
                // Request-id order is part of the deterministic inbox contract. Retain the whole
                // suffix rather than letting a later fire-and-forget reply overtake this waiter.
                incomingAIReplies.append(contentsOf: replies[index...])
                break
            }
        }
    }

    /// Returns `true` only after the reply has been consumed. An awaited reply whose coroutine
    /// cannot receive an instruction slice remains completely transactional: the ordered inbox
    /// entry, request mode, in-flight slot, and suspended coroutine all survive until a later tick.
    private func deliverAIReply(id: UInt64, text: String?, errorText: String?) -> Bool {
        let boundedText = text.map(boundedScriptVisibleAIText)
        let boundedError = errorText.map(boundedScriptVisibleAIText)
        guard let mode = aiRequestModes[id] else {
            // The owning script/session canceled this request. A broker reply can still arrive,
            // but it no longer owns a coroutine or an event destination in this runtime.
            return true
        }
        switch mode {
        case .ask:
            aiRequestModes.removeValue(forKey: id)
            aiInFlightCount = max(0, aiInFlightCount - 1)
            state.eventBus.raise(
                kind: .aiReplied, subject: .world,
                payload: ["requestId": .int(Int64(id)), "text": boundedText.map { .string($0) } ?? .null,
                          "error": boundedError.map { .string($0) } ?? .null],
                source: .engine, tick: host.currentTick
            )
            return true
        case .await:
            let waiting = scheduled.filter { $0.awaitToken == id }.sorted { $0.ordinal < $1.ordinal }
            guard !waiting.isEmpty else {
                aiRequestModes.removeValue(forKey: id)
                aiInFlightCount = max(0, aiInFlightCount - 1)
                return true
            }
            guard nextInstructionSlice > 0 else { return false }
            for run in waiting {
                _ = removeScheduledRun(key: run.key, ordinal: run.ordinal)
                guard scheduledRunIsCurrent(run) else {
                    try? lua.close(run.coroutine)
                    if run.isLoad, instances[run.key] != nil {
                        unloadInstance(
                            key: run.key, runUnloadHandler: false, removeDurableTimers: true,
                            dropSubscriptions: true
                        )
                        failedDefinitions.removeValue(forKey: run.key)
                    }
                    continue
                }
                let args: [ScriptValue] = boundedText != nil
                    ? [.string(boundedText!), .null] : [.null, .string(boundedError ?? "timeout")]
                let result = resumeScheduledRun(run, args: args)
                if case .deferred = result {
                    // Defensive against a future scheduler policy changing between admission and
                    // resume. The caller retains this reply and every higher request-id suffix.
                    _ = appendSuspendedRun(run)
                    return false
                }
                if run.isLoad { finishResumedLoad(key: run.key, result: result, tick: host.currentTick) }
            }
            aiRequestModes.removeValue(forKey: id)
            aiInFlightCount = max(0, aiInFlightCount - 1)
            return true
        }
    }

    /// Lua's `ScriptValue` string ceiling is measured in UTF-8 bytes, not Swift `Character`s.
    /// Clamp every reply at Core's final script-visible boundary as well as at the app broker so
    /// injected/test responders and future transports cannot fault `ai.await` argument pushes or
    /// `ai.replied` event delivery with an otherwise successful response.
    private func boundedScriptVisibleAIText(_ value: String) -> String {
        let limit = max(0, budgets.valueStringBytes)
        guard value.utf8.count > limit else { return value }
        var result = ""
        result.reserveCapacity(min(limit, value.utf8.count))
        var byteCount = 0
        for character in value {
            let characterText = String(character)
            let characterBytes = characterText.utf8.count
            guard characterBytes <= limit - byteCount else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private func cancelAIRequest(_ id: UInt64) {
        guard aiRequestModes.removeValue(forKey: id) != nil else { return }
        aiCancellationHandoff?(id)
        aiInFlightCount = max(0, aiInFlightCount - 1)
        aiOutbox.removeAll { $0.id == id }
        incomingAIReplies.removeAll { $0.id == id }
    }

    private func finishResumedLoad(key: String, result: RunResult, tick: Int64) {
        guard let instance = instances[key] else { return }
        switch result {
        case .completed:
            guard definitionIsCurrent(instance) else {
                unloadInstance(
                    key: key, runUnloadHandler: false, removeDurableTimers: true,
                    dropSubscriptions: true
                )
                failedDefinitions.removeValue(forKey: key)
                return
            }
            var live = instance
            live.live = true
            instances[key] = live
            failedDefinitions.removeValue(forKey: key)
            scriptStore.storeLastError(live.ref, live.name, nil)
            state.eventBus.raise(
                kind: .load, subject: live.ref, payload: ["name": .string(live.name)],
                source: .engine, tick: tick,
                subjectType: eventSubjectType(for: live.ref)
            )
        case .yielded:
            break
        case .deferred:
            break
        case .faulted:
            failLoad(key: key, definition: instance.definition)
        }
    }

    private func scheduledRunIsCurrent(_ run: ScheduledRun) -> Bool {
        let scriptKey: String
        if run.isLoad {
            scriptKey = run.key
        } else if let parsed = parseKey(run.key) {
            scriptKey = parsed.owner.canonical + "#" + parsed.name
        } else {
            return false
        }
        guard let instance = instances[scriptKey] else { return false }
        // A load coroutine belongs to a not-yet-live instance; every other suspended coroutine
        // belongs to a module/handler that must still be live and unchanged.
        return definitionIsCurrent(instance) && (run.isLoad || instance.live)
    }

    private func resumeScheduledRun(_ run: ScheduledRun, args: [ScriptValue]) -> RunResult {
        resumeAndSchedule(
            key: run.key, coroutine: run.coroutine, args: args,
            isLoad: run.isLoad, context: nil, causedBy: run.causedBy,
            handlerEventCount: run.handlerEventCount
        )
    }

    /// ai-object-graph (change 2): the broker calls this — from any thread
    /// that ultimately serializes onto the main/game-loop thread before this
    /// call (the app layer's network completion handlers already dispatch
    /// back to main, matching every other network callback in this codebase)
    /// — once a real reply (or a definitive failure) for `id` is known.
    /// Queued, not applied immediately: delivery only ever happens inside
    /// `runAIInbox`, at the fixed script-phase point, so a reply that lands
    /// mid-tick from the app's per-frame pump still only ever mutates
    /// scripting state at the one deterministic phase this whole subsystem
    /// promises.
    public func submitAIReply(id: UInt64, text: String?, error: String?) {
        incomingAIReplies.append((id, text, error))
    }

    // MARK: - unload (§7.5 step 6, §8.2)

    /// Runs `on("unload")`-registered closures (if any were captured via
    /// `register`) against an attrs-only facade and drops the compiled
    /// environment for every `(ref,name)` in `refs`. Called from
    /// `GameCore+Scripting.handleScriptedChunkUnload` (chunk unload) and
    /// `exitToTitle` (whole-session shutdown).
    func unloadScripts(for refs: [ObjectRef]) {
        for ref in refs.sorted(by: { utf8Less($0.canonical, $1.canonical) }) {
            let refKey = ref.canonical
            var names = knownDefinitionNamesByRef[refKey] ?? []
            names.formUnion(scriptStore.list(ref).map(\.name))
            for name in names.sorted(by: utf8Less) {
                let key = refKey + "#" + name
                pendingDefinitionLoads.removeValue(forKey: key)
                if let instance = instances[key] {
                    unloadInstance(
                        key: key, runUnloadHandler: instance.live, removeDurableTimers: false,
                        dropSubscriptions: false
                    )
                }
                failedDefinitions.removeValue(forKey: key)
            }
            knownDefinitionNamesByRef.removeValue(forKey: refKey)
        }
    }

    private func failLoad(key: String, definition: ScriptRecord) {
        let retainedTimerIDs = instances[key]?.timerIDsAtLoadStart ?? []
        let owner = instances[key]?.ref
        let scriptName = instances[key]?.name
        unloadInstance(
            key: key, runUnloadHandler: false, removeDurableTimers: false,
            dropSubscriptions: true
        )
        if let owner, let scriptName {
            timers.removeAll {
                $0.owner == owner && $0.scriptName == scriptName && !retainedTimerIDs.contains($0.id)
            }
        }
        failedDefinitions[key] = definition
    }

    private func unloadInstance(
        key: String, runUnloadHandler: Bool, removeDurableTimers: Bool,
        dropSubscriptions: Bool
    ) {
        guard let instance = instances[key] else { return }
        if runUnloadHandler, let unloadFn = namedHandlers[key + "#unload"] {
            let unloadError: String? = {
                let previousScript = currentScript
                let previousUnloadState = unloadActive
                currentScript = (instance.ref, instance.name)
                unloadActive = true
                defer {
                    unloadActive = previousUnloadState
                    currentScript = previousScript
                }
                do {
                    switch try lua.call(
                        unloadFn, args: [], slice: budgets.handlerSliceInstructions
                    ) {
                    case .success:
                        return nil
                    case .failure(let fault):
                        return fault.message
                    }
                } catch {
                    return "script runtime could not run unload"
                }
            }()
            // An edit/detach unloads a stale instance after its persisted definition has
            // already changed. Preserve diagnostics for a still-current chunk/shutdown
            // unload, but never write an old callback's fault onto the replacement record.
            if let unloadError, definitionIsCurrent(instance) {
                scriptStore.storeLastError(instance.ref, instance.name, unloadError)
                state.eventBus.raise(
                    kind: .scriptFaulted, subject: instance.ref,
                    payload: ["name": .string(instance.name), "message": .string(unloadError)],
                    source: .engine, tick: host.currentTick,
                    subjectType: eventSubjectType(for: instance.ref)
                )
            }
        }
        let discardedRuns = scheduled.filter { $0.key == key || $0.key.hasPrefix(key + "#") }
        for run in discardedRuns { try? lua.close(run.coroutine) }
        let canceledAIRequestIDs = Set(discardedRuns.compactMap(\.awaitToken))
        if !canceledAIRequestIDs.isEmpty {
            for id in canceledAIRequestIDs { cancelAIRequest(id) }
        }
        if definitionIsCurrent(instance) {
            let words = instance.randomAdapter.inner.stateWords
            scriptStore.storeRNGWords(
                instance.ref, instance.name, [words.0, words.1, words.2, words.3]
            )
        }
        _ = clearFurnaceOutputOverride(for: instance.ref, scriptName: instance.name)
        instance.environment.destroy()
        instances.removeValue(forKey: key)
        _ = removeScheduledRuns { $0.key == key || $0.key.hasPrefix(key + "#") }
        namedHandlers = namedHandlers.filter { !$0.key.hasPrefix(key + "#") }
        if removeDurableTimers {
            timers.removeAll { $0.owner == instance.ref && $0.scriptName == instance.name }
        }
        if dropSubscriptions {
            state.eventBus.dropScriptOwnedSubscriptions(owner: instance.ref, scriptName: instance.name)
        }
    }

    /// Whole-session teardown (`exitToTitle`): unload every live instance,
    /// synchronously, before the world record is captured for save.
    func unloadAllForShutdown() {
        var refs = Set(instances.values.map(\.ref))
        for canonical in knownDefinitionNamesByRef.keys {
            if let ref = ObjectRef.parse(canonical) { refs.insert(ref) }
        }
        for key in failedDefinitions.keys {
            if let parsed = parseKey(key) { refs.insert(parsed.owner) }
        }
        unloadScripts(for: Array(refs))
    }

    /// §8.6: persists every live instance's current RNG stream words. Called
    /// once at the end of the script phase (cheap: a handful of live
    /// instances at most, guarded by the same zero-scripts fast path).
    public func persistRNGState() {
        guard !instances.isEmpty else { return }
        for instance in instances.values where instance.live {
            let words = instance.randomAdapter.inner.stateWords
            scriptStore.storeRNGWords(instance.ref, instance.name, [words.0, words.1, words.2, words.3])
        }
    }

    // MARK: - ephemeral run (§9.3 `run_script` / `/script run`)

    /// Runs `source` once, immediately, against `owner` — never persisted,
    /// never subscribed, never timed, never yieldable (`lua.call` is the
    /// synchronous, non-yieldable form; an attempted `wait`/`ai.await`
    /// becomes `.invalidYield`, matching §9.3's "capability-reduced: no
    /// subscribe, no timers, no `ai.*`"). This change's documented
    /// simplification of "runs once in the next phase" (§9.3) — see
    /// ARCHITECTURE.md.
    public func runEphemeral(source: String, owner: ObjectRef) -> ScriptRunOutcome {
        runEphemeral(source: source, owner: owner, policy: .fullyGated)
    }

    /// Runs only the source supplied by a host user's explicit editor Run Once action. This narrow
    /// entry point bypasses the persisted trust flag because opening an imported world's editor
    /// must not make its visible draft untestable, but it neither flips that flag nor saves or
    /// attaches the draft. Calls made by the draft may mutate the live world and those mutations
    /// may later be saved. The `doScripts` kill switch and open-world requirement still apply.
    /// Commands, AI tools, and LAN forwarding must continue to call `runEphemeral`.
    public func runEphemeralForEditorExplicitRun(source: String, owner: ObjectRef) -> ScriptRunOutcome {
        runEphemeral(source: source, owner: owner, policy: .editorExplicitRun)
    }

    private func runEphemeral(
        source: String, owner: ObjectRef, policy: EphemeralRunPolicy
    ) -> ScriptRunOutcome {
        if let refusal = ephemeralRunRefusal(for: policy) { return .failure(refusal) }
        guard case .live = graph.resolve(owner) else { return .failure("\(owner.canonical) is not loaded") }
        if case .refused(let stage, let message, _, let line) = ScriptValidator.validate(
            source: source, chunkName: "run", using: lua
        ) {
            return .failure("validation stage \(stage) line \(line): \(message)")
        }
        let transientRandom = RandomStreamBoxAdapter(
            RandomX(mix32(UInt32(truncatingIfNeeded: nextOrdinal)))
        )
        let env = lua.makeEnvironment(
            name: "run#\(nextOrdinal)", hostBindings: buildHostBindings(),
            random: transientRandom
        )
        nextOrdinal += 1
        defer { env.destroy() }
        let wrapped = "local self, world, player = ...\n" + source
        switch env.compile(source: wrapped, chunkName: "run") {
        case .failure(let fault):
            return .failure("compile error: \(fault.message)")
        case .success(let fn):
            let previous = currentScript
            let previousEphemeralRun = ephemeralRunActive
            let previousTransientRandom = transientExecutionRandom
            currentScript = (owner, "run")
            ephemeralRunActive = true
            transientExecutionRandom = transientRandom
            defer {
                transientExecutionRandom = previousTransientRandom
                ephemeralRunActive = previousEphemeralRun
                currentScript = previous
            }
            let outcome: ScriptCallOutcome
            do {
                outcome = try lua.call(
                    fn, args: [handleValue(for: owner), handleValue(for: .world), handleValue(for: .player)],
                    slice: budgets.handlerSliceInstructions
                )
            } catch {
                return .failure("call failed")
            }
            switch outcome {
            case .success:
                return .success(
                    "ran '\(owner.canonical)' script once (draft not saved or attached; live changes may persist)"
                )
            case .failure(let fault): return .failure("runtime error: \(fault.message)")
            }
        }
    }

    private func ephemeralRunRefusal(for policy: EphemeralRunPolicy) -> String? {
        guard let world = host.world(for: host.currentDimension) else {
            return "scripting is unavailable because no world is loaded"
        }
        if case .fullyGated = policy, !host.scriptsEnabled {
            return "scripting is not trusted for this world"
        }
        guard (world.gameRules["doScripts"] ?? 1) != 0 else {
            return "scripting is disabled by the doScripts gamerule"
        }
        return nil
    }

    // MARK: - validation / dry-run (ai-object-graph, change 2, design.md §9.4)

    /// Stages 0-3 of `ScriptValidator` against this session's `LuaState` —
    /// the same compile-time gate `h:attach`/`/script attach`/`runEphemeral`
    /// already use, exposed for the AI tool loop's `check_script` query tool
    /// and as the first half of `AIScriptValidationGate.validate` (which
    /// adds stage 5 on top). `lua` itself stays un-exposed; this is the one
    /// operation callers outside this file need from it.
    /// scripting-ui-and-replication (change 3), design.md §12: the F3 debug-summary line's own
    /// data source. Cheap (a count over the already-in-memory `instances`/`scheduled`/`timers`
    /// collections, no scan) — safe to read every frame the overlay is on, matching §15's
    /// zero-cost invariant (a world with no scripts has empty collections here, so this is
    /// effectively free even when F3 is showing).
    public var summary: ScriptRuntimeSummary {
        refreshInstructionBudget()
        return ScriptRuntimeSummary(
            liveScripts: instances.values.filter(\.live).count,
            suspendedCoroutines: scheduled.count,
            durableTimers: timers.count,
            instructionsUsedThisTick: instructionsUsedThisTick,
            instructionBudgetRemaining: max(0, instructionTokens),
            instructionBucketCapacity: max(0, budgets.perTickBucket)
        )
    }

    public func validateSource(_ source: String, chunkName: String) -> ScriptValidation {
        ScriptValidator.validate(source: source, chunkName: chunkName, using: lua)
    }

    /// scripting-ui-and-replication (change 3): the app target (`Sources/Elysium`, the full
    /// `ScriptEditorScreen`) does not depend on `ElysiumScript` (design.md §4's own module
    /// diagram — only `ElysiumCore` is allowed to see it), so it cannot spell `ScriptValidation`
    /// by name. This is the anticorruption translation at that seam — the same pattern
    /// `ScriptingDisplayText.isValidScriptSource` already established for
    /// `ScriptTextHygiene.isClean` — re-expressed as an `ElysiumCore`-native type the editor can
    /// use directly for its error-line highlight.
    public func validateSourceForEditor(_ source: String, chunkName: String) -> ScriptValidationResult {
        switch validateSource(source, chunkName: chunkName) {
        case .accepted:
            return ScriptValidationResult(outcome: .accepted)
        case .refused(let stage, let message, let hint, let line):
            return ScriptValidationResult(outcome: .refused(stage: stage, message: message, hint: hint, line: line))
        }
    }

    /// Stage-6 advisory execution: compile and resume `source` once in a scratch environment over
    /// a read-only facade (throwaway RNG, no AI, no attribute/world writes). Reads still use the
    /// owner's real handles. A normal completion passes; a first `wait`/`ai.await` is reported as
    /// a valid but prefix-limited suspension and its coroutine is closed without scheduling;
    /// faults and slice preemption are failures. Registered handler closures are not invoked in
    /// this bounded pass. Nothing is persisted, emitted, sent to chat/AI, or allowed to escape the
    /// throwaway environment, and the pass does not consume the live scheduler/RNG ordinal. The
    /// method never throws; callers decide whether a failure is blocking (editor Check) or an
    /// advisory warning (AI attach validation).
    public func dryRunOutcome(
        source: String, owner: ObjectRef, mode: ScriptMode, handlerEvent: EventKind? = nil,
        handlerSubject: ObjectRef? = nil, handlerSubjectIsExact: Bool = true
    ) -> ScriptDryRunOutcome {
        guard case .live = graph.resolve(owner) else { return .failure("\(owner.canonical) is not loaded") }
        let wasDryRun = dryRunActive
        dryRunActive = true
        defer { dryRunActive = wasDryRun }
        let transientRandom = RandomStreamBoxAdapter(RandomX(0xD8A1_1D8A))
        let env = lua.makeEnvironment(
            name: "dryrun", hostBindings: buildHostBindings(),
            random: transientRandom
        )
        defer { env.destroy() }
        let wrapped = mode == .module
            ? "local self, world, player = ...\n" + source
            : "local self, world, player, ev = ...\n" + source
        switch env.compile(source: wrapped, chunkName: "dryrun") {
        case .failure(let fault):
            return .failure(fault.message)
        case .success(let fn):
            let selectedEvent = handlerEvent ?? EventKind.parse("dryrun") ?? .load
            let selectedSubject = handlerSubject ?? owner
            let selectedDescriptor: ScriptEventDescriptor?
            if handlerSubjectIsExact {
                let subjectRecord: ObjectRecord
                if case .live(let live) = graph.resolve(selectedSubject) {
                    subjectRecord = AttributeStore.readRecord(live, host: host)
                } else {
                    subjectRecord = ObjectRecord()
                }
                selectedDescriptor = EventDescriptorRegistry.descriptor(
                    for: selectedEvent, declaredOn: selectedSubject, in: subjectRecord
                )
            } else {
                selectedDescriptor = EventDescriptorRegistry.descriptor(for: selectedEvent)
            }
            if mode == .handler, selectedDescriptor == nil {
                return .compiledOnly(
                    "custom event '\(selectedEvent.rawValue)' has no declared payload schema, so its handler was not executed"
                )
            }
            let previous = currentScript
            let previousTransientRandom = transientExecutionRandom
            currentScript = (owner, "dryrun")
            transientExecutionRandom = transientRandom
            defer {
                transientExecutionRandom = previousTransientRandom
                currentScript = previous
            }
            let args: [ScriptValue]
            if mode == .module {
                args = [handleValue(for: owner), handleValue(for: .world), handleValue(for: .player)]
            } else {
                // The editor and AI attach flow pass the handler's selected trigger. The custom
                // fallback returned `compiledOnly` above, so only a registry-described event is
                // ever executed with representative payload data.
                let event = syntheticDryRunEvent(
                    kind: selectedEvent, subject: selectedSubject, descriptor: selectedDescriptor
                )
                args = [
                    handleValue(for: owner), handleValue(for: .world), handleValue(for: .player),
                    eventValue(event),
                ]
            }
            do {
                guard let coroutine = try lua.makeCoroutine(function: fn) else {
                    return .failure("dry run failed to create a coroutine")
                }
                defer { try? lua.close(coroutine) }
                switch try lua.resume(coroutine, args: args, slice: budgets.handlerSliceInstructions) {
                case .completed:
                    return .completed
                case .yielded(.wait(_)):
                    // Attached module/handler execution is yieldable. A first suspension proves
                    // this prefix reached a legal boundary; never schedule the throwaway
                    // coroutine or continue into a later tick from Check/dry-run.
                    return .suspended("wait()")
                case .yielded(.await(_)):
                    return .suspended("ai.await()")
                case .yielded(.preempted):
                    return .failure("dry run reached its instruction slice without completing or yielding")
                case .faulted(let fault):
                    return .failure(fault.message)
                }
            } catch {
                return .failure("dry run failed to execute")
            }
        }
    }

    /// Compatibility helper for existing validation callers: suspension is legal attached-script
    /// behavior, while actual dry-run failures retain the historical optional-message shape.
    public func dryRun(
        source: String, owner: ObjectRef, mode: ScriptMode, handlerEvent: EventKind? = nil,
        handlerSubject: ObjectRef? = nil, handlerSubjectIsExact: Bool = true
    ) -> String? {
        if case .failure(let message) = dryRunOutcome(
            source: source, owner: owner, mode: mode, handlerEvent: handlerEvent,
            handlerSubject: handlerSubject, handlerSubjectIsExact: handlerSubjectIsExact
        ) {
            return message
        }
        return nil
    }

    /// Builds the same event shape handler delivery uses, without enqueueing anything. Registry
    /// order and fixed non-null values make this deterministic. Nullable fields intentionally use
    /// one valid typed value so Check can exercise guarded and direct payload access without a
    /// missing live event becoming a false runtime fault.
    private func syntheticDryRunEvent(
        kind: EventKind, subject: ObjectRef, descriptor: ScriptEventDescriptor?
    ) -> ScriptEvent {
        var payload: [String: AttrValue] = [:]
        if let descriptor {
            for field in descriptor.payload {
                payload[field.name] = representativeDryRunValue(for: field, subject: subject)
            }
        }
        return ScriptEvent(
            seq: 0, tick: host.currentTick, kind: kind, subject: subject,
            payload: payload, source: .engine
        )
    }

    private func representativeDryRunValue(
        for field: ScriptEventFieldDescriptor, subject: ObjectRef
    ) -> AttrValue {
        switch field.type {
        case .any:
            return .string("dryrun")
        case .boolean:
            return .bool(true)
        case .integer:
            return .int(1)
        case .number:
            return .number(1)
        case .string:
            return .string("dryrun")
        case .function:
            // Functions cannot cross the ScriptValue boundary. Event descriptors do not
            // currently expose one; nil remains the only safe forward-compatible stand-in.
            return .null
        case .table, .map:
            return .map([:])
        case .objectHandle:
            return handleValue(for: subject)
        case .attributeProxy:
            return attrsHandleValue(for: subject)
        case .event:
            return .map([
                "kind": .string("dryrun"), "subject": handleValue(for: subject),
                "tick": .int(host.currentTick), "source": .string("engine"),
            ])
        case .item:
            return .map(["item": .string("dryrun"), "count": .int(1), "damage": .int(0)])
        case .effectList, .list:
            return .list([])
        case .enumeration(let values):
            return .string(values.first ?? "dryrun")
        }
    }

}


/// `ScriptLogSink` -> stdout, capped and hygiene-filtered upstream already
/// (design.md Condition 33) — no further processing needed; `/script log`
/// is out of scope for 1c (deferred, documented in ARCHITECTURE.md).
final class ScriptRuntimeLogSink: ScriptLogSink {
    func log(envId: UInt64, line: String) {
        print("[script] \(line)")
    }
}

/// Bridges the game's `RandomX` (Core) to the `ScriptRandomStream` protocol
/// (ElysiumScript) through a small value box, since `ElysiumScript` cannot
/// see `RandomX` directly (design.md Decision 11 — `ScriptHostBindings.swift`
/// already conforms `RandomX` itself; this wrapper exists only because
/// `makeEnvironment` wants a value it can copy into its own bookkeeping while
/// this runtime also wants to read the *same* stream back out for
/// persistence — `RandomStreamBox`'s own class semantics inside
/// `ElysiumScript` are `internal`, so this runtime keeps its own reference).
final class RandomStreamBoxAdapter: ScriptRandomStream {
    var inner: RandomX
    init(_ inner: RandomX) { self.inner = inner }
    func nextUInt32() -> UInt32 { inner.next() }
    func reseed(_ seed: UInt32) { inner = RandomX(seed) }
}
