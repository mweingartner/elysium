// Portable deterministic float math — bit-reproducible reference implementation
// (fdlibm 5.3c sin/cos/atan/atan2, exp/log/pow). Simulation code calls these instead of
// Foundation trig/math so results are bit-identical with the golden baselines: only
// IEEE-exact operations (+ - * / sqrt) are used.
//
// The sin/cos/atan/atan2/exp/log/pow kernels below are ported from fdlibm 5.3c:
//
//   Copyright (C) 1993, 2004 by Sun Microsystems, Inc. All rights reserved.
//
//   Developed at SunSoft, a Sun Microsystems, Inc. business.
//   Permission to use, copy, modify, and distribute this
//   software is freely granted, provided that this notice
//   is preserved.

import Foundation

@inline(__always) private func HI(_ x: Double) -> Int32 {
    Int32(truncatingIfNeeded: x.bitPattern >> 32)
}
@inline(__always) private func LO(_ x: Double) -> Int32 {
    Int32(truncatingIfNeeded: x.bitPattern & 0xffff_ffff)
}
@inline(__always) private func fromWords(_ h: UInt32, _ l: UInt32) -> Double {
    Double(bitPattern: (UInt64(h) << 32) | UInt64(l))
}
@inline(__always) private func setHI(_ x: Double, _ h: UInt32) -> Double {
    Double(bitPattern: (UInt64(h) << 32) | (x.bitPattern & 0xffff_ffff))
}

@inline(__always) public func detHyp(_ a: Double, _ b: Double) -> Double {
    (a * a + b * b).squareRoot()
}
@inline(__always) public func detHyp3(_ a: Double, _ b: Double, _ c: Double) -> Double {
    (a * a + b * b + c * c).squareRoot()
}

// ---------------------------------------------------------------------------
// __kernel_sin / __kernel_cos
// ---------------------------------------------------------------------------
private let half = 0.5
private let S1 = fromWords(0xbfc55555, 0x55555549)
private let S2 = fromWords(0x3f811111, 0x1110f8a6)
private let S3 = fromWords(0xbf2a01a0, 0x19c161d5)
private let S4 = fromWords(0x3ec71de3, 0x57b1fe7d)
private let S5 = fromWords(0xbe5ae5e6, 0x8a2b9ceb)
private let S6 = fromWords(0x3de5d93a, 0x5acfd57c)

private let C1 = fromWords(0x3fa55555, 0x5555554c)
private let C2 = fromWords(0xbf56c16c, 0x16c15177)
private let C3 = fromWords(0x3efa01a0, 0x19cb1590)
private let C4 = fromWords(0xbe927e4f, 0x809c52ad)
private let C5 = fromWords(0x3e21ee9e, 0xbdb4b1c4)
private let C6 = fromWords(0xbda8fae9, 0xbe8838d4)

private let one = 1.0

private func kernelSin(_ x: Double, _ y: Double, _ iy: Int) -> Double {
    let ix = HI(x) & 0x7fffffff
    if ix < 0x3e400000 {            /* |x| < 2**-27 */
        if Int32(x) == 0 { return x }
    }
    let z = x * x
    let v = z * x
    let r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
    if iy == 0 { return x + v * (S1 + z * r) }
    return x - ((z * (half * y - v * r) - y) - v * S1)
}

private func kernelCos(_ x: Double, _ y: Double) -> Double {
    let ix = HI(x) & 0x7fffffff
    if ix < 0x3e400000 {            /* if |x| < 2**-27 */
        if Int32(x) == 0 { return one }
    }
    let z = x * x
    let r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))))
    if ix < 0x3fd33333 {            /* if |x| < 0.3 */
        return one - (0.5 * z - (z * r - x * y))
    }
    let qx: Double
    if ix > 0x3fe90000 {            /* x > 0.78125 */
        qx = 0.28125
    } else {
        qx = fromWords(UInt32(bitPattern: ix - 0x00200000), 0)   /* x/4 */
    }
    let hz = 0.5 * z - qx
    let a = one - qx
    return a - (hz - (z * r - x * y))
}

// ---------------------------------------------------------------------------
// __ieee754_rem_pio2 (small + medium ranges; gameplay never exceeds 2^19·π/2)
// ---------------------------------------------------------------------------
private let invpio2 = fromWords(0x3fe45f30, 0x6dc9c883)
private let pio2_1 = fromWords(0x3ff921fb, 0x54400000)
private let pio2_1t = fromWords(0x3dd0b461, 0x1a626331)
private let pio2_2 = fromWords(0x3dd0b461, 0x1a600000)
private let pio2_2t = fromWords(0x3ba3198a, 0x2e037073)
private let pio2_3 = fromWords(0x3ba3198a, 0x2e000000)
private let pio2_3t = fromWords(0x397b839a, 0x252049c1)

