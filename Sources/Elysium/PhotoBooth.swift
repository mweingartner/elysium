// Visual census rig (ELYSIUM_PHOTOBOOTH=1) — captures EVERY mob and EVERY block
// in-game, exactly as rendered (current settings/packs/shaders), to
// /tmp/vc-captures/{mobs,blocks}/<name>[@angle].png (or the directory supplied
// by ELYSIUM_BOOTH_OUTPUT). Drives the real sim:
// builds a lit platform, summons/places each subject, settles a few ticks,
// then reads back the scene framebuffer (no UI) and writes a PNG. Set
// ELYSIUM_BOOTH_SIDE_ONLY=1 for one exact side-view portrait per subject.

import AppKit
import Foundation
import ImageIO
import Metal
import ElysiumCore

final class PhotoBooth {
    private let game: GameCore
    private let renderer: WorldRenderer

    private enum Phase {
        case warmup
        case buildSet
        case mobs
        case blocks
        case textureAudit
        case done
    }
    private var phase = Phase.warmup
    private var tick = 0
    private var lastWorldTime = -1
    private var subjectIdx = 0
    private var subjectTick = 0
    private var angleIdx = 0
    private var mobList: [String] = []
    private var blockList: [Int] = []
    private var currentMob: Entity?
    private var captured = 0
    private let outRoot: String
    private let sideOnly: Bool
    private let textureAuditScope: String?
    private var textureAuditShots: [TextureAuditShot] = []
    private var textureAuditView = 0

    /// A deliberately small capture recipe.  It can place compound models
    /// (notably both halves of a door) and request both sides of asymmetric
    /// stateful art without changing the user's loaded save.
    private struct TextureAuditCell {
        let dx: Int
        let dy: Int
        let dz: Int
        let id: UInt16
        let meta: Int
    }

    private struct TextureAuditShot {
        let label: String
        let cells: [TextureAuditCell]
        /// Horizontal camera directions that see the intended broad faces.
        let views: [Int]
    }

    /// World-space bounds of a mesh-authored prehistoric presentation, used
    /// only by the side-view census. Collision dimensions deliberately stay
    /// compact for gameplay and are too small to frame a Microraptor's wings
    /// or a sauropod's full profile.
    private struct VisualBounds {
        /// The maximum screen-plane dimension for the fixed +X camera used by
        /// a true side portrait.  Deliberately excludes X/depth: a pterosaur's
        /// wingspan and a Microraptor's lateral flight feathers must not make
        /// an otherwise compact profile look tiny in its own capture.
        let sideSpan: Double
        let height: Double
        let centerY: Double
    }

    // set geometry
    private let SX = 0, SY = 200, SZ = 0          // subject position

