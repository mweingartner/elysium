// ScriptRuntimeBench.swift — task 5.3 and 5.5 (C22). `--bench-scripts`
// (`main.swift`'s early branch) calls `runScriptRuntimeBench()` instead of running
// the ordinary checks; every row here is `print`ed, informational only — nothing in
// this file calls `check(...)`, so none of it is counted toward 469. Exits 0
// regardless of the numbers (design.md Decision 13: "exits 0; not counted").

import ElysiumCore
import ElysiumScript
import Foundation

private final class BenchLogSink: ScriptLogSink {
    func log(envId: UInt64, line: String) {}
}

/// Wall-clock microseconds for one run of `body` (design.md's existing
/// `DispatchTime.now().uptimeNanoseconds` convention, already used elsewhere in
/// `main.swift` for the mesh/worldsim/entity bench lines).
private func elapsedMicroseconds(_ body: () -> Void) -> Double {
    let t0 = DispatchTime.now()
    body()
    let t1 = DispatchTime.now()
    return Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000.0
}

/// Median of 5 raw samples (design.md Decision 13: "median of 5").
private func medianOf5(_ sample: () -> Double) -> Double {
    var xs = (0..<5).map { _ in sample() }
    xs.sort()
    return xs[2]
}

private func printRow(_ name: String, _ microseconds: Double) {
    print("  \(name): \(String(format: "%.3f", microseconds)) µs")
}

