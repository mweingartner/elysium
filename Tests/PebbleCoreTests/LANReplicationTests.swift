import XCTest
@testable import PebbleCore

final class LANReplicationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllRecipes()
        registerAllEntities()
    }

    func testChangeLogCoalescesByPositionAndDrainsInInsertionOrder() {
        let log = LANReplicationChangeLog()
        log.record(LANBlockChange(dimension: 0, x: 1, y: 64, z: 1, cell: Int(B.dirt) << 4))
        log.record(LANBlockChange(dimension: 0, x: 2, y: 64, z: 1, cell: Int(B.stone) << 4))
        log.record(LANBlockChange(dimension: 0, x: 1, y: 64, z: 1, cell: Int(B.cobblestone) << 4))

        XCTAssertEqual(log.count, 2)
        let first = log.drain(maxCount: 1)
        XCTAssertEqual(first, [LANBlockChange(dimension: 0, x: 1, y: 64, z: 1, cell: Int(B.cobblestone) << 4)])

        let rest = log.drain()
        XCTAssertEqual(rest, [LANBlockChange(dimension: 0, x: 2, y: 64, z: 1, cell: Int(B.stone) << 4)])
        XCTAssertEqual(log.count, 0)
    }

    func testHostSessionAppliesValidatedBreakAndPlaceBlockIntents() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 2.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.creative
        ))
        _ = world.setBlock(2, 64, 1, Int(B.dirt) << 4)

        let breakResult = session.applyBlockIntent(
            LANBlockIntent(action: .breakBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0),
            from: "peer-a",
            to: world
        )
        XCTAssertEqual(breakResult, .applied([
            LANBlockChange(dimension: 0, x: 2, y: 64, z: 1, cell: 0),
        ]))
        XCTAssertEqual(world.getBlock(2, 64, 1), 0)

        let stone = Int(B.stone) << 4
        let placeResult = session.applyBlockIntent(
            LANBlockIntent(action: .placeBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0, cell: stone),
            from: "peer-a",
            to: world
        )
        XCTAssertEqual(placeResult, .applied([
            LANBlockChange(dimension: 0, x: 2, y: 65, z: 1, cell: stone),
        ]))
        XCTAssertEqual(world.getBlock(2, 65, 1), stone)
    }

    func testHostSessionAppliesUseBlockIntentForOpenableBlocks() {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession(x: 2.5, y: 64, z: 1.5, yaw: .pi / 2)

        forceSetBlock(world, x: 2, y: 63, z: 1, cell: Int(cell(B.stone, 0)))
        forceSetBlock(world, x: 2, y: 64, z: 1, cell: Int(cell(B.oak_door, 0)))
        forceSetBlock(world, x: 2, y: 65, z: 1, cell: Int(cell(B.oak_door, 8)))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .useBlock, x: 2, y: 64, z: 1, face: Dir.up, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .applied([
                LANBlockChange(dimension: Dim.overworld.rawValue, x: 2, y: 64, z: 1, cell: Int(cell(B.oak_door, 4))),
            ])
        )
        XCTAssertEqual(world.getBlock(2, 64, 1), Int(cell(B.oak_door, 4)))

        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .useBlock, x: 2, y: 65, z: 1, face: Dir.up, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .applied([
                LANBlockChange(dimension: Dim.overworld.rawValue, x: 2, y: 64, z: 1, cell: Int(cell(B.oak_door, 0))),
            ])
        )
        XCTAssertEqual(world.getBlock(2, 64, 1), Int(cell(B.oak_door, 0)))

        forceSetBlock(world, x: 3, y: 63, z: 1, cell: Int(cell(B.stone, 0)))
        forceSetBlock(world, x: 3, y: 64, z: 1, cell: Int(cell(B.oak_trapdoor, 0)))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .useBlock, x: 3, y: 64, z: 1, face: Dir.up, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .applied([
                LANBlockChange(dimension: Dim.overworld.rawValue, x: 3, y: 64, z: 1, cell: Int(cell(B.oak_trapdoor, 4))),
            ])
        )

        let gate = bid("oak_fence_gate")
        forceSetBlock(world, x: 4, y: 63, z: 1, cell: Int(cell(B.stone, 0)))
        forceSetBlock(world, x: 4, y: 64, z: 1, cell: Int(cell(gate, 0)))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .useBlock, x: 4, y: 64, z: 1, face: Dir.up, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .applied([
                LANBlockChange(dimension: Dim.overworld.rawValue, x: 4, y: 64, z: 1, cell: Int(cell(gate, 6))),
            ])
        )
    }

    func testHostSessionRejectsOrIgnoresUnsupportedUseBlockIntentTargets() {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession()

        forceSetBlock(world, x: 2, y: 63, z: 1, cell: Int(cell(B.stone, 0)))
        forceSetBlock(world, x: 2, y: 64, z: 1, cell: Int(cell(B.iron_door, 0)))
        forceSetBlock(world, x: 2, y: 65, z: 1, cell: Int(cell(B.iron_door, 8)))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .useBlock, x: 2, y: 64, z: 1, face: Dir.up, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .ignored("unsupported use target")
        )

        forceSetBlock(world, x: 3, y: 64, z: 1, cell: Int(cell(B.stone, 0)))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .useBlock, x: 3, y: 64, z: 1, face: Dir.up, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .ignored("unsupported use target")
        )

        session.setPermissions(LANPeerPermissions(canChangeDimensions: true), for: "peer-a")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 3.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dimension: Dim.nether.rawValue
        ))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .useBlock, x: 3, y: 64, z: 1, face: Dir.up, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .rejected("target dimension unavailable")
        )
    }

    func testHostSessionRejectsOutOfReachOrInvalidPlacementCells() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 100,
            y: 64,
            z: 100,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival
        ))
        _ = world.setBlock(2, 64, 1, Int(B.dirt) << 4)

        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .breakBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .rejected("target out of reach")
        )

        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 2.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.creative
        ))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .placeBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0, cell: Int(UInt16.max)),
                from: "peer-a",
                to: world
            ),
            .rejected("invalid placement cell")
        )
    }

    func testHostSessionClampsUnauthorizedCreativeDimensionAndPreservesReconnectRecord() {
        let session = LANMultiplayerHostSession()

        XCTAssertEqual(session.acceptPeer(playerID: "peer-a", displayName: "Alex", tick: 3), .joined)
        let sanitized = session.updatePlayerState(
            LANPlayerState(
                playerID: "peer-a",
                displayName: "Spoofed",
                x: 8,
                y: 66,
                z: 9,
                yaw: 0.4,
                pitch: 0.1,
                health: 20,
                hunger: 19,
                selectedHotbarSlot: 2,
                gameMode: GameMode.creative,
                dimension: Dim.nether.rawValue
            ),
            currentDimension: Dim.overworld.rawValue,
            tick: 4
        )

        XCTAssertEqual(sanitized?.displayName, "Alex")
        XCTAssertEqual(sanitized?.gameMode, GameMode.survival)
        XCTAssertEqual(sanitized?.dimension, Dim.overworld.rawValue)

        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 2, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: 1, count: 32),
            ]),
            from: "peer-a"
        )
        session.disconnectPeer(playerID: "peer-a", tick: 10)

        var record = session.peerRecord(playerID: "peer-a")
        XCTAssertEqual(record?.lifecycle, .disconnected)
        XCTAssertEqual(record?.inventory?.slots.first?.count, 32)
        XCTAssertEqual(record?.disconnectedTick, 10)

        XCTAssertEqual(session.acceptPeer(playerID: "peer-a", displayName: "Alex Again", tick: 12), .reconnected)
        record = session.peerRecord(playerID: "peer-a")
        XCTAssertEqual(record?.lifecycle, .connected)
        XCTAssertEqual(record?.inventory?.slots.first?.count, 32)
        XCTAssertEqual(record?.playerState?.x, 8)
    }

    func testHostSessionPermissionGatesBuildContainerCraftingTemplateAndDeadPlayers() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 2.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival
        ))
        session.setPermissions(LANPeerPermissions(canBuild: false, canUseContainers: false, canCraft: false, canUseTemplates: false), for: "peer-a")
        _ = world.setBlock(2, 64, 1, Int(B.dirt) << 4)

        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .breakBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .rejected("permission denied: build")
        )
        XCTAssertEqual(
            session.authorizeContainerIntent(LANContainerIntent(action: .open, containerID: "chest@2,64,1", slot: -1, button: 0, shift: false), from: "peer-a"),
            .rejected("permission denied: container")
        )
        XCTAssertEqual(session.authorizeCraftingIntent(from: "peer-a"), .rejected("permission denied: crafting"))

        let result = session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Tiny", x: 1, y: 64, z: 1, rotation: 0),
            from: "peer-a",
            world: world,
            loadTemplate: { _ in nil },
            saveTemplate: { _ in false }
        )
        XCTAssertEqual(result, .rejected("permission denied: template"))

        session.setPermissions(LANPeerPermissions(), for: "peer-a")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 2.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 0,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dead: true
        ))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .breakBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .rejected("player is dead")
        )
    }

    func testHostSessionTemplatePermissionFlowPlacesAndUndoesValidatedTemplate() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.creative
        ))
        let dirt = UInt16(Int(B.dirt) << 4)
        _ = world.setBlock(1, 63, 1, Int(dirt))
        let template = ObjectTemplate(
            name: "Tiny",
            anchorX: 0,
            anchorY: 0,
            anchorZ: 0,
            sizeX: 1,
            sizeY: 1,
            sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: dirt)]
        )
        var saved = ["Tiny": template]

        let placed = session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Tiny", x: 1, y: 64, z: 1, rotation: 0),
            from: "peer-a",
            world: world,
            loadTemplate: { saved[$0] },
            saveTemplate: { saved[$0.name] = $0; return true }
        )

        XCTAssertEqual(placed, .placed(name: "Tiny", blocks: 1, blockEntities: 0, cleared: 0, filled: 0))
        XCTAssertEqual(world.getBlock(1, 64, 1), Int(dirt))
        XCTAssertEqual(session.pendingBlockChanges(), [
            LANBlockChange(dimension: Dim.overworld.rawValue, x: 1, y: 64, z: 1, cell: Int(dirt)),
        ])

        let undone = session.applyTemplateIntent(
            LANTemplateIntent(action: .undoPlacement, templateName: "Tiny", x: 1, y: 64, z: 1, rotation: 0),
            from: "peer-a",
            world: world,
            loadTemplate: { saved[$0] },
            saveTemplate: { saved[$0.name] = $0; return true }
        )

        XCTAssertEqual(undone, .undone(name: "Tiny", restored: 1))
        XCTAssertEqual(world.getBlock(1, 64, 1), 0)
    }

    func testHostSessionTemplateIntentRejectsOutOfReachTargets() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 100,
            y: 64,
            z: 100,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival
        ))

        let result = session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Tiny", x: 1, y: 64, z: 1, rotation: 0),
            from: "peer-a",
            world: world,
            loadTemplate: { _ in nil },
            saveTemplate: { _ in false }
        )

        XCTAssertEqual(result, .rejected("target out of reach"))
    }

    func testRemotePlayerEntitiesSpawnUpdateAndRemoveFromWorldSnapshots() {
        let world = makeLoadedWorld()
        let initial = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1,
            y: 65,
            z: 2,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 18,
            selectedHotbarSlot: 3,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        )

        var report = applyLANRemotePlayers([initial], to: world, localPlayerID: "local")
        XCTAssertEqual(report, LANRemotePlayerApplyReport(spawned: 1, updated: 0, removed: 0))
        var remote = world.entities.compactMap { $0 as? LANRemotePlayerEntity }.first
        XCTAssertEqual(remote?.multiplayerPlayerID, "peer-a")
        XCTAssertEqual(remote?.x, 1)
        XCTAssertEqual(remote?.yaw ?? .nan, lanRemotePlayerRenderYaw(fromPlayerYaw: initial.yaw), accuracy: 0.000_001)
        XCTAssertEqual(remote?.headYaw ?? .nan, lanRemotePlayerRenderYaw(fromPlayerYaw: initial.yaw), accuracy: 0.000_001)

        let moved = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 4,
            y: 66,
            z: 5,
            yaw: 0.5,
            pitch: 0,
            health: 19,
            hunger: 17,
            selectedHotbarSlot: 3,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        )
        report = applyLANRemotePlayers([moved], to: world, localPlayerID: "local")
        XCTAssertEqual(report.spawned, 0)
        XCTAssertEqual(report.updated, 1)
        remote = world.entities.compactMap { $0 as? LANRemotePlayerEntity }.first
        XCTAssertEqual(remote?.x, 4)
        XCTAssertEqual(remote?.health, 19)
        XCTAssertEqual(remote?.yaw ?? .nan, lanRemotePlayerRenderYaw(fromPlayerYaw: moved.yaw), accuracy: 0.000_001)
        XCTAssertEqual(remote?.bodyYaw ?? .nan, lanRemotePlayerRenderYaw(fromPlayerYaw: moved.yaw), accuracy: 0.000_001)

        let nether = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 4,
            y: 66,
            z: 5,
            yaw: 0.5,
            pitch: 0,
            health: 19,
            hunger: 17,
            selectedHotbarSlot: 3,
            gameMode: GameMode.survival,
            dimension: Dim.nether.rawValue
        )
        report = applyLANRemotePlayers([nether], to: world, localPlayerID: "local")
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(world.entities.compactMap { $0 as? LANRemotePlayerEntity }.isEmpty)
    }

    func testLANRemotePlayerRenderYawAppliesHalfTurnAndWraps() {
        XCTAssertEqual(lanRemotePlayerRenderYaw(fromPlayerYaw: 0), .pi, accuracy: 0.000_001)
        XCTAssertEqual(lanRemotePlayerRenderYaw(fromPlayerYaw: .pi), 0, accuracy: 0.000_001)
        XCTAssertEqual(lanRemotePlayerRenderYaw(fromPlayerYaw: -.pi / 2), .pi / 2, accuracy: 0.000_001)
        XCTAssertTrue(lanRemotePlayerRenderYaw(fromPlayerYaw: 1.0e30).isFinite)
    }

    func testLANRemotePlayerPresentationSmoothsWithoutLocalTickRewind() {
        let world = makeLoadedWorld()
        let initial = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1,
            y: 65,
            z: 2,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        )
        let remote = LANRemotePlayerEntity(world: world, state: initial)

        var pose = remote.presentationPose(timeSec: 0)
        XCTAssertEqual(pose.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(pose.z, 2, accuracy: 0.000_001)

        let moved = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 4,
            y: 65,
            z: 2,
            yaw: 0.5,
            pitch: 0.1,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        )
        remote.apply(moved)
        pose = remote.presentationPose(timeSec: 0.016)
        XCTAssertGreaterThan(pose.x, 1)
        XCTAssertLessThan(pose.x, 4)
        let afterFirstRender = pose.x

        remote.tick()
        pose = remote.presentationPose(timeSec: 0.032)
        XCTAssertGreaterThanOrEqual(pose.x, afterFirstRender)
        XCTAssertLessThan(pose.x, 4)

        remote.apply(moved)
        let afterDuplicateApply = remote.presentationPose(timeSec: 0.048)
        XCTAssertGreaterThanOrEqual(afterDuplicateApply.x, pose.x)
        XCTAssertLessThan(afterDuplicateApply.x, 4)
    }

    func testLANRemotePlayerPresentationSnapsForTeleports() {
        let world = makeLoadedWorld()
        let remote = LANRemotePlayerEntity(world: world, state: LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1,
            y: 65,
            z: 2,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        ))
        _ = remote.presentationPose(timeSec: 0)

        remote.apply(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 40,
            y: 90,
            z: -30,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        ))

        let pose = remote.presentationPose(timeSec: 0.016)
        XCTAssertEqual(pose.x, 40, accuracy: 0.000_001)
        XCTAssertEqual(pose.y, 90, accuracy: 0.000_001)
        XCTAssertEqual(pose.z, -30, accuracy: 0.000_001)
    }

    func testLANClientEntityPurgeKeepsOnlyAuthoritativeLANEntities() {
        let world = makeLoadedWorld()
        let localPlayer = Player(world: world)
        localPlayer.setPos(1.5, 65, 1.5)
        world.addEntity(localPlayer)

        let remote = LANRemotePlayerEntity(world: world, state: LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 2,
            y: 65,
            z: 2,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        ))
        world.addEntity(remote)

        let mirroredDrop = ItemEntity(world: world)
        mirroredDrop.lanReplicationSourceID = 99
        mirroredDrop.lanReplicatedMirror = true
        world.addEntity(mirroredDrop)

        let localChicken = Chicken(world: world)
        world.addEntity(localChicken)

        let removed = removeLANClientNonAuthoritativeEntities(from: world, localPlayer: localPlayer)

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(world.entities.contains { $0 === localPlayer })
        XCTAssertTrue(world.entities.contains { $0 === remote })
        XCTAssertTrue(world.entities.contains { $0 === mirroredDrop })
        XCTAssertFalse(world.entities.contains { $0 === localChicken })
    }

    func testChunkSectionSnapshotAppliesToTargetWorld() throws {
        let source = makeLoadedWorld()
        let target = World(dim: .overworld, seed: 99)
        var dirtiedSections: [LANChunkSectionPosition] = []
        target.hooks.onSectionDirty = { cx, cz, sy in
            dirtiedSections.append(LANChunkSectionPosition(dimension: target.dim.rawValue, cx: cx, cz: cz, sectionY: sy))
        }
        let sectionY = (64 - source.info.minY) >> 4
        let dirt = Int(B.dirt) << 4
        let stone = Int(B.stone) << 4
        _ = source.setBlock(4, 64, 4, dirt)
        _ = source.setBlock(5, 65, 4, stone)

        let snapshot = try XCTUnwrap(makeLANChunkSectionSnapshot(
            from: try XCTUnwrap(source.getChunk(0, 0)),
            dimension: source.dim.rawValue,
            sectionY: sectionY
        ))

        XCTAssertTrue(applyLANChunkSectionSnapshot(snapshot, to: target))
        XCTAssertEqual(target.getBlock(4, 64, 4), dirt)
        XCTAssertEqual(target.getBlock(5, 65, 4), stone)
        XCTAssertEqual(dirtiedSections, [
            LANChunkSectionPosition(dimension: target.dim.rawValue, cx: 0, cz: 0, sectionY: sectionY),
        ])
    }

    func testClientSessionAppliesBatchAndDropsMalformedSectionsAndCells() {
        let client = LANMultiplayerClientSession()
        let validCell = Int(B.dirt) << 4
        let invalidCell = Int(UInt16.max)
        let player = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1,
            y: 65,
            z: 2,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 18,
            selectedHotbarSlot: 3,
            gameMode: GameMode.survival
        )
        let validSection = LANChunkSectionSnapshot(
            dimension: 0,
            cx: 0,
            cz: 0,
            sectionY: 8,
            minY: 64,
            cells: Array(repeating: UInt16(validCell), count: LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        )
        let malformedSection = LANChunkSectionSnapshot(
            dimension: 0,
            cx: 0,
            cz: 0,
            sectionY: 8,
            minY: 64,
            cells: [UInt16(validCell)]
        )
        let batch = LANReplicationBatch(
            tick: 12,
            fullSnapshot: true,
            world: LANWorldSummary(
                worldID: "w",
                worldName: "World",
                seed: 1,
                gameMode: GameMode.survival,
                difficulty: 2,
                dimension: 0,
                playerCount: 2
            ),
            worldState: LANWorldStateSnapshot(
                dimension: 0,
                time: 1234,
                dayTime: 6000,
                difficulty: 3,
                raining: true,
                thundering: false,
                rainLevel: 0.75,
                thunderLevel: 0.25,
                weatherTimer: 99
            ),
            players: [player],
            blockChanges: [
                LANBlockChange(dimension: 0, x: 1, y: 64, z: 1, cell: validCell),
                LANBlockChange(dimension: 0, x: 2, y: 64, z: 1, cell: invalidCell),
            ],
            chunkSections: [validSection, malformedSection],
            entities: [LANEntitySnapshot(entityID: 7, type: "zombie", x: 1, y: 64, z: 1, yaw: 0, pitch: 0, health: 20, dead: false)],
            inventories: [LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 3, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: 1, count: 64),
            ])],
            blockEntities: [
                LANBlockEntitySnapshot(
                    dimension: 0,
                    x: 4,
                    y: 64,
                    z: 4,
                    type: "container",
                    slotCount: 27,
                    slots: [LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("coal"), count: 4)]
                ),
            ]
        )

        let report = client.apply(batch)

        XCTAssertEqual(report.appliedBlockChanges, 1)
        XCTAssertEqual(report.ignoredInvalidCells, 1)
        XCTAssertEqual(report.appliedChunkSections, 1)
        XCTAssertEqual(report.ignoredInvalidSections, 1)
        XCTAssertEqual(client.latestTick, 12)
        XCTAssertEqual(client.players["peer-a"], player)
        XCTAssertEqual(client.worldState?.time, 1234)
        XCTAssertEqual(client.worldState?.dayTime, 6000)
        XCTAssertEqual(client.blockCells[LANBlockPosition(dimension: 0, x: 1, y: 64, z: 1)], validCell)
        XCTAssertNil(client.blockCells[LANBlockPosition(dimension: 0, x: 2, y: 64, z: 1)])
        XCTAssertEqual(client.entities[7]?.type, "zombie")
        XCTAssertEqual(report.appliedEntitySnapshots, 1)
        XCTAssertEqual(client.inventories["peer-a"]?.slots.first?.count, 64)
        XCTAssertEqual(report.appliedBlockEntities, 1)
        XCTAssertEqual(client.blockEntities[LANBlockPosition(dimension: 0, x: 4, y: 64, z: 4)]?.slots.first?.count, 4)
    }

    func testBlockEntitySnapshotsReplicateContainerContentsAndClearSlots() throws {
        let host = makeLoadedWorld()
        let client = makeLoadedWorld()
        let chestCell = Int(B.chest) << 4
        _ = host.setBlock(2, 64, 2, chestCell)
        _ = client.setBlock(2, 64, 2, chestCell)
        let chest = makeContainerBE(2, 64, 2, 27)
        chest.items![0] = ItemStack(iid("diamond"), 3)
        chest.items![5] = ItemStack(iid("stick"), 1, label: "Marker")
        host.setBlockEntity(chest)

        var snapshots = makeLANBlockEntitySnapshots(in: host)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].slotCount, 27)
        XCTAssertEqual(snapshots[0].slots.map(\.slot), [0, 5])

        var report = applyLANReplicationBatch(
            LANReplicationBatch(tick: 1, fullSnapshot: false, blockEntities: snapshots),
            to: client
        )
        XCTAssertEqual(report.appliedBlockEntities, 1)
        let clientChest = try XCTUnwrap(client.getBlockEntity(2, 64, 2))
        XCTAssertEqual(clientChest.items?[0], ItemStack(iid("diamond"), 3))
        XCTAssertEqual(clientChest.items?[5], ItemStack(iid("stick"), 1, label: "Marker"))

        chest.items![0] = nil
        chest.items![5] = nil
        chest.items![1] = ItemStack(iid("coal"), 4)
        snapshots = makeLANBlockEntitySnapshots(in: host)
        report = applyLANReplicationBatch(
            LANReplicationBatch(tick: 2, fullSnapshot: false, blockEntities: snapshots),
            to: client
        )
        XCTAssertEqual(report.appliedBlockEntities, 1)
        let updatedChest = try XCTUnwrap(client.getBlockEntity(2, 64, 2))
        XCTAssertTrue(updatedChest === clientChest)
        XCTAssertNil(updatedChest.items?[0])
        XCTAssertNil(updatedChest.items?[5])
        XCTAssertEqual(updatedChest.items?[1], ItemStack(iid("coal"), 4))
    }

    func testCraftingTableBlockEntitySnapshotsReplicateSharedGrid() throws {
        let host = makeLoadedWorld()
        let client = makeLoadedWorld()
        let tableCell = Int(B.crafting_table) << 4
        _ = host.setBlock(3, 64, 2, tableCell)
        _ = client.setBlock(3, 64, 2, tableCell)
        let table = makeCraftingTableBE(3, 64, 2)
        table.items![0] = ItemStack(iid("oak_planks"), 1)
        table.items![1] = ItemStack(iid("oak_planks"), 1)
        host.setBlockEntity(table)

        let snapshots = makeLANBlockEntitySnapshots(in: host)
        XCTAssertEqual(snapshots.first?.type, "crafting")
        XCTAssertEqual(snapshots.first?.slotCount, 9)

        let report = applyLANReplicationBatch(
            LANReplicationBatch(tick: 3, fullSnapshot: false, blockEntities: snapshots),
            to: client
        )
        XCTAssertEqual(report.appliedBlockEntities, 1)
        let clientTable = try XCTUnwrap(client.getBlockEntity(3, 64, 2))
        XCTAssertEqual(clientTable.type, "crafting")
        XCTAssertEqual(clientTable.items?.count, 9)
        XCTAssertEqual(clientTable.items?[0], ItemStack(iid("oak_planks"), 1))
        XCTAssertEqual(clientTable.items?[1], ItemStack(iid("oak_planks"), 1))
    }

    func testBlockEntitySnapshotsPrioritizeContainersNearPlayers() throws {
        let world = makeLoadedWorld()
        _ = world.setBlock(1, 64, 1, Int(B.chest) << 4)
        _ = world.setBlock(12, 64, 12, Int(B.chest) << 4)
        let nearOrigin = makeContainerBE(1, 64, 1, 27)
        nearOrigin.items![0] = ItemStack(iid("stick"), 1)
        let nearPlayer = makeContainerBE(12, 64, 12, 27)
        nearPlayer.items![0] = ItemStack(iid("diamond"), 1)
        world.setBlockEntity(nearOrigin)
        world.setBlockEntity(nearPlayer)

        let snapshots = makeLANBlockEntitySnapshots(
            in: world,
            prioritizedAround: [(x: 12.5, z: 12.5)],
            maxCount: 1
        )

        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.x, 12)
        XCTAssertEqual(snapshot.z, 12)
        XCTAssertEqual(snapshot.slots.first?.itemID, iid("diamond"))
    }

    func testBlockEntitySnapshotValidationRejectsBadSlotsAndWrongBlocks() {
        let world = makeLoadedWorld()
        _ = world.setBlock(2, 64, 2, Int(B.stone) << 4)
        _ = world.setBlock(3, 64, 2, Int(B.chest) << 4)

        let wrongBlock = LANBlockEntitySnapshot(
            dimension: Dim.overworld.rawValue,
            x: 2,
            y: 64,
            z: 2,
            type: "container",
            slotCount: 27,
            slots: [LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)]
        )
        let invalidItem = LANBlockEntitySnapshot(
            dimension: Dim.overworld.rawValue,
            x: 3,
            y: 64,
            z: 2,
            type: "container",
            slotCount: 27,
            slots: [LANBlockEntitySlotSnapshot(slot: 0, itemID: itemDefs.count + 100, count: 1)]
        )
        let duplicateSlot = LANBlockEntitySnapshot(
            dimension: Dim.overworld.rawValue,
            x: 3,
            y: 64,
            z: 2,
            type: "container",
            slotCount: 27,
            slots: [
                LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1),
                LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("stick"), count: 1),
            ]
        )

        let report = applyLANReplicationBatch(
            LANReplicationBatch(tick: 4, fullSnapshot: false, blockEntities: [wrongBlock, invalidItem, duplicateSlot]),
            to: world
        )

        XCTAssertEqual(report.appliedBlockEntities, 0)
        XCTAssertEqual(report.ignoredInvalidBlockEntities, 3)
        XCTAssertNil(world.getBlockEntity(2, 64, 2))
        XCTAssertNil(world.getBlockEntity(3, 64, 2))
    }

    func testWorldStateSnapshotAppliesTimeWeatherAndDifficulty() {
        let world = makeLoadedWorld()
        world.time = 1
        world.dayTime = 2
        world.difficulty = 1
        world.raining = false
        world.thundering = false
        world.rainLevel = 0
        world.thunderLevel = 0
        world.weatherTimer = 10

        let snapshot = LANWorldStateSnapshot(
            dimension: Dim.overworld.rawValue,
            time: 42_000,
            dayTime: DAY_LENGTH + 123,
            difficulty: 99,
            raining: true,
            thundering: true,
            rainLevel: 1.4,
            thunderLevel: -2,
            weatherTimer: 999_999
        )

        XCTAssertTrue(applyLANWorldStateSnapshot(snapshot, to: world))
        XCTAssertEqual(world.time, 42_000)
        XCTAssertEqual(world.dayTime, 123)
        XCTAssertEqual(world.difficulty, 3)
        XCTAssertTrue(world.raining)
        XCTAssertTrue(world.thundering)
        XCTAssertEqual(world.rainLevel, 1)
        XCTAssertEqual(world.thunderLevel, 0)
        XCTAssertEqual(world.weatherTimer, 240_000)

        let nether = World(dim: .nether, seed: 42)
        XCTAssertFalse(applyLANWorldStateSnapshot(snapshot, to: nether))
    }

    func testRuntimeBlockHookRecordsPlantAndSimulationDeltasForReplication() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        world.hooks.onBlockChanged = { x, y, z, _, newCell, _ in
            _ = session.recordBlockChange(dimension: world.dim.rawValue, x: x, y: y, z: z, cell: newCell)
        }

        let wheat = Int(cell(B.wheat, 4))
        _ = world.setBlock(3, 64, 3, wheat)
        XCTAssertEqual(session.drainBlockChanges(), [
            LANBlockChange(dimension: Dim.overworld.rawValue, x: 3, y: 64, z: 3, cell: wheat),
        ])

        _ = world.setBlock(4, 64, 3, Int(cell(B.wheat, 5)), SET_SILENT)
        XCTAssertTrue(session.drainBlockChanges().isEmpty)
    }

    func testEntitySnapshotsIncludeDroppedItemAndXpPayloads() throws {
        let world = makeLoadedWorld()
        let item = spawnItem(world, 1.5, 65, 2.5, ItemStack(iid("coal"), 32, damage: 3, label: "Fuel"))
        item.pickupDelay = 20
        let orb = XPOrb(world: world)
        orb.setPos(3.5, 65, 2.5)
        orb.amount = 7
        world.addEntity(orb)

        let snapshots = makeLANEntitySnapshots(in: world)

        let itemSnapshot = try XCTUnwrap(snapshots.first { $0.entityID == item.id })
        XCTAssertEqual(itemSnapshot.type, "item")
        XCTAssertEqual(itemSnapshot.itemID, iid("coal"))
        XCTAssertEqual(itemSnapshot.itemCount, 32)
        XCTAssertEqual(itemSnapshot.itemDamage, 3)
        XCTAssertEqual(itemSnapshot.itemLabel, "Fuel")

        let xpSnapshot = try XCTUnwrap(snapshots.first { $0.entityID == orb.id })
        XCTAssertEqual(xpSnapshot.type, "xp_orb")
        XCTAssertEqual(xpSnapshot.xpAmount, 7)
    }

    func testEntitySnapshotsMirrorPassiveAndHostileMobs() throws {
        let world = makeLoadedWorld()
        let chicken = Chicken(world: world)
        chicken.setPos(2.5, 65, 2.5)
        world.addEntity(chicken)
        let zombie = Zombie(world: world)
        zombie.setPos(4.5, 65, 4.5)
        zombie.health = 12
        world.addEntity(zombie)

        let snapshots = makeLANEntitySnapshots(in: world)

        XCTAssertTrue(snapshots.contains { $0.entityID == chicken.id && $0.type == "chicken" })
        let zombieSnapshot = try XCTUnwrap(snapshots.first { $0.entityID == zombie.id })
        XCTAssertEqual(zombieSnapshot.type, "zombie")
        XCTAssertEqual(zombieSnapshot.health, 12)

        let clientWorld = makeLoadedWorld()
        let report = applyLANReplicationBatch(
            LANReplicationBatch(tick: 4, fullSnapshot: false, entities: snapshots, entitySnapshotsComplete: true),
            to: clientWorld
        )

        XCTAssertEqual(report.appliedEntitySnapshots, 2)
        XCTAssertEqual(clientWorld.entities.compactMap { $0 as? Chicken }.count, 1)
        XCTAssertEqual(clientWorld.entities.compactMap { $0 as? Zombie }.count, 1)
        XCTAssertTrue(clientWorld.entities.compactMap { $0 as? Entity }.allSatisfy { $0.lanReplicatedMirror })
    }

    func testReplicationBatchMaterializesUpdatesAndRemovesMirroredDroppedItemsAndXp() throws {
        let clientWorld = makeLoadedWorld()
        let coalID = iid("coal")
        let itemSnapshot = LANEntitySnapshot(
            entityID: 44,
            type: "item",
            x: 1.5,
            y: 65,
            z: 2.5,
            yaw: 0,
            pitch: 0,
            health: nil,
            dead: false,
            itemID: coalID,
            itemCount: 12,
            itemDamage: 1,
            itemLabel: "Shared"
        )
        let xpSnapshot = LANEntitySnapshot(
            entityID: 45,
            type: "xp_orb",
            x: 3.5,
            y: 65,
            z: 2.5,
            yaw: 0,
            pitch: 0,
            health: nil,
            dead: false,
            xpAmount: 5
        )

        var report = applyLANReplicationBatch(
            LANReplicationBatch(tick: 1, fullSnapshot: false, entities: [itemSnapshot, xpSnapshot], entitySnapshotsComplete: true),
            to: clientWorld
        )

        XCTAssertEqual(report.appliedEntitySnapshots, 2)
        let item = try XCTUnwrap(clientWorld.entities.compactMap { $0 as? ItemEntity }.first)
        XCTAssertEqual(item.lanReplicationSourceID, 44)
        XCTAssertTrue(item.lanReplicatedMirror)
        XCTAssertEqual(item.stack, ItemStack(coalID, 12, damage: 1, label: "Shared"))
        XCTAssertGreaterThan(item.pickupDelay, 1000)
        XCTAssertTrue(item.noGravity)
        XCTAssertTrue(item.noClip)
        let orb = try XCTUnwrap(clientWorld.entities.compactMap { $0 as? XPOrb }.first)
        XCTAssertEqual(orb.lanReplicationSourceID, 45)
        XCTAssertEqual(orb.amount, 5)

        let movedItem = LANEntitySnapshot(
            entityID: 44,
            type: "item",
            x: 4.5,
            y: 66,
            z: 5.5,
            yaw: 0.1,
            pitch: 0,
            health: nil,
            dead: false,
            itemID: coalID,
            itemCount: 8
        )
        report = applyLANReplicationBatch(
            LANReplicationBatch(tick: 2, fullSnapshot: false, entities: [movedItem], entitySnapshotsComplete: true),
            to: clientWorld
        )

        XCTAssertEqual(report.appliedEntitySnapshots, 1)
        XCTAssertEqual(report.removedEntitySnapshots, 1)
        XCTAssertEqual(clientWorld.entities.compactMap { $0 as? ItemEntity }.first?.x, 4.5)
        XCTAssertEqual(clientWorld.entities.compactMap { $0 as? ItemEntity }.first?.stack.count, 8)
        XCTAssertTrue(clientWorld.entities.compactMap { $0 as? XPOrb }.isEmpty)

        report = applyLANReplicationBatch(
            LANReplicationBatch(tick: 3, fullSnapshot: false, entities: [], entitySnapshotsComplete: true),
            to: clientWorld
        )

        XCTAssertEqual(report.removedEntitySnapshots, 1)
        XCTAssertTrue(clientWorld.entities.allSatisfy { ($0 as? Entity)?.lanReplicatedMirror != true })
    }

    func testInvalidDroppedItemSnapshotsAreRejectedWithoutMutatingWorld() {
        let clientWorld = makeLoadedWorld()
        let invalidItem = LANEntitySnapshot(
            entityID: 1,
            type: "item",
            x: 0,
            y: 65,
            z: 0,
            yaw: 0,
            pitch: 0,
            health: nil,
            dead: false,
            itemID: itemDefs.count + 100,
            itemCount: 1
        )

        let report = applyLANReplicationBatch(
            LANReplicationBatch(tick: 1, fullSnapshot: false, entities: [invalidItem]),
            to: clientWorld
        )

        XCTAssertEqual(report.ignoredInvalidEntities, 1)
        XCTAssertTrue(clientWorld.entities.isEmpty)
    }

    func testBlockOnlyReplicationBatchDoesNotClearMirroredEntities() throws {
        let clientWorld = makeLoadedWorld()
        let itemSnapshot = LANEntitySnapshot(
            entityID: 22,
            type: "item",
            x: 1.5,
            y: 65,
            z: 2.5,
            yaw: 0,
            pitch: 0,
            health: nil,
            dead: false,
            itemID: iid("coal"),
            itemCount: 4
        )
        _ = applyLANReplicationBatch(
            LANReplicationBatch(tick: 1, fullSnapshot: false, entities: [itemSnapshot], entitySnapshotsComplete: true),
            to: clientWorld
        )
        XCTAssertEqual(clientWorld.entities.compactMap { $0 as? ItemEntity }.count, 1)

        let report = applyLANReplicationBatch(
            LANReplicationBatch(
                tick: 2,
                fullSnapshot: false,
                blockChanges: [LANBlockChange(dimension: Dim.overworld.rawValue, x: 1, y: 64, z: 1, cell: Int(B.dirt) << 4)]
            ),
            to: clientWorld
        )

        XCTAssertEqual(report.appliedBlockChanges, 1)
        XCTAssertEqual(report.removedEntitySnapshots, 0)
        XCTAssertEqual(clientWorld.entities.compactMap { $0 as? ItemEntity }.count, 1)
    }

    func testMirroredDroppedItemsAndXpCannotBePickedUpByLocalPlayerTick() {
        let world = makeLoadedWorld()
        let player = Player(world: world)
        player.setPos(1.5, 65, 1.5)
        world.addEntity(player)

        let item = ItemEntity(world: world)
        item.setPos(1.5, 65, 1.5)
        item.stack = ItemStack(iid("coal"), 4)
        item.pickupDelay = 0
        item.lanReplicationSourceID = 1
        item.lanReplicatedMirror = true
        world.addEntity(item)

        let orb = XPOrb(world: world)
        orb.setPos(1.5, 65, 1.5)
        orb.amount = 5
        orb.lanReplicationSourceID = 2
        orb.lanReplicatedMirror = true
        world.addEntity(orb)

        player.age = 1
        player.tick()

        XCTAssertFalse(item.dead)
        XCTAssertFalse(orb.dead)
        XCTAssertEqual(player.countItem(iid("coal")), 0)
        XCTAssertEqual(player.xp, 0)
    }

    func testMonsterDeathDropsReplicateToAllClientsAtAuthoritativeLocation() throws {
        let hostWorld = makeLoadedWorld()
        let mob = GuaranteedDropMob(world: hostWorld)
        mob.setPos(4.5, 65, 4.5)

        mob.die("test")

        let hostItem = try XCTUnwrap(hostWorld.entities.compactMap { $0 as? ItemEntity }.first)
        XCTAssertEqual(hostItem.stack, ItemStack(iid("coal"), 3))
        XCTAssertEqual(hostItem.x, mob.x, accuracy: 0.000_001)
        XCTAssertEqual(hostItem.y, mob.y + mob.height / 2, accuracy: 0.000_001)
        XCTAssertEqual(hostItem.z, mob.z, accuracy: 0.000_001)

        let snapshots = makeLANEntitySnapshots(in: hostWorld)
        let itemSnapshot = try XCTUnwrap(snapshots.first { $0.entityID == hostItem.id })
        XCTAssertEqual(itemSnapshot.itemID, iid("coal"))
        XCTAssertEqual(itemSnapshot.itemCount, 3)
        XCTAssertEqual(itemSnapshot.x, hostItem.x, accuracy: 0.000_001)
        XCTAssertEqual(itemSnapshot.y, hostItem.y, accuracy: 0.000_001)
        XCTAssertEqual(itemSnapshot.z, hostItem.z, accuracy: 0.000_001)

        let clientA = makeLoadedWorld()
        let clientB = makeLoadedWorld()
        let batch = LANReplicationBatch(tick: 10, fullSnapshot: false, entities: [itemSnapshot], entitySnapshotsComplete: true)
        XCTAssertEqual(applyLANReplicationBatch(batch, to: clientA).appliedEntitySnapshots, 1)
        XCTAssertEqual(applyLANReplicationBatch(batch, to: clientB).appliedEntitySnapshots, 1)

        let mirroredA = try XCTUnwrap(clientA.entities.compactMap { $0 as? ItemEntity }.first)
        let mirroredB = try XCTUnwrap(clientB.entities.compactMap { $0 as? ItemEntity }.first)
        XCTAssertTrue(mirroredA.lanReplicatedMirror)
        XCTAssertTrue(mirroredB.lanReplicatedMirror)
        XCTAssertEqual(mirroredA.stack, hostItem.stack)
        XCTAssertEqual(mirroredB.stack, hostItem.stack)
        XCTAssertEqual(mirroredA.x, hostItem.x, accuracy: 0.000_001)
        XCTAssertEqual(mirroredB.x, hostItem.x, accuracy: 0.000_001)
        XCTAssertEqual(mirroredA.y, hostItem.y, accuracy: 0.000_001)
        XCTAssertEqual(mirroredB.y, hostItem.y, accuracy: 0.000_001)
        XCTAssertEqual(mirroredA.z, hostItem.z, accuracy: 0.000_001)
        XCTAssertEqual(mirroredB.z, hostItem.z, accuracy: 0.000_001)
    }

    func testLANRemotePlayerPicksUpHostAuthoritativeDroppedItemsAndPublishesInventory() throws {
        let hostWorld = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1.5,
            y: 65,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        ))
        XCTAssertEqual(
            applyLANRemotePlayers(
                session.peerPlayerStates(),
                to: hostWorld,
                localPlayerID: "host",
                inventorySnapshots: session.peerInventorySnapshotsByPlayerID()
            ).spawned,
            1
        )
        let remote = try XCTUnwrap(hostWorld.entities.compactMap { $0 as? LANRemotePlayerEntity }.first)
        let item = spawnItem(hostWorld, 1.5, 65.5, 1.5, ItemStack(iid("coal"), 4))
        item.pickupDelay = 0

        remote.age = 1
        remote.tick()

        XCTAssertTrue(item.dead)
        XCTAssertEqual(remote.inventory[0], ItemStack(iid("coal"), 4))

        let remoteInventory = makeLANInventorySnapshot(remote)
        session.recordInventorySnapshot(remoteInventory, from: "peer-a")
        let batch = session.makeBatch(
            tick: 12,
            fullSnapshot: false,
            worldSummary: nil,
            worldState: nil,
            localPlayer: nil,
            chunkSections: [],
            entitySnapshots: makeLANEntitySnapshots(in: hostWorld),
            entitySnapshotsComplete: true,
            inventorySnapshots: []
        )

        let publishedInventory = try XCTUnwrap(batch.inventories.first { $0.playerID == "peer-a" })
        XCTAssertEqual(publishedInventory.slots, [
            LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 4),
        ])
        XCTAssertTrue(batch.entities.contains { $0.entityID == item.id && $0.dead })
    }

    func testHostSessionMakeBatchCarriesProvidedBlockEntitySnapshots() throws {
        let hostWorld = makeLoadedWorld()
        _ = hostWorld.setBlock(2, 64, 2, Int(B.barrel) << 4)
        let barrel = makeContainerBE(2, 64, 2, 27)
        barrel.items![0] = ItemStack(iid("coal"), 6)
        hostWorld.setBlockEntity(barrel)
        let blockEntitySnapshots = makeLANBlockEntitySnapshots(in: hostWorld)

        let batch = LANMultiplayerHostSession().makeBatch(
            tick: 13,
            fullSnapshot: false,
            worldSummary: nil,
            worldState: nil,
            localPlayer: nil,
            chunkSections: [],
            entitySnapshots: [],
            entitySnapshotsComplete: true,
            inventorySnapshots: [],
            blockEntitySnapshots: blockEntitySnapshots
        )

        let snapshot = try XCTUnwrap(batch.blockEntities.first)
        XCTAssertEqual(snapshot.type, "container")
        XCTAssertEqual(snapshot.slots, [
            LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("coal"), count: 6),
        ])
    }

    func testLANClientAppliesHostAuthoritativeInventorySnapshotToLocalPlayer() {
        let clientWorld = makeLoadedWorld()
        let player = Player(world: clientWorld)
        player.inventory[0] = ItemStack(iid("stick"), 1)
        player.xp = 0
        player.xpLevel = 0
        player.xpProgress = 0

        let snapshot = LANPlayerInventorySnapshot(
            playerID: "peer-a",
            selectedHotbarSlot: 2,
            slots: [
                LANInventorySlotSnapshot(slot: 2, itemID: iid("coal"), count: 4),
                LANInventorySlotSnapshot(slot: 9, itemID: iid("bone"), count: 2),
            ],
            xp: 7,
            xpLevel: 1,
            xpProgress: 0.25
        )

        XCTAssertTrue(applyLANInventorySnapshot(snapshot, to: player))
        XCTAssertNil(player.inventory[0])
        XCTAssertEqual(player.selectedSlot, 2)
        XCTAssertEqual(player.inventory[2], ItemStack(iid("coal"), 4))
        XCTAssertEqual(player.inventory[9], ItemStack(iid("bone"), 2))
        XCTAssertEqual(player.xp, 7)
        XCTAssertEqual(player.xpLevel, 1)
        XCTAssertEqual(player.xpProgress, 0.25, accuracy: 0.000_001)

        let invalid = LANPlayerInventorySnapshot(
            playerID: "peer-a",
            selectedHotbarSlot: 0,
            slots: [LANInventorySlotSnapshot(slot: 0, itemID: itemDefs.count + 100, count: 1)]
        )
        XCTAssertFalse(applyLANInventorySnapshot(invalid, to: player))
        XCTAssertNil(player.inventory[0])
        XCTAssertEqual(player.inventory[2], ItemStack(iid("coal"), 4))
    }

    func testReplicationBatchCapsLargePayloadCollections() {
        let changes = (0..<(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES + 10)).map {
            LANBlockChange(dimension: 0, x: $0, y: 64, z: 0, cell: 0)
        }
        let entities = (0..<(LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES + 10)).map {
            LANEntitySnapshot(entityID: $0, type: "zombie", x: 0, y: 64, z: 0, yaw: 0, pitch: 0, health: 20, dead: false)
        }
        let blockEntities = (0..<(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES + 10)).map {
            LANBlockEntitySnapshot(
                dimension: 0,
                x: $0,
                y: 64,
                z: 0,
                type: "container",
                slotCount: 27,
                slots: [LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)]
            )
        }

        let batch = LANReplicationBatch(
            tick: 1,
            fullSnapshot: false,
            blockChanges: changes,
            entities: entities,
            blockEntities: blockEntities
        )

        XCTAssertEqual(batch.blockChanges.count, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES)
        XCTAssertEqual(batch.entities.count, LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES)
        XCTAssertEqual(batch.blockEntities.count, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES)
        XCTAssertTrue(batch.isWithinReplicationCaps)
    }

    func testMaximumChunkSectionBatchFitsFrameCap() throws {
        let section = LANChunkSectionSnapshot(
            dimension: 0,
            cx: 0,
            cz: 0,
            sectionY: 0,
            minY: -64,
            cells: Array(repeating: UInt16.max, count: LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        )
        let batch = LANReplicationBatch(
            tick: 1,
            fullSnapshot: true,
            chunkSections: Array(repeating: section, count: LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS)
        )

        let encoded = try LANMultiplayerFrameCodec.encode(.replicationBatch(batch))

        XCTAssertLessThanOrEqual(encoded.count, LANMultiplayerFrameCodec.headerByteCount + LAN_MULTIPLAYER_MAX_FRAME_BYTES)
    }

    func testInitialSnapshotChunkSectionsAndBlockEntitiesFitFrameCap() throws {
        let section = LANChunkSectionSnapshot(
            dimension: 0,
            cx: 0,
            cz: 0,
            sectionY: 0,
            minY: -64,
            cells: Array(repeating: UInt16.max, count: LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        )
        let slots = (0..<LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS).map {
            LANBlockEntitySlotSnapshot(slot: $0, itemID: iid("stone"), count: 64)
        }
        let blockEntities = (0..<16).map {
            LANBlockEntitySnapshot(
                dimension: 0,
                x: $0,
                y: 64,
                z: 0,
                type: "container",
                slotCount: LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS,
                slots: slots
            )
        }
        let batch = LANReplicationBatch(
            tick: 1,
            fullSnapshot: true,
            chunkSections: Array(repeating: section, count: LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS),
            blockEntities: blockEntities
        )

        let encoded = try LANMultiplayerFrameCodec.encode(.replicationBatch(batch))

        XCTAssertLessThanOrEqual(encoded.count, LANMultiplayerFrameCodec.headerByteCount + LAN_MULTIPLAYER_MAX_FRAME_BYTES)
    }

    func testVisibleChunkRequestCoversNeighborReadyAreaWithinFrameCap() throws {
        let world = makeVisibleNeighborhoodWorld(surfaceY: 63)
        let request = LANChunkRequest(
            dimension: Dim.overworld.rawValue,
            cx: 0,
            cz: 0,
            radius: LAN_MULTIPLAYER_DEFAULT_CHUNK_REQUEST_RADIUS,
            centerY: 64,
            verticalRadius: LAN_MULTIPLAYER_DEFAULT_CHUNK_VERTICAL_RADIUS
        )

        let snapshots = makeLANChunkSectionSnapshots(for: request, in: world)
        let chunkKeys = Set(snapshots.map { "\($0.cx),\($0.cz)" })
        let encoded = try LANMultiplayerFrameCodec.encode(.replicationBatch(LANReplicationBatch(
            tick: 1,
            fullSnapshot: true,
            chunkSections: snapshots
        )))

        XCTAssertEqual(chunkKeys.count, 9)
        XCTAssertLessThanOrEqual(snapshots.count, LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS)
        XCTAssertLessThanOrEqual(encoded.count, LANMultiplayerFrameCodec.headerByteCount + LAN_MULTIPLAYER_MAX_FRAME_BYTES)
        XCTAssertEqual(snapshots.first?.cx, 0)
        XCTAssertEqual(snapshots.first?.cz, 0)
    }

    func testLegacySingleChunkRequestStillReturnsFullChunkSections() {
        let world = makeVisibleNeighborhoodWorld(surfaceY: 63)
        let request = LANChunkRequest(dimension: Dim.overworld.rawValue, cx: 0, cz: 0, radius: 0)

        let snapshots = makeLANChunkSectionSnapshots(for: request, in: world)

        XCTAssertEqual(snapshots.count, world.info.height / SECTION_H)
        XCTAssertTrue(snapshots.allSatisfy { $0.cx == 0 && $0.cz == 0 })
    }

    // MARK: - W2: entitySnapshotsComplete purge gating

    func testEntitySnapshotsCompleteFalseDoesNotPurgeMissingMirrorsClientSide() {
        let clientWorld = makeLoadedWorld()
        let first = LANEntitySnapshot(entityID: 1, type: "zombie", x: 1, y: 64, z: 1, yaw: 0, pitch: 0, health: 20, dead: false)
        let second = LANEntitySnapshot(entityID: 2, type: "zombie", x: 2, y: 64, z: 2, yaw: 0, pitch: 0, health: 20, dead: false)

        _ = applyLANReplicationBatch(
            LANReplicationBatch(tick: 1, fullSnapshot: false, entities: [first, second], entitySnapshotsComplete: true),
            to: clientWorld
        )
        XCTAssertEqual(clientWorld.entities.compactMap { $0 as? Zombie }.count, 2)

        // A truncated batch (entitySnapshotsComplete=false) omitting `second` must NOT purge it.
        let truncated = applyLANReplicationBatch(
            LANReplicationBatch(tick: 2, fullSnapshot: false, entities: [first], entitySnapshotsComplete: false),
            to: clientWorld
        )
        XCTAssertEqual(truncated.removedEntitySnapshots, 0)
        XCTAssertEqual(clientWorld.entities.compactMap { $0 as? Zombie }.count, 2)

        // A complete batch omitting `second` DOES purge it.
        let complete = applyLANReplicationBatch(
            LANReplicationBatch(tick: 3, fullSnapshot: false, entities: [first], entitySnapshotsComplete: true),
            to: clientWorld
        )
        XCTAssertEqual(complete.removedEntitySnapshots, 1)
        XCTAssertEqual(clientWorld.entities.compactMap { $0 as? Zombie }.count, 1)
    }

    func testHostSessionMakeBatchPassesThroughEntitySnapshotsCompleteFlag() {
        let session = LANMultiplayerHostSession()

        let incomplete = session.makeBatch(
            tick: 1,
            fullSnapshot: false,
            worldSummary: nil,
            worldState: nil,
            localPlayer: nil,
            chunkSections: [],
            entitySnapshots: [],
            entitySnapshotsComplete: false,
            inventorySnapshots: []
        )
        XCTAssertFalse(incomplete.entitySnapshotsComplete)

        let complete = session.makeBatch(
            tick: 2,
            fullSnapshot: false,
            worldSummary: nil,
            worldState: nil,
            localPlayer: nil,
            chunkSections: [],
            entitySnapshots: [],
            entitySnapshotsComplete: true,
            inventorySnapshots: []
        )
        XCTAssertTrue(complete.entitySnapshotsComplete)
    }

    // MARK: - W2 amendment A1: entity snapshot dimension filtering

    func testEntitySnapshotDimensionFilterDropsCrossDimensionSnapshotsAndPreservesOtherDimensionMirrors() {
        let overworld = makeLoadedWorld()

        let overworldZombie = LANEntitySnapshot(
            entityID: 10, type: "zombie", x: 1, y: 64, z: 1, yaw: 0, pitch: 0, health: 20, dead: false,
            dimension: Dim.overworld.rawValue
        )
        var report = applyLANEntitySnapshots([overworldZombie], to: overworld)
        XCTAssertEqual(report.appliedEntitySnapshots, 1)
        XCTAssertEqual(overworld.entities.compactMap { $0 as? Zombie }.count, 1)

        // A nether-tagged snapshot must be dropped (never materialized) in an overworld world, even
        // as an incomplete/delta batch that does not otherwise reference the overworld mirror.
        let netherZombie = LANEntitySnapshot(
            entityID: 11, type: "zombie", x: 2, y: 64, z: 2, yaw: 0, pitch: 0, health: 20, dead: false,
            dimension: Dim.nether.rawValue
        )
        report = applyLANEntitySnapshots([netherZombie], to: overworld, removeMissing: false)
        XCTAssertEqual(report.appliedEntitySnapshots, 0)
        XCTAssertEqual(report.ignoredInvalidEntities, 1)
        XCTAssertEqual(overworld.entities.compactMap { $0 as? Zombie }.count, 1)

        // A complete-list purge pass that still includes the overworld snapshot alongside the
        // dropped cross-dimension one must keep the overworld mirror (it IS in the wanted set) —
        // the purge only removes mirrors that are genuinely absent from the complete list.
        report = applyLANEntitySnapshots([overworldZombie, netherZombie], to: overworld, removeMissing: true)
        XCTAssertEqual(report.removedEntitySnapshots, 0)
        XCTAssertEqual(overworld.entities.compactMap { $0 as? Zombie }.count, 1)
    }

    func testMakeLANEntitySnapshotsStampsHostWorldDimension() {
        let nether = World(dim: .nether, seed: 7)
        let zombie = Zombie(world: nether)
        zombie.setPos(1.5, 64, 1.5)
        nether.addEntity(zombie)

        let snapshots = makeLANEntitySnapshots(in: nether)

        XCTAssertEqual(snapshots.first?.dimension, Dim.nether.rawValue)
    }

    func testMirroredEntityVelocityIsSetFromSnapshotNotZeroed() {
        let world = makeLoadedWorld()
        let snapshot = LANEntitySnapshot(
            entityID: 20, type: "zombie", x: 1, y: 64, z: 1, yaw: 0, pitch: 0, health: 20, dead: false,
            vx: 1.5, vy: -0.5, vz: 2.5, onGround: true, fire: true
        )

        _ = applyLANEntitySnapshots([snapshot], to: world)

        let mirror = try! XCTUnwrap(world.entities.compactMap { $0 as? Zombie }.first)
        XCTAssertEqual(mirror.vx, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(mirror.vy, -0.5, accuracy: 0.000_001)
        XCTAssertEqual(mirror.vz, 2.5, accuracy: 0.000_001)
        XCTAssertTrue(mirror.onGround)
        XCTAssertGreaterThan(mirror.fireTicks, 0)
    }

    // MARK: - W2: container edit intent

    func testApplyContainerEditIntentAppliesValidDepositAndStoresPeerInventory() throws {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession()
        let chestCell = Int(B.chest) << 4
        _ = world.setBlock(2, 64, 1, chestCell)
        let chest = makeContainerBE(2, 64, 1, 27)
        world.setBlockEntity(chest)

        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("diamond"), count: 2),
                LANInventorySlotSnapshot(slot: 1, itemID: iid("stick"), count: 3),
            ]),
            from: "peer-a"
        )

        var slots = [LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("diamond"), count: 2)]
        let editedBE = LANBlockEntitySnapshot(
            dimension: Dim.overworld.rawValue,
            x: 2, y: 64, z: 1,
            type: "container",
            slotCount: 27,
            slots: slots
        )
        let inventory = LANPlayerInventorySnapshot(
            playerID: "peer-a",
            selectedHotbarSlot: 0,
            slots: [LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 3)]
        )
        let intent = LANContainerEditIntent(blockEntity: editedBE, inventory: inventory, revision: 1, editSeq: 1)

        let result = session.applyContainerEditIntent(intent, from: "peer-a", to: world)
        guard case .applied(let be) = result else {
            return XCTFail("expected .applied, got \(result)")
        }
        XCTAssertEqual(be.slots.first?.itemID, iid("diamond"))
        let stored = try XCTUnwrap(world.getBlockEntity(2, 64, 1))
        XCTAssertEqual(stored.items?[0], ItemStack(iid("diamond"), 2))
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first?.itemID, iid("stick"))
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventoryRevision, 1)

        // wrong-type/incompatible cell rejected
        slots = [LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("diamond"), count: 1)]
        _ = world.setBlock(3, 64, 1, Int(B.stone) << 4)
        let incompatible = LANContainerEditIntent(
            blockEntity: LANBlockEntitySnapshot(dimension: Dim.overworld.rawValue, x: 3, y: 64, z: 1, type: "container", slotCount: 27, slots: slots),
            inventory: inventory,
            revision: 2,
            editSeq: 2
        )
        let rejected = session.applyContainerEditIntent(incompatible, from: "peer-a", to: world)
        XCTAssertEqual(rejected, .rejected("incompatible container target"))

        // out-of-reach rejected
        let farSession = makeAcceptedHostSession(x: 500, y: 64, z: 500)
        let farResult = farSession.applyContainerEditIntent(intent, from: "peer-a", to: world)
        XCTAssertEqual(farResult, .rejected("target out of reach"))
    }

    func testAcceptPeerSeedsEmptyInventoryBaselineForContainerValidation() throws {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession()
        _ = world.setBlock(2, 64, 1, Int(B.chest) << 4)
        let chest = makeContainerBE(2, 64, 1, 27)
        chest.items![0] = ItemStack(iid("coal"), 1)
        world.setBlockEntity(chest)

        let intent = LANContainerEditIntent(
            blockEntity: LANBlockEntitySnapshot(
                dimension: Dim.overworld.rawValue,
                x: 2, y: 64, z: 1,
                type: "container",
                slotCount: 27,
                slots: []
            ),
            inventory: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1),
            ]),
            revision: 1,
            editSeq: 1
        )

        let result = session.applyContainerEditIntent(intent, from: "peer-a", to: world)
        guard case .applied = result else {
            return XCTFail("expected .applied, got \(result)")
        }
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first?.itemID, iid("coal"))
    }

    func testApplyContainerEditIntentRejectsNonConservativeItemCreation() throws {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession()
        _ = world.setBlock(2, 64, 1, Int(B.chest) << 4)
        world.setBlockEntity(makeContainerBE(2, 64, 1, 27))
        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: []),
            from: "peer-a"
        )

        let intent = LANContainerEditIntent(
            blockEntity: LANBlockEntitySnapshot(
                dimension: Dim.overworld.rawValue,
                x: 2, y: 64, z: 1,
                type: "container",
                slotCount: 27,
                slots: [LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("diamond"), count: 1)]
            ),
            inventory: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: []),
            revision: 1,
            editSeq: 1
        )

        XCTAssertEqual(
            session.applyContainerEditIntent(intent, from: "peer-a", to: world),
            .rejected("container edit is not host-verifiable")
        )
        let chest = try XCTUnwrap(world.getBlockEntity(2, 64, 1))
        XCTAssertNil(chest.items?[0])
        XCTAssertNil(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first)
    }

    func testApplyContainerEditIntentAllowsCraftingTableRecipeTransform() throws {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession()
        _ = world.setBlock(2, 64, 1, Int(B.crafting_table) << 4)
        let table = makeCraftingTableBE(2, 64, 1)
        table.items![0] = ItemStack(iid("oak_planks"), 1)
        table.items![3] = ItemStack(iid("oak_planks"), 1)
        world.setBlockEntity(table)
        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: []),
            from: "peer-a"
        )

        let beforeGrid = try XCTUnwrap(table.items)
        let plan = try XCTUnwrap(currentCraftingPlan(from: beforeGrid, gridWidth: 3, gridHeight: 3))
        XCTAssertEqual(itemDef(plan.output.id).name, "stick")
        XCTAssertEqual(plan.output.count, 4)

        let intent = LANContainerEditIntent(
            blockEntity: LANBlockEntitySnapshot(
                dimension: Dim.overworld.rawValue,
                x: 2, y: 64, z: 1,
                type: "crafting",
                slotCount: 9,
                slots: []
            ),
            inventory: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 4),
            ]),
            revision: 1,
            editSeq: 1
        )

        let result = session.applyContainerEditIntent(intent, from: "peer-a", to: world)
        guard case .applied(let be) = result else {
            return XCTFail("expected .applied, got \(result)")
        }
        XCTAssertTrue(be.slots.isEmpty)
        let updatedTable = try XCTUnwrap(world.getBlockEntity(2, 64, 1))
        XCTAssertEqual(updatedTable.items?.compactMap { $0 }.count, 0)
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first?.itemID, iid("stick"))
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first?.count, 4)
    }

    func testApplyContainerEditIntentDirtiesBlockEntityQueue() {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession()
        _ = world.setBlock(2, 64, 1, Int(B.chest) << 4)
        world.setBlockEntity(makeContainerBE(2, 64, 1, 27))
        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1),
            ]),
            from: "peer-a"
        )

        let editedBE = LANBlockEntitySnapshot(
            dimension: Dim.overworld.rawValue, x: 2, y: 64, z: 1, type: "container", slotCount: 27,
            slots: [LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)]
        )
        let intent = LANContainerEditIntent(
            blockEntity: editedBE,
            inventory: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: []),
            revision: 1,
            editSeq: 1
        )
        _ = session.applyContainerEditIntent(intent, from: "peer-a", to: world)

        XCTAssertEqual(session.drainDirtyBlockEntities(), [
            LANBlockPosition(dimension: Dim.overworld.rawValue, x: 2, y: 64, z: 1),
        ])
        XCTAssertTrue(session.drainDirtyBlockEntities().isEmpty)
    }

    // MARK: - W2: inventory revision gating

    func testApplyInventoryUpdateGatesOnStrictlyGreaterRevisionAndRejectsInvalidSlots() {
        let session = makeAcceptedHostSession()

        let first = LANInventoryUpdate(
            playerID: "peer-a",
            revision: 1,
            snapshot: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 5),
            ])
        )
        XCTAssertTrue(session.applyInventoryUpdate(first, from: "peer-a"))
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first?.count, 5)
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventoryRevision, 1)

        // equal revision ignored
        let equal = LANInventoryUpdate(
            playerID: "peer-a",
            revision: 1,
            snapshot: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 99),
            ])
        )
        XCTAssertFalse(session.applyInventoryUpdate(equal, from: "peer-a"))
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first?.count, 5)

        // lower revision ignored
        let lower = LANInventoryUpdate(
            playerID: "peer-a",
            revision: 0,
            snapshot: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 1),
            ])
        )
        XCTAssertFalse(session.applyInventoryUpdate(lower, from: "peer-a"))
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first?.count, 5)

        // higher revision applies
        let higher = LANInventoryUpdate(
            playerID: "peer-a",
            revision: 2,
            snapshot: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 12),
            ])
        )
        XCTAssertTrue(session.applyInventoryUpdate(higher, from: "peer-a"))
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first?.count, 12)
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventoryRevision, 2)

        // invalid slot rejects the whole update (fail closed) — revision stays at 2
        let invalidSlot = LANInventoryUpdate(
            playerID: "peer-a",
            revision: 3,
            snapshot: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: itemDefs.count + 100, count: 1),
            ])
        )
        XCTAssertFalse(session.applyInventoryUpdate(invalidSlot, from: "peer-a"))
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventoryRevision, 2)
        XCTAssertEqual(session.peerRecord(playerID: "peer-a")?.inventory?.slots.first?.count, 12)
    }

    // MARK: - W2: grant idempotency

    func testEnqueueGrantProducesMonotoneGrantIDsAndDrainsInOrder() {
        let session = makeAcceptedHostSession()

        let first = session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)], xp: 0, clearAll: false, to: "peer-a")
        let second = session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 1, itemID: iid("stick"), count: 2)], xp: 5, clearAll: false, to: "peer-a")

        XCTAssertEqual(first?.grantID, 1)
        XCTAssertEqual(second?.grantID, 2)

        let drained = session.drainGrants(for: "peer-a")
        XCTAssertEqual(drained.map(\.grantID), [1, 2])
        XCTAssertTrue(session.drainGrants(for: "peer-a").isEmpty)

        XCTAssertEqual(session.peerRestoreState(playerID: "peer-a")?.grantID, 2)
    }

    func testDrainAllGrantsReturnsDeterministicPlayerIDOrder() {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-b", displayName: "Bea")
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")

        _ = session.enqueueGrant(items: [], xp: 1, clearAll: false, to: "peer-b")
        _ = session.enqueueGrant(items: [], xp: 2, clearAll: false, to: "peer-a")

        let drained = session.drainAllGrants()
        XCTAssertEqual(drained.map(\.playerID), ["peer-a", "peer-b"])
        XCTAssertTrue(session.drainAllGrants().isEmpty)
    }

    // MARK: - W2: ghost actor

    func testGhostBreakSpawnsDropsConsumesToolDurabilityAndRecordsBlockChange() throws {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession()
        world.hooks.onBlockChanged = { [weak session] x, y, z, _, newCell, _ in
            _ = session?.recordBlockChange(dimension: world.dim.rawValue, x: x, y: y, z: z, cell: newCell)
        }
        _ = world.setBlock(2, 64, 1, Int(B.stone) << 4)

        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a", displayName: "Alex", x: 2.5, y: 64, z: 1.5, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival
        ))
        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_pickaxe"), count: 1, damage: 0),
            ]),
            from: "peer-a"
        )

        let registry = LANHostGhostRegistry()
        let outcome = registry.applyBreak(for: "peer-a", x: 2, y: 64, z: 1, world: world, session: session)

        XCTAssertTrue(outcome.broke)
        XCTAssertEqual(world.getBlock(2, 64, 1), 0)
        let drop = try XCTUnwrap(world.entities.compactMap { $0 as? ItemEntity }.first)
        XCTAssertEqual(drop.stack.id, iid("cobblestone"))
        XCTAssertEqual(outcome.inventory.slots.first?.itemID, iid("iron_pickaxe"))
        XCTAssertEqual(outcome.inventory.slots.first?.damage, 1)
        XCTAssertEqual(session.drainBlockChanges(), [
            LANBlockChange(dimension: Dim.overworld.rawValue, x: 2, y: 64, z: 1, cell: 0),
        ])
    }

    func testGhostBreakSpillsContainerContentsAndMarksDirtyBlockEntity() throws {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession()
        _ = world.setBlock(2, 64, 1, Int(B.chest) << 4)
        let chest = makeContainerBE(2, 64, 1, 27)
        chest.items![0] = ItemStack(iid("diamond"), 2)
        world.setBlockEntity(chest)

        let registry = LANHostGhostRegistry()
        let outcome = registry.applyBreak(for: "peer-a", x: 2, y: 64, z: 1, world: world, session: session)

        XCTAssertTrue(outcome.broke)
        XCTAssertEqual(outcome.spilledContainerAt, LANBlockPosition(dimension: Dim.overworld.rawValue, x: 2, y: 64, z: 1))
        XCTAssertTrue(world.entities.compactMap { $0 as? ItemEntity }.contains { $0.stack.id == iid("diamond") })
        XCTAssertEqual(session.drainDirtyBlockEntities(), [
            LANBlockPosition(dimension: Dim.overworld.rawValue, x: 2, y: 64, z: 1),
        ])
    }

    func testGhostAttackHurtsRealMobRejectsProxyTargetsAndReturnsDurabilityDelta() throws {
        let world = makeLoadedWorld()
        let session = makeAcceptedHostSession()
        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_sword"), count: 1, damage: 0),
            ]),
            from: "peer-a"
        )
        let zombie = Zombie(world: world)
        zombie.setPos(3, 64, 1.5)
        zombie.health = 20
        world.addEntity(zombie)

        let registry = LANHostGhostRegistry()
        let outcome = registry.applyAttack(for: "peer-a", targetEntityID: zombie.id, world: world, session: session)

        XCTAssertTrue(outcome.attacked)
        XCTAssertLessThan(zombie.health, 20)
        XCTAssertEqual(outcome.inventory.slots.first?.itemID, iid("iron_sword"))

        // Attacking a proxy (PvE only, D-K) must be rejected.
        let proxy = LANRemotePlayerEntity(world: world, state: LANPlayerState(
            playerID: "peer-b", displayName: "Bea", x: 3, y: 64, z: 1.5, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival
        ))
        world.addEntity(proxy)
        let rejected = registry.applyAttack(for: "peer-a", targetEntityID: proxy.id, world: world, session: session)
        XCTAssertFalse(rejected.attacked)
        XCTAssertEqual(rejected.reason, "PvP not supported")
    }

    func testProxyHurtRecordsDamageEventLeavesHealthUnchangedAndReturnsFalse() {
        let world = makeLoadedWorld()
        let proxy = LANRemotePlayerEntity(world: world, state: LANPlayerState(
            playerID: "peer-a", displayName: "Alex", x: 1, y: 64, z: 1, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival
        ))
        world.addEntity(proxy)

        let attacker = Zombie(world: world)
        attacker.setPos(2, 64, 1)

        let result = proxy.hurt(4, "mob", attacker)

        XCTAssertFalse(result)
        XCTAssertEqual(proxy.health, 20)
        let events = proxy.drainPendingDamage()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.playerID, "peer-a")
        XCTAssertEqual(events.first?.amount, 4)
        XCTAssertTrue(proxy.drainPendingDamage().isEmpty)

        // no-op damage does not enqueue an event
        XCTAssertFalse(proxy.hurt(0, "mob", attacker))
        XCTAssertTrue(proxy.drainPendingDamage().isEmpty)
    }

    // MARK: - W2: death drops

    func testConsumeDeathDropsFiresExactlyOncePerEpochAcrossDeadAliveFlaps() {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("diamond"), count: 1),
            ]),
            from: "peer-a"
        )
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a", displayName: "Alex", x: 1, y: 64, z: 1, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival
        ))

        // alive -> dead transition
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a", displayName: "Alex", x: 1, y: 64, z: 1, yaw: 0, pitch: 0,
            health: 0, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival, dead: true
        ))

        let firstDrop = session.consumeDeathDrops(for: "peer-a")
        XCTAssertNotNil(firstDrop)
        XCTAssertEqual(firstDrop?.inventory.slots.first?.itemID, iid("diamond"))
        XCTAssertNil(session.consumeDeathDrops(for: "peer-a"), "must not fire twice within the same epoch")

        // dead -> alive (respawn) -> dead again: new epoch, drop fires again
        session.setPermissions(LANPeerPermissions(canRespawn: true), for: "peer-a")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a", displayName: "Alex", x: 1, y: 64, z: 1, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival, dead: false
        ))
        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 1),
            ]),
            from: "peer-a"
        )
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a", displayName: "Alex", x: 2, y: 65, z: 2, yaw: 0, pitch: 0,
            health: 0, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival, dead: true
        ))

        let secondDrop = session.consumeDeathDrops(for: "peer-a")
        XCTAssertNotNil(secondDrop)
        XCTAssertEqual(secondDrop?.inventory.slots.first?.itemID, iid("stick"))
        XCTAssertEqual(secondDrop?.x, 2)
        XCTAssertEqual(secondDrop?.y, 65)
        XCTAssertEqual(secondDrop?.z, 2)
        XCTAssertNil(session.consumeDeathDrops(for: "peer-a"))
    }

    func testSpawnPlayerDeathDropsSpawnsExpectedItemEntitiesAndXp() {
        let world = makeLoadedWorld()
        let inventory = LANPlayerInventorySnapshot(
            playerID: "peer-a",
            selectedHotbarSlot: 0,
            slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: iid("diamond"), count: 3),
                LANInventorySlotSnapshot(slot: 5, itemID: iid("stick"), count: 1),
            ],
            xpLevel: 4
        )

        spawnPlayerDeathDrops(inventory: inventory, at: 5, 64, 5, in: world)

        let drops = world.entities.compactMap { $0 as? ItemEntity }
        XCTAssertEqual(drops.count, 2)
        XCTAssertTrue(drops.contains { $0.stack.id == iid("diamond") && $0.stack.count == 3 })
        XCTAssertTrue(drops.contains { $0.stack.id == iid("stick") && $0.stack.count == 1 })
        let orbs = world.entities.compactMap { $0 as? XPOrb }
        XCTAssertFalse(orbs.isEmpty)
        XCTAssertEqual(orbs.reduce(0) { $0 + $1.amount }, 28)
    }

    // MARK: - W2 amendment A4: requeueBlockChanges

    func testRequeueBlockChangesRestoresDrainedChangesForRedrain() {
        let session = LANMultiplayerHostSession()
        _ = session.recordBlockChange(dimension: 0, x: 1, y: 64, z: 1, cell: Int(B.dirt) << 4)
        _ = session.recordBlockChange(dimension: 0, x: 2, y: 64, z: 1, cell: Int(B.stone) << 4)

        let drained = session.drainBlockChanges()
        XCTAssertEqual(drained.count, 2)
        XCTAssertTrue(session.drainBlockChanges().isEmpty)

        session.requeueBlockChanges(drained)
        let redrained = session.drainBlockChanges()
        XCTAssertEqual(redrained.sorted { $0.x < $1.x }, drained.sorted { $0.x < $1.x })
        XCTAssertTrue(session.drainBlockChanges().isEmpty)
    }

    private func makeAcceptedHostSession(
        x: Double = 2.5,
        y: Double = 64,
        z: Double = 1.5,
        yaw: Double = 0,
        dimension: Int = Dim.overworld.rawValue
    ) -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: x,
            y: y,
            z: z,
            yaw: yaw,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dimension: dimension
        ))
        return session
    }

    private func forceSetBlock(_ world: World, x: Int, y: Int, z: Int, cell: Int) {
        guard let chunk = world.getChunkAt(x, z), chunk.inYRange(y) else {
            XCTFail("test fixture missing loaded chunk at \(x),\(y),\(z)")
            return
        }
        chunk.set(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W), UInt16(cell))
    }

    private func makeLoadedWorld() -> World {
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }

    private func makeVisibleNeighborhoodWorld(surfaceY: Int) -> World {
        let world = World(dim: .overworld, seed: 42)
        for cz in -1...1 {
            for cx in -1...1 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                for z in 0..<CHUNK_W {
                    for x in 0..<CHUNK_W {
                        chunk.set(x, surfaceY, z, UInt16(Int(B.stone) << 4))
                    }
                }
                chunk.status = .generated
                chunk.buildHeightmap()
                world.setChunk(chunk)
            }
        }
        return world
    }

    private final class GuaranteedDropMob: LivingEntity {
        override var type: String { "guaranteed_drop_mob" }

        override init(world: World) {
            super.init(world: world)
            width = 0.6
            height = 1.8
            maxHealth = 10
            health = 10
        }

        override func drops() -> [DropEntry] {
            [DropEntry("coal", min: 3, max: 3, chance: 1)]
        }
    }
}