    init(game: GameCore, renderer: WorldRenderer) {
        self.game = game
        self.renderer = renderer
        let environment = ProcessInfo.processInfo.environment
        self.sideOnly = environment["ELYSIUM_BOOTH_SIDE_ONLY"] == "1"
        self.outRoot = environment["ELYSIUM_BOOTH_OUTPUT"] ?? "/tmp/vc-captures"
        self.textureAuditScope = environment["ELYSIUM_BOOTH_TEXTURE_AUDIT"]?.lowercased()
        // The usual census retains its historical /tmp default.  Stateful
        // texture audits are review artifacts, so require an explicit caller
        // destination and a fresh test world instead of leaving an unbounded
        // capture set behind or altering a loaded save.
        let auditHasExplicitOutput = textureAuditScope == nil || environment["ELYSIUM_BOOTH_OUTPUT"] != nil
        let auditHasFreshWorld = textureAuditScope == nil || environment["ELYSIUM_NEWWORLD"] != nil
        let auditReady = auditHasExplicitOutput && auditHasFreshWorld
        if auditReady {
            try? FileManager.default.createDirectory(atPath: outRoot + "/mobs", withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: outRoot + "/blocks", withIntermediateDirectories: true)
            if textureAuditScope != nil {
                try? FileManager.default.createDirectory(atPath: outRoot + "/texture-audit", withIntermediateDirectories: true)
            }
        }
        mobList = spawnableMobs().sorted()
        blockList = (1..<blockDefs.count).filter { id in
            let n = blockDefs[id].name
            return n != "air" && n != "cave_air" && n != "void_air" && n != "moving_piston"
                && n != "end_portal" && n != "end_gateway" && n != "bubble_column"
        }
        // ELYSIUM_BOOTH_MOBS / ELYSIUM_BOOTH_BLOCKS: comma lists to shoot a subset
        // ("-" = none); unset = full census. ELYSIUM_BOOTH_SIDE_ONLY=1
        // records a single exact side instead of the normal face/back pair;
        // ELYSIUM_BOOTH_OUTPUT supplies an isolated capture root.
        if let f = ProcessInfo.processInfo.environment["ELYSIUM_BOOTH_MOBS"] {
            let want = Set(f.components(separatedBy: ","))
            mobList = f == "-" ? [] : mobList.filter { want.contains($0) }
        }
        if let f = ProcessInfo.processInfo.environment["ELYSIUM_BOOTH_BLOCKS"] {
            let want = Set(f.components(separatedBy: ","))
            blockList = f == "-" ? [] : blockList.filter { want.contains(blockDefs[$0].name) }
        }
        if let textureAuditScope {
            guard auditReady else {
                mobList = []
                blockList = []
                phase = .done
                print("[booth] texture audit requires ELYSIUM_BOOTH_OUTPUT and ELYSIUM_NEWWORLD; no captures queued")
                fflush(stdout)
                return
            }
            mobList = []
            blockList = []
            textureAuditShots = makeTextureAuditShots(scope: textureAuditScope)
            print("[booth] \(textureAuditShots.count) stateful texture subjects queued (explicit output)")
            fflush(stdout)
            return
        }
        let viewDescription = sideOnly ? "side-only" : "face/back"
        print("[booth] \(mobList.count) mobs + \(blockList.count) blocks queued (\(viewDescription))")
        fflush(stdout)
    }