func runScriptRuntimeBench() {
    print("\n— script runtime bench (--bench-scripts; informational, not counted)")

    // ---- µs per 1k instructions (hook on) --------------------------------------
    let usPer1kInstructions = medianOf5 {
        var budgets = ScriptBudgets.defaults
        budgets.handlerTotalInstructions = 50_000_000
        guard let state = try? LuaState(budgets: budgets, math: ScriptHostMath.deterministic, log: BenchLogSink())
        else { return 0 }
        let env = state.makeEnvironment(name: "bench", random: RandomX(1))
        guard
            let fn = try? env.compile(
                source: "local i = 0; local n = 2000000; while i < n do i = i + 1 end; return i",
                chunkName: "instructionBench"
            ).get(),
            let coroutine = try? state.makeCoroutine(function: fn) ?? nil
        else { return 0 }
        let us = elapsedMicroseconds {
            _ = try? state.resume(coroutine, args: [], slice: 50_000_000)
        }
        let instructions = max(coroutine.instructionsUsed, 1)
        return us / (Double(instructions) / 1_000.0)
    }
    printRow("µs per 1k instructions (hook on)", usPer1kInstructions)
    if usPer1kInstructions > 40 {
        print(
            "  LUAU RULE TRIGGERED: µs/1k instructions (\(String(format: "%.3f", usPer1kInstructions))) > 40 — "
                + "a 50,000-instruction per-tick budget would exceed 2 ms"
        )
    } else {
        print(
            "  Luau rule: µs/1k instructions (\(String(format: "%.3f", usPer1kInstructions))) "
                + "<= 40 — 50,000-instruction per-tick budget stays under 2 ms"
        )
    }

    // ---- µs per host function call ---------------------------------------------
    let usPerHostCall = medianOf5 {
        guard
            let state = try? LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: BenchLogSink())
        else { return 0 }
        let probe = HostFunction { _ in .values([.int(0)]) }
        let env = state.makeEnvironment(name: "bench", hostBindings: [.function(name: "probe", probe)], random: RandomX(1))
        let calls = 5_000
        guard
            let fn = try? env.compile(
                source: "for i = 1, \(calls) do probe(i) end", chunkName: "hostCallBench"
            ).get()
        else { return 0 }
        let us = elapsedMicroseconds {
            _ = try? state.call(fn, args: [], slice: 10_000_000)
        }
        return us / Double(calls)
    }
    printRow("µs per host function call", usPerHostCall)

    // ---- µs per handle method call ----------------------------------------------
    let usPerHandleMethodCall = medianOf5 {
        guard
            let state = try? LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: BenchLogSink())
        else { return 0 }
        let dispatch = HandleDispatch(methods: ["m": { _, _ in .values([.int(0)]) }])
        let kind = state.registerHandleKind(name: "bench", dispatch: dispatch, interned: false)
        guard let handleValue = try? state.makeHandle(kind: kind, ref: "bench:1", id: 1) else { return 0 }
        let getHandle = HostFunction { _ in .values([handleValue]) }
        let env = state.makeEnvironment(
            name: "bench", hostBindings: [.function(name: "getHandle", getHandle)], random: RandomX(1)
        )
        let calls = 5_000
        guard
            let fn = try? env.compile(
                source: "local h = getHandle(); for i = 1, \(calls) do h:m() end", chunkName: "handleMethodBench"
            ).get()
        else { return 0 }
        let us = elapsedMicroseconds {
            _ = try? state.call(fn, args: [], slice: 10_000_000)
        }
        return us / Double(calls)
    }
    printRow("µs per handle method call", usPerHandleMethodCall)

    // ---- µs per environment creation --------------------------------------------
    let usPerEnvironmentCreation = medianOf5 {
        guard
            let state = try? LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: BenchLogSink())
        else { return 0 }
        let creations = 500
        let us = elapsedMicroseconds {
            for i in 0..<creations {
                _ = state.makeEnvironment(name: "bench\(i)", random: RandomX(UInt32(i + 1)))
            }
        }
        return us / Double(creations)
    }
    printRow("µs per environment creation", usPerEnvironmentCreation)

    // ---- µs per thread create/resume/close cycle ---------------------------------
    let usPerThreadCycle = medianOf5 {
        guard
            let state = try? LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: BenchLogSink())
        else { return 0 }
        let env = state.makeEnvironment(name: "bench", random: RandomX(1))
        guard let fn = try? env.compile(source: "return 1", chunkName: "threadCycleBench").get() else { return 0 }
        let cycles = 2_000
        let us = elapsedMicroseconds {
            for _ in 0..<cycles {
                guard let coroutine = try? state.makeCoroutine(function: fn) ?? nil else { continue }
                _ = try? state.resume(coroutine, args: [], slice: 10_000)
                try? state.close(coroutine)
            }
        }
        return us / Double(cycles)
    }
    printRow("µs per thread create/resume/close cycle", usPerThreadCycle)

    // ---- emergency-GC latency at cap ----------------------------------------------
    let emergencyGCLatency = medianOf5 {
        var budgets = ScriptBudgets.defaults
        budgets.memoryCapBytes = 256 * 1024
        budgets.hostOverCapDiagnosticBytes = 64 * 1024
        budgets.handlerTotalInstructions = 50_000_000
        guard let state = try? LuaState(budgets: budgets, math: ScriptHostMath.deterministic, log: BenchLogSink())
        else { return 0 }
        let env = state.makeEnvironment(name: "bench", random: RandomX(1))
        guard
            let fn = try? env.compile(
                source: "local t = {}; local i = 0; while true do i = i + 1; t[i] = (\"x\"):rep(200) end",
                chunkName: "emergencyGCBench"
            ).get(),
            let coroutine = try? state.makeCoroutine(function: fn) ?? nil
        else { return 0 }
        // Drive the coroutine to its memory cap first (not timed) ...
        _ = try? state.resume(coroutine, args: [], slice: 50_000_000)
        // ... then time the host-driven full collection a real scheduler would run
        // right after observing the trip, recovering headroom at the worst moment.
        return elapsedMicroseconds {
            state.collectFull()
        }
    }
    printRow("emergency-GC latency at cap", emergencyGCLatency)

    // ---- C22: flooded-hash lookup -------------------------------------------------
    let floodedHashLookup = medianOf5 {
        guard
            let state = try? LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: BenchLogSink())
        else { return 0 }
        let env = state.makeEnvironment(name: "bench", random: RandomX(1))
        guard
            let fn = try? env.compile(
                source: """
                    local t = {}
                    for i = 1, 20000 do t["key" .. i] = i end
                    local hit = 0
                    for round = 1, 10 do
                      for i = 1, 20000 do
                        if t["key" .. i] ~= nil then hit = hit + 1 end
                      end
                    end
                    return hit
                    """,
                chunkName: "floodedHashBench"
            ).get()
        else { return 0 }
        return elapsedMicroseconds {
            _ = try? state.call(fn, args: [], slice: 100_000_000)
        }
    }
    printRow("flooded-hash lookup (20k keys x 10 rounds)", floodedHashLookup)

    // ---- C22: sparse `next` scan ---------------------------------------------------
    let sparseNextScan = medianOf5 {
        guard
            let state = try? LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: BenchLogSink())
        else { return 0 }
        let env = state.makeEnvironment(name: "bench", random: RandomX(1))
        guard
            let fn = try? env.compile(
                source: """
                    local t = {}
                    for i = 1, 4000 do t[i * 97] = i end
                    local count = 0
                    for k, v in pairs(t) do count = count + 1 end
                    return count
                    """,
                chunkName: "sparseNextBench"
            ).get()
        else { return 0 }
        return elapsedMicroseconds {
            _ = try? state.call(fn, args: [], slice: 100_000_000)
        }
    }
    printRow("sparse next scan (4k sparse keys)", sparseNextScan)

    // ---- C22: 256 KiB string compare -----------------------------------------------
    let stringCompare256KiB = medianOf5 {
        guard
            let state = try? LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: BenchLogSink())
        else { return 0 }
        let env = state.makeEnvironment(name: "bench", random: RandomX(1))
        guard
            let fn = try? env.compile(
                source: """
                    local a = ("x"):rep(262144)
                    local b = ("x"):rep(262143) .. "y"
                    local same = 0
                    for i = 1, 200 do
                      if a == a then same = same + 1 end
                      if a == b then same = same + 1 end
                    end
                    return same
                    """,
                chunkName: "stringCompareBench"
            ).get()
        else { return 0 }
        return elapsedMicroseconds {
            _ = try? state.call(fn, args: [], slice: 100_000_000)
        }
    }
    printRow("256 KiB string compare (200 rounds)", stringCompare256KiB)
}