private let npio2_hw: [Int32] = [
    0x3ff921fb, 0x400921fb, 0x4012d97c, 0x401921fb, 0x401f6a7a, 0x4022d97c,
    0x4025fdbb, 0x402921fb, 0x402c463a, 0x402f6a7a, 0x4031475c, 0x4032d97c,
    0x40346b9c, 0x4035fdbb, 0x40378fdb, 0x403921fb, 0x403ab41b, 0x403c463a,
    0x403dd85a, 0x403f6a7a, 0x40407e4c, 0x4041475c, 0x4042106c, 0x4042d97c,
    0x4043a28c, 0x40446b9c, 0x404534ac, 0x4045fdbb, 0x4046c6cb, 0x40478fdb,
    0x404858eb, 0x404921fb,
]

private func remPio2(_ x: Double) -> (Int, Double, Double) {
    let hx = HI(x)
    let ix = hx & 0x7fffffff
    if ix <= 0x3fe921fb {           /* |x| ~<= pi/4, no need for reduction */
        return (0, x, 0)
    }
    if ix < 0x4002d97c {            /* |x| < 3pi/4, special case with n=+-1 */
        if hx > 0 {
            var z = x - pio2_1
            let y0: Double, y1: Double
            if ix != 0x3ff921fb {   /* 33+53 bit pi is good enough */
                y0 = z - pio2_1t
                y1 = (z - y0) - pio2_1t
            } else {                /* near pi/2, use 33+33+53 bit pi */
                z -= pio2_2
                y0 = z - pio2_2t
                y1 = (z - y0) - pio2_2t
            }
            return (1, y0, y1)
        } else {
            var z = x + pio2_1
            let y0: Double, y1: Double
            if ix != 0x3ff921fb {
                y0 = z + pio2_1t
                y1 = (z - y0) + pio2_1t
            } else {
                z += pio2_2
                y0 = z + pio2_2t
                y1 = (z - y0) + pio2_2t
            }
            return (-1, y0, y1)
        }
    }
    if ix <= 0x413921fb {           /* |x| ~<= 2^19*(pi/2), medium size */
        let t = abs(x)
        let n = Int(t * invpio2 + half)
        let fn = Double(n)
        var r = t - fn * pio2_1
        var w = fn * pio2_1t        /* 1st round good to 85 bit */
        var y0: Double
        if n < 32 && ix != npio2_hw[n - 1] {
            y0 = r - w              /* quick check no cancellation */
        } else {
            let j = ix >> 20
            y0 = r - w
            var high = HI(y0)
            var i = j - ((high >> 20) & 0x7ff)
            if i > 16 {             /* 2nd iteration needed, good to 118 */
                var t2 = r
                w = fn * pio2_2
                r = t2 - w
                w = fn * pio2_2t - ((t2 - r) - w)
                y0 = r - w
                high = HI(y0)
                i = j - ((high >> 20) & 0x7ff)
                if i > 49 {         /* 3rd iteration, 151 bits acc */
                    t2 = r
                    w = fn * pio2_3
                    r = t2 - w
                    w = fn * pio2_3t - ((t2 - r) - w)
                    y0 = r - w
                }
            }
        }
        let y1 = (r - y0) - w
        if hx < 0 { return (-n, -y0, -y1) }
        return (n, y0, y1)
    }
    fatalError("DetMath: |x| too large for trig reduction: \(x)")
}

// ---------------------------------------------------------------------------
// sin / cos
// ---------------------------------------------------------------------------
public func detSin(_ x: Double) -> Double {
    let ix = HI(x) & 0x7fffffff
    if ix <= 0x3fe921fb { return kernelSin(x, 0, 0) }
    if ix >= 0x7ff00000 { return x - x }   /* NaN/Inf */
    let (n, y0, y1) = remPio2(x)
    switch n & 3 {
    case 0: return kernelSin(y0, y1, 1)
    case 1: return kernelCos(y0, y1)
    case 2: return -kernelSin(y0, y1, 1)
    default: return -kernelCos(y0, y1)
    }
}

public func detCos(_ x: Double) -> Double {
    let ix = HI(x) & 0x7fffffff
    if ix <= 0x3fe921fb { return kernelCos(x, 0) }
    if ix >= 0x7ff00000 { return x - x }
    let (n, y0, y1) = remPio2(x)
    switch n & 3 {
    case 0: return kernelCos(y0, y1)
    case 1: return -kernelSin(y0, y1, 1)
    case 2: return -kernelCos(y0, y1)
    default: return kernelSin(y0, y1, 1)
    }
}