    /// Builds a compact visual matrix around the shared mapping code.  Oak is
    /// the exhaustive state representative; every other material gets a real
    /// paired/default capture so asymmetric Faithful asset variants remain
    /// reviewable without producing thousands of committed files.
    private func makeTextureAuditShots(scope: String) -> [TextureAuditShot] {
        let normalized = scope == "" ? "all" : scope
        let wantsDoors = normalized == "all" || normalized == "doors" || normalized == "openables"
        let wantsTrapdoors = normalized == "all" || normalized == "trapdoors" || normalized == "openables"
        let wantsGates = normalized == "all" || normalized == "gates" || normalized == "openables"
        var shots: [TextureAuditShot] = []

        let doors = blockDefs.filter { $0.shape == .door }.map { UInt16($0.id) }
            .sorted { blockDefs[Int($0)].name < blockDefs[Int($1)].name }
        let trapdoors = blockDefs.filter { $0.shape == .trapdoor }.map { UInt16($0.id) }
            .sorted { blockDefs[Int($0)].name < blockDefs[Int($1)].name }
        let gates = blockDefs.filter { $0.shape == .fenceGate }.map { UInt16($0.id) }
            .sorted { blockDefs[Int($0)].name < blockDefs[Int($1)].name }

        if wantsDoors, let oak = doors.first(where: { blockDefs[Int($0)].name == "oak_door" }) {
            // Every valid lower/upper pairing, viewed from both broad faces.
            for facing in 0..<4 {
                for open in [false, true] {
                    for hingeRight in [false, true] {
                        let side = open
                            ? (hingeRight ? leftOf(facing) : rightOf(facing))
                            : facing
                        let state = "f\(facing)-\(open ? "open" : "closed")-\(hingeRight ? "right" : "left")"
                        shots.append(TextureAuditShot(
                            label: "door-oak-\(state)",
                            cells: [
                                TextureAuditCell(dx: 0, dy: 0, dz: 0, id: oak,
                                                 meta: facing | (open ? 4 : 0)),
                                TextureAuditCell(dx: 0, dy: 1, dz: 0, id: oak,
                                                 meta: 8 | (hingeRight ? 1 : 0)),
                            ],
                            views: [side, FACE_OPP[side]]
                        ))
                    }
                }
            }
            // Material assets can differ even though they share the door mesh.
            // Pair every remaining type correctly, then capture both faces.
            for door in doors where door != oak {
                shots.append(defaultDoorAuditShot(door))
            }
        }

        if wantsTrapdoors, let oak = trapdoors.first(where: { blockDefs[Int($0)].name == "oak_trapdoor" }) {
            // Four facings × open/closed × top/bottom makes every legal leaf
            // presentation visible.  Other material tiles share that mesh.
            for facing in 0..<4 {
                for open in [false, true] {
                    for top in [false, true] {
                        let broadSide = open ? (facing ^ 1) : facing
                        let state = "f\(facing)-\(open ? "open" : "closed")-\(top ? "top" : "bottom")"
                        shots.append(TextureAuditShot(
                            label: "trapdoor-oak-\(state)",
                            cells: [TextureAuditCell(dx: 0, dy: 0, dz: 0, id: oak,
                                                     meta: facing | (open ? 4 : 0) | (top ? 8 : 0))],
                            views: [broadSide, FACE_OPP[broadSide]]
                        ))
                    }
                }
            }
            for trapdoor in trapdoors where trapdoor != oak {
                shots.append(defaultFlatAuditShot("trapdoor", trapdoor, views: [0, 1]))
            }
        }

        if wantsGates, let oak = gates.first(where: { blockDefs[Int($0)].name == "oak_fence_gate" }) {
            // The matrix includes both leaf poses and the lower in-wall model.
            for facing in 0..<4 {
                for open in [false, true] {
                    for inWall in [false, true] {
                        let state = "f\(facing)-\(open ? "open" : "closed")-\(inWall ? "wall" : "free")"
                        shots.append(TextureAuditShot(
                            label: "gate-oak-\(state)",
                            cells: [TextureAuditCell(dx: 0, dy: 0, dz: 0, id: oak,
                                                     meta: facing | (open ? 4 : 0) | (inWall ? 8 : 0))],
                            views: [facing, FACE_OPP[facing]]
                        ))
                    }
                }
            }
            for gate in gates where gate != oak {
                shots.append(defaultFlatAuditShot("gate", gate, views: [0, 1]))
            }
        }

        if shots.isEmpty {
            print("[booth] unknown texture-audit scope '\(scope)'; use all, doors, trapdoors, gates, or openables")
            fflush(stdout)
        }
        return shots
    }

    private func defaultDoorAuditShot(_ id: UInt16) -> TextureAuditShot {
        let name = blockDefs[Int(id)].name
        return TextureAuditShot(
            label: "door-\(name)-default",
            cells: [
                TextureAuditCell(dx: 0, dy: 0, dz: 0, id: id, meta: 0),
                TextureAuditCell(dx: 0, dy: 1, dz: 0, id: id, meta: 8),
            ],
            views: [0, 1]
        )
    }

    private func defaultFlatAuditShot(_ category: String, _ id: UInt16,
                                      views: [Int]) -> TextureAuditShot {
        TextureAuditShot(
            label: "\(category)-\(blockDefs[Int(id)].name)-default",
            cells: [TextureAuditCell(dx: 0, dy: 0, dz: 0, id: id, meta: 0)],
            views: views
        )
    }

