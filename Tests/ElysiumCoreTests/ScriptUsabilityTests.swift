// ScriptUsabilityTests.swift — regression coverage for the scripting usability polish:
// fault notices in chat (C1), author line numbers (C2), `/script attach` validation (C3),
// repeating `every(n, fn)` closures and `cancel(id)` (C4), typo guards for event and
// attribute names (C5), and the scripting help text (C6, Core half — the `/help` chat command
// itself is covered app-side by `ScriptingHelpCommandTests`).

import Foundation
import ElysiumScript
import XCTest
@testable import ElysiumCore

@MainActor
final class ScriptUsabilityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
        if itemDefs.isEmpty { registerAllItems() }
    }

    /// Reference box so the `say` sink closure can append without capturing an inout.
    private final class ChatLines {
        var lines: [String] = []
    }

    private struct Harness {
        let host: FakeObjectGraphHost
        let state: GameScriptingState
        let runtime: ScriptRuntime
        let scripts: ScriptStore
        let attributes: AttributeStore
        let chat: ChatLines
    }

    private func makeHarness(seed: Int, budgets: ScriptBudgets = .defaults, withPlayer: Bool = false) throws -> Harness {
        let host = FakeObjectGraphHost()
        let world = World(dim: .overworld, seed: UInt32(seed))
        host.worldsByDim[.overworld] = world
        if withPlayer {
            let player = Player(world: world)
            player.setPos(0.5, 65, 0.5)
            world.addEntity(player)
            host.localPlayer = player
        }
        let state = GameScriptingState()
        let chat = ChatLines()
        let runtime = try ScriptRuntime(
            host: host, state: state, budgets: budgets, say: { chat.lines.append($0) }
        )
        state.scriptRuntime = runtime
        state.eventBus.delivery = { [weak runtime] event, targets in runtime?.deliver(event, targets) }
        state.eventBus.deliveryAdmission = { [weak runtime] event, targets in
            runtime?.admittedDeliveryCount(for: event, targets: targets) ?? 0
        }
        let graph = ObjectGraph(host: host)
        return Harness(
            host: host, state: state, runtime: runtime, scripts: ScriptStore(graph: graph),
            attributes: AttributeStore(graph: graph), chat: chat
        )
    }

    /// Mirrors `GameCore.runEventBusPhase()`'s script-phase order at an explicit tick.
    private func step(_ h: Harness, tick: Int64) {
        h.host.currentTick = tick
        h.state.anyScriptsAttached = true
        h.runtime.resetPerTickCounters()
        h.runtime.runLoads()
        h.runtime.runAIInbox()
        h.runtime.runResumptions()
        _ = h.state.eventBus.runDeliveryPhase(tick: tick)
        h.runtime.persistRNGState()
    }

    private func attachModule(_ h: Harness, _ name: String, _ source: String, on ref: ObjectRef = .world) throws {
        _ = try h.scripts.attach(ref, name: name, source: source, mode: .module, triggers: [], by: .player, tick: 0).get()
    }

    // MARK: - C1 fault notices

    func testFaultNoticeNamesObjectScriptMessageAndHowToLook() throws {
        let h = try makeHarness(seed: 401)
        try attachModule(h, "greeter", "error(\"boom\")")
        step(h, tick: 1)

        let notices = h.chat.lines.filter { $0.hasPrefix("[script] ") }
        XCTAssertEqual(notices.count, 1, "\(h.chat.lines)")
        XCTAssertEqual(notices.first, "[script] greeter on world failed: line 1: boom (/script show world greeter)")
        XCTAssertTrue(h.scripts.get(.world, "greeter")?.lastError?.contains("boom") == true)
    }

    func testCompileFaultAndHandlerFaultAlsoPostNotices() throws {
        let h = try makeHarness(seed: 402)
        _ = try h.scripts.attach(
            .world, name: "broken", source: "local = 1", mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        try attachModule(h, "callback", "self:on(\"test.ping\", function(ev) error(\"pong failed\") end)")
        step(h, tick: 1)
        XCTAssertTrue(h.chat.lines.contains { $0.hasPrefix("[script] broken on world failed: line 1:") }, "\(h.chat.lines)")

        h.state.eventBus.raise(kind: try XCTUnwrap(EventKind.parse("test.ping")), subject: .world, source: .engine, tick: 1)
        step(h, tick: 2)
        XCTAssertTrue(
            h.chat.lines.contains { $0 == "[script] callback on world failed: line 1: pong failed (/script show world callback)" },
            "\(h.chat.lines)"
        )
    }

    func testFaultNoticeIsHygienicBoundedAndKeepsTheHowToLookSuffix() throws {
        let h = try makeHarness(seed: 403)
        let long = String(repeating: "x", count: 400)
        try attachModule(h, "noisy", "error(\"§cred\\nsecond line \\u{202E}rtl " + long + "\")")
        step(h, tick: 1)

        let notice = try XCTUnwrap(h.chat.lines.first { $0.hasPrefix("[script] noisy") })
        XCTAssertLessThanOrEqual(notice.utf8.count, 256)
        XCTAssertFalse(notice.contains("§"))
        XCTAssertFalse(notice.contains("\n"))
        XCTAssertFalse(notice.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertTrue(notice.hasSuffix(" (/script show world noisy)"), notice)
    }

    func testFaultNoticeIsNeverPostedFromCheckOrDryRun() throws {
        let h = try makeHarness(seed: 404)
        guard case .failure = h.runtime.dryRunOutcome(source: "error(\"dry\")", owner: .world, mode: .module) else {
            return XCTFail("dry run should report the error")
        }
        XCTAssertEqual(h.chat.lines, [])
    }

    func testNoticeLimiterRepeatsIdenticalAfter1200AndChangedAfter200Ticks() {
        var limiter = ScriptNoticeLimiter()
        XCTAssertEqual(limiter.admit(key: "a", message: "m1", tick: 10), .post)
        XCTAssertEqual(limiter.admit(key: "a", message: "m1", tick: 11), .suppressed)
        XCTAssertEqual(limiter.admit(key: "a", message: "m2", tick: 209), .suppressed)
        XCTAssertEqual(limiter.admit(key: "a", message: "m2", tick: 210), .post)
        XCTAssertEqual(limiter.admit(key: "a", message: "m2", tick: 1_409), .suppressed)
        XCTAssertEqual(limiter.admit(key: "a", message: "m2", tick: 1_410), .post)
        XCTAssertEqual(limiter.admit(key: "b", message: "m1", tick: 1_410), .post, "keys are independent")
    }

    func testNoticeLimiterCapsFourPerTickAndSummarizesTheOverflowLater() {
        var limiter = ScriptNoticeLimiter()
        let outcomes = (0..<7).map { limiter.admit(key: "s\($0)", message: "boom", tick: 5) }
        XCTAssertEqual(outcomes, [.post, .post, .post, .post, .overflow, .overflow, .overflow])
        XCTAssertNil(limiter.takeOverflowSummary(at: 5), "the summary waits for a later tick")
        XCTAssertEqual(limiter.takeOverflowSummary(at: 6), 3)
        XCTAssertNil(limiter.takeOverflowSummary(at: 7))
        XCTAssertEqual(limiter.admit(key: "s5", message: "boom", tick: 6), .post,
                       "an overflowed notice is not recorded as shown, so it may appear on a later tick")
        XCTAssertEqual(limiter.admit(key: "s5", message: "boom", tick: 7), .suppressed, "once shown, its quiet window applies")
        XCTAssertEqual(limiter.admit(key: "fresh", message: "boom", tick: 6), .post, "the per-tick count resets")
    }

    func testOverflowSummaryAppearsAtMostOncePer200Ticks() {
        var limiter = ScriptNoticeLimiter()
        var summaries: [Int64] = []
        for tick in Int64(0)..<600 {
            if limiter.takeOverflowSummary(at: tick) != nil { summaries.append(tick) }
            for index in 0..<5 { _ = limiter.admit(key: "t\(tick)-\(index)", message: "boom", tick: tick) }
        }
        XCTAssertEqual(summaries, [1, 201, 401], "overflow on every tick still yields one summary per 200 ticks")
    }

    func testOverflowedFaultNoticeIsShownOnAFollowingTick() throws {
        let h = try makeHarness(seed: 407)
        for index in 0..<5 {
            try attachModule(h, "bad\(index)", "self:on(\"test.boom\", function(ev) error(\"boom\") end)")
        }
        step(h, tick: 1)
        h.state.eventBus.raise(kind: try XCTUnwrap(EventKind.parse("test.boom")), subject: .world, source: .engine, tick: 1)
        step(h, tick: 2)
        let failed = { h.chat.lines.filter { $0.contains(" failed: ") } }
        XCTAssertEqual(failed().count, 4, "\(h.chat.lines)")
        XCTAssertFalse(failed().contains { $0.hasPrefix("[script] bad4 ") }, "bad4 overflowed the 4-per-tick cap")
        h.state.eventBus.raise(kind: try XCTUnwrap(EventKind.parse("test.boom")), subject: .world, source: .engine, tick: 2)
        step(h, tick: 3)
        XCTAssertEqual(failed().last, "[script] bad4 on world failed: line 1: boom (/script show world bad4)", "\(h.chat.lines)")
        XCTAssertEqual(failed().count, 5, "the four already shown stay inside their quiet window")
    }

    func testBoundedNoticeLineOmitsADetailThatCannotFitEvenAnEllipsis() {
        for headBytes in 251...254 {
            let prefix = String(repeating: "p", count: headBytes - 3)
            let line = ScriptRuntime.boundedNoticeLine(prefix: prefix, detail: "too long to fit", suffix: " ()")
            XCTAssertLessThanOrEqual(line.utf8.count, 256)
            XCTAssertTrue(line.hasSuffix(" ()"), "the suffix always survives (\(headBytes)): \(line)")
            if 256 - headBytes < 3 { XCTAssertFalse(line.contains("…"), "no bare ellipsis (\(headBytes))") }
        }
        let fits = ScriptRuntime.boundedNoticeLine(prefix: String(repeating: "p", count: 251), detail: "ok", suffix: " ()")
        XCTAssertEqual(fits, String(repeating: "p", count: 251) + "ok ()", "a detail that fits is kept even in a tiny budget")
    }

    func testNoticeLimiterMemoryIsBounded() {
        var limiter = ScriptNoticeLimiter()
        for index in 0..<(ScriptNoticeLimiter.maxTrackedKeys * 3) {
            _ = limiter.admit(key: "script-\(index)", message: "boom", tick: Int64(index))
        }
        XCTAssertLessThanOrEqual(limiter.trackedKeyCount, ScriptNoticeLimiter.maxTrackedKeys)
    }

    func testManyFaultsInOneTickPostFourNoticesThenOneSummaryLine() throws {
        let h = try makeHarness(seed: 405)
        for index in 0..<6 {
            try attachModule(h, "bad\(index)", "error(\"boom\")")
        }
        step(h, tick: 1)
        XCTAssertEqual(h.chat.lines.filter { $0.contains(" failed: ") }.count, 4, "\(h.chat.lines)")
        step(h, tick: 2)
        XCTAssertEqual(h.chat.lines.last, "[script] …and 2 more script faults (/script list)")
        step(h, tick: 3)
        XCTAssertEqual(h.chat.lines.count, 5, "the summary is posted once")
    }

    func testRepeatedCallbackFaultIsRateLimitedButStillRecorded() throws {
        let h = try makeHarness(seed: 406)
        try attachModule(h, "flaky", "self:on(\"test.flaky\", function(ev) error(\"same\") end)")
        step(h, tick: 1)
        let kind = try XCTUnwrap(EventKind.parse("test.flaky"))
        for tick in Int64(2)...Int64(6) {
            h.state.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: tick)
            step(h, tick: tick)
        }
        XCTAssertEqual(h.chat.lines.filter { $0.hasPrefix("[script] flaky") }.count, 1)
        XCTAssertEqual(h.state.eventBus.recentEvents().filter { $0.kind == .scriptFaulted }.count, 5,
                       "rate limiting is presentation-only; every fault event is still raised")
        h.state.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: 1_202)
        step(h, tick: 1_202)
        XCTAssertEqual(h.chat.lines.filter { $0.hasPrefix("[script] flaky") }.count, 2)
    }

    // MARK: - C2 author line numbers

    func testRuntimeErrorReportsTheAuthorsLine() throws {
        let h = try makeHarness(seed: 410)
        try attachModule(h, "liner", "local a = 1\nlocal b = 2\nerror(\"boom\")")
        step(h, tick: 1)
        let lastError = try XCTUnwrap(h.scripts.get(.world, "liner")?.lastError)
        XCTAssertTrue(lastError.contains(":3:"), lastError)
    }

    func testHandlerSyntaxErrorLineAgreesBetweenValidatorAndLoad() throws {
        let h = try makeHarness(seed: 411)
        let source = "local ok = true\nlocal = 2"
        guard case .refused(_, _, _, let line) = h.runtime.validateSource(source, chunkName: "typo") else {
            return XCTFail("validator should refuse")
        }
        XCTAssertEqual(line, 2)
        _ = try h.scripts.attach(
            .world, name: "typo", source: source, mode: .handler,
            triggers: [Trigger(event: try XCTUnwrap(EventKind.parse("test.custom")), attribute: nil, target: .object(.world))],
            by: .player, tick: 0
        ).get()
        step(h, tick: 1)
        let lastError = try XCTUnwrap(h.scripts.get(.world, "typo")?.lastError)
        XCTAssertTrue(lastError.contains(":2:"), lastError)
    }

    func testEphemeralAndDryRunReportTheAuthorsLine() throws {
        let h = try makeHarness(seed: 412)
        guard case .failure(let run) = h.runtime.runEphemeral(source: "local a = 1\nerror(\"run\")", owner: .world) else {
            return XCTFail("run should fail")
        }
        XCTAssertTrue(run.contains(":2:"), run)
        guard case .failure(let dry) = h.runtime.dryRunOutcome(
            source: "local a = 1\n\nerror(\"dry\")", owner: .world, mode: .module
        ) else { return XCTFail("dry run should fail") }
        XCTAssertTrue(dry.contains(":3:"), dry)
    }

    func testWrapperKeepsParenthesisCommentAndEmptySourcesWorking() throws {
        let h = try makeHarness(seed: 413)
        try attachModule(h, "paren", "(function() world.attrs.paren_ran = true end)()")
        try attachModule(h, "comment", "-- leading comment\nworld.attrs.comment_ran = true")
        try attachModule(h, "block_comment", "--[[ long\ncomment ]] world.attrs.block_comment_ran = true")
        step(h, tick: 1)
        XCTAssertNil(h.scripts.get(.world, "paren")?.lastError)
        XCTAssertNil(h.scripts.get(.world, "comment")?.lastError)
        XCTAssertNil(h.scripts.get(.world, "block_comment")?.lastError)
        XCTAssertEqual(h.attributes.get(.world, "paren_ran"), .bool(true))
        XCTAssertEqual(h.attributes.get(.world, "comment_ran"), .bool(true))
        XCTAssertEqual(h.attributes.get(.world, "block_comment_ran"), .bool(true))
        XCTAssertEqual(ScriptRuntime.wrappedChunkSource("", mode: .module), "local self, world, player = ...; ")
        XCTAssertEqual(h.runtime.dryRunOutcome(source: "", owner: .world, mode: .module), .completed)
        XCTAssertFalse(ScriptRuntime.wrappedChunkSource("x", mode: .handler).contains("\n"))
    }

    // MARK: - C3 /script attach validation

    private func makeGame(_ label: String) -> GameCore {
        let game = PersistenceTestSupport.makeGame(owner: self, label: label)
        game.createWorld(name: label, seedText: "31", mode: GameMode.creative, difficulty: 2)
        return game
    }

    func testScriptAttachRefusesSyntaxErrorWithItsLineAndStoresNothing() {
        let game = makeGame("attach-syntax")
        let context = game.scriptingCommandContext()
        let result = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "bad", "module", "local ok = 1\nlocal = 2"], context: context
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.lines.first?.hasPrefix("attach refused — line 2: ") == true, "\(result.lines)")
        XCTAssertNil(context.scriptStore.get(.world, "bad"))

        let handler = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "bad", "handler", "test.go", "if then"], context: context
        )
        XCTAssertFalse(handler.ok)
        XCTAssertTrue(handler.lines.first?.hasPrefix("attach refused — line 1: ") == true, "\(handler.lines)")
        XCTAssertNil(context.scriptStore.get(.world, "bad"))
    }

    func testScriptAttachRunsTheLintAndEventLiteralChecks() {
        let game = makeGame("attach-lint")
        let context = game.scriptingCommandContext()
        let lint = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "bad", "module", "os.exit()"], context: context
        )
        XCTAssertFalse(lint.ok)
        XCTAssertTrue(lint.lines.first?.contains("os.exit") == true, "\(lint.lines)")

        let literal = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "bad", "module", "on(\"Bad.Event\", function() end)"], context: context
        )
        XCTAssertFalse(literal.ok)
        XCTAssertTrue(literal.lines.first?.contains("'Bad.Event' is not a valid event name") == true, "\(literal.lines)")
        XCTAssertNil(context.scriptStore.get(.world, "bad"))
    }

    func testScriptAttachValidatesWithScriptsSwitchedOffAndForGuests() {
        let game = makeGame("attach-gates")
        let context = game.scriptingCommandContext()
        context.setKillSwitch(false)
        let off = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "bad", "module", "local = 1"], context: game.scriptingCommandContext()
        )
        XCTAssertFalse(off.ok)
        let good = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "good", "module", "world.attrs.x = 1"],
            context: game.scriptingCommandContext()
        )
        XCTAssertTrue(good.ok, "\(good.lines)")

        let guest = game.scriptingCommandContext(guestPeerID: "guest1")
        let refused = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "guestbad", "module", "local = 1"], context: guest
        )
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.lines.first?.hasPrefix("attach refused — line 1: ") == true, "\(refused.lines)")
        XCTAssertNil(guest.scriptStore.get(.world, "guestbad"))
    }

    func testScriptAttachRepliesWithEventTypoHints() {
        let game = makeGame("attach-typo")
        let context = game.scriptingCommandContext()
        let handler = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "watch", "handler", "block.broke", "say(\"x\")"], context: context
        )
        XCTAssertTrue(handler.ok, "\(handler.lines)")
        XCTAssertTrue(handler.lines.contains("'block.broke' is not a built-in event — did you mean 'block.broken'?"), "\(handler.lines)")

        let module = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "mod", "module", "on(\"block.placed2\", function() end)"],
            context: context
        )
        XCTAssertTrue(module.ok, "\(module.lines)")
        XCTAssertTrue(module.lines.contains { $0.contains("did you mean 'block.placed'?") }, "\(module.lines)")

        let custom = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "lumber", "module", "on(\"lumber.milestone\", function() end)"],
            context: context
        )
        XCTAssertTrue(custom.ok)
        XCTAssertEqual(custom.lines.count, 1, "a distant custom event name is not a typo: \(custom.lines)")
    }

    // MARK: - C4 repeating closures

    func testEveryClosureFiresAtFiveTenAndFifteen() throws {
        let h = try makeHarness(seed: 420)
        try attachModule(h, "pulse", "every(5, function() world.attrs.beats = (world.attrs.beats or 0) + 1 end)")
        step(h, tick: 0)
        var observed: [Int64: AttrValue?] = [:]
        for tick in Int64(1)...Int64(16) {
            step(h, tick: tick)
            observed[tick] = h.attributes.get(.world, "beats")
        }
        XCTAssertEqual(observed[4] ?? nil, nil)
        XCTAssertEqual(observed[5] ?? nil, .int(1))
        XCTAssertEqual(observed[9] ?? nil, .int(1))
        XCTAssertEqual(observed[10] ?? nil, .int(2))
        XCTAssertEqual(observed[15] ?? nil, .int(3))
        XCTAssertEqual(observed[16] ?? nil, .int(3))
        XCTAssertNil(h.scripts.get(.world, "pulse")?.lastError)
    }

    func testEveryClosureStopsAfterDetachAndEdit() throws {
        let h = try makeHarness(seed: 421)
        try attachModule(h, "pulse", "every(1, function() world.attrs.beats = (world.attrs.beats or 0) + 1 end)")
        step(h, tick: 0)
        step(h, tick: 1)
        step(h, tick: 2)
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(2))
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 1)

        _ = try h.scripts.attach(.world, name: "pulse", source: "world.attrs.edited = true", mode: .module,
                                 triggers: [], by: .player, tick: 2).get()
        step(h, tick: 3)
        step(h, tick: 4)
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(2), "an edit retires the old closure timer")
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 0)

        try attachModule(h, "pulse", "every(1, function() world.attrs.beats2 = (world.attrs.beats2 or 0) + 1 end)")
        step(h, tick: 5)
        step(h, tick: 6)
        XCTAssertEqual(h.attributes.get(.world, "beats2"), .int(1))
        XCTAssertTrue(try h.scripts.detach(.world, "pulse").get())
        step(h, tick: 7)
        step(h, tick: 8)
        XCTAssertEqual(h.attributes.get(.world, "beats2"), .int(1))
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 0)
    }

    func testEveryClosureErrorStopsTheTimerAndRecordsAFault() throws {
        let h = try makeHarness(seed: 422)
        try attachModule(h, "fragile", """
        every(2, function()
          world.attrs.beats = (world.attrs.beats or 0) + 1
          if world.attrs.beats == 2 then error("second beat failed") end
        end)
        """)
        for tick in Int64(0)...Int64(12) { step(h, tick: tick) }
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(2))
        XCTAssertTrue(h.scripts.get(.world, "fragile")?.lastError?.contains("second beat failed") == true)
        XCTAssertTrue(h.scripts.get(.world, "fragile")?.lastError?.contains(":3:") == true)
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 0)
        XCTAssertTrue(h.chat.lines.contains { $0.hasPrefix("[script] fragile on world failed: line 3: second beat failed") })
    }

    func testEveryClosureFiringsEachGetAFreshCallbackBudget() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerTotalInstructions = 20_000
        let h = try makeHarness(seed: 423, budgets: budgets)
        try attachModule(h, "worker", """
        every(1, function()
          local n = 0
          for i = 1, 400 do n = n + i end
          world.attrs.beats = (world.attrs.beats or 0) + 1
        end)
        """)
        for tick in Int64(0)...Int64(30) { step(h, tick: tick) }
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(30))
        XCTAssertNil(h.scripts.get(.world, "worker")?.lastError, "30 firings exceed one callback's lifetime budget")
    }

    func testEveryClosureSkipsBeatsWhileItsPreviousFiringIsSuspended() throws {
        let h = try makeHarness(seed: 424)
        try attachModule(h, "slow", """
        every(2, function()
          world.attrs.starts = (world.attrs.starts or 0) + 1
          wait(5)
          world.attrs.ends = (world.attrs.ends or 0) + 1
        end)
        """)
        for tick in Int64(0)...Int64(14) { step(h, tick: tick) }
        // Starts at 2; 4 and 6 are skipped while it waits until 7; next start at 8 (wait to 13), then 14.
        XCTAssertEqual(h.attributes.get(.world, "starts"), .int(3))
        XCTAssertEqual(h.attributes.get(.world, "ends"), .int(2))
        XCTAssertLessThanOrEqual(h.runtime.summary.suspendedCoroutines, 1)
    }

    func testAfterStaysOneShotAndCancelStopsBothForms() throws {
        let h = try makeHarness(seed: 425)
        try attachModule(h, "timers", """
        after(2, function() world.attrs.after_runs = (world.attrs.after_runs or 0) + 1 end)
        local cancelled_after = after(3, function() world.attrs.cancelled_after = true end)
        world.attrs.after_id_is_number = type(cancelled_after) == "number"
        world.attrs.cancel_after = cancel(cancelled_after)
        local id = every(1, function() world.attrs.beats = (world.attrs.beats or 0) + 1 end)
        world.attrs.every_id_is_number = type(id) == "number"
        self:on("test.stop", function(ev) world.attrs.cancel_every = cancel(id); world.attrs.cancel_again = cancel(id) end)
        """)
        step(h, tick: 0)
        step(h, tick: 1)
        step(h, tick: 2)
        step(h, tick: 3)
        XCTAssertEqual(h.attributes.get(.world, "after_runs"), .int(1))
        XCTAssertNil(h.attributes.get(.world, "cancelled_after"))
        XCTAssertEqual(h.attributes.get(.world, "after_id_is_number"), .bool(true))
        XCTAssertEqual(h.attributes.get(.world, "every_id_is_number"), .bool(true))
        XCTAssertEqual(h.attributes.get(.world, "cancel_after"), .bool(true))
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(3))

        h.state.eventBus.raise(kind: try XCTUnwrap(EventKind.parse("test.stop")), subject: .world, source: .engine, tick: 3)
        step(h, tick: 4)
        let afterCancel = h.attributes.get(.world, "beats")
        step(h, tick: 5)
        step(h, tick: 6)
        XCTAssertEqual(h.attributes.get(.world, "beats"), afterCancel)
        XCTAssertEqual(h.attributes.get(.world, "cancel_every"), .bool(true))
        XCTAssertEqual(h.attributes.get(.world, "cancel_again"), .bool(false))
        for tick in Int64(7)...Int64(10) { step(h, tick: tick) }
        XCTAssertEqual(h.attributes.get(.world, "after_runs"), .int(1), "after stays one-shot")
    }

    func testCancellingAnotherSuspendedTimerInTheSamePassIsNotAFault() throws {
        let h = try makeHarness(seed: 428)
        try attachModule(h, "pair", """
        local victim
        after(2, function() world.attrs.cancelled = cancel(victim) end)
        victim = after(2, function() world.attrs.victim_ran = true end)
        """)
        step(h, tick: 0)
        step(h, tick: 1)
        step(h, tick: 2)
        XCTAssertEqual(h.attributes.get(.world, "cancelled"), .bool(true))
        XCTAssertNil(h.attributes.get(.world, "victim_ran"))
        XCTAssertNil(h.scripts.get(.world, "pair")?.lastError, "a run closed earlier in the same pass must be skipped")
        XCTAssertEqual(h.chat.lines, [])
    }

    func testRepeatingClosureCapIsACatchableError() throws {
        let h = try makeHarness(seed: 426)
        try attachModule(h, "greedy", """
        local accepted = 0
        for i = 1, 20 do
          local ok, err = pcall(every, 10, function() end)
          if ok then accepted = accepted + 1 else world.attrs.cap_error = err end
        end
        world.attrs.accepted = accepted
        """)
        step(h, tick: 0)
        XCTAssertEqual(h.attributes.get(.world, "accepted"), .int(Int64(ScriptClosureTimerRegistry.maxPerScript)))
        guard case .string(let message)? = h.attributes.get(.world, "cap_error") else { return XCTFail("missing cap error") }
        XCTAssertTrue(message.contains("limit 16"), message)
        XCTAssertNil(h.scripts.get(.world, "greedy")?.lastError)
    }

    func testDryRunValidatesTimerArgumentsAndSchedulesNothing() throws {
        let h = try makeHarness(seed: 427)
        XCTAssertEqual(
            h.runtime.dryRunOutcome(source: "local id = every(5, function() end); cancel(id)", owner: .world, mode: .module),
            .completed
        )
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 0)
        XCTAssertEqual(h.runtime.summary.suspendedCoroutines, 0)
        guard case .failure = h.runtime.dryRunOutcome(source: "every(0, function() end)", owner: .world, mode: .module) else {
            return XCTFail("a non-positive interval must fail Check")
        }
        guard case .failure = h.runtime.dryRunOutcome(source: "every(5, 42)", owner: .world, mode: .module) else {
            return XCTFail("a non-callable handler must fail Check")
        }
        guard case .failure = h.runtime.dryRunOutcome(source: "cancel(\"x\")", owner: .world, mode: .module) else {
            return XCTFail("cancel requires a numeric id")
        }
    }

    // MARK: - C5 typo guards

    func testEditDistanceIsDamerauBoundedAndDeterministic() {
        XCTAssertEqual(ScriptNameSuggestions.editDistance("block.broke", "block.broken"), 1)
        XCTAssertEqual(ScriptNameSuggestions.editDistance("helth", "health"), 1)
        XCTAssertEqual(ScriptNameSuggestions.editDistance("healht", "health"), 1, "a transposition is one edit")
        XCTAssertEqual(ScriptNameSuggestions.editDistance("", "abc"), 3)
        XCTAssertNil(ScriptNameSuggestions.editDistance(String(repeating: "a", count: 65), "a"))
        XCTAssertEqual(ScriptNameSuggestions.nearestBuiltInEvent(to: "block.broke"), "block.broken")
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInEvent(to: "lumber.milestone"))
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInEvent(to: "block.broken"), "an exact built-in is not a typo")
        XCTAssertEqual(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .entity, to: "helth"), "health")
        XCTAssertEqual(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .entity, to: "maxHelth"), "max_health")
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .entity, to: "hp"), "two-letter names are never near misses")
        // The attribute typo warning is stricter than the event warning: short names need a
        // swapped pair or (from five characters) a single edit; two edits need eight.
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .entity, to: "helht"))
        XCTAssertEqual(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .entity, to: "max_helht"), "max_health")
        XCTAssertEqual(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .block, to: "opne"), "open")
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .block, to: "hit"), "an ordinary custom name beside 'lit'")
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .block, to: "home"), "an ordinary custom name beside 'mode'")
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .block, to: "opn"), "a single edit on a short name is not enough")
        XCTAssertTrue(ScriptNameSuggestions.isLikelyTypo("lti", "lit"))
        XCTAssertFalse(ScriptNameSuggestions.isLikelyTypo("health", "health"))
        XCTAssertFalse(ScriptNameSuggestions.isNearMiss("hlth", "health"), "four-letter names allow one edit")
        XCTAssertEqual(ScriptNameSuggestions.editDistance("helthh", "health"), 2)
        XCTAssertTrue(ScriptNameSuggestions.isNearMiss("helthh", "health"), "longer names allow two edits")
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .world, to: "mood"))
    }

    func testOnWithATypoOfABuiltInStillSubscribesButWarnsOnce() throws {
        let h = try makeHarness(seed: 430)
        try attachModule(h, "greeter", "on(\"block.broke\", function(ev) end)")
        step(h, tick: 1)
        XCTAssertEqual(h.state.eventBus.scriptOwnedSubscriptionCount, 1, "open custom events still subscribe")
        XCTAssertEqual(
            h.chat.lines.filter { $0.contains("is not a built-in event") },
            ["[script] greeter: 'block.broke' is not a built-in event — did you mean 'block.broken'?"]
        )
        XCTAssertNil(h.scripts.get(.world, "greeter")?.lastError)
    }

    func testDeclaredOrDistantCustomEventsDoNotWarn() throws {
        let h = try makeHarness(seed: 431)
        try attachModule(h, "declared", """
        self:declareEvent("block.broke", {})
        on("block.broke", function(ev) end)
        subscribe(world, "lumber.milestone", function(ev) end)
        self:on("attribute.changed", function(ev) end)
        """)
        step(h, tick: 1)
        XCTAssertFalse(h.chat.lines.contains { $0.contains("is not a built-in event") }, "\(h.chat.lines)")
        XCTAssertNil(h.scripts.get(.world, "declared")?.lastError)
    }

    func testHandlerAttachWithATypoTriggerWarnsOnLoad() throws {
        let h = try makeHarness(seed: 432)
        _ = try h.scripts.attach(
            .world, name: "watch", source: "world.attrs.ran = true", mode: .handler,
            triggers: [Trigger(event: try XCTUnwrap(EventKind.parse("entity.dyed")), attribute: nil, target: .object(.world))],
            by: .player, tick: 0
        ).get()
        step(h, tick: 1)
        XCTAssertTrue(
            h.chat.lines.contains("[script] watch: 'entity.dyed' is not a built-in event — did you mean 'entity.died'?"),
            "\(h.chat.lines)"
        )
    }

    func testOnCommandRepliesWithTheTypoHint() {
        let game = makeGame("on-typo")
        let result = ScriptingCommands.run(
            command: "on", arguments: ["world", "player.joind", "brain.joined"], context: game.scriptingCommandContext()
        )
        XCTAssertTrue(result.ok, "\(result.lines)")
        XCTAssertTrue(result.lines.contains("'player.joind' is not a built-in event — did you mean 'player.joined'?"), "\(result.lines)")
        let exact = ScriptingCommands.run(
            command: "on", arguments: ["world", "lumber.milestone", "brain.lumber"], context: game.scriptingCommandContext()
        )
        XCTAssertEqual(exact.lines.count, 1)
    }

    func testDotSugarTypoOfABuiltInWritesTheAttributeAndWarnsOnce() throws {
        let h = try makeHarness(seed: 433, withPlayer: true)
        let world = try XCTUnwrap(h.host.worldsByDim[.overworld])
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        _ = world.setBlock(1, 64, 1, Int(cell(B.stone)))
        let block = ObjectRef.block(dim: .overworld, x: 1, y: 64, z: 1)
        try attachModule(h, "greeter", "player.helth = 5\nplayer.mood = 1", on: block)
        step(h, tick: 1)
        XCTAssertNil(h.scripts.get(block, "greeter")?.lastError)
        XCTAssertEqual(h.attributes.get(.player, "helth"), .int(5), "the write succeeds exactly as before the guard")
        XCTAssertEqual(h.attributes.get(.player, "mood"), .int(1))
        let warnings = { h.chat.lines.filter { $0.contains("is not a built-in attribute") } }
        XCTAssertEqual(warnings(), [
            "[script] greeter on block:overworld:1,64,1: 'helth' is not a built-in attribute — did you mean 'health'? (h.attrs.helth is the custom form)",
        ], "one warning for the typo and none for an ordinary name: \(h.chat.lines)")

        // An existing attribute, `h:set`, and `h.attrs` never warn; neither does Check.
        try attachModule(h, "later", """
        player.helth = 6
        player:set("max_helht", 1)
        player.attrs.maxHelth = 2
        """)
        step(h, tick: 2)
        XCTAssertNil(h.scripts.get(.world, "later")?.lastError)
        XCTAssertEqual(h.attributes.get(.player, "helth"), .int(6))
        XCTAssertEqual(warnings().count, 1, "\(h.chat.lines)")
        let before = h.chat.lines
        XCTAssertEqual(h.runtime.dryRunOutcome(source: "player.maxHealht = 30", owner: .world, mode: .module), .completed)
        XCTAssertEqual(h.chat.lines, before, "Check never warns")
    }

    func testDotSugarTypoWrittenDuringUnloadNeitherChecksNorWarns() throws {
        let h = try makeHarness(seed: 435, withPlayer: true)
        try attachModule(h, "leaving", "register(\"unload\", function() player.helth = 3 end)")
        step(h, tick: 1)
        XCTAssertTrue(try h.scripts.detach(.world, "leaving").get())
        step(h, tick: 2)
        XCTAssertEqual(h.attributes.get(.player, "helth"), .int(3), "unload may still write custom attributes")
        XCTAssertEqual(h.runtime.attributeTypoChecks.checksPerformed, 0)
        XCTAssertFalse(h.chat.lines.contains { $0.contains("is not a built-in attribute") }, "\(h.chat.lines)")
    }

    func testDotSugarKeepsWorkingForExistingFarAndExplicitCustomAttributes() throws {
        let h = try makeHarness(seed: 434, withPlayer: true)
        _ = try h.attributes.set(.player, "helth", .int(1), by: .player).get()
        try attachModule(h, "ok", """
        player.helth = 5
        world.mood = "calm"
        world:set("raning", true)
        world.attrs.thunderin = true
        """)
        step(h, tick: 1)
        XCTAssertNil(h.scripts.get(.world, "ok")?.lastError)
        XCTAssertEqual(h.attributes.get(.player, "helth"), .int(5))
        XCTAssertEqual(h.attributes.get(.world, "mood"), .string("calm"))
        XCTAssertEqual(h.attributes.get(.world, "raning"), .bool(true))
        XCTAssertEqual(h.attributes.get(.world, "thunderin"), .bool(true))
    }

    // MARK: - C6 help text (Core half)

    func testScriptingHelpLinesAreShortAndCoverTheBasics() {
        let summary = ScriptingCommands.helpSummary()
        for command in ["script", "on", "unsubscribe", "events"] {
            XCTAssertTrue(summary.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(command))
        }
        let lines = ScriptingCommands.scriptHelpLines()
        XCTAssertGreaterThan(lines.count, 2)
        for line in lines { XCTAssertLessThanOrEqual(line.count, 100, line) }
        let text = lines.joined(separator: "\n")
        for needle in ["/script edit", "Command-E", "/script attach", "/script list", "Inspector", "docs/SCRIPTING_GUIDE.md"] {
            XCTAssertTrue(text.contains(needle), "missing \(needle)")
        }
    }

    func testScriptUsageMentionsEdit() {
        let game = makeGame("usage-edit")
        let result = ScriptingCommands.run(command: "script", arguments: [], context: game.scriptingCommandContext())
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.lines.joined(separator: " ").contains("edit [target] [name]"), "\(result.lines)")
        XCTAssertFalse(result.lines.contains { $0.hasSuffix("…") }, "the usage must not be truncated: \(result.lines)")
    }
}