// ---------------------------------------------------------------------------
// atan / atan2
// ---------------------------------------------------------------------------
private let atanhi: [Double] = [
    fromWords(0x3fddac67, 0x0561bb4f), fromWords(0x3fe921fb, 0x54442d18),
    fromWords(0x3fef730b, 0xd281f69b), fromWords(0x3ff921fb, 0x54442d18),
]
private let atanlo: [Double] = [
    fromWords(0x3c7a2b7f, 0x222f65e2), fromWords(0x3c81a626, 0x33145c07),
    fromWords(0x3c700788, 0x7af0cbbd), fromWords(0x3c91a626, 0x33145c07),
]
private let aT: [Double] = [
    fromWords(0x3fd55555, 0x5555550d), fromWords(0xbfc99999, 0x9998ebc4),
    fromWords(0x3fc24924, 0x920083ff), fromWords(0xbfbc71c6, 0xfe231671),
    fromWords(0x3fb745cd, 0xc54c206e), fromWords(0xbfb3b0f2, 0xaf749a6d),
    fromWords(0x3fb10d66, 0xa0d03d51), fromWords(0xbfadde2d, 0x52defd9a),
    fromWords(0x3fa97b4b, 0x24760deb), fromWords(0xbfa2b444, 0x2c6a6c2f),
    fromWords(0x3f90ad3a, 0xe322da11),
]
private let hugeVal = 1.0e300

public func detAtan(_ xIn: Double) -> Double {
    var x = xIn
    let hx = HI(x)
    let ix = hx & 0x7fffffff
    if ix >= 0x44100000 {           /* if |x| >= 2^66 */
        let low = LO(x)
        if ix > 0x7ff00000 || (ix == 0x7ff00000 && low != 0) { return x + x } /* NaN */
        if hx > 0 { return atanhi[3] + atanlo[3] }
        return -atanhi[3] - atanlo[3]
    }
    var id: Int
    if ix < 0x3fdc0000 {            /* |x| < 0.4375 */
        if ix < 0x3e200000 {        /* |x| < 2^-29 */
            if hugeVal + x > one { return x }
        }
        id = -1
    } else {
        x = abs(x)
        if ix < 0x3ff30000 {        /* |x| < 1.1875 */
            if ix < 0x3fe60000 {    /* 7/16 <= |x| < 11/16 */
                id = 0; x = (2.0 * x - one) / (2.0 + x)
            } else {                /* 11/16 <= |x| < 19/16 */
                id = 1; x = (x - one) / (x + one)
            }
        } else {
            if ix < 0x40038000 {    /* |x| < 2.4375 */
                id = 2; x = (x - 1.5) / (one + 1.5 * x)
            } else {                /* 2.4375 <= |x| < 2^66 */
                id = 3; x = -1.0 / x
            }
        }
    }
    let z = x * x
    let w = z * z
    let s1 = z * (aT[0] + w * (aT[2] + w * (aT[4] + w * (aT[6] + w * (aT[8] + w * aT[10])))))
    let s2 = w * (aT[1] + w * (aT[3] + w * (aT[5] + w * (aT[7] + w * aT[9]))))
    if id < 0 { return x - x * (s1 + s2) }
    let zz = atanhi[id] - ((x * (s1 + s2) - atanlo[id]) - x)
    return hx < 0 ? -zz : zz
}

private let tiny = 1.0e-300
private let pi_o_4 = fromWords(0x3fe921fb, 0x54442d18)
private let pi_o_2 = fromWords(0x3ff921fb, 0x54442d18)
private let m_pi = fromWords(0x400921fb, 0x54442d18)
private let pi_lo = fromWords(0x3ca1a626, 0x33145c07)