    /// once per frame after game.frame(); paces on sim ticks
    func tickBooth() {
        guard game.hasWorld(), let p = game.player else { return }
        let wt = game.world.time
        if wt == lastWorldTime { return }
        lastWorldTime = wt
        tick += 1
        subjectTick += 1

        switch phase {
        case .warmup:
            if tick > 40 {
                runCommand(game, "/gamemode creative")
                runCommand(game, "/heal")
                runCommand(game, "/time set 6000")
                runCommand(game, "/weather clear")
                runCommand(game, "/tp \(SX) \(SY + 2) \(SZ)")
                phase = .buildSet
                subjectTick = 0
            }
        case .buildSet:
            if subjectTick == 10 {
                let w = game.world
                // platform: smooth stone floor + a back wall of light-gray for contrast
                for dz in -14...14 {
                    for dx in -14...14 {
                        w.setBlock(SX + dx, SY - 1, SZ + dz, Int(cell(B.smooth_stone)))
                        for dy in 0...8 { w.setBlock(SX + dx, SY + dy, SZ + dz, 0) }
                    }
                }
                p.flying = true
                phase = textureAuditScope == nil ? .mobs : .textureAudit
                subjectIdx = 0
                subjectTick = 0
                angleIdx = 0
                print(textureAuditScope == nil
                    ? "[booth] set built, starting mob captures"
                    : "[booth] set built, starting stateful texture audit")
                fflush(stdout)
            }
        case .mobs:
            tickMobs(p)
        case .blocks:
            tickBlocks(p)
        case .textureAudit:
            tickTextureAudit(p)
        case .done:
            break
        }
    }

    private func prehistoricVisualBounds(_ name: String) -> VisualBounds? {
        guard name.hasPrefix("prehistoric.") else { return nil }
        let model = getModel(name)
        var minX = Double.infinity, minY = Double.infinity, minZ = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity, maxZ = -Double.infinity
        func include(_ x: Double, _ y: Double, _ z: Double) {
            minX = min(minX, x); minY = min(minY, y); minZ = min(minZ, z)
            maxX = max(maxX, x); maxY = max(maxY, y); maxZ = max(maxZ, z)
        }
        for part in model.parts {
            let pivot = part.pivot
            for mesh in part.meshes {
                for face in mesh.faces {
                    for vertex in face.vertices {
                        include(pivot.0 + vertex.x, pivot.1 + vertex.y, pivot.2 + vertex.z)
                    }
                }
            }
            for box in part.boxes {
                include(pivot.0 + box.x - box.grow, pivot.1 + box.y - box.grow, pivot.2 + box.z - box.grow)
                include(pivot.0 + box.x + box.w + box.grow,
                        pivot.1 + box.y + box.h + box.grow,
                        pivot.2 + box.z + box.d + box.grow)
            }
        }
        guard minX.isFinite, minY.isFinite, minZ.isFinite,
              maxX.isFinite, maxY.isFinite, maxZ.isFinite else { return nil }
        let scale = model.scale / 16
        let sideSpan = max(maxY - minY, maxZ - minZ) * scale
        let height = (maxY - minY) * scale
        let centerY = (minY + maxY) * scale * 0.5
        return VisualBounds(sideSpan: sideSpan, height: height, centerY: centerY)
    }

    private func aimCamera(_ p: Player, dist: Double, height: Double,
                           targetHeight: Double? = nil, yawDeg: Double) {
        let yaw = yawDeg * .pi / 180
        // Camera orbits the subject, which stands at yaw 0 facing +Z (the
        // renderer's vanilla-rig flip points authored -Z fronts along +Z).
        // yawDeg 150 lands on the face side; -30 on the rear quarter. This
        // orbit was always authored for that convention — before the facing
        // flip landed, "front" captures actually photographed backs.
        let cx = Double(SX) + 0.5 + sin(yaw) * dist
        let cz = Double(SZ) + 0.5 - cos(yaw) * dist
        let cy = Double(SY) + height
        p.setPos(cx, cy - PLAYER_EYE, cz)
        p.vx = 0; p.vy = 0; p.vz = 0
        // face the subject (positive pitch looks down)
        let dx = (Double(SX) + 0.5) - cx
        let dz = (Double(SZ) + 0.5) - cz
        p.yaw = detAtan2(-dx, dz)
        let hd = (dx * dx + dz * dz).squareRoot()
        let targetY = Double(SY) + (targetHeight ?? height * 0.45)
        p.pitch = detAtan2(cy - targetY, hd)
    }

