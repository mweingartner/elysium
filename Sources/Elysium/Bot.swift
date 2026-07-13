// Scripted-input physics bot (ELYSIUM_BOT=1) — exercises the REAL input path
// (GameCore.keyDown/keyUp → tick → vanilla travel) on a command-built flat
// platform and asserts the same vanilla constants the elysmoke harness proves
// in isolation. Per-tick positions land in /tmp/vc-bot.log, verdicts in
// /tmp/vc-bot-report.txt.

import Foundation
import ElysiumCore

final class PhysicsBot {
    private let game: GameCore
    private var phase = 0
    private var phaseTick = 0
    private var lastWorldTime = -1
    private var log: [String] = []
    private var report: [String] = []
    private var samples: [(Int, Double, Double, Double)] = []
    private var done = false
    private var totalTicks = 0
    private var jumpBaseY = 199.0
    private var fallStarted = false

    init(game: GameCore) {
        self.game = game
    }

    private func key(_ code: String, _ down: Bool) {
        // widely-spaced timestamps — phase-local ticks tripped the
        // double-tap-forward sprint detector (<250ms between presses)
        if down { game.keyDown(code, now: Double(totalTicks) * 1000) }
        else { game.keyUp(code) }
    }
    private func cmd(_ c: String) { runCommand(game, c) }
    private func pass(_ name: String, _ ok: Bool, _ detail: String) {
        report.append("\(ok ? "PASS" : "FAIL")  \(name)  \(detail)")
        print("[bot] \(report.last!)")
    }

    /// call once per frame after game.frame(); fires once per sim tick
    func tick() {
        guard !done, game.hasWorld(), let p = game.player else { return }
        let wt = game.world.time
        if wt == lastWorldTime { return }
        lastWorldTime = wt
        phaseTick += 1
        totalTicks += 1
        log.append("t\(wt) ph\(phase) x\(p.x) y\(p.y) z\(p.z) vy\(p.vy) og\(p.onGround ? 1 : 0)")
        samples.append((phase, p.x, p.y, p.z))

        switch phase {
        case 0:
            // wait for the world, then build the test platform
            if phaseTick > 60 {
                cmd("/gamemode survival")
                cmd("/heal")
                cmd("/tp 0 201 0")
                cmd("/fill -16 198 -16 16 198 16 stone")
                cmd("/fill -16 199 -16 16 220 16 air")
                cmd("/tp 0.5 199.0 0.5")
                advance()
            }
        case 1:
            // settle on the platform
            if phaseTick > 20 { advance() }
        case 2:
            // WALK +Z, measure at tick 40 (converged; 40 × 0.216 stays on the slab)
            if phaseTick == 1 {
                cmd("/tp 0.5 199.0 0.5")
                p.yaw = 0
                key("KeyW", true)
            }
            if phaseTick == 40 {
                let d = samples.suffix(2)
                let perTick = d.last!.3 - d.first!.3
                let expect = 0.98 * 0.1 * (0.21600002 / 0.216) / (1 - 0.546)
                pass("in-app walk speed", abs(perTick - expect) < 1e-6,
                     String(format: "%.4f b/s (vanilla 4.317)", perTick * 20))
                key("KeyW", false)
                advance()
            }
        case 3:
            // SPRINT
            if phaseTick == 1 {
                cmd("/tp 0.5 199.0 0.5")
                key("ControlLeft", true)
                key("KeyW", true)
            }
            if phaseTick == 40 {
                let d = samples.suffix(2)
                let perTick = d.last!.3 - d.first!.3
                let expect = 0.98 * 0.13 * (0.21600002 / 0.216) / (1 - 0.546)
                pass("in-app sprint speed", abs(perTick - expect) < 1e-6,
                     String(format: "%.4f b/s (vanilla 5.612)", perTick * 20))
                key("KeyW", false)
                key("ControlLeft", false)
                advance()
            }
        case 4:
            // brake, re-center
            if phaseTick == 1 { cmd("/tp 0.5 199.0 0.5") }
            if phaseTick > 30 { advance() }
        case 5:
            // JUMP apex from standstill
            if phaseTick == 1 {
                jumpBaseY = p.y
                key("Space", true)
            }
            if phaseTick == 3 { key("Space", false) }
            if phaseTick == 30 {
                let apex = samples.filter { $0.0 == 5 }.map { $0.2 }.max()! - jumpBaseY
                pass("in-app jump apex", abs(apex - 1.2522) < 0.001,
                     String(format: "%.4f (vanilla 1.2522)", apex))
                advance()
            }
        case 6:
            // STRAFE check: D moves toward -X when facing +Z (the A/D fix)
            if phaseTick == 1 {
                cmd("/tp 0.5 199.0 0.5")
                p.yaw = 0
                key("KeyD", true)
            }
            if phaseTick == 30 {
                key("KeyD", false)
                let dx = p.x - 0.5
                pass("in-app D strafes right (-X at yaw 0)", dx < -0.5,
                     String(format: "dx=%.2f", dx))
                advance()
            }
        case 7:
            // FALL: 20 blocks onto the slab — measure on the landing tick,
            // before saturation regen (from /heal) can refill any hearts
            if phaseTick == 1 {
                fallStarted = false
                cmd("/heal")
                cmd("/tp 0.5 219.0 0.5")
            }
            if phaseTick > 2 && !p.onGround { fallStarted = true }
            if fallStarted && p.onGround {
                let dmg = 20 - p.health
                pass("in-app 20-block fall damage", dmg > 14 && dmg <= 17.5,
                     String(format: "%.1f (vanilla 17)", dmg))
                cmd("/heal")
                advance()
            } else if phaseTick == 120 {
                pass("in-app 20-block fall damage", false, "never landed")
                advance()
            }
        default:
            finish()
        }
    }

    private func advance() {
        phase += 1
        phaseTick = 0
    }

    private func finish() {
        done = true
        try? log.joined(separator: "\n").write(toFile: "/tmp/vc-bot.log", atomically: true, encoding: .utf8)
        let failures = report.filter { $0.hasPrefix("FAIL") }.count
        report.append("\(report.count - failures)/\(report.count) passed")
        try? report.joined(separator: "\n").write(toFile: "/tmp/vc-bot-report.txt", atomically: true, encoding: .utf8)
        print("[bot] done — \(report.last!)")
        fflush(stdout)
    }
}