public func detAtan2(_ y: Double, _ x: Double) -> Double {
    let hx = HI(x), lx = LO(x)
    let ix = hx & 0x7fffffff
    let hy = HI(y), ly = LO(y)
    let iy = hy & 0x7fffffff
    let lxNZ = Int32(bitPattern: (UInt32(bitPattern: lx) | UInt32(bitPattern: 0 &- lx)) >> 31)
    let lyNZ = Int32(bitPattern: (UInt32(bitPattern: ly) | UInt32(bitPattern: 0 &- ly)) >> 31)
    if (ix | lxNZ) > 0x7ff00000 || (iy | lyNZ) > 0x7ff00000 {  /* x or y is NaN */
        return x + y
    }
    if ((hx &- 0x3ff00000) | lx) == 0 { return detAtan(y) }   /* x=1.0 */
    let m = Int((hy >> 31) & 1) | Int((hx >> 30) & 2)        /* 2*sign(x)+sign(y) */

    /* when y = 0 */
    if (iy | ly) == 0 {
        switch m {
        case 0, 1: return y             /* atan(+-0,+anything)=+-0 */
        case 2: return m_pi + tiny      /* atan(+0,-anything) = pi */
        default: return -m_pi - tiny    /* atan(-0,-anything) =-pi */
        }
    }
    /* when x = 0 */
    if (ix | lx) == 0 { return hy < 0 ? -pi_o_2 - tiny : pi_o_2 + tiny }

    /* when x is INF */
    if ix == 0x7ff00000 {
        if iy == 0x7ff00000 {
            switch m {
            case 0: return pi_o_4 + tiny
            case 1: return -pi_o_4 - tiny
            case 2: return 3.0 * pi_o_4 + tiny
            default: return -3.0 * pi_o_4 - tiny
            }
        } else {
            switch m {
            case 0: return 0.0
            case 1: return -0.0
            case 2: return m_pi + tiny
            default: return -m_pi - tiny
            }
        }
    }
    /* when y is INF */
    if iy == 0x7ff00000 { return hy < 0 ? -pi_o_2 - tiny : pi_o_2 + tiny }

    /* compute y/x */
    let k = (iy &- ix) >> 20
    var z: Double
    if k > 60 { z = pi_o_2 + 0.5 * pi_lo }      /* |y/x| >  2**60 */
    else if hx < 0 && k < -60 { z = 0.0 }       /* |y|/x < -2**60 */
    else { z = detAtan(abs(y / x)) }             /* safe to do y/x */
    switch m {
    case 0: return z                            /* atan(+,+) */
    case 1: return setHI(z, UInt32(bitPattern: HI(z)) ^ 0x80000000) /* atan(-,+) */
    case 2: return m_pi - (z - pi_lo)           /* atan(+,-) */
    default: return (z - pi_lo) - m_pi          /* atan(-,-) */
    }
}

// ---------------------------------------------------------------------------
// setLO — the __LO(x) = ... write-side companion to setHI, used by the exp/log/pow ports.
// ---------------------------------------------------------------------------
@inline(__always) private func setLO(_ x: Double, _ l: UInt32) -> Double {
    Double(bitPattern: (x.bitPattern & 0xffff_ffff_0000_0000) | UInt64(l))
}

/// Truncating double→Int32 conversion equivalent to C's `(int)x` cast, implemented through
/// bit decomposition so it can never trap: Swift's `Int32(_: Double)` initializer traps for
/// NaN, infinities and magnitudes outside `Int32`'s range, which fdlibm's own `(int)` casts
/// never guard against syntactically (they rely on the caller having already bounded the
/// argument). Every call site below is reached only after fdlibm's own domain filtering has
/// bounded the argument to a small range, so the saturate/NaN-to-zero paths here are a
/// defensive backstop, never the expected path.
@inline(__always) private func truncToInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483648.0 { return Int32.max }
    if x <= -2147483649.0 { return Int32.min }
    let bits = x.bitPattern
    let negative = (bits >> 63) != 0
    let biasedExponent = Int32(truncatingIfNeeded: (bits >> 52) & 0x7ff)
    let exponent = biasedExponent &- 1023
    if exponent < 0 { return 0 }
    let fraction = bits & 0x000f_ffff_ffff_ffff
    let mantissa = biasedExponent == 0 ? fraction : (fraction | 0x0010_0000_0000_0000)
    // |x| < 2^31 here (range-checked above), so exponent <= 30 and the shift below is always
    // a right shift by 22...52 — never negative, never >= 64.
    let shift = UInt64(52 &- exponent)
    let magnitude = mantissa &>> shift
    let signedMagnitude = Int32(truncatingIfNeeded: magnitude)
    return negative ? (0 &- signedMagnitude) : signedMagnitude
}

// ---------------------------------------------------------------------------
// exp — __ieee754_exp (fdlibm e_exp.c)
// ---------------------------------------------------------------------------
private let expOne = 1.0
private let expHalf: [Double] = [0.5, -0.5]
private let expHugeVal = 1.0e300
private let expTwom1000 = fromWords(0x01700000, 0)                          /* 2**-1000 */
private let expOThreshold = fromWords(0x40862E42, 0xFEFA39EF)               /* overflow */
private let expUThreshold = fromWords(0xc0874910, 0xD52D3051)               /* underflow */
private let expLn2HI: [Double] = [
    fromWords(0x3fe62e42, 0xfee00000), fromWords(0xbfe62e42, 0xfee00000),
]
private let expLn2LO: [Double] = [
    fromWords(0x3dea39ef, 0x35793c76), fromWords(0xbdea39ef, 0x35793c76),
]
private let expInvln2 = fromWords(0x3ff71547, 0x652b82fe)
private let expP1 = fromWords(0x3FC55555, 0x5555553E)
private let expP2 = fromWords(0xBF66C16C, 0x16BEBD93)
private let expP3 = fromWords(0x3F11566A, 0xAF25DE2C)
private let expP4 = fromWords(0xBEBBBD41, 0xC5D26BF1)
private let expP5 = fromWords(0x3E663769, 0x72BEA4D0)

