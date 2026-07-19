import XCTest
@preconcurrency @testable import ElysiumCore

@MainActor
final class RPGLocalPreferencesTests: XCTestCase {
    private enum InjectedFailure: Error { case write }

    private func waitUntil(
        timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for RPG preference lifecycle", file: file, line: line)
    }

    private func makeDatabase(_ label: String) throws -> SaveDB {
        try PersistenceTestSupport.makeDatabase(owner: self, label: "rpg-lifecycle-\(label)")
    }

    @discardableResult
    private func installLegacyPlayer(
        in database: SaveDB, id: String, seed: Int32,
        slots: [Any] = ["spell:ignite"]
    ) throws -> WorldRecord {
        let record = WorldRecord(id: id, name: "Legacy", seed: seed,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let player = Player(world: World(dim: .overworld, seed: UInt32(bitPattern: seed)))
        player.rpg = try rpgCreateCharacter(RPGCreationDraft(
            pathID: "arcanist",
            starterSkillID: "spell_formula", starterSpellIDs: ["ignite"])).get()
        var playerJSON = player.save()
        var rpg = try XCTUnwrap(playerJSON["rpg"] as? [String: Any])
        rpg["actionQuickSlots"] = slots
        playerJSON["rpg"] = rpg
        database.putPlayer(record.id, ["dim": 0, "data": playerJSON])
        return record
    }

    func testScopeValidationAndCanonicalRoundTrips() throws {
        let local = try RPGLocalPreferenceScope.validatedLocalWorld("world-record-1")
        let host = try LANHostInstallationIDV6(bytes: Array(0..<16))
        let world = try LANWorldIDV6(bytes: Array(16..<32))
        let lan = RPGLocalPreferenceScope.lanV6(hostInstallationID: host, worldLANID: world)
        for scope in [local, lan] {
            let data = try JSONEncoder().encode(scope)
            XCTAssertEqual(try JSONDecoder().decode(RPGLocalPreferenceScope.self, from: data), scope)
        }
        XCTAssertThrowsError(try RPGLocalPreferenceScope.validatedLocalWorld(""))
        XCTAssertThrowsError(try RPGLocalPreferenceScope.validatedLocalWorld(String(repeating: "x", count: 65)))
    }

    func testNormalizationReducersAndDigestsArePure() throws {
        var state = try XCTUnwrap(rpgScreenFixture(pathID: "arcanist", branchID: "arcanist_elementalist"))
        if !state.preparedSpellIDs.contains("ignite") { XCTAssertNil(rpgPrepareSpell("ignite", in: &state)) }
        state = repairRPGCharacterState(state)
        let token = rpgPreparedActionToken(kind: .spell, id: "ignite")
        let raw = RPGQuickSlotPreferences(tokens: [token, token, "spell:missing", nil])
        let normalized = rpgNormalizeQuickSlotPreferences(raw, against: state)
        XCTAssertEqual(normalized.tokens.count, 9)
        XCTAssertEqual(normalized.tokens[0], token)
        XCTAssertNil(normalized.tokens[1])
        XCTAssertNil(normalized.tokens[2])

        let assigned = try rpgAssignQuickSlot(token: token, slot: 8, preferences: .empty, state: state).get()
        XCTAssertEqual(assigned.tokens[8], token)
        let moved = try rpgMoveQuickSlot(from: 8, to: 4, preferences: assigned, state: state).get()
        XCTAssertEqual(moved.tokens[4], token)
        let cleared = try rpgClearQuickSlot(4, preferences: moved, state: state).get()
        XCTAssertEqual(cleared, .empty)
        XCTAssertEqual(rpgQuickSlotActions(state: state, preferences: assigned)[8]?.id, "ignite")

        let scope = try RPGLocalPreferenceScope.validatedLocalWorld("world-record-1")
        let sourceA = try rpgLegacyQuickSlotSourceDigest(assigned)
        let sourceB = try rpgLegacyQuickSlotSourceDigest(assigned)
        XCTAssertEqual(sourceA, sourceB)
        let destinationA = try rpgQuickSlotDestinationDigest(scope: scope, preferences: assigned, revision: 1)
        let destinationB = try rpgQuickSlotDestinationDigest(scope: scope, preferences: assigned, revision: 2)
        XCTAssertNotEqual(sourceA, destinationA)
        XCTAssertNotEqual(destinationA, destinationB)
    }

    func testPreferenceDecoderRejectsWrongShapeAndInvalidTokens() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(RPGQuickSlotPreferences.self,
                                                       from: Data("[null]".utf8)))
        let invalid = "[\"spell:" + String(repeating: "x", count: 129) + "\",null,null,null,null,null,null,null,null]"
        XCTAssertThrowsError(try JSONDecoder().decode(RPGQuickSlotPreferences.self,
                                                       from: Data(invalid.utf8)))
    }

    func testStorageCodecIsStrictAndRejectsLANDestinationScope() throws {
        let preferences = RPGQuickSlotPreferences(tokens: ["skill:power_strike", nil,
                                                            "spell:ignite"])
        let payload = try rpgEncodeQuickSlotPreferencesStoragePayload(preferences)
        XCTAssertEqual(Array(payload.prefix(6)), Array("PBLQS1".utf8))
        XCTAssertEqual(try rpgDecodeQuickSlotPreferencesStoragePayload(payload), preferences)
        XCTAssertThrowsError(try rpgDecodeQuickSlotPreferencesStoragePayload(payload + Data([0])))
        XCTAssertThrowsError(try rpgEncodeQuickSlotPreferencesStoragePayload(
            RPGQuickSlotPreferences(tokens: ["skill:power_strike", "skill:power_strike"])))

        let host = try LANHostInstallationIDV6(bytes: Array(0..<16))
        let world = try LANWorldIDV6(bytes: Array(16..<32))
        XCTAssertThrowsError(try rpgQuickSlotDestinationDigest(
            scope: .lanV6(hostInstallationID: host, worldLANID: world),
            preferences: preferences, revision: 1))
    }

    func testSaveDBLocalPreferenceAdapterMaterializesAndCASes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ElysiumRPGAdapter-\(UUID().uuidString).sqlite")
        var database: SaveDB? = try SaveDB.open(databaseURL: url, migrateLegacy: false)
        database!.putWorld(WorldRecord(id: "adapter-world", name: "Adapter", seed: 1,
                                       gameMode: 0, difficulty: 1))
        let initialPreferences = RPGQuickSlotPreferences(tokens: ["skill:power_strike"])
        let initial = try database!.materializeRPGQuickSlotPreferences(
            worldRecordID: "adapter-world", defaults: initialPreferences)
        XCTAssertEqual(initial.revision, 1)
        XCTAssertEqual(initial.preferences, initialPreferences)
        XCTAssertEqual(SaveDB._testLastRPGDecodeRank(), 0)

        let replacement = RPGQuickSlotPreferences(tokens: [nil, "spell:ignite"])
        let updated = try database!.compareAndSwapRPGQuickSlotPreferences(
            worldRecordID: "adapter-world", expected: initial,
            candidatePreferences: replacement)
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.preferences, replacement)
        XCTAssertEqual(SaveDB._testLastRPGDecodeRank(), 0)

        database!.putWorld(WorldRecord(id: "legacy-adapter-world", name: "Legacy", seed: 2,
                                       gameMode: 0, difficulty: 1))
        let legacy = RPGQuickSlotPreferences(tokens: ["spell:ignite"])
        let migrated = try database!.materializeLegacyRPGQuickSlotPreferences(
            worldRecordID: "legacy-adapter-world", legacy: legacy)
        XCTAssertTrue(migrated.insertedDestination)
        XCTAssertEqual(migrated.snapshot.preferences, legacy)
        let repeated = try database!.materializeLegacyRPGQuickSlotPreferences(
            worldRecordID: "legacy-adapter-world", legacy: legacy)
        XCTAssertFalse(repeated.insertedDestination)
        XCTAssertEqual(repeated.snapshot, migrated.snapshot)
        try database!.close(); database = nil

        let reopened = try SaveDB.open(databaseURL: url, migrateLegacy: false)
        XCTAssertEqual(try reopened.loadRPGQuickSlotPreferences(
            worldRecordID: "adapter-world"), updated)
        try reopened.close()
    }

    func testGameCoreLoadsMissingThenMaterializesDefaultsAndCASPublishesOnlyAfterCommit() throws {
        let database = try makeDatabase("default-cas")
        let game = GameCore(db: database)
        let host = RPGLocalPreferenceTestHost(); game.host = host
        game.createWorld(name: "Defaults", seedText: "991", mode: GameMode.survival,
                         difficulty: 1)
        let draft = RPGCreationDraft(
            pathID: "arcanist",
            starterSkillID: "spell_formula", starterSpellIDs: ["ignite"])
        XCTAssertTrue(game.requestRPGCreateCharacter(draft).hasPrefix("Created"))
        waitUntil { game.rpgLocalPreferenceRevision == 1 }
        XCTAssertEqual(host.preferenceRefreshes.last?.localPreferenceRevision, 1)
        XCTAssertFalse(try XCTUnwrap(host.preferenceRefreshes.last).persistenceFailed)
        let defaults = try XCTUnwrap(game.rpgQuickSlotPreferences)
        XCTAssertEqual(defaults.tokens[0], "spell:ignite")
        let context = try XCTUnwrap(game._testLastRPGLocalPreferenceContext)
        XCTAssertGreaterThan(context.worldEntryGeneration, 0)
        XCTAssertGreaterThan(context.operationID, 0)
        XCTAssertEqual(context.expectedLiveRevision, .absent)

        let stateBefore = game.player.rpg
        let inventoryBefore = game.player.inventory.map {
            $0.map { "\($0.id):\($0.count):\($0.damage)" }
        }
        let message = game.requestRPGAssignPreparedActionToQuickSlot(
            kind: .spell, id: "ignite", slot: 8)
        XCTAssertTrue(message.hasPrefix("Saving slot"))
        XCTAssertEqual(game.rpgQuickSlotPreferences, defaults,
                       "candidate must not publish before storage completion")
        waitUntil { game.rpgLocalPreferenceRevision == 2 }
        XCTAssertEqual(host.preferenceRefreshes.last?.localPreferenceRevision, 2)
        XCTAssertFalse(try XCTUnwrap(host.preferenceRefreshes.last).persistenceFailed)
        XCTAssertEqual(game.rpgQuickSlotPreferences?.tokens[8], "spell:ignite")
        XCTAssertNil(game.rpgQuickSlotPreferences?.tokens[0])
        XCTAssertEqual(game.player.rpg, stateBefore)
        XCTAssertEqual(game.player.inventory.map {
            $0.map { "\($0.id):\($0.count):\($0.damage)" }
        },
                       inventoryBefore)
        XCTAssertEqual(game._testLastRPGLocalPreferenceContext?.expectedLiveRevision, .exact(1))
        XCTAssertEqual(try database.loadRPGQuickSlotPreferences(
            worldRecordID: try XCTUnwrap(game.worldRec?.id))?.preferences,
                       game.rpgQuickSlotPreferences)
    }

    func testDelayedDefaultDoesNotPublishBeforeItsOwnCommit() throws {
        let database = try makeDatabase("delayed-default")
        let game = GameCore(db: database)
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "default materialization delayed")
        let lock = NSLock()
        var operationCount = 0
        game._testRPGLocalPreferenceBeforeIO = { _ in
            lock.lock(); operationCount += 1; let isDefault = operationCount == 2; lock.unlock()
            if isDefault { entered.fulfill(); gate.wait() }
        }
        game.createWorld(name: "Delayed Default", seedText: "992",
                         mode: GameMode.survival, difficulty: 1)
        XCTAssertTrue(game.requestRPGCreateCharacter(RPGCreationDraft(
            pathID: "arcanist",
            starterSkillID: "spell_formula", starterSpellIDs: ["ignite"])
        ).hasPrefix("Created"))
        wait(for: [entered], timeout: 2)
        XCTAssertNil(game.rpgQuickSlotPreferences)
        XCTAssertNil(try database.loadRPGQuickSlotPreferences(
            worldRecordID: try XCTUnwrap(game.worldRec?.id)))
        gate.signal()
        waitUntil { game.rpgLocalPreferenceRevision == 1 }
        XCTAssertEqual(game.rpgQuickSlotPreferences?.tokens[0], "spell:ignite")
    }

    func testLegacyMigrationReceiptPublishesAndOnlyThenAllowsPlayerKeyOmission() throws {
        let database = try makeDatabase("legacy")
        let record = WorldRecord(id: "legacy-world", name: "Legacy", seed: 41,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let state = try rpgCreateCharacter(RPGCreationDraft(
            pathID: "arcanist",
            starterSkillID: "spell_formula", starterSpellIDs: ["ignite"])).get()
        let player = Player(world: World(dim: .overworld, seed: 41))
        player.rpg = state
        var playerJSON = player.save()
        var rpgJSON = try XCTUnwrap(playerJSON["rpg"] as? [String: Any])
        rpgJSON["actionQuickSlots"] = ["spell:ignite", NSNull(), NSNull(), NSNull(),
                                         NSNull(), NSNull(), NSNull(), NSNull(), NSNull()]
        playerJSON["rpg"] = rpgJSON
        database.putPlayer(record.id, ["dim": 0, "data": playerJSON])

        let game = GameCore(db: database)
        game.loadWorld(record.id)
        XCTAssertNotNil((game.player.save()["rpg"] as? [String: Any])?["actionQuickSlots"])
        waitUntil {
            game.rpgLocalPreferenceRevision == 1
                && game.player.rpgLegacyQuickSlotEnvelope?.omissionEligible == true
        }
        let envelope = try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope)
        XCTAssertTrue(envelope.omissionEligible)
        XCTAssertNil((game.player.save()["rpg"] as? [String: Any])?["actionQuickSlots"])
        XCTAssertNil((((try database.getPlayerChecked(record.id))?.data["data"]
            as? [String: Any])?["rpg"] as? [String: Any])?["actionQuickSlots"])
        let stored = try XCTUnwrap(database.loadRPGQuickSlotPreferences(worldRecordID: record.id))
        XCTAssertEqual(stored.preferences.tokens[0], "spell:ignite")
        XCTAssertEqual(stored.migrationOriginDigest, stored.digest)
        XCTAssertEqual(stored.migrationOriginRevision, stored.revision)
    }

    func testChangedLegacyEnvelopeDiscardsCommittedOldReceiptWithoutOmissionOrPublish() throws {
        let database = try makeDatabase("legacy-replaced")
        let record = WorldRecord(id: "legacy-replaced-world", name: "Legacy", seed: 42,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let state = try rpgCreateCharacter(RPGCreationDraft(
            pathID: "arcanist",
            starterSkillID: "spell_formula", starterSpellIDs: ["ignite"])).get()
        let player = Player(world: World(dim: .overworld, seed: 42)); player.rpg = state
        var playerJSON = player.save()
        var rpgJSON = try XCTUnwrap(playerJSON["rpg"] as? [String: Any])
        rpgJSON["actionQuickSlots"] = ["spell:ignite"]
        playerJSON["rpg"] = rpgJSON
        database.putPlayer(record.id, ["dim": 0, "data": playerJSON])

        let game = GameCore(db: database)
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "legacy operation delayed")
        game._testRPGLocalPreferenceBeforeIO = { _ in entered.fulfill(); gate.wait() }
        game.loadWorld(record.id)
        wait(for: [entered], timeout: 2)
        let original = try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope)
        var replacementSave = game.player.save()
        var replacementRPG = try XCTUnwrap(replacementSave["rpg"] as? [String: Any])
        replacementRPG["actionQuickSlots"] = [NSNull(), "spell:mage_light"]
        replacementSave["rpg"] = replacementRPG
        game.player.load(replacementSave)
        let replacement = try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope)
        XCTAssertGreaterThan(replacement.envelopeVersion, original.envelopeVersion)
        XCTAssertNotEqual(replacement.sourceDigest, original.sourceDigest)
        gate.signal()
        waitUntil { (try? database.loadRPGQuickSlotPreferences(worldRecordID: record.id)) != nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(game.rpgQuickSlotPreferences)
        XCTAssertFalse(try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope).omissionEligible)
        XCTAssertNotNil((game.player.save()["rpg"] as? [String: Any])?["actionQuickSlots"])
        XCTAssertEqual(game.rpgLocalPreferenceFailureCount, 0)
    }

    func testLegacyEnvelopeVersionAndSourceMismatchAreIndependentlyRejected() throws {
        var envelope = try RPGLegacyQuickSlotEnvelope(
            preferences: RPGQuickSlotPreferences(tokens: ["spell:ignite"]),
            envelopeVersion: 8)
        XCTAssertFalse(envelope.markOmissionEligible(
            envelopeVersion: 9, sourceDigest: envelope.sourceDigest))
        XCTAssertFalse(envelope.omissionEligible)
        let otherSource = try rpgLegacyQuickSlotSourceDigest(
            RPGQuickSlotPreferences(tokens: ["spell:mage_light"]))
        XCTAssertFalse(envelope.markOmissionEligible(
            envelopeVersion: 8, sourceDigest: otherSource))
        XCTAssertFalse(envelope.omissionEligible)
        XCTAssertTrue(envelope.markOmissionEligible(
            envelopeVersion: 8, sourceDigest: envelope.sourceDigest))
    }

    func testGameCoreRejectsLegacyReceiptWithMissingImmutableOrigin() throws {
        let database = try makeDatabase("origin-mismatch")
        let record = WorldRecord(id: "origin-mismatch-world", name: "Origin", seed: 43,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let player = Player(world: World(dim: .overworld, seed: 43))
        player.rpg = try rpgCreateCharacter(RPGCreationDraft(
            pathID: "arcanist",
            starterSkillID: "spell_formula", starterSpellIDs: ["ignite"])).get()
        var playerJSON = player.save()
        var rpgJSON = try XCTUnwrap(playerJSON["rpg"] as? [String: Any])
        rpgJSON["actionQuickSlots"] = ["spell:ignite"]
        playerJSON["rpg"] = rpgJSON
        database.putPlayer(record.id, ["dim": 0, "data": playerJSON])

        let game = GameCore(db: database)
        game._testRPGLegacyMigrationResultTransform = { receipt in
            RPGLegacyQuickSlotMigrationResult(
                snapshot: RPGQuickSlotStorageSnapshot(
                    preferences: receipt.snapshot.preferences,
                    revision: receipt.snapshot.revision,
                    digest: receipt.snapshot.digest,
                    migrationOriginDigest: nil,
                    migrationOriginRevision: nil),
                sourceDigest: receipt.sourceDigest,
                insertedDestination: receipt.insertedDestination)
        }
        game.loadWorld(record.id)
        waitUntil { (try? database.loadRPGQuickSlotPreferences(worldRecordID: record.id)) != nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(game.rpgQuickSlotPreferences)
        XCTAssertFalse(try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope).omissionEligible)
        XCTAssertEqual(game.rpgLocalPreferenceFailureCount, 0)
    }

    func testCrashCutBeforePlayerCASRetainsKeyThenRestartPublishesAdvancedDestinationAndOmits() throws {
        let database = try makeDatabase("advanced-origin")
        let record = WorldRecord(id: "advanced-origin-world", name: "Advanced", seed: 44,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let player = Player(world: World(dim: .overworld, seed: 44))
        player.rpg = try rpgCreateCharacter(RPGCreationDraft(
            pathID: "arcanist",
            starterSkillID: "spell_formula", starterSpellIDs: ["ignite"])).get()
        var durableLegacyPlayer = player.save()
        var rpgJSON = try XCTUnwrap(durableLegacyPlayer["rpg"] as? [String: Any])
        rpgJSON["actionQuickSlots"] = ["spell:ignite"]
        durableLegacyPlayer["rpg"] = rpgJSON
        database.putPlayer(record.id, ["dim": 0, "data": durableLegacyPlayer])

        let omissionBarrier = database._testArmPlayerCASBarrier(.beforeFacade)
        let conflictWritten = expectation(description: "newer player row written at CAS barrier")
        DispatchQueue.global().async {
            guard omissionBarrier.waitUntilReached() else {
                XCTFail("checked player CAS did not reach before-facade barrier")
                omissionBarrier.resume()
                conflictWritten.fulfill()
                return
            }
            do {
                let revisionOne = try XCTUnwrap(database.loadRPGQuickSlotPreferences(
                    worldRecordID: record.id))
                let advanced = try database.compareAndSwapRPGQuickSlotPreferences(
                    worldRecordID: record.id, expected: revisionOne,
                    candidatePreferences: RPGQuickSlotPreferences(
                        tokens: [nil, "spell:ignite"]))
                XCTAssertEqual(advanced.revision, 2)
                XCTAssertNotEqual(advanced.migrationOriginDigest, advanced.digest)
                XCTAssertEqual(advanced.migrationOriginRevision, 1)
                var crashRow = try XCTUnwrap(database.getPlayer(record.id))
                crashRow["crashCut"] = true
                database.putPlayer(record.id, crashRow)
            } catch {
                XCTFail("could not install the conflicting crash-cut row: \(error)")
            }
            omissionBarrier.resume()
            conflictWritten.fulfill()
        }
        let first = GameCore(db: database)
        let host = RPGLocalPreferenceTestHost(); first.host = host
        first.loadWorld(record.id)
        wait(for: [conflictWritten], timeout: 5)
        waitUntil { first.rpgLocalPreferencePersistenceFailed }
        XCTAssertEqual(host.actionBars.last, "Could not save RPG quick slots")
        XCTAssertNotNil((((try database.getPlayerChecked(record.id))?.data["data"]
            as? [String: Any])?["rpg"] as? [String: Any])?["actionQuickSlots"])
        let advanced = try XCTUnwrap(database.loadRPGQuickSlotPreferences(
            worldRecordID: record.id))
        XCTAssertEqual(advanced.revision, 2)

        let restarted = GameCore(db: database)
        restarted.loadWorld(record.id)
        waitUntil {
            restarted.rpgLocalPreferenceRevision == advanced.revision
                && restarted.player.rpgLegacyQuickSlotEnvelope?.omissionEligible == true
        }
        XCTAssertEqual(restarted.rpgQuickSlotPreferences, advanced.preferences)
        XCTAssertTrue(try XCTUnwrap(restarted.player.rpgLegacyQuickSlotEnvelope).omissionEligible)
        XCTAssertNil((((try database.getPlayerChecked(record.id))?.data["data"]
            as? [String: Any])?["rpg"] as? [String: Any])?["actionQuickSlots"])

        let reloaded = GameCore(db: database)
        reloaded.loadWorld(record.id)
        waitUntil { reloaded.rpgLocalPreferenceRevision == advanced.revision }
        XCTAssertNil(reloaded.player.rpgLegacyQuickSlotEnvelope)
        XCTAssertEqual(reloaded.rpgQuickSlotPreferences, advanced.preferences)
    }

    func testTeardownBeforeFinalSegmentSkipsOmissionCASAndRetainsKey() throws {
        let database = try makeDatabase("teardown-before-final")
        let record = try installLegacyPlayer(
            in: database, id: "teardown-before-final-world", seed: 50)
        let game = GameCore(db: database)
        game._testRPGCheckedPlayerOmissionBeforeFinalSegment = { [weak game] in
            game?._testRPGCheckedPlayerOmissionBeforeFinalSegment = nil
            game?.exitToTitle()
        }
        game.loadWorld(record.id)
        waitUntil { !game.inWorld }
        XCTAssertEqual(game._testRPGCheckedPlayerOmissionFinalSegmentCount, 0)
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
        XCTAssertEqual(game.rpgLocalPreferenceFailureCount, 0)
    }

    func testPlayerCASBeforeFacadeHoldsMainUntilCommitThenTeardownRuns() throws {
        let database = try makeDatabase("teardown-during-final")
        let record = try installLegacyPlayer(
            in: database, id: "teardown-during-final-world", seed: 51)
        let barrier = database._testArmPlayerCASBarrier(.beforeFacade)
        let queued = expectation(description: "teardown queued while CAS holds main")
        let tornDown = expectation(description: "queued teardown completed")
        let game = GameCore(db: database)
        var events: [String] = []
        game._testRPGCheckedPlayerOmissionDidCommit = { events.append("commit") }
        game._testRPGWorldTeardownDidInvalidate = { events.append("teardown") }
        DispatchQueue.global().async {
            guard barrier.waitUntilReached() else {
                XCTFail("checked player CAS did not reach before-facade barrier")
                barrier.resume(); queued.fulfill()
                return
            }
            DispatchQueue.main.async {
                game.exitToTitle()
                tornDown.fulfill()
            }
            queued.fulfill()
            barrier.resume()
        }
        game.loadWorld(record.id)
        wait(for: [queued, tornDown], timeout: 5)
        XCTAssertEqual(events, ["commit", "teardown"])
        XCTAssertEqual(game._testRPGCheckedPlayerOmissionFinalSegmentCount, 1)
        XCTAssertFalse(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
    }

    func testPlayerCASAfterCommitFinishesOldPublicationBeforeLaterEnvelopeReplacement() throws {
        let database = try makeDatabase("replacement-after-commit")
        let record = try installLegacyPlayer(
            in: database, id: "replacement-after-commit-world", seed: 52)
        let barrier = database._testArmPlayerCASBarrier(.afterCommit)
        let replaced = expectation(description: "later envelope replacement persisted")
        let game = GameCore(db: database)
        var events: [String] = []
        game._testRPGCheckedPlayerOmissionDidCommit = { events.append("commit") }
        DispatchQueue.global().async {
            guard barrier.waitUntilReached() else {
                XCTFail("checked player CAS did not reach after-commit barrier")
                barrier.resume()
                return
            }
            DispatchQueue.main.async {
                events.append("replacement")
                var replacement = game.player.save(omitLegacyQuickSlots: true)
                var rpg = (replacement["rpg"] as? [String: Any]) ?? [:]
                rpg["actionQuickSlots"] = [NSNull(), "spell:mage_light"]
                replacement["rpg"] = rpg
                game.player.load(replacement)
                game.saveAndFlush(synchronous: true)
                replaced.fulfill()
            }
            barrier.resume()
        }
        game.loadWorld(record.id)
        wait(for: [replaced], timeout: 5)
        XCTAssertEqual(events, ["commit", "replacement"])
        XCTAssertFalse(try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope).omissionEligible)
        let durable = try XCTUnwrap(database.getPlayerChecked(record.id))
        XCTAssertTrue(playerSnapshotHasLegacySlots(durable))
        let slots = ((((durable.data["data"] as? [String: Any])?["rpg"]
            as? [String: Any])?["actionQuickSlots"] as? [Any]))
        XCTAssertEqual(slots?[1] as? String, "spell:mage_light")
    }

    func testEnvelopeReplacementDuringPlayerCASCannotMarkOrDropReplacementKey() throws {
        let database = try makeDatabase("player-envelope-replacement")
        let record = try installLegacyPlayer(
            in: database, id: "player-envelope-replacement-world", seed: 61)
        let game = GameCore(db: database)
        game._testRPGCheckedPlayerOmissionBeforeFinalSegment = { [weak game] in
            guard let game else { return }
            game._testRPGCheckedPlayerOmissionBeforeFinalSegment = nil
            var replacement = game.player.save()
            var rpg = (replacement["rpg"] as? [String: Any]) ?? [:]
            rpg["actionQuickSlots"] = [NSNull(), "spell:mage_light"]
            replacement["rpg"] = rpg
            game.player.load(replacement)
        }
        game.loadWorld(record.id)
        waitUntil {
            game.player.rpgLegacyQuickSlotEnvelope?.preferences.tokens[1]
                == "spell:mage_light"
        }
        XCTAssertEqual(game._testRPGCheckedPlayerOmissionFinalSegmentCount, 0)
        XCTAssertFalse(try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope).omissionEligible)
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
        game.saveAndFlush(synchronous: true)
        let durable = try XCTUnwrap(database.getPlayerChecked(record.id))
        XCTAssertTrue(playerSnapshotHasLegacySlots(durable))
        let durableSlots = ((((durable.data["data"] as? [String: Any])?["rpg"]
            as? [String: Any])?["actionQuickSlots"] as? [Any]))
        XCTAssertEqual(durableSlots?[1] as? String, "spell:mage_light")
    }

    func testPlayerCASBeforeFacadeSameWorldAndABAReturnsMarkOnlyFinalSession() throws {
        let database = try makeDatabase("player-cas-aba")
        let a = try installLegacyPlayer(in: database, id: "player-cas-a", seed: 62)
        let b = WorldRecord(id: "player-cas-b", name: "B", seed: 63,
                            gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(b)
        let game = GameCore(db: database)
        let gate = DispatchSemaphore(value: 0)
        let replacementReadBlocked = expectation(description: "replacement A read blocked")
        var firstGeneration: UInt64 = 0
        game._testRPGCheckedPlayerOmissionBeforeFinalSegment = { [weak game] in
            guard let game else { return }
            game._testRPGCheckedPlayerOmissionBeforeFinalSegment = nil
            firstGeneration = game._testLastRPGLocalPreferenceContext?.worldEntryGeneration ?? 0
            game._testRPGLocalPreferenceBeforeIO = { context in
                if context.worldEntryGeneration > firstGeneration {
                    replacementReadBlocked.fulfill()
                    gate.wait()
                }
            }
            game.loadWorld(a.id)
            game.loadWorld(b.id)
            game.loadWorld(a.id)
        }
        game.loadWorld(a.id)
        wait(for: [replacementReadBlocked], timeout: 5)
        let finalGeneration = try XCTUnwrap(game._testLastRPGLocalPreferenceContext)
            .worldEntryGeneration
        XCTAssertGreaterThan(finalGeneration, firstGeneration)
        XCTAssertEqual(game._testRPGCheckedPlayerOmissionFinalSegmentCount, 0)
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(a.id))))
        XCTAssertFalse(try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope).omissionEligible)
        game._testRPGLocalPreferenceBeforeIO = nil
        gate.signal()
        waitUntil {
            game.worldRec?.id == a.id
                && game.player.rpgLegacyQuickSlotEnvelope?.omissionEligible == true
        }
        XCTAssertEqual(game._testRPGCheckedPlayerOmissionFinalSegmentCount, 1)
        XCTAssertNil((((try database.getPlayerChecked(a.id))?.data["data"]
            as? [String: Any])?["rpg"] as? [String: Any])?["actionQuickSlots"])
        XCTAssertEqual(game.rpgLocalPreferenceFailureCount, 0)
    }

    func testStalePlayerCASConflictPreservesNewerFieldsAndPostsNoFailure() throws {
        let database = try makeDatabase("stale-player-conflict")
        let record = try installLegacyPlayer(
            in: database, id: "stale-player-conflict-world", seed: 64)
        let game = GameCore(db: database)
        let host = RPGLocalPreferenceTestHost(); game.host = host
        game._testRPGCheckedPlayerOmissionBeforeFinalSegment = { [weak game] in
            guard let game else { return }
            game._testRPGCheckedPlayerOmissionBeforeFinalSegment = nil
            game.loadWorld(record.id)
            var newer = database.getPlayer(record.id) ?? [:]
            newer["newerWriter"] = true
            database.putPlayer(record.id, newer)
        }
        game.loadWorld(record.id)
        waitUntil {
            game.player.rpgLegacyQuickSlotEnvelope?.omissionEligible == true
        }
        XCTAssertEqual(game.rpgLocalPreferenceFailureCount, 0)
        XCTAssertFalse(host.actionBars.contains("Could not save RPG quick slots"))
        XCTAssertEqual((try database.getPlayerChecked(record.id))?.data["newerWriter"] as? Bool,
                       true)
        XCTAssertFalse(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
    }

    func testDeletedAndRecreatedSameWorldCannotReusePriorSessionOmissionIdentity() throws {
        let database = try makeDatabase("deleted-recreated-omission-identity")
        let record = try installLegacyPlayer(
            in: database, id: "recreated-omission-world", seed: 65)
        let game = GameCore(db: database)
        game.loadWorld(record.id)
        waitUntil {
            game.player.rpgLegacyQuickSlotEnvelope?.omissionEligible == true
        }
        XCTAssertFalse(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
        let completedFinalSegments = game._testRPGCheckedPlayerOmissionFinalSegmentCount
        XCTAssertEqual(completedFinalSegments, 1)

        game.exitToTitle()
        game.deleteWorld(record.id)
        _ = try installLegacyPlayer(
            in: database, id: record.id, seed: record.seed)

        let migrationGate = DispatchSemaphore(value: 0)
        let migrationBlocked = expectation(description: "recreated migration blocked before IO")
        game._testRPGLocalPreferenceBeforeIO = { _ in
            migrationBlocked.fulfill()
            migrationGate.wait()
        }
        game.loadWorld(record.id)
        wait(for: [migrationBlocked], timeout: 2)
        XCTAssertFalse(try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope).omissionEligible)

        game.saveAndFlush(synchronous: true)
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
        game.exitToTitle()
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
        XCTAssertEqual(game._testRPGCheckedPlayerOmissionFinalSegmentCount,
                       completedFinalSegments,
                       "the recreated session must issue no omission CAS before its receipt")

        game._testRPGLocalPreferenceBeforeIO = nil
        migrationGate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
    }

    func testDirectSameWorldLegacyRestoreCannotReusePriorSessionOmissionIdentity() throws {
        let database = try makeDatabase("direct-restore-omission-identity")
        let record = try installLegacyPlayer(
            in: database, id: "direct-restore-omission-world", seed: 66)
        let legacyBackup = try XCTUnwrap(database.getPlayer(record.id))
        let game = GameCore(db: database)
        game.loadWorld(record.id)
        waitUntil {
            game.player.rpgLegacyQuickSlotEnvelope?.omissionEligible == true
        }
        let completedFinalSegments = game._testRPGCheckedPlayerOmissionFinalSegmentCount
        XCTAssertEqual(completedFinalSegments, 1)
        game.exitToTitle()

        database.putPlayer(record.id, legacyBackup)
        let migrationGate = DispatchSemaphore(value: 0)
        let migrationBlocked = expectation(description: "restored migration blocked before IO")
        game._testRPGLocalPreferenceBeforeIO = { _ in
            migrationBlocked.fulfill()
            migrationGate.wait()
        }
        game.loadWorld(record.id)
        wait(for: [migrationBlocked], timeout: 2)
        XCTAssertFalse(try XCTUnwrap(game.player.rpgLegacyQuickSlotEnvelope).omissionEligible)

        game.saveAndFlush(synchronous: true)
        game.exitToTitle()
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
        XCTAssertEqual(game._testRPGCheckedPlayerOmissionFinalSegmentCount,
                       completedFinalSegments,
                       "the restored session must issue no omission CAS before its receipt")

        game._testRPGLocalPreferenceBeforeIO = nil
        migrationGate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
    }

    func testActiveDeleteDuringOmissionIsRejectedAndSameIDRecreationCannotCommitStaleCAS() throws {
        let database = try makeDatabase("active-delete-before-omission")
        let record = try installLegacyPlayer(
            in: database, id: "active-delete-before-omission-world", seed: 67)
        let legacyBackup = try XCTUnwrap(database.getPlayer(record.id))
        let replacementGate = DispatchSemaphore(value: 0)
        let replacementBlocked = expectation(
            description: "same-ID replacement migration blocked before IO")
        let game = GameCore(db: database)
        game._testRPGCheckedPlayerOmissionBeforeFinalSegment = { [weak game] in
            guard let game else { return }
            game._testRPGCheckedPlayerOmissionBeforeFinalSegment = nil
            game.deleteWorld(record.id)
            XCTAssertNotNil(database.getWorld(record.id),
                            "active-world deletion must fail closed")

            // Model an adversarial caller that nevertheless attempts to recreate the same durable
            // identity and restore the byte-identical legacy player backup.
            database.putWorld(record)
            database.putPlayer(record.id, legacyBackup)
            game._testRPGLocalPreferenceBeforeIO = { _ in
                replacementBlocked.fulfill()
                replacementGate.wait()
            }
            game.loadWorld(record.id)
        }
        game.loadWorld(record.id)
        wait(for: [replacementBlocked], timeout: 3)
        XCTAssertEqual(game._testRPGCheckedPlayerOmissionFinalSegmentCount, 0)
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))

        game.saveAndFlush(synchronous: true)
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
        game.exitToTitle()
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
        XCTAssertEqual(game._testRPGCheckedPlayerOmissionFinalSegmentCount, 0,
                       "no omission CAS may start before the replacement receipt")

        game._testRPGLocalPreferenceBeforeIO = nil
        replacementGate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
    }

    func testActiveDeleteAfterCommittedOmissionCannotAutosaveRecreateWithoutPreferences() throws {
        let database = try makeDatabase("active-delete-after-omission")
        let record = try installLegacyPlayer(
            in: database, id: "active-delete-after-omission-world", seed: 68)
        let game = GameCore(db: database)
        game.loadWorld(record.id)
        waitUntil {
            game.player.rpgLegacyQuickSlotEnvelope?.omissionEligible == true
        }
        let committedPreferences = try XCTUnwrap(
            database.loadRPGQuickSlotPreferences(worldRecordID: record.id))
        XCTAssertFalse(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))

        game.deleteWorld(record.id)
        XCTAssertNotNil(database.getWorld(record.id),
                        "active-world deletion must not reach durable storage")
        XCTAssertEqual(try database.loadRPGQuickSlotPreferences(worldRecordID: record.id),
                       committedPreferences)

        game.saveAndFlush(synchronous: true)
        XCTAssertNotNil(database.getWorld(record.id))
        XCTAssertEqual(try database.loadRPGQuickSlotPreferences(worldRecordID: record.id),
                       committedPreferences,
                       "autosave must never recreate a slot-free player without its preferences")
        XCTAssertFalse(playerSnapshotHasLegacySlots(
            try XCTUnwrap(database.getPlayerChecked(record.id))))
    }

    private func playerSnapshotHasLegacySlots(_ snapshot: SaveDBPlayerRowSnapshot) -> Bool {
        guard let data = snapshot.data["data"] as? [String: Any],
              let rpg = data["rpg"] as? [String: Any] else { return false }
        return rpg.keys.contains("actionQuickSlots")
    }

    func testPlayerPersistenceQueueSelfEntryIsNonBlocking() throws {
        XCTAssertTrue(GameCore(db: try makeDatabase("player-queue-self-entry"))
            ._testRPGPlayerPersistenceQueueSelfEntry())
    }

    func testDelayedSameWorldAndABAReturnsCannotPublishIntoReplacementSession() throws {
        let database = try makeDatabase("aba")
        let a = WorldRecord(id: "world-a", name: "Same", seed: 1,
                            gameMode: GameMode.survival, difficulty: 1)
        let b = WorldRecord(id: "world-b", name: "Same", seed: 2,
                            gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(a); database.putWorld(b)
        let expected = try database.materializeRPGQuickSlotPreferences(
            worldRecordID: a.id,
            defaults: RPGQuickSlotPreferences(tokens: ["spell:ignite"]))
        _ = try database.materializeRPGQuickSlotPreferences(
            worldRecordID: b.id,
            defaults: RPGQuickSlotPreferences(tokens: ["skill:guard_stance"]))

        let game = GameCore(db: database)
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "first A read reached delay gate")
        let lock = NSLock()
        var firstOperation: UInt64?
        game._testRPGLocalPreferenceBeforeIO = { context in
            lock.lock()
            let shouldBlock = firstOperation == nil
            if shouldBlock { firstOperation = context.operationID }
            lock.unlock()
            if shouldBlock {
                entered.fulfill()
                gate.wait()
            }
        }
        game.loadWorld(a.id)
        let firstContext = try XCTUnwrap(game._testLastRPGLocalPreferenceContext)
        wait(for: [entered], timeout: 2)
        game.exitToTitle()
        game.loadWorld(b.id)
        game.exitToTitle()
        game.loadWorld(a.id)
        let replacementContext = try XCTUnwrap(game._testLastRPGLocalPreferenceContext)
        XCTAssertGreaterThan(replacementContext.worldEntryGeneration,
                             firstContext.worldEntryGeneration)
        XCTAssertNotEqual(replacementContext.operationID, firstContext.operationID)
        gate.signal()
        waitUntil { game.rpgLocalPreferenceRevision == expected.revision }
        XCTAssertEqual(game.rpgQuickSlotPreferences, expected.preferences)
        XCTAssertEqual(game.rpgLocalPreferenceFailureCount, 0)
    }

    func testDelayedSameWorldReadCannotPublishIntoDirectReplacementEntry() throws {
        let database = try makeDatabase("same-world-replacement")
        let record = WorldRecord(id: "same-world", name: "Same", seed: 3,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let expected = try database.materializeRPGQuickSlotPreferences(
            worldRecordID: record.id,
            defaults: RPGQuickSlotPreferences(tokens: ["spell:ignite"]))
        let game = GameCore(db: database)
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "first same-world read delayed")
        let lock = NSLock(); var blocked = false
        game._testRPGLocalPreferenceBeforeIO = { _ in
            lock.lock(); let shouldBlock = !blocked; blocked = true; lock.unlock()
            if shouldBlock { entered.fulfill(); gate.wait() }
        }
        game.loadWorld(record.id)
        let first = try XCTUnwrap(game._testLastRPGLocalPreferenceContext)
        wait(for: [entered], timeout: 2)
        game.exitToTitle()
        game.loadWorld(record.id)
        let replacement = try XCTUnwrap(game._testLastRPGLocalPreferenceContext)
        XCTAssertGreaterThan(replacement.worldEntryGeneration, first.worldEntryGeneration)
        gate.signal()
        waitUntil { game.rpgLocalPreferenceRevision == expected.revision }
        XCTAssertEqual(game.rpgQuickSlotPreferences, expected.preferences)
        XCTAssertEqual(game.rpgLocalPreferenceFailureCount, 0)
    }

    func testDelayedStaleCASIsSilentUntilReplacementSessionLoadsCommittedValue() throws {
        let database = try makeDatabase("stale-cas")
        let record = WorldRecord(id: "stale-cas-world", name: "Stale CAS", seed: 6,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let initial = try database.materializeRPGQuickSlotPreferences(
            worldRecordID: record.id,
            defaults: RPGQuickSlotPreferences(tokens: ["spell:ignite"]))
        let game = GameCore(db: database)
        let host = RPGLocalPreferenceTestHost(); game.host = host
        game.loadWorld(record.id)
        waitUntil { game.rpgLocalPreferenceRevision == initial.revision }
        let refreshCountBeforeCAS = host.preferenceRefreshes.count

        let casGate = DispatchSemaphore(value: 0)
        let replacementGate = DispatchSemaphore(value: 0)
        let casEntered = expectation(description: "CAS delayed")
        let replacementEntered = expectation(description: "replacement load delayed")
        let lock = NSLock(); var gateIndex = 0
        game._testRPGLocalPreferenceBeforeIO = { _ in
            lock.lock(); gateIndex += 1; let index = gateIndex; lock.unlock()
            if index == 1 { casEntered.fulfill(); casGate.wait() }
            if index == 2 { replacementEntered.fulfill(); replacementGate.wait() }
        }
        XCTAssertTrue(game.persistRPGQuickSlotCandidate(
            RPGQuickSlotPreferences(tokens: [nil, "spell:ignite"])))
        wait(for: [casEntered], timeout: 2)
        game.exitToTitle()
        game.loadWorld(record.id)
        casGate.signal()
        wait(for: [replacementEntered], timeout: 2)
        host.actionBars.removeAll() // discard ordinary world-entry copy before stale completion
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(game.rpgQuickSlotPreferences)
        XCTAssertNil(game.rpgLocalPreferenceRevision)
        XCTAssertEqual(game.rpgLocalPreferenceFailureCount, 0)
        XCTAssertTrue(host.actionBars.isEmpty)
        XCTAssertEqual(host.preferenceRefreshes.count, refreshCountBeforeCAS,
                       "stale completion must not notify the replacement UI session")
        let committed = try XCTUnwrap(database.loadRPGQuickSlotPreferences(
            worldRecordID: record.id))
        XCTAssertEqual(committed.revision, 2)
        replacementGate.signal()
        waitUntil { game.rpgLocalPreferenceRevision == committed.revision }
        XCTAssertEqual(game.rpgQuickSlotPreferences, committed.preferences)
        XCTAssertTrue(host.actionBars.isEmpty)
        XCTAssertEqual(host.preferenceRefreshes.count, refreshCountBeforeCAS + 1)
        XCTAssertEqual(host.preferenceRefreshes.last?.worldEntryGeneration,
                       game._testLastRPGLocalPreferenceContext?.worldEntryGeneration)
    }

    func testCurrentCASFailureKeepsLiveAndStoredSnapshotsByteIdentical() throws {
        let database = try makeDatabase("failure")
        let record = WorldRecord(id: "failure-world", name: "Failure", seed: 5,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let initial = try database.materializeRPGQuickSlotPreferences(
            worldRecordID: record.id,
            defaults: RPGQuickSlotPreferences(tokens: ["spell:ignite"]))
        let game = GameCore(db: database)
        let host = RPGLocalPreferenceTestHost(); game.host = host
        game.loadWorld(record.id)
        waitUntil { game.rpgLocalPreferenceRevision == initial.revision }
        game._testRPGLocalPreferenceFailure = { context in
            if context.expectedLiveRevision == .exact(initial.revision) { return InjectedFailure.write }
            return nil
        }
        let liveBefore = game.rpgQuickSlotPreferences
        XCTAssertTrue(game.persistRPGQuickSlotCandidate(
            RPGQuickSlotPreferences(tokens: [nil, "spell:ignite"])))
        waitUntil { game.rpgLocalPreferenceFailureCount == 1 }
        XCTAssertEqual(game.rpgQuickSlotPreferences, liveBefore)
        XCTAssertEqual(game.rpgLocalPreferenceRevision, initial.revision)
        XCTAssertEqual(try database.loadRPGQuickSlotPreferences(worldRecordID: record.id), initial)
        XCTAssertTrue(game.rpgLocalPreferencePersistenceFailed)
        let failureStatus = try XCTUnwrap(game.rpgLocalPreferenceStatus)
        XCTAssertEqual(failureStatus.operation, .saveQuickSlots)
        XCTAssertEqual(failureStatus.target, .character)
        XCTAssertEqual(failureStatus.kind, .persistenceFailure)
        XCTAssertEqual(failureStatus.persistence, .localUntilReplaced)
        XCTAssertNotNil(failureStatus.identity.stableID)
        XCTAssertEqual(host.actionBars.last, "Could not save RPG quick slots")
        XCTAssertEqual(host.preferenceRefreshes.last,
            RPGLocalPreferenceUIRefresh(
                worldEntryGeneration: try XCTUnwrap(game._testLastRPGLocalPreferenceContext).worldEntryGeneration,
                       localPreferenceRevision: initial.revision, persistenceFailed: true))

        game._testRPGLocalPreferenceFailure = nil
        XCTAssertTrue(game.persistRPGQuickSlotCandidate(
            RPGQuickSlotPreferences(tokens: [nil, "spell:ignite"])))
        waitUntil { game.rpgLocalPreferenceRevision == initial.revision + 1 }
        XCTAssertNil(game.rpgLocalPreferenceStatus)
        XCTAssertFalse(game.rpgLocalPreferencePersistenceFailed)
    }

    func testDelayedCASCompletionAfterTeardownEmitsNoUIRefresh() throws {
        let database = try makeDatabase("refresh-teardown")
        let record = WorldRecord(id: "refresh-teardown-world", name: "Refresh", seed: 9,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let initial = try database.materializeRPGQuickSlotPreferences(
            worldRecordID: record.id,
            defaults: RPGQuickSlotPreferences(tokens: ["spell:ignite"]))
        let game = GameCore(db: database)
        let host = RPGLocalPreferenceTestHost(); game.host = host
        game.loadWorld(record.id)
        waitUntil { game.rpgLocalPreferenceRevision == initial.revision }
        let refreshCount = host.preferenceRefreshes.count
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "quick-slot CAS blocked")
        game._testRPGLocalPreferenceBeforeIO = { _ in entered.fulfill(); gate.wait() }
        XCTAssertTrue(game.persistRPGQuickSlotCandidate(
            RPGQuickSlotPreferences(tokens: [nil, "spell:ignite"])))
        wait(for: [entered], timeout: 2)
        game.exitToTitle()
        gate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(game.rpgQuickSlotPreferences)
        XCTAssertEqual(host.preferenceRefreshes.count, refreshCount)
        XCTAssertEqual(try database.loadRPGQuickSlotPreferences(
            worldRecordID: record.id)?.revision, initial.revision + 1)
    }

    func testLocalPersistenceStatusCounterExhaustionFailsClosedWithoutIdentityReuse() throws {
        let database = try makeDatabase("status-counter-exhaustion")
        let record = WorldRecord(id: "status-counter-world", name: "Counter", seed: 17,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let initial = try database.materializeRPGQuickSlotPreferences(
            worldRecordID: record.id, defaults: .empty)
        let game = GameCore(db: database)
        let host = RPGLocalPreferenceTestHost(); game.host = host
        game.loadWorld(record.id)
        waitUntil { game.rpgLocalPreferenceRevision == initial.revision }
        game._testSetRPGLocalPreferenceFailureCount(.max)
        game._testRPGLocalPreferenceFailure = { _ in InjectedFailure.write }
        let refreshCount = host.preferenceRefreshes.count
        XCTAssertTrue(game.persistRPGQuickSlotCandidate(
            RPGQuickSlotPreferences(tokens: ["skill:interpose"])))
        waitUntil { host.preferenceRefreshes.count == refreshCount + 1 }
        XCTAssertEqual(game.rpgLocalPreferenceFailureCount, .max)
        XCTAssertNil(game.rpgLocalPreferenceStatus)
        XCTAssertFalse(game.rpgLocalPreferencePersistenceFailed)
    }

    func testMaximumLiveRevisionQueuesNoCASOrStorageOperation() throws {
        let database = try makeDatabase("max-live-revision")
        let record = WorldRecord(id: "max-live-world", name: "Max", seed: 8,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let initial = try database.materializeRPGQuickSlotPreferences(
            worldRecordID: record.id,
            defaults: RPGQuickSlotPreferences(tokens: ["spell:ignite"]))
        let game = GameCore(db: database)
        game.loadWorld(record.id)
        waitUntil { game.rpgLocalPreferenceRevision == initial.revision }
        let scope = try XCTUnwrap(game.rpgLocalPreferenceScope)
        let cappedPreferences = RPGQuickSlotPreferences(tokens: [nil, "spell:ignite"])
        let cappedRevision: UInt64 = 1_000_000_000
        let capped = RPGQuickSlotStorageSnapshot(
            preferences: cappedPreferences, revision: cappedRevision,
            digest: try rpgQuickSlotDestinationDigest(
                scope: scope, preferences: cappedPreferences, revision: cappedRevision),
            migrationOriginDigest: nil, migrationOriginRevision: nil)
        game._testInstallRPGLocalPreferenceSnapshot(capped)
        let contextBefore = game._testLastRPGLocalPreferenceContext
        var ioCount = 0
        game._testRPGLocalPreferenceBeforeIO = { _ in ioCount += 1 }
        XCTAssertFalse(game.persistRPGQuickSlotCandidate(
            RPGQuickSlotPreferences(tokens: ["spell:ignite"])))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(ioCount, 0)
        XCTAssertEqual(game._testLastRPGLocalPreferenceContext, contextBefore)
        XCTAssertEqual(game.rpgLocalPreferenceRevision, cappedRevision)
        XCTAssertEqual(game.rpgQuickSlotPreferences, cappedPreferences)
        XCTAssertEqual(try database.loadRPGQuickSlotPreferences(worldRecordID: record.id), initial)
    }

    func testGenerationAndOperationExhaustionIssueNoStorageRequest() throws {
        let database = try makeDatabase("exhaustion")
        let record = WorldRecord(id: "exhaustion-world", name: "Exhaustion", seed: 7,
                                 gameMode: GameMode.survival, difficulty: 1)
        database.putWorld(record)
        let game = GameCore(db: database)
        var callCount = 0
        game._testRPGLocalPreferenceBeforeIO = { _ in callCount += 1 }
        game._testSetRPGWorldEntryGeneration(.max)
        game.loadWorld(record.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(game.rpgQuickSlotPreferences)
        XCTAssertEqual(callCount, 0)

        let second = GameCore(db: database)
        second._testRPGLocalPreferenceBeforeIO = { _ in callCount += 1 }
        second._testSetRPGLocalPreferenceOperationID(.max)
        second.loadWorld(record.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(second.rpgQuickSlotPreferences)
        XCTAssertEqual(callCount, 0)
    }
}

private final class RPGLocalPreferenceTestHost: GameHost {
    var actionBars: [String] = []
    var preferenceRefreshes: [RPGLocalPreferenceUIRefresh] = []
    func rpgLocalPreferenceDidRefresh(_ refresh: RPGLocalPreferenceUIRefresh) {
        preferenceRefreshes.append(refresh)
    }
    func hasScreen() -> Bool { false }
    func screenPausesGame() -> Bool { false }
    func openScreen(_ kind: String, _ data: ScreenData?) {}
    func openTrading(_ villager: Mob) {}
    func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
    func openChat(_ prefix: String) {}
    func openDeathScreen(_ message: String) {}
    func openPauseScreen() {}
    func openTitleScreen() {}
    func closeAllScreens() {}
    func releasePointer() {}
    func capturePointer() {}
    func showActionBar(_ text: String, _ time: Int) { actionBars.append(text) }
    func pushChat(_ line: String) {}
    func pushToast(_ adv: AdvancementDef) {}
    func setBossBars(_ bars: [BossBarInfo]) {}
    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double,
                   _ volume: Double, _ pitch: Double) {}
    func playUI(_ name: String) {}
    func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
    func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
    func tickMusic(_ mood: String, _ enabled: Bool) {}
    func stopDisc() {}
    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double,
                      _ count: Int, _ spread: Double, _ cell: Int) {}
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double,
                            _ groundY: Double) {}
    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int,
                    _ mesh: MeshOutput) {}
    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {}
    func clearAllSections() {}
}