    private func tickMobs(_ p: Player) {
        if subjectIdx >= mobList.count {
            phase = .blocks
            subjectIdx = 0
            subjectTick = 0
            angleIdx = 0
            print("[booth] mobs done (\(captured) captures), starting blocks")
            fflush(stdout)
            return
        }
        let name = mobList[subjectIdx]
        if subjectTick == 1 {
            // clear lingering entities, spawn fresh subject
            for e in game.world.entities {
                if let ent = e as? Entity, !(ent is Player) { ent.remove() }
            }
            currentMob = spawnMob(game.world, name, Double(SX) + 0.5, Double(SY), Double(SZ) + 0.5,
                                  SpawnOpts(persistent: true))
            if let m = currentMob as? LivingEntity {
                m.yaw = 0
                m.bodyYaw = 0
                m.headYaw = 0
                m.vx = 0; m.vy = 0; m.vz = 0
            }
        }
        guard let mob = currentMob, !mob.dead else {
            if subjectTick > 4 { advanceSubject() }   // unspawnable here — skip
            return
        }
        // freeze the subject in place each tick so poses stay consistent
        mob.setPos(Double(SX) + 0.5, Double(SY), Double(SZ) + 0.5)
        mob.vx = 0; mob.vy = 0; mob.vz = 0
        // undead burn at the booth's noon clamp — the hurt flash tinted whole
        // captures pink and read as a texture defect
        mob.fireTicks = 0
        if let m = mob as? LivingEntity {
            m.yaw = 0; m.bodyYaw = 0; m.headYaw = 0
            m.health = m.maxHealth
            m.hurtTime = 0   // no red flash in captures
            if sideOnly {
                // Controllers can update gait state before the booth freezes
                // velocity.  Reset every renderer-consumed motion scalar so a
                // side portrait is a neutral anatomical reference, not a
                // random mid-stride or attack frame. The historical two-view
                // census keeps its existing live-pose behavior.
                m.limbAmp = 0
                m.limbSwing = 0
                m.attackAnim = 0
            }
        }
        if sideOnly && name.hasPrefix("prehistoric.") {
            // A spawn controller can briefly retain takeoff/flap state even
            // after the booth has frozen velocity.  Portraits need the same
            // neutral, on-ground anatomy for every taxon; otherwise a true
            // side view can catch a pterosaur in an arbitrary flap pose.
            mob.data.prehistoricAction = "idle"
            mob.data.prehistoricActionTicks = 0
        }
        let visualBounds = sideOnly ? prehistoricVisualBounds(name) : nil
        let collisionSize = max(Double(mob.width), Double(mob.height))
        let size = visualBounds?.sideSpan ?? collisionSize
        // The normal game FOV is 70 degrees.  This puts the full lateral
        // silhouette at a comfortably inspectable scale while retaining a
        // safety margin for a pose's moving limbs and tail.
        let dist = sideOnly ? max(0.72, size * 0.98 + 0.16) : max(2.2, size * 1.9 + 1.2)
        let height = visualBounds.map { $0.centerY + max(0.42, $0.height * 0.28) }
            ?? (Double(mob.height) * 0.62 + 1.1)
        if subjectTick == 6 {
            // A 90-degree orbit is a true lateral profile of the subject's
            // +Z-facing authoring direction, not a three-quarter approximation.
            let yawDeg: Double = sideOnly ? 90 : (angleIdx == 0 ? 150 : -30)
            aimCamera(p, dist: dist, height: height, targetHeight: visualBounds?.centerY, yawDeg: yawDeg)
        }
        if subjectTick == 9 {
            let suffix = sideOnly ? "side" : (angleIdx == 0 ? "front" : "back")
            renderer.requestCapture(path: "\(outRoot)/mobs/\(name)@\(suffix).png")
            captured += 1
        }
        if subjectTick >= 11 {
            if !sideOnly && angleIdx == 0 {
                angleIdx = 1
                subjectTick = 5   // re-aim + capture second angle
            } else {
                mob.remove()
                currentMob = nil
                advanceSubject()
            }
        }
    }

