import Foundation
import simd
import ElysiumCore

/// Render-only, hierarchical bat rig. Flight is always head-up; only the actual
/// hanging state inverts the entire animal and folds its wings. These cosmetic
/// curves never advance simulation or consume the world's deterministic RNG.
enum BatPresentation {
    static func partMatrix(_ name: String, hanging: Bool, time: Double,
                           headYaw: Double = 0, ceilingOffset: Double = 1) -> simd_float4x4 {
        let identity = matrix_identity_float4x4
        let phase = time * (.pi * 4) // two complete wingbeats per second
        var root = identity
        if hanging {
            root = mTranslate(root, 0, Float(ceilingOffset), 0)
            root = mRotateX(root, .pi)
        } else {
            root = mTranslate(root, 0, Float(sin(phase - 0.4) * 0.035), 0)
        }

        var shoulders = mTranslate(root, 0, 7.0 / 16, 0)
        if !hanging {
            // In this Y-up/-Z-forward rig, negative pitch trails the torso behind
            // the face. Positive pitch would tuck it forward under the bat's nose.
            shoulders = mRotateX(shoulders, Float(-0.76 - 0.10 * cos(phase)))
        }

        switch name {
        case "head":
            var head = mTranslate(root, 0, 7.0 / 16, 0)
            head = mRotateY(head, Float(max(-0.5, min(0.5, headYaw))))
            if !hanging { head = mRotateX(head, Float(-0.08 * (1 + sin(phase)))) }
            return head
        case "body":
            return shoulders
        case "feet":
            var feet = mTranslate(shoulders, 0, -5.0 / 16, 0)
            if !hanging { feet = mRotateX(feet, Float(0.15 * sin(phase - 0.3))) }
            return feet
        case "wingR", "wingL", "wingTipR", "wingTipL":
            let right = name.hasSuffix("R")
            let side: Float = right ? -1 : 1
            var wing = mTranslate(shoulders, side * 1.5 / 16, 0, 0)
            // Tip lag softens the reversal; folded tips wrap toward the body's
            // front while roosting. The tip inherits its moving inner-wing pivot.
            let inner = hanging ? 0.16 : 0.12 + 1.10 * sin(phase)
            wing = mRotateY(wing, -side * Float(inner))
            if name.hasPrefix("wingTip") {
                wing = mTranslate(wing, side * 2 / 16, 0, 0)
                let tip = hanging ? -2.10 : 0.35 + 0.65 * sin(phase - 0.65)
                wing = mRotateY(wing, -side * Float(tip))
            }
            return wing
        default:
            return identity
        }
    }
}
