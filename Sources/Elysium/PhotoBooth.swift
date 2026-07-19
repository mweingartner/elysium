// Visual census rig (ELYSIUM_PHOTOBOOTH=1) — captures EVERY mob and EVERY block
// in-game, exactly as rendered (current settings/packs/shaders), to
// /tmp/vc-captures/{mobs,blocks}/<name>[@angle].png. Drives the real sim:
// builds a lit platform, summons/places each subject, settles a few ticks,
// then reads back the scene framebuffer (no UI) and writes a PNG.

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
    private let outRoot = "/tmp/vc-captures"

    // set geometry
    private let SX = 0, SY = 200, SZ = 0          // subject position

    init(game: GameCore, renderer: WorldRenderer) {
        self.game = game
        self.renderer = renderer
        try? FileManager.default.createDirectory(atPath: outRoot + "/mobs", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: outRoot + "/blocks", withIntermediateDirectories: true)
        mobList = spawnableMobs().sorted()
        blockList = (1..<blockDefs.count).filter { id in
            let n = blockDefs[id].name
            return n != "air" && n != "cave_air" && n != "void_air" && n != "moving_piston"
                && n != "end_portal" && n != "end_gateway" && n != "bubble_column"
        }
        // ELYSIUM_BOOTH_MOBS / ELYSIUM_BOOTH_BLOCKS: comma lists to shoot a subset
        // ("-" = none); unset = full census
        if let f = ProcessInfo.processInfo.environment["ELYSIUM_BOOTH_MOBS"] {
            let want = Set(f.components(separatedBy: ","))
            mobList = f == "-" ? [] : mobList.filter { want.contains($0) }
        }
        if let f = ProcessInfo.processInfo.environment["ELYSIUM_BOOTH_BLOCKS"] {
            let want = Set(f.components(separatedBy: ","))
            blockList = f == "-" ? [] : blockList.filter { want.contains(blockDefs[$0].name) }
        }
        print("[booth] \(mobList.count) mobs + \(blockList.count) blocks queued")
        fflush(stdout)
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
                phase = .mobs
                subjectIdx = 0
                subjectTick = 0
                angleIdx = 0
                print("[booth] set built, starting mob captures")
                fflush(stdout)
            }
        case .mobs:
            tickMobs(p)
        case .blocks:
            tickBlocks(p)
        case .done:
            break
        }
    }

    private func aimCamera(_ p: Player, dist: Double, height: Double, yawDeg: Double) {
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
        let targetY = Double(SY) + height * 0.45
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
        }
        let size = max(Double(mob.width), Double(mob.height))
        let dist = max(2.2, size * 1.9 + 1.2)
        let height = Double(mob.height) * 0.62 + 1.1
        if subjectTick == 6 { aimCamera(p, dist: dist, height: height, yawDeg: angleIdx == 0 ? 150 : -30) }
        if subjectTick == 9 {
            let suffix = angleIdx == 0 ? "front" : "back"
            renderer.requestCapture(path: "\(outRoot)/mobs/\(name)@\(suffix).png")
            captured += 1
        }
        if subjectTick >= 11 {
            if angleIdx == 0 {
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
