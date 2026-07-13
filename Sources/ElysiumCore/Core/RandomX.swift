// Seeded RNG + position hashing — bit
// deterministic 32-bit wrap semantics: adds wrap as UInt32, shifts are
// logical, multiplies truncate to 32 bits. Verified against goldens.

import Foundation

@inline(__always)
public func hashString(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for u in s.unicodeScalars {
        h ^= UInt32(u.value & 0xFFFF)
        h = h &* 16777619
    }
    return h
}

/// murmur3 finalizer
@inline(__always)
public func mix32(_ input: UInt32) -> UInt32 {
    var h = input
    h ^= h >> 16
    h = h &* 0x85eb_ca6b
    h ^= h >> 13
    h = h &* 0xc2b2_ae35
    h ^= h >> 16
    return h
}

@inline(__always)
private func imul(_ a: Int, _ b: UInt32) -> UInt32 {
    UInt32(bitPattern: Int32(truncatingIfNeeded: a)) &* b
}

/// deterministic hash of 2D coords + seed + salt → uint32
@inline(__always)
public func hash2(_ seed: UInt32, _ x: Int, _ z: Int, _ salt: UInt32 = 0) -> UInt32 {
    var h = seed ^ (salt &* 0x9e37_79b9)
    h = mix32(h ^ imul(x, 0x27d4_eb2d))
    h = mix32(h ^ imul(z, 0x1656_67b1))
    return h
}

@inline(__always)
public func hash3(_ seed: UInt32, _ x: Int, _ y: Int, _ z: Int, _ salt: UInt32 = 0) -> UInt32 {
    var h = seed ^ (salt &* 0x9e37_79b9)
    h = mix32(h ^ imul(x, 0x27d4_eb2d))
    h = mix32(h ^ imul(y, 0x85eb_ca6b))
    h = mix32(h ^ imul(z, 0x1656_67b1))
    return h
}

@inline(__always)
public func hashFloat2(_ seed: UInt32, _ x: Int, _ z: Int, _ salt: UInt32 = 0) -> Double {
    Double(hash2(seed, x, z, salt)) / 4294967296.0
}

@inline(__always)
public func hashFloat3(_ seed: UInt32, _ x: Int, _ y: Int, _ z: Int, _ salt: UInt32 = 0) -> Double {
    Double(hash3(seed, x, y, z, salt)) / 4294967296.0
}

/// mutable PRNG (sfc32) — identical sequence for any seed, on any machine
public struct RandomX {
    public var debugStateA: UInt32 { a }
    private var a: UInt32
    private var b: UInt32
    private var c: UInt32
    private var d: UInt32

    public init(_ seed: UInt32) {
        a = mix32(seed)
        b = mix32(a ^ 0x9e37_79b9)
        c = mix32(b ^ 0x85eb_ca6b)
        d = mix32(c ^ 0xc2b2_ae35)
        for _ in 0..<8 { _ = next() }
    }

    @inline(__always)
    public mutating func next() -> UInt32 {
        let t = a &+ b &+ d
        d = d &+ 1
        a = b ^ (b >> 9)
        b = c &+ (c &<< 3)
        c = (c &<< 21) | (c >> 11)
        c = c &+ t
        return t
    }

    @inline(__always)
    public mutating func nextFloat() -> Double { Double(next()) / 4294967296.0 }
    @inline(__always)
    public mutating func nextDouble() -> Double { nextFloat() }
    /// floor(float * bound) — must match deterministic for permutation shuffles to agree
    @inline(__always)
    public mutating func nextInt(_ bound: Int) -> Int { Int((nextFloat() * Double(bound)).rounded(.down)) }
    @inline(__always)
    public mutating func nextIntBetween(_ minInc: Int, _ maxInc: Int) -> Int {
        minInc + nextInt(maxInc - minInc + 1)
    }
    @inline(__always)
    public mutating func nextBoolean() -> Bool { (next() & 1) == 0 }
    @inline(__always)
    public mutating func chance(_ p: Double) -> Bool { nextFloat() < p }

    public mutating func nextGaussian() -> Double {
        var u = 0.0, v = 0.0
        while u == 0 { u = nextFloat() }
        while v == 0 { v = nextFloat() }
        return (-2.0 * Foundation.log(u)).squareRoot() * detCos(2.0 * .pi * v)
    }

    /// triangular distribution used by vanilla ore placement
    public mutating func nextTriangular(_ mode: Double, _ deviation: Double) -> Double {
        mode + deviation * (nextFloat() - nextFloat())
    }

    public mutating func pick<T>(_ arr: [T]) -> T { arr[nextInt(arr.count)] }

    public mutating func shuffle<T>(_ arr: inout [T]) {
        var i = arr.count - 1
        while i > 0 {
            let j = nextInt(i + 1)
            arr.swapAt(i, j)
            i -= 1
        }
    }

    public mutating func pickWeighted<T>(_ arr: [T], _ weightOf: (T) -> Double) -> T {
        var total = 0.0
        for t in arr { total += weightOf(t) }
        var r = nextFloat() * total
        for t in arr {
            r -= weightOf(t)
            if r <= 0 { return t }
        }
        return arr[arr.count - 1]
    }
}

@inline(__always)
public func chunkRandom(_ seed: UInt32, _ cx: Int, _ cz: Int, _ salt: UInt32) -> RandomX {
    RandomX(hash2(seed, cx, cz, salt))
}
