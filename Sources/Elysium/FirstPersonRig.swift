import Foundation
import simd
import ElysiumCore

enum FirstPersonHandGrip: String {
    case standard, pickaxe, round, shield, draw
}

struct FirstPersonAimDepth {
    private var value: Float?
    private var lastTime: Double?

    mutating func observe(_ target: Float, at time: Double) -> Float {
        guard target.isFinite, target > 0, time.isFinite else { return value ?? 1.75 }
        defer { lastTime = time }
        guard let value, let lastTime, time >= lastTime else { self.value = target; return target }
        let blend = Float(1-exp(-min(0.1,time-lastTime)/0.06))
        let next = value+(target-value)*blend
        self.value = next
        return next
    }
}

/// Presentation-space anatomy. The hand owns the grip; the arm reaches that wrist
/// from a shoulder below the viewport instead of rotating as part of the tool.
struct FirstPersonArmPose {
    let wrist: SIMD3<Float>
    let elbow: SIMD3<Float>
    let shoulder: SIMD3<Float>
    let forearm: simd_float4x4
    let upperArm: simd_float4x4

    static func solve(hand: simd_float4x4, left: Bool) -> Self {
        let p = hand * SIMD4<Float>(0,-0.10,0,1)
        let wrist = SIMD3(p.x,p.y,p.z)
        let side: Float = left ? -1 : 1
        let preferredShoulder = SIMD3<Float>(side*0.55,-0.82,-0.85)
        let delta = preferredShoulder-wrist
        let d = max(0.001,simd_length(delta))
        let axis = delta/d
        let lower: Float = 0.40, upper: Float = 0.45
        // Equipment lowering may take the entire limb below the viewport. Keep
        // bone lengths rather than stretching a visible forearm to a fixed anchor.
        let distance = min(lower+upper-0.002,max(abs(upper-lower)+0.002,d))
        let shoulder = wrist+axis*distance
        let along = (lower*lower + distance*distance-upper*upper)/(2*distance)
        let height = sqrt(max(0,lower*lower-along*along))
        let pole = SIMD3<Float>(side*0.7,-0.3,0.15)
        let perpendicular = pole-axis*simd_dot(pole,axis)
        let bend = simd_length_squared(perpendicular) > 0.00001
            ? simd_normalize(perpendicular) : SIMD3<Float>(side,0,0)
        let elbow = wrist+axis*along+bend*height
        func bone(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> simd_float4x4 {
            vmTranslation(from) * simd_float4x4(simd_quatf(from: SIMD3(0,-1,0),to: simd_normalize(to-from)))
        }
        return .init(wrist:wrist,elbow:elbow,shoulder:shoulder,
                     forearm:bone(wrist,elbow),upperArm:bone(elbow,shoulder))
    }
}

enum FirstPersonStrike {
    static func aimedProp(rest: simd_float4x4, muzzle: SIMD3<Float>,
                          forward: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let origin = SIMD3(rest.columns.3.x,rest.columns.3.y,rest.columns.3.z)
        let orientation = simd_quatf(rest)
        let delta = target-origin
        guard simd_length_squared(forward)>0.0001, simd_length_squared(delta)>0.0001 else { return rest }
        let axis = simd_normalize(forward)
        let along = simd_dot(muzzle,axis)
        // Solve |muzzle + t*axis| = |target-grip|, then rotate that local
        // point onto the target. Unlike iterative look-at, this includes the
        // lateral muzzle offset and is exact even for nearby targets.
        let discriminant = simd_length_squared(delta)-simd_length_squared(muzzle)+along*along
        guard discriminant.isFinite, discriminant>=0 else { return rest }
        let distance = sqrt(discriminant)-along
        guard distance>=0 else { return rest } // target is behind the tip
        let correction = simd_quatf(from:simd_normalize(orientation.act(muzzle+distance*axis)),
                                   to:simd_normalize(delta))
        return vmTranslation(origin)*simd_float4x4(simd_normalize(correction*orientation))
    }

    static func equipmentPose(_ pose: simd_float4x4, lift: Double) -> simd_float4x4 {
        let amount = lift.isFinite ? min(1,max(0,lift)) : 0
        return vmTranslation(SIMD3(0,-Float(amount)*1.25,0))*pose
    }