public func detExp(_ xIn: Double) -> Double {
    var x = xIn
    let hxFull = HI(x)
    let xsb = Int((hxFull >> 31) & 1)
    let hx = hxFull & 0x7fffffff

    if hx >= 0x40862E42 {
        if hx >= 0x7ff00000 {
            if (hx & 0xfffff) | LO(x) != 0 { return x + x }            /* NaN */
            return xsb == 0 ? x : 0.0                                   /* exp(+-inf) */
        }
        if x > expOThreshold { return expHugeVal * expHugeVal }        /* overflow */
        if x < expUThreshold { return expTwom1000 * expTwom1000 }      /* underflow */
    }

    var k: Int32 = 0
    var hi = 0.0, lo = 0.0
    if hx > 0x3fd62e42 {                          /* |x| > 0.5 ln2 */
        if hx < 0x3FF0A2B2 {                       /* and |x| < 1.5 ln2 */
            hi = x - expLn2HI[xsb]
            lo = expLn2LO[xsb]
            k = Int32(1 - xsb - xsb)
        } else {
            k = truncToInt32(expInvln2 * x + expHalf[xsb])
            let t = Double(k)
            hi = x - t * expLn2HI[0]                /* t*ln2HI is exact here */
            lo = t * expLn2LO[0]
        }
        x = hi - lo
    } else if hx < 0x3e300000 {                    /* when |x| < 2**-28 */
        if expHugeVal + x > expOne { return expOne + x }  /* trigger inexact */
    }
    /* else: 0x3e300000 <= hx <= 0x3fd62e42 -> k stays 0, x unchanged (primary range) */

    let t2 = x * x
    let c = x - t2 * (expP1 + t2 * (expP2 + t2 * (expP3 + t2 * (expP4 + t2 * expP5))))
    if k == 0 { return expOne - ((x * c) / (c - 2.0) - x) }
    var y = expOne - ((lo - (x * c) / (2.0 - c)) - hi)
    if k >= -1021 {
        y = setHI(y, UInt32(bitPattern: HI(y) &+ (k << 20)))    /* add k to y's exponent */
        return y
    } else {
        y = setHI(y, UInt32(bitPattern: HI(y) &+ ((k &+ 1000) << 20)))
        return y * expTwom1000
    }
}

// ---------------------------------------------------------------------------
// log — __ieee754_log (fdlibm e_log.c)
// ---------------------------------------------------------------------------
private let logLn2HI = fromWords(0x3fe62e42, 0xfee00000)
private let logLn2LO = fromWords(0x3dea39ef, 0x35793c76)
private let logTwo54 = fromWords(0x43500000, 0)
private let logLg1 = fromWords(0x3FE55555, 0x55555593)
private let logLg2 = fromWords(0x3FD99999, 0x9997FA04)
private let logLg3 = fromWords(0x3FD24924, 0x94229359)
private let logLg4 = fromWords(0x3FCC71C5, 0x1D8E78AF)
private let logLg5 = fromWords(0x3FC74664, 0x96CB03DE)
private let logLg6 = fromWords(0x3FC39A09, 0xD078C69F)
private let logLg7 = fromWords(0x3FC2F112, 0xDF3E5244)
private let logZero = 0.0

public func detLog(_ xIn: Double) -> Double {
    var x = xIn
    var hx = HI(x)
    let lx = LO(x)

    var k: Int32 = 0
    if hx < 0x00100000 {                            /* x < 2**-1022 */
        if ((hx & 0x7fffffff) | lx) == 0 { return -logTwo54 / logZero }  /* log(+-0)=-inf */
        if hx < 0 { return (x - x) / logZero }                            /* log(-#) = NaN */
        k &-= 54
        x *= logTwo54                                /* subnormal number, scale up x */
        hx = HI(x)
    }
    if hx >= 0x7ff00000 { return x + x }
    k &+= (hx >> 20) &- 1023
    hx &= 0x000fffff
    let i = (hx &+ 0x95f64) & 0x100000
    x = setHI(x, UInt32(bitPattern: hx | (i ^ 0x3ff00000)))   /* normalize x or x/2 */
    k &+= (i >> 20)
    let f = x - 1.0
    if (0x000fffff & (2 &+ hx)) < 3 {                /* |f| < 2**-20 */
        if f == logZero {
            if k == 0 { return logZero }
            let dk = Double(k)
            return dk * logLn2HI + dk * logLn2LO
        }
        let r = f * f * (0.5 - 0.33333333333333333 * f)
        if k == 0 { return f - r }
        let dk = Double(k)
        return dk * logLn2HI - ((r - dk * logLn2LO) - f)
    }
    let s = f / (2.0 + f)
    let dk = Double(k)
    let z = s * s
    var i2 = hx &- 0x6147a
    let w = z * z
    let j = 0x6b851 &- hx
    let t1 = w * (logLg2 + w * (logLg4 + w * logLg6))
    let t2 = z * (logLg1 + w * (logLg3 + w * (logLg5 + w * logLg7)))
    i2 |= j
    let r = t2 + t1
    if i2 > 0 {
        let hfsq = 0.5 * f * f
        if k == 0 { return f - (hfsq - s * (hfsq + r)) }
        return dk * logLn2HI - ((hfsq - (s * (hfsq + r) + dk * logLn2LO)) - f)
    } else {
        if k == 0 { return f - s * (f - r) }
        return dk * logLn2HI - ((s * (f - r) - dk * logLn2LO) - f)
    }
}

