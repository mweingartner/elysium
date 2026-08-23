// ScriptBudgets.swift
//
// Pure-data budgets for the embedded Lua runtime (design.md Decision 6). This is the
// only file Lane A (the C/vendoring foundation) writes under Sources/ElysiumScript —
// it exists so the ElysiumScript target has at least one Swift source and compiles
// standalone; every other Swift file in this target (LuaState, ScriptValue, the
// sandbox-facing wrappers, ...) is owned by later lanes of embed-lua-runtime.
//
// ScriptBudgets carries no behavior — it is a plain data struct so tests can shrink
// the numbers that matter for a fast, deterministic trip (memory cap, allocation
// rate, instruction totals) without touching production code. `.defaults` reproduces
// the numbers from design.md Decision 6 / the programme design's §8.4 defaults.

import CLua

public struct ScriptBudgets: Sendable, Equatable {
    /// Instructions charged to a coroutine's slice before it preempts (or, with no
    /// enclosing coroutine, hard-faults — design.md Condition 35).
    public var handlerSliceInstructions: Int

    /// Instructions a single coroutine may accumulate over its lifetime before it
    /// faults with `.instructionBudget`, regardless of `pcall` (design.md Decision 6).
    public var handlerTotalInstructions: Int

    /// Instructions budgeted for one scheduler tick (bookkeeping only in this
    /// change; the scheduler that spends it lands in a later change).
    public var perTickInstructions: Int

    /// The rolling bucket `perTickInstructions` refills into (bookkeeping only).
    public var perTickBucket: Int

    /// Consecutive preemptions after which the scheduler should deprioritize a
    /// coroutine (counter exposed on `ScriptCoroutine`; not enforced in this change).
    public var maxConsecutivePreemptions: Int

    /// Bytes a script frame may request from the allocator within one slice before
    /// `.allocationRate` trips (design.md Decision 5).
    public var allocationRatePerSliceBytes: Int

    /// The hard, state-wide allocator cap; exceeding it trips `.memoryCap`
    /// (design.md Decision 5).
    public var memoryCapBytes: Int

    /// Slack above `memoryCapBytes` a host section (never a script frame) may push
    /// into before `LuaState.memoryStatus.overCapHost` is set (design.md Decision 5).
    public var hostOverCapDiagnosticBytes: Int

    /// Maximum idle pooled coroutine threads a `LuaState` keeps (design.md Decision 7).
    public var threadPoolMax: Int

    /// Bytes a single `print` line may contain before truncation (design.md
    /// Condition 33); the CLua sandbox enforces the matching constant directly.
    public var logLineBytes: Int

    /// Lines a slice may `print` before "print budget exceeded" (design.md Condition 33).
    public var logLinesPerSlice: Int

    /// `ScriptValue.string` length cap, in bytes (design.md Decision 10).
    public var valueStringBytes: Int

    /// `ScriptValue.list` element-count cap.
    public var valueListElements: Int

    /// `ScriptValue.map` key-count cap.
    public var valueMapKeys: Int

    /// Maximum nesting depth for a marshaled `ScriptValue`.
    public var valueDepth: Int

    /// Maximum total nodes (list/map entries, transitively) for a marshaled `ScriptValue`.
    public var valueNodes: Int

    /// Source text length cap, in bytes, before `ScriptValidator`/`checkSyntax` refuse it.
    public var sourceBytes: Int

    /// Chunk name length cap, in bytes.
    public var chunkNameBytes: Int

    /// `ScriptFault.message` length cap, in bytes.
    public var faultMessageBytes: Int

    /// `ScriptFault.traceback` length cap, in bytes.
    public var tracebackBytes: Int