    static let pickaxeScale: Float = 0.98/0.85
    // Keep the pommel within the closed fist, not protruding through a bent
    // wrist. This moves the unchanged mesh along its own straight handle.
    static let pickaxeSocketOffset = SIMD3<Float>(0,0.05,0)
    static func workingPoint(_ definition: ItemDef, mesh: ViewmodelMesh) -> SIMD3<Float> {
        if definition.tool?.type == "pickaxe" { return workingPoint(definition) }
        let points = mesh.vertices.map { SIMD3($0.position.x,$0.position.y,$0.position.z) }
        guard let top = points.map(\.y).max(), let bottom = points.map(\.y).min() else {
            return workingPoint(definition)
        }
        let head = points.filter { $0.y >= bottom+(top-bottom)*0.70 }
        let edge: [SIMD3<Float>]
        if definition.tool?.type == "axe" || definition.tool?.type == "hoe",
           let inner = head.map(\.x).min() {
            edge = head.filter { abs($0.x-inner)<0.0001 }
        } else {
            edge = points.filter { abs($0.y-top)<0.0001 }
        }
        guard !edge.isEmpty else { return workingPoint(definition) }
        // Center the real exposed edge, not a guessed profile length. This
        // continues to track replacement resource-pack silhouettes accurately.
        let minimum = edge.reduce(edge[0]) { simd_min($0,$1) }
        let maximum = edge.reduce(edge[0]) { simd_max($0,$1) }
        return (minimum+maximum)*0.5
    }

    static func workingPoint(_ definition: ItemDef) -> SIMD3<Float> {
        let profile = ViewmodelProfile.item(definition)
        switch definition.tool?.type {
        case "pickaxe": return SIMD3(-0.27625,0.48875,0) * pickaxeScale + pickaxeSocketOffset
        case "axe": return SIMD3(-0.16,profile.length*0.68,0)
        case "shovel": return SIMD3(0,profile.length*0.76,0)
        case "hoe": return SIMD3(-0.16,profile.length*0.68,0)
        case "sword": return SIMD3(0,profile.length*0.76,0)
        default: return SIMD3(0,profile.length*0.65,-0.03)
        }
    }

    /// Keep the working end on the visible target ray at impact. This is a
    /// reach-bounded viewmodel proxy, not an extension of gameplay reach.
    static func pose(rest: simd_float4x4, progress: Double?, action: ViewmodelAction,
                     workingPoint: SIMD3<Float>, target: SIMD3<Float>, reducedMotion: Bool) -> simd_float4x4 {
        guard let progress, progress.isFinite, progress > 0, progress < 1 else { return rest }
        let p = Float(progress)
        let wind = rest * vmTranslation(SIMD3(0.035,0.10,0.035))
            * vmRotation(SIMD3(0.24,-0.06,-0.16))
        let desiredWrist: SIMD3<Float>
        switch action {
        case .cutting: desiredWrist = SIMD3(0.27,-0.24,-1.08)
        case .digging: desiredWrist = SIMD3(0.22,-0.36,-1.12)
        default: desiredWrist = SIMD3(0.24,-0.29,-1.13)
        }
        let direction = simd_normalize(target-desiredWrist)
        let localAxis = simd_normalize(workingPoint)
        func basis(axis: SIMD3<Float>, face: SIMD3<Float>) -> simd_float3x3 {
            let front = simd_normalize(face-axis*simd_dot(face,axis))
            return .init(columns:(simd_normalize(simd_cross(axis,front)),axis,front))
        }
        // Preserve a readable broad face, subject to honest foreshortening as
        // the blade approaches the target. Never billboard the head separately.
        let local = basis(axis:localAxis,face:SIMD3(0,0,1))
        let desired = basis(axis:direction,face:SIMD3(0.18,0.08,1))
        let rotation = desired * local.transpose
        let contactPosition = target-rotation*workingPoint
        let contact = vmTranslation(contactPosition) * simd_float4x4(simd_quatf(rotation))
        func smooth(_ value: Float) -> Float { value*value*(3-2*value) }
        func blend(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float) -> simd_float4x4 {
            let pa = SIMD3(a.columns.3.x,a.columns.3.y,a.columns.3.z)
            let pb = SIMD3(b.columns.3.x,b.columns.3.y,b.columns.3.z)
            return vmTranslation(pa+(pb-pa)*t) * simd_float4x4(simd_slerp(simd_quatf(a),simd_quatf(b),t))
        }
        let result: simd_float4x4
        if p < 0.24 { result = blend(rest,wind,smooth(p/0.24)) }
        else if p < 0.43 { result = blend(wind,contact,smooth((p-0.24)/0.19)) }
        else if p <= 0.49 { result = contact }
        else { result = blend(contact,rest,smooth((p-0.49)/0.51)) }
        return reducedMotion ? blend(rest,result,0.22) : result
    }
}