// ---------------------------------------------------------------------------
// scalbn — scalbn(x, n) (fdlibm s_scalbn.c); private, used only by detPow
// ---------------------------------------------------------------------------
private let scalbnTwo54 = fromWords(0x43500000, 0)
private let scalbnTwom54 = fromWords(0x3C900000, 0)
private let scalbnHuge = 1.0e+300
private let scalbnTiny = 1.0e-300

private func detScalbn(_ xIn: Double, _ nIn: Int32) -> Double {
    var x = xIn
    let n = nIn
    var hx = HI(x)
    let lx = LO(x)
    var k = (hx & 0x7ff00000) >> 20                 /* extract exponent */
    if k == 0 {                                      /* 0 or subnormal x */
        if (lx | (hx & 0x7fffffff)) == 0 { return x }  /* +-0 */
        x *= scalbnTwo54
        hx = HI(x)
        k = ((hx & 0x7ff00000) >> 20) &- 54
        if n < -50000 { return scalbnTiny * x }        /* underflow */
    }
    if k == 0x7ff { return x + x }                   /* NaN or Inf */
    k = k &+ n
    if k > 0x7fe { return scalbnHuge * (x < 0 ? -scalbnHuge : scalbnHuge) }  /* overflow */
    if k > 0 {                                        /* normal result */
        x = setHI(x, UInt32(bitPattern: (hx & Int32(bitPattern: 0x800fffff)) | (k << 20)))
        return x
    }
    if k <= -54 {
        if n > 50000 { return scalbnHuge * (x < 0 ? -scalbnHuge : scalbnHuge) }   /* overflow */
        return scalbnTiny * (x < 0 ? -scalbnTiny : scalbnTiny)                     /* underflow */
    }
    k &+= 54                                          /* subnormal result */
    x = setHI(x, UInt32(bitPattern: (hx & Int32(bitPattern: 0x800fffff)) | (k << 20)))
    return x * scalbnTwom54
}

// ---------------------------------------------------------------------------
// pow — __ieee754_pow (fdlibm e_pow.c)
// ---------------------------------------------------------------------------
private let powBp: [Double] = [1.0, 1.5]
private let powDpH: [Double] = [0.0, fromWords(0x3FE2B803, 0x40000000)]
private let powDpL: [Double] = [0.0, fromWords(0x3E4CFDEB, 0x43CFD006)]
private let powZero = 0.0
private let powOne = 1.0
private let powTwo = 2.0
private let powTwo53 = fromWords(0x43400000, 0)
private let powHuge = 1.0e300
private let powTiny = 1.0e-300
private let powL1 = fromWords(0x3FE33333, 0x33333303)
private let powL2 = fromWords(0x3FDB6DB6, 0xDB6FABFF)
private let powL3 = fromWords(0x3FD55555, 0x518F264D)
private let powL4 = fromWords(0x3FD17460, 0xA91D4101)
private let powL5 = fromWords(0x3FCD864A, 0x93C9DB65)
private let powL6 = fromWords(0x3FCA7E28, 0x4A454EEF)
private let powP1 = fromWords(0x3FC55555, 0x5555553E)
private let powP2 = fromWords(0xBF66C16C, 0x16BEBD93)
private let powP3 = fromWords(0x3F11566A, 0xAF25DE2C)
private let powP4 = fromWords(0xBEBBBD41, 0xC5D26BF1)
private let powP5 = fromWords(0x3E663769, 0x72BEA4D0)
private let powLg2 = fromWords(0x3FE62E42, 0xFEFA39EF)
private let powLg2H = fromWords(0x3FE62E43, 0x00000000)
private let powLg2L = fromWords(0xBE205C61, 0x0CA86C39)
private let powOvt = fromWords(0x3C971547, 0x652b82fe)                     /* 8.0085662595372944372e-17 */
private let powCp = fromWords(0x3FEEC709, 0xDC3A03FD)
private let powCpH = fromWords(0x3FEEC709, 0xE0000000)
private let powCpL = fromWords(0xBE3E2FE0, 0x145B01F5)
private let powIvln2 = fromWords(0x3FF71547, 0x652B82FE)
private let powIvln2H = fromWords(0x3FF71547, 0x60000000)
private let powIvln2L = fromWords(0x3E54AE0B, 0xF85DDF44)