    private func tickBlocks(_ p: Player) {
        if subjectIdx >= blockList.count {
            phase = .done
            print("[booth] DONE — \(captured) captures in \(outRoot)")
            fflush(stdout)
            return
        }
        let id = blockList[subjectIdx]
        let w = game.world
        if subjectTick == 1 {
            for e in w.entities {                                       // pop drops
                if let ent = e as? Entity, !(ent is Player) { ent.remove() }
            }
            // reset the pedestal area
            for dz in -2...2 {
                for dx in -2...2 {
                    for dy in 0...4 { w.setBlock(SX + dx, SY + dy, SZ + dz, 0) }
                    w.setBlock(SX + dx, SY - 1, SZ + dz, Int(cell(B.smooth_stone)))
                }
            }
            w.setBlock(SX, SY, SZ, Int(cell(UInt16(id))))
        }
        if subjectTick == 5 { aimCamera(p, dist: 2.6, height: 1.55, yawDeg: 150) }
        if subjectTick == 8 {
            renderer.requestCapture(path: "\(outRoot)/blocks/\(blockDefs[id].name).png")
            captured += 1
        }
        if subjectTick >= 10 { advanceSubject() }
    }

    private func textureAuditCameraYaw(_ side: Int) -> Double {
        switch side & 3 {
        case 0: return 0       // north / -Z
        case 1: return 180     // south / +Z
        case 2: return -90     // west / -X
        default: return 90      // east / +X
        }
    }

    private func tickTextureAudit(_ p: Player) {
        guard subjectIdx < textureAuditShots.count else {
            phase = .done
            print("[booth] TEXTURE AUDIT DONE — \(captured) captures in \(outRoot)/texture-audit")
            fflush(stdout)
            return
        }

        let shot = textureAuditShots[subjectIdx]
        guard !shot.views.isEmpty else {
            subjectIdx += 1
            subjectTick = 0
            textureAuditView = 0
            return
        }
        let w = game.world
        if subjectTick == 1 {
            // Rebuild only the booth pedestal.  Audit initialization requires
            // ELYSIUM_NEWWORLD, so this is a disposable presentation world.
            for dz in -2...2 {
                for dx in -2...2 {
                    for dy in 0...4 { w.setBlock(SX + dx, SY + dy, SZ + dz, 0) }
                    w.setBlock(SX + dx, SY - 1, SZ + dz, Int(cell(B.smooth_stone)))
                }
            }
            for state in shot.cells {
                w.setBlock(SX + state.dx, SY + state.dy, SZ + state.dz,
                           Int(cell(state.id, state.meta)), SET_NO_NEIGHBORS)
            }
        }
        let side = shot.views[textureAuditView]
        if subjectTick == 5 {
            aimCamera(p, dist: 2.9, height: 1.75, targetHeight: 0.82,
                      yawDeg: textureAuditCameraYaw(side))
        }
        if subjectTick == 8 {
            let view = textureAuditView == 0 ? "front" : "back"
            renderer.requestCapture(path: "\(outRoot)/texture-audit/\(shot.label)@\(view).png")
            captured += 1
        }
        if subjectTick >= 10 {
            if textureAuditView + 1 < shot.views.count {
                textureAuditView += 1
                subjectTick = 4     // re-aim on the next simulation tick
            } else {
                textureAuditView = 0
                advanceSubject()
            }
        }
    }

    private func advanceSubject() {
        subjectIdx += 1
        subjectTick = 0
        angleIdx = 0
        // keep it noon and keep the floor intact (dragon grief, explosions)
        game.world.time = (game.world.time / 24000) * 24000 + 6000
        let w = game.world
        for dz in -14...14 {
            for dx in -14...14 where w.getBlock(SX + dx, SY - 1, SZ + dz) >> 4 != Int(B.smooth_stone) {
                w.setBlock(SX + dx, SY - 1, SZ + dz, Int(cell(B.smooth_stone)))
            }
        }
        if subjectIdx % 50 == 0 {
            print("[booth] progress \(subjectIdx) (\(captured) captured)")
            fflush(stdout)
        }
    }
}
