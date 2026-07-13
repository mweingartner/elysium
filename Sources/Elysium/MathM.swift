// Render math: projection/view matrices, frustum culling, and the small
// mat4 op set the entity animator uses (deterministic op set).

import simd

func mat4Perspective(fovYRad: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let f = 1 / tan(fovYRad / 2)
    // Metal NDC z in [0,1]
    return simd_float4x4(columns: (
        SIMD4<Float>(f / aspect, 0, 0, 0),
        SIMD4<Float>(0, f, 0, 0),
        SIMD4<Float>(0, 0, far / (near - far), -1),
        SIMD4<Float>(0, 0, far * near / (near - far), 0)
    ))
}

func mat4Ortho(l: Float, r: Float, b: Float, t: Float, n: Float, f: Float) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4<Float>(2 / (r - l), 0, 0, 0),
        SIMD4<Float>(0, 2 / (t - b), 0, 0),
        SIMD4<Float>(0, 0, 1 / (n - f), 0),
        SIMD4<Float>((l + r) / (l - r), (t + b) / (b - t), n / (n - f), 1)
    ))
}

func mat4LookDir(eye: SIMD3<Float>, dir: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(dir)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(columns: (
        SIMD4<Float>(s.x, u.x, -f.x, 0),
        SIMD4<Float>(s.y, u.y, -f.y, 0),
        SIMD4<Float>(s.z, u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

// in-place style mat ops matching the frozen baseline (translate/rotate/scale multiply on the right)
@inline(__always) func mTranslate(_ m: simd_float4x4, _ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var t = matrix_identity_float4x4
    t.columns.3 = SIMD4<Float>(x, y, z, 1)
    return m * t
}
@inline(__always) func mRotateX(_ m: simd_float4x4, _ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    var r = matrix_identity_float4x4
    r.columns.1 = SIMD4<Float>(0, c, s, 0)
    r.columns.2 = SIMD4<Float>(0, -s, c, 0)
    return m * r
}
@inline(__always) func mRotateY(_ m: simd_float4x4, _ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    var r = matrix_identity_float4x4
    r.columns.0 = SIMD4<Float>(c, 0, -s, 0)
    r.columns.2 = SIMD4<Float>(s, 0, c, 0)
    return m * r
}
@inline(__always) func mRotateZ(_ m: simd_float4x4, _ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    var r = matrix_identity_float4x4
    r.columns.0 = SIMD4<Float>(c, s, 0, 0)
    r.columns.1 = SIMD4<Float>(-s, c, 0, 0)
    return m * r
}
@inline(__always) func mScale(_ m: simd_float4x4, _ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var s = matrix_identity_float4x4
    s.columns.0.x = x
    s.columns.1.y = y
    s.columns.2.z = z
    return m * s
}

struct Frustum {
    var planes = [SIMD4<Float>](repeating: .zero, count: 6)

    mutating func setFromMatrix(_ m: simd_float4x4) {
        // rows of m (column-major)
        let r0 = SIMD4<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = SIMD4<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = SIMD4<Float>(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = SIMD4<Float>(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)
        planes[0] = r3 + r0
        planes[1] = r3 - r0
        planes[2] = r3 + r1
        planes[3] = r3 - r1
        planes[4] = r3 + r2
        planes[5] = r3 - r2
    }

    func intersectsBox(_ x0: Float, _ y0: Float, _ z0: Float, _ x1: Float, _ y1: Float, _ z1: Float) -> Bool {
        for p in planes {
            let px = p.x > 0 ? x1 : x0
            let py = p.y > 0 ? y1 : y0
            let pz = p.z > 0 ? z1 : z0
            if p.x * px + p.y * py + p.z * pz + p.w < 0 { return false }
        }
        return true
    }
}