public func detPow(_ x: Double, _ y: Double) -> Double {
    // i0/i1 in the upstream source (an endianness probe reading `*(int*)&one`) are computed
    // but never used anywhere else in __ieee754_pow; omitted here as dead code.
    let hx = HI(x), lx = LO(x)
    let hy = HI(y), ly = LO(y)
    let ix = hx & 0x7fffffff
    let iy = hy & 0x7fffffff

    if (iy | ly) == 0 { return powOne }                          /* x**0 = 1 */

    if ix > 0x7ff00000 || (ix == 0x7ff00000 && lx != 0)
        || iy > 0x7ff00000 || (iy == 0x7ff00000 && ly != 0) {
        return x + y                                              /* +-NaN */
    }

    /* yisint: 0 = not integer, 1 = odd integer, 2 = even integer (only computed when x<0) */
    var yisint: Int32 = 0
    if hx < 0 {
        if iy >= 0x43400000 {
            yisint = 2
        } else if iy >= 0x3ff00000 {
            let k = (iy >> 20) &- 0x3ff
            if k > 20 {
                // ly>>(52-k)/(j<<(52-k)) mirror an unsigned shift by a runtime amount that the
                // upstream C leaves formally undefined for k > 52 (huge |y|); done here with
                // masking shifts so it can never trap, matching the hardware's usual
                // mod-bitwidth shift behaviour. The golden this is checked against (Decision
                // 14) never exercises |y| this huge, so this path is covered only by the
                // no-trap sweep, not by a bit-exact match requirement.
                let shiftAmount = UInt32(bitPattern: 52 &- k)
                let lyU = UInt32(bitPattern: ly)
                let jU = lyU &>> shiftAmount
                if (jU &<< shiftAmount) == lyU { yisint = 2 &- Int32(bitPattern: jU & 1) }
            } else if ly == 0 {
                let shiftAmount = UInt32(bitPattern: 20 &- k)      /* 0...20, always in range */
                let iyU = UInt32(bitPattern: iy)
                let jU = iyU &>> shiftAmount
                if (jU &<< shiftAmount) == iyU { yisint = 2 &- Int32(bitPattern: jU & 1) }
            }
        }
    }

    if ly == 0 {
        if iy == 0x7ff00000 {                                     /* y is +-inf */
            if ((ix &- 0x3ff00000) | lx) == 0 { return y - y }     /* inf**+-1 is NaN */
            if ix >= 0x3ff00000 { return hy >= 0 ? y : powZero }   /* (|x|>1)**+-inf */
            return hy < 0 ? -y : powZero                            /* (|x|<1)**-,+inf */
        }
        if iy == 0x3ff00000 {                                      /* y is +-1 */
            return hy < 0 ? powOne / x : x
        }
        if hy == 0x40000000 { return x * x }                       /* y is 2 */
        if hy == 0x3fe00000 {                                       /* y is 0.5 */
            if hx >= 0 { return x.squareRoot() }                    /* x >= +0 */
        }
    }

    let ax = abs(x)
    if lx == 0 {
        if ix == 0x7ff00000 || ix == 0 || ix == 0x3ff00000 {       /* x is +-0,+-inf,+-1 */
            var z = ax
            if hy < 0 { z = powOne / z }
            if hx < 0 {
                if ((ix &- 0x3ff00000) | yisint) == 0 {
                    z = (z - z) / (z - z)                            /* (-1)**non-int is NaN */
                } else if yisint == 1 {
                    z = -z                                            /* (x<0)**odd = -(|x|**odd) */
                }
            }
            return z
        }
    }

    var n = (hx >> 31) &+ 1

    if (n | yisint) == 0 { return (x - x) / (x - x) }               /* (x<0)**(non-int) is NaN */

    var s = powOne
    if (n | (yisint &- 1)) == 0 { s = -powOne }                     /* (-ve)**(odd int) */

    var t1 = 0.0, t2 = 0.0

    if iy > 0x41e00000 {                                             /* |y| > 2**31 */
        if iy > 0x43f00000 {                                         /* |y| > 2**64 */
            if ix <= 0x3fefffff { return hy < 0 ? powHuge * powHuge : powTiny * powTiny }
            if ix >= 0x3ff00000 { return hy > 0 ? powHuge * powHuge : powTiny * powTiny }
        }
        if ix < 0x3fefffff { return hy < 0 ? s * powHuge * powHuge : s * powTiny * powTiny }
        if ix > 0x3ff00000 { return hy > 0 ? s * powHuge * powHuge : s * powTiny * powTiny }
        /* now |1-x| is tiny <= 2**-20 */
        let t = ax - powOne
        let w = (t * t) * (0.5 - t * (0.3333333333333333333333 - t * 0.25))
        let u = powIvln2H * t
        let v = t * powIvln2L - w * powIvln2
        var t1a = u + v
        t1a = setLO(t1a, 0)
        t2 = v - (t1a - u)
        t1 = t1a
    } else {
        var ss = 0.0, s2 = 0.0, sH = 0.0, sL = 0.0, tH = 0.0, tL = 0.0
        n = 0
        var axv = ax
        var ixv = ix
        if ixv < 0x00100000 {                                        /* subnormal x */
            axv *= powTwo53
            n &-= 53
            ixv = HI(axv)
        }
        n &+= (ixv >> 20) &- 0x3ff
        let j = ixv & 0x000fffff
        ixv = j | 0x3ff00000
        var k: Int32
        if j <= 0x3988E {
            k = 0
        } else if j < 0xBB67A {
            k = 1
        } else {
            k = 0
            n &+= 1
            ixv &-= 0x00100000
        }
        axv = setHI(axv, UInt32(bitPattern: ixv))

        let u = axv - powBp[Int(k)]
        let v = powOne / (axv + powBp[Int(k)])
        ss = u * v
        sH = setLO(ss, 0)
        tH = setHI(powZero, UInt32(bitPattern: ((ixv >> 1) | 0x20000000) &+ 0x00080000 &+ (k << 18)))
        tL = axv - (tH - powBp[Int(k)])
        sL = v * ((u - sH * tH) - sH * tL)
        s2 = ss * ss
        var r = s2 * s2 * (powL1 + s2 * (powL2 + s2 * (powL3 + s2 * (powL4 + s2 * (powL5 + s2 * powL6)))))
        r += sL * (sH + ss)
        s2 = sH * sH
        tH = 3.0 + s2 + r
        tH = setLO(tH, 0)
        tL = r - ((tH - 3.0) - s2)
        let u2 = sH * tH
        let v2 = sL * tH + tL * ss
        var pH = u2 + v2
        pH = setLO(pH, 0)
        let pL = v2 - (pH - u2)
        let zH = powCpH * pH
        let zL = powCpL * pH + pL * powCp + powDpL[Int(k)]
        let t = Double(n)
        var t1b = ((zH + zL) + powDpH[Int(k)]) + t
        t1b = setLO(t1b, 0)
        t2 = zL - (((t1b - t) - powDpH[Int(k)]) - zH)
        t1 = t1b
    }

    let y1 = setLO(y, 0)
    let pL = (y - y1) * t1 + y * t2
    var pH = y1 * t1
    var z = pL + pH
    var j = HI(z)
    var i = LO(z)
    if j >= 0x40900000 {                                             /* z >= 1024 */
        if ((j &- 0x40900000) | i) != 0 { return s * powHuge * powHuge }  /* z > 1024 */
        if pL + powOvt > z - pH { return s * powHuge * powHuge }
    } else if (j & 0x7fffffff) >= 0x4090cc00 {                        /* z <= -1075 */
        if ((j &- Int32(bitPattern: 0xc090cc00)) | i) != 0 { return s * powTiny * powTiny }
        if pL <= z - pH { return s * powTiny * powTiny }
    }

    i = j & 0x7fffffff
    var k = (i >> 20) &- 0x3ff
    n = 0
    if i > 0x3fe00000 {                                                /* |z| > 0.5 */
        n = j &+ (0x00100000 >> (k &+ 1))
        k = ((n & 0x7fffffff) >> 20) &- 0x3ff
        var t = powZero
        t = setHI(t, UInt32(bitPattern: n & ~(0x000fffff >> k)))
        n = ((n & 0x000fffff) | 0x00100000) >> (20 &- k)
        if j < 0 { n = -n }
        pH -= t
    }
    var t = pL + pH
    t = setLO(t, 0)
    let u = t * powLg2H
    let v = (pL - (t - pH)) * powLg2 + t * powLg2L
    z = u + v
    let w = v - (z - u)
    t = z * z
    t1 = z - t * (powP1 + t * (powP2 + t * (powP3 + t * (powP4 + t * powP5))))
    let r2 = (z * t1) / (t1 - powTwo) - (w + z * w)
    z = powOne - (r2 - z)
    j = HI(z)
    j &+= (n << 20)
    if (j >> 20) <= 0 {
        z = detScalbn(z, n)
    } else {
        z = setHI(z, UInt32(bitPattern: HI(z) &+ (n << 20)))
    }
    return s * z
}

// ---------------------------------------------------------------------------
// Seeded gameplay RNG — reference implementation. All state-affecting
// randomness draws from this stream in frozen call order; cosmetic-only
// randomness stays off-stream so golden hashes never see it.
// ---------------------------------------------------------------------------
public var gameRng = RandomX(0x6A57)
public func resetGameRng(_ seed: UInt32) { gameRng = RandomX(seed) }