    public init(
        handlerSliceInstructions: Int,
        handlerTotalInstructions: Int,
        perTickInstructions: Int,
        perTickBucket: Int,
        maxConsecutivePreemptions: Int,
        allocationRatePerSliceBytes: Int,
        memoryCapBytes: Int,
        hostOverCapDiagnosticBytes: Int,
        threadPoolMax: Int,
        logLineBytes: Int,
        logLinesPerSlice: Int,
        valueStringBytes: Int,
        valueListElements: Int,
        valueMapKeys: Int,
        valueDepth: Int,
        valueNodes: Int,
        sourceBytes: Int,
        chunkNameBytes: Int,
        faultMessageBytes: Int,
        tracebackBytes: Int
    ) {
        self.handlerSliceInstructions = handlerSliceInstructions
        self.handlerTotalInstructions = handlerTotalInstructions
        self.perTickInstructions = perTickInstructions
        self.perTickBucket = perTickBucket
        self.maxConsecutivePreemptions = maxConsecutivePreemptions
        self.allocationRatePerSliceBytes = allocationRatePerSliceBytes
        self.memoryCapBytes = memoryCapBytes
        self.hostOverCapDiagnosticBytes = hostOverCapDiagnosticBytes
        self.threadPoolMax = threadPoolMax
        self.logLineBytes = logLineBytes
        self.logLinesPerSlice = logLinesPerSlice
        self.valueStringBytes = valueStringBytes
        self.valueListElements = valueListElements
        self.valueMapKeys = valueMapKeys
        self.valueDepth = valueDepth
        self.valueNodes = valueNodes
        self.sourceBytes = sourceBytes
        self.chunkNameBytes = chunkNameBytes
        self.faultMessageBytes = faultMessageBytes
        self.tracebackBytes = tracebackBytes
    }

    /// design.md Decision 6 / the programme design's §8.4 and §17-12 defaults.
    public static let defaults = ScriptBudgets(
        handlerSliceInstructions: 5_000,
        handlerTotalInstructions: 100_000,
        perTickInstructions: 50_000,
        perTickBucket: 250_000,
        maxConsecutivePreemptions: 20,
        allocationRatePerSliceBytes: 2 * 1024 * 1024,
        memoryCapBytes: 16 * 1024 * 1024,
        hostOverCapDiagnosticBytes: 1 * 1024 * 1024,
        threadPoolMax: 256,
        logLineBytes: 512,
        logLinesPerSlice: 256,
        valueStringBytes: 4 * 1024,
        valueListElements: 256,
        valueMapKeys: 64,
        valueDepth: 4,
        valueNodes: 1_024,
        sourceBytes: 16 * 1024,
        chunkNameBytes: 64,
        faultMessageBytes: 512,
        tracebackBytes: 2 * 1024
    )
}

/// Read-only mirror of the sandbox's compile-time numeric library caps
/// (object-graph-attributes change 1a carry-forward, N4-2 / design.md Decision
/// 12). These used to be duplicated as ten mutable `ScriptBudgets` fields that
/// nothing read and that could silently drift from `elysium_sandbox.c`'s own
/// literals; `.current` calls the C shim's `elysium_library_caps()` getter, so
/// the C constants stay the single source of truth and docs/tests read the
/// same numbers the sandbox actually enforces.
public struct ScriptLibraryCaps: Sendable, Equatable {
    /// `string.find`/`match`/`gmatch`/`gsub` subject length cap, in bytes.
    public var patternSubjectBytes: Int
    /// `string.find`/`match`/`gmatch`/`gsub` pattern length cap, in bytes.
    public var patternBytes: Int
    /// `string.find`/`match`/`gmatch`/`gsub` matcher step budget per call.
    public var matchSteps: Int
    /// `gsub`/`format`/`pack`/`rep`/`concat` result length cap, in bytes.
    public var resultBytes: Int
    /// `string.byte` requested range cap, in bytes.
    public var byteRangeBytes: Int
    /// `table.sort` element-count cap.
    public var sortElements: Int
    /// `table.unpack` result-count cap.
    public var unpackResults: Int
    /// `table.move` element-count cap.
    public var moveElements: Int
    /// `utf8.codepoint`/`len`/`offset`/`codes` subject length cap, in bytes.
    public var utf8SubjectBytes: Int
    /// `string.format` conversion-count cap.
    public var formatConversions: Int
    /// Maximum string length the sandbox's C string helpers will build, in bytes.
    public var maxStringBytes: Int

    /// Reads `elysium_library_caps()` fresh each call — the values are
    /// compile-time constants in `elysium_shim.c`, so this is cheap and always
    /// current; nothing caches a stale copy.
    public static var current: ScriptLibraryCaps {
        let raw = elysium_library_caps()
        return ScriptLibraryCaps(
            patternSubjectBytes: Int(raw.patternSubjectBytes),
            patternBytes: Int(raw.patternBytes),
            matchSteps: Int(raw.matchSteps),
            resultBytes: Int(raw.resultBytes),
            byteRangeBytes: Int(raw.byteRangeBytes),
            sortElements: Int(raw.sortElements),
            unpackResults: Int(raw.unpackResults),
            moveElements: Int(raw.moveElements),
            utf8SubjectBytes: Int(raw.utf8SubjectBytes),
            formatConversions: Int(raw.formatConversions),
            maxStringBytes: Int(raw.maxStringBytes)
        )
    }
}
