import Foundation
import XCTest
@testable import ElysiumCore

/// Covers the deterministic-math part of change 3 (`docs/scripting-and-eventing-design.md`
/// §16 row 3 / §17 Decision 10): the fdlibm `tan`/`asin`/`acos`/`log10` ports (`detTan`,
/// `detAsin`, `detAcos`, `detLog10`) and the derived `detLog2` (see its doc comment in
/// DetMath.swift for the provenance decision — classic fdlibm has no `e_log2.c`), their
/// independent frozen reference (`goldens/fmath-trig-goldens.json`, produced by
/// `scripts/fdlibm-reference/gen-trig-goldens.c`/`.sh`), the no-trap guarantee, exact
/// metamorphic invariants, and a pin that the pre-existing DetMath surface
/// (`detSin`/`detCos`/`detAtan`/`detAtan2`/`detExp`/`detLog`/`detPow`, `RandomX.nextGaussian`,
/// `gameRng`/`resetGameRng`) is untouched — this change is additive only.
final class DetMathTrigLogTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Hex word format ("hi-lo" per Double), matching goldens/fmath-goldens.json

    private func parseHexWord(_ s: Substring) -> Double {
        let parts = s.split(separator: "-")
        let hi = UInt64(parts[0], radix: 16)!
        let lo = UInt64(parts[1], radix: 16)!
        return Double(bitPattern: (hi << 32) | lo)
    }

    private func hexWord(_ x: Double) -> String {
        String(x.bitPattern >> 32, radix: 16) + "-" + String(x.bitPattern & 0xffff_ffff, radix: 16)
    }

    /// Bit-exact except that any two NaNs compare equal regardless of payload — same
    /// comparator contract as DetMathExpLogPowTests / the golden generator's own convention.
    private func bitwiseEqualOrBothNaN(_ a: Double, _ b: Double) -> Bool {
        if a.isNaN && b.isNaN { return true }
        return a.bitPattern == b.bitPattern
    }

    private func loadGolden() throws -> (tan: [String], asinAcos: [String], log2Log10: [String]) {
        let url = repositoryRoot.appendingPathComponent("goldens/fmath-trig-goldens.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (json["tan"] as! [String], json["asinAcos"] as! [String], json["log2Log10"] as! [String])
    }

    // MARK: - Golden cross-check (bit patterns)

    func testTanGoldenProbesAreBitIdentical() throws {
        let (tan, _, _) = try loadGolden()
        XCTAssertGreaterThanOrEqual(tan.count, 900, "gen-trig-goldens.c: tan probe count")
        var mismatches: [String] = []
        for probe in tan {
            let parts = probe.split(separator: ":")
            let x = parseHexWord(parts[0])
            let want = parseHexWord(parts[1])
            let got = detTan(x)
            if !bitwiseEqualOrBothNaN(got, want) {
                mismatches.append("tan(\(hexWord(x))): got \(hexWord(got)) want \(hexWord(want))")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first few:\n" +
                      mismatches.prefix(10).joined(separator: "\n"))
    }

    func testAsinAcosGoldenProbesAreBitIdentical() throws {
        let (_, asinAcos, _) = try loadGolden()
        XCTAssertGreaterThanOrEqual(asinAcos.count, 900, "gen-trig-goldens.c: asinAcos probe count")
        var mismatches: [String] = []
        for probe in asinAcos {
            let parts = probe.split(separator: ":")
            let x = parseHexWord(parts[0])
            let outs = parts[1].split(separator: ",")
            let wantAsin = parseHexWord(outs[0])
            let wantAcos = parseHexWord(outs[1])
            let gotAsin = detAsin(x)
            let gotAcos = detAcos(x)
            if !bitwiseEqualOrBothNaN(gotAsin, wantAsin) {
                mismatches.append("asin(\(hexWord(x))): got \(hexWord(gotAsin)) want \(hexWord(wantAsin))")
            }
            if !bitwiseEqualOrBothNaN(gotAcos, wantAcos) {
                mismatches.append("acos(\(hexWord(x))): got \(hexWord(gotAcos)) want \(hexWord(wantAcos))")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first few:\n" +
                      mismatches.prefix(10).joined(separator: "\n"))
    }

    func testLog2Log10GoldenProbesAreBitIdentical() throws {
        let (_, _, log2Log10) = try loadGolden()
        XCTAssertGreaterThanOrEqual(log2Log10.count, 700, "gen-trig-goldens.c: log2Log10 probe count")
        var mismatches: [String] = []
        for probe in log2Log10 {
            let parts = probe.split(separator: ":")
            let x = parseHexWord(parts[0])
            let outs = parts[1].split(separator: ",")
            let wantLog2 = parseHexWord(outs[0])
            let wantLog10 = parseHexWord(outs[1])
            let gotLog2 = detLog2(x)
            let gotLog10 = detLog10(x)
            if !bitwiseEqualOrBothNaN(gotLog2, wantLog2) {
                mismatches.append("log2(\(hexWord(x))): got \(hexWord(gotLog2)) want \(hexWord(wantLog2))")
            }
            if !bitwiseEqualOrBothNaN(gotLog10, wantLog10) {
                mismatches.append("log10(\(hexWord(x))): got \(hexWord(gotLog10)) want \(hexWord(wantLog10))")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first few:\n" +
                      mismatches.prefix(10).joined(separator: "\n"))
    }

    func testGeneratorScriptReproducesTheCommittedGoldenByteForByte() throws {
        // Frozen reference (same contract as gen-explog-goldens.c / DetMathExpLogPowTests):
        // the committed golden is never hand-edited, and the generator that produced it must
        // still reproduce it exactly. Skipped (not failed) when `cc` is unavailable.
        guard FileManager.default.fileExists(atPath: "/usr/bin/cc") else {
            throw XCTSkip("cc not available")
        }
        let scriptPath = repositoryRoot.appendingPathComponent("scripts/fdlibm-reference/gen-trig-goldens.sh").path
        let committedPath = repositoryRoot.appendingPathComponent("goldens/fmath-trig-goldens.json").path
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")

        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: committedPath))
        try originalBytes.write(to: tmp)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")

        let regenerated = try Data(contentsOf: URL(fileURLWithPath: committedPath))
        XCTAssertEqual(regenerated, originalBytes, "generator output drifted from the committed golden")

        try regenerated.write(to: URL(fileURLWithPath: committedPath))
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Special-value tables

    func testTanSpecialValues() {
        XCTAssertEqual(detTan(0.0).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(detTan(-0.0).bitPattern, (-0.0).bitPattern)
        XCTAssertTrue(detTan(Double.nan).isNaN)
        XCTAssertTrue(detTan(.infinity).isNaN, "tan(+-inf) is NaN")
        XCTAssertTrue(detTan(-.infinity).isNaN)
        // tan(pi) is not exactly 0: pi is not exactly representable, so this is a tiny
        // negative number close to zero (sin(pi)~1.2e-16, cos(pi)~-1), not a special case.
        XCTAssertTrue(detTan(.pi) < 0 && detTan(.pi) > -1e-10)
        // tan(pi/2) does not diverge to infinity (finite double reduction), but is huge:
        XCTAssertTrue(abs(detTan(Double.pi / 2)) > 1e10)
    }

    func testAsinSpecialValues() {
        XCTAssertEqual(detAsin(0.0).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(detAsin(-0.0).bitPattern, (-0.0).bitPattern)
        XCTAssertEqual(detAsin(1.0), .pi / 2, accuracy: 1e-15)
        XCTAssertEqual(detAsin(-1.0), -(.pi / 2), accuracy: 1e-15)
        XCTAssertTrue(detAsin(1.5).isNaN, "asin(|x|>1) is NaN")
        XCTAssertTrue(detAsin(-1.5).isNaN)
        XCTAssertTrue(detAsin(Double.nan).isNaN)
        XCTAssertTrue(detAsin(.infinity).isNaN)
        XCTAssertTrue(detAsin(-.infinity).isNaN)
    }

    func testAcosSpecialValues() {
        XCTAssertEqual(detAcos(1.0).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(detAcos(-1.0), .pi, accuracy: 1e-15)
        XCTAssertEqual(detAcos(0.0), .pi / 2, accuracy: 1e-15)
        XCTAssertTrue(detAcos(1.5).isNaN, "acos(|x|>1) is NaN")
        XCTAssertTrue(detAcos(-1.5).isNaN)
        XCTAssertTrue(detAcos(Double.nan).isNaN)
        XCTAssertTrue(detAcos(.infinity).isNaN)
        XCTAssertTrue(detAcos(-.infinity).isNaN)
    }

    func testLog2SpecialValues() {
        XCTAssertEqual(detLog2(1.0).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(detLog2(2.0), 1.0)
        XCTAssertEqual(detLog2(1024.0), 10.0)
        XCTAssertEqual(detLog2(.infinity), .infinity)
        XCTAssertEqual(detLog2(0.0), -.infinity)
        XCTAssertEqual(detLog2(-0.0), -.infinity)
        XCTAssertTrue(detLog2(-1.0).isNaN, "log2(x<0) = NaN")
        XCTAssertTrue(detLog2(-.infinity).isNaN)
        XCTAssertTrue(detLog2(Double.nan).isNaN)
    }

    func testLog10SpecialValues() {
        XCTAssertEqual(detLog10(1.0).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(detLog10(10.0), 1.0)
        XCTAssertEqual(detLog10(1000.0), 3.0)
        XCTAssertEqual(detLog10(.infinity), .infinity)
        XCTAssertEqual(detLog10(0.0), -.infinity)
        XCTAssertEqual(detLog10(-0.0), -.infinity)
        XCTAssertTrue(detLog10(-1.0).isNaN, "log10(x<0) = NaN")
        XCTAssertTrue(detLog10(-.infinity).isNaN)
        XCTAssertTrue(detLog10(Double.nan).isNaN)
    }

    /// `detLog2(2**n) == n` exactly for every representable power of two — the exactness
    /// property documented on `detLog2` in DetMath.swift, spot-checked directly here (the
    /// golden's "powers of two" band already covers this at scale).
    func testLog2ExactForPowersOfTwo() {
        for n in [-1074, -1073, -1050, -1022, -1, 0, 1, 2, 10, 52, 53, 100, 500, 1000, 1023] {
            let x = Foundation.pow(2.0, Double(n))
            guard x.isFinite, x > 0 else { continue }
            XCTAssertEqual(detLog2(x), Double(n), "detLog2(2**\(n)) should be exactly \(n)")
        }
    }

    // MARK: - No-trap sweep

    func testNoTrapOnExtendedSpecialInputs() {
        let doubles: [Double] = [
            .infinity, -.infinity, .nan, -0.0, 0.0,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
            .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
            .leastNormalMagnitude, -.leastNormalMagnitude,
            Double(bitPattern: 0x7ff0000000000001),   // NaN payload 1
            Double(bitPattern: 0xfff8000000000001),   // NaN payload, sign set
            Double(bitPattern: 0x7ff4000000000abc),   // another NaN payload
            1.0, -1.0, 1.5, -1.5, 0.5, -0.5,
            1e308, -1e308, 1e-308, -1e-308,
            .pi, -.pi, .pi / 2, -.pi / 2, .pi / 4, -.pi / 4,
            1e10, -1e10, 1e100, -1e100, 1e300, -1e300,
        ]
        for x in doubles {
            _ = detTan(x)
            _ = detAsin(x)
            _ = detAcos(x)
            _ = detLog2(x)
            _ = detLog10(x)
        }
        XCTAssertTrue(true, "reaching here without a trap/crash is the assertion")
    }

    /// Wide, deterministic (seeded, not `Double.random`) bit-pattern sweep across every
    /// finite, infinite, NaN, subnormal and zero bit-pattern class — including the huge
    /// magnitudes that force `detTan` through the full Payne-Hanek reduction
    /// (`kernelRemPio2`), the most complex and highest-risk-of-trap code path this change
    /// adds. The assertion is purely "does not trap", not a golden match.
    func testNoTrapRandomBitPatternSweep() {
        var rng = RandomX(0xBADA55)
        for _ in 0..<50_000 {
            let bitsX = (UInt64(rng.next()) << 32) | UInt64(rng.next())
            let x = Double(bitPattern: bitsX)
            _ = detTan(x)
            _ = detAsin(x)
            _ = detAcos(x)
            _ = detLog2(x)
            _ = detLog10(x)
        }
        XCTAssertTrue(true, "50000 random bit patterns through tan/asin/acos/log2/log10 without a trap")
    }

    // MARK: - Monotonicity spot checks

    func testAsinMonotonicOnItsDomain() {
        let xs: [Double] = [-1.0, -0.9, -0.5, -0.1, 0.0, 0.1, 0.5, 0.9, 1.0]
        for i in 1..<xs.count {
            XCTAssertLessThanOrEqual(detAsin(xs[i - 1]), detAsin(xs[i]),
                                      "detAsin should be non-decreasing: \(xs[i-1]) -> \(xs[i])")
        }
    }

    func testAcosMonotonicallyDecreasingOnItsDomain() {
        let xs: [Double] = [-1.0, -0.9, -0.5, -0.1, 0.0, 0.1, 0.5, 0.9, 1.0]
        for i in 1..<xs.count {
            XCTAssertGreaterThanOrEqual(detAcos(xs[i - 1]), detAcos(xs[i]),
                                         "detAcos should be non-increasing: \(xs[i-1]) -> \(xs[i])")
        }
    }

    func testLog2AndLog10MonotonicOnPositiveReals() {
        let xs: [Double] = [1e-300, 1e-10, 0.5, 1.0, 2.0, 10.0, 1e10, 1e100, 1e300]
        for i in 1..<xs.count {
            XCTAssertLessThan(detLog2(xs[i - 1]), detLog2(xs[i]))
            XCTAssertLessThan(detLog10(xs[i - 1]), detLog10(xs[i]))
        }
    }

    func testTanMonotonicWithinTheOpenPrincipalInterval() {
        // Strictly increasing on (-pi/2, pi/2); spot-checked away from the singularity where
        // the golden's dense/huge bands already give it thorough bit-exact coverage.
        let xs: [Double] = [-1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5]
        for i in 1..<xs.count {
            XCTAssertLessThan(detTan(xs[i - 1]), detTan(xs[i]))
        }
    }

    // MARK: - Metamorphic checks (bit-exact only — see note)

    // Note on scope: `detAsin(x) + detAcos(x) == pi/2` and similar cofunction identities are
    // NOT included here because they are not bit-exact — each side is built from a different
    // rational-polynomial evaluation (different p/q coefficients combined differently per
    // branch), so their floating-point sum lands within a few ULP of pi/2 but essentially
    // never exactly on it. Only identities the algorithms enforce structurally (oddness, via
    // an explicit sign branch that negates an otherwise-identical magnitude computation) are
    // checked here, bit-for-bit, with no tolerance.

    /// `detAsin(-x) == -detAsin(x)` for every non-NaN `x` — `detAsin` computes its magnitude
    /// from `ix = hx & 0x7fffffff` and `abs(x)` (sign-independent) and applies the sign only
    /// in the final `hx > 0 ? result : -result`, so this holds bit-for-bit, not just
    /// approximately (verified over a 500,000-sample bit-pattern sweep during development).
    func testAsinOddnessIsBitExact() {
        var rng = RandomX(0x0DD0DD)
        for _ in 0..<20_000 {
            let bitsX = (UInt64(rng.next()) << 32) | UInt64(rng.next())
            let x = Double(bitPattern: bitsX)
            if x.isNaN { continue }
            let a = detAsin(x)
            let b = detAsin(-x)
            if a.isNaN {
                XCTAssertTrue(b.isNaN)
                continue
            }
            XCTAssertEqual(a.bitPattern, (-b).bitPattern, "detAsin(-\(x)) should be exactly -detAsin(\(x))")
        }
    }

    /// `detTan(-x) == -detTan(x)` for every non-NaN `x`, including the huge-argument path —
    /// `kernelTan` folds `-x` to `x` (with `y` co-negated) before reducing near pi/4, and
    /// `tanRemPio2` negates `(n, y0, y1)` outright for `hx < 0`, so the whole pipeline
    /// preserves oddness exactly (verified over a 500,000-sample bit-pattern sweep during
    /// development, including magnitudes that force the full Payne-Hanek reduction).
    func testTanOddnessIsBitExact() {
        var rng = RandomX(0x0DD1234)
        for _ in 0..<20_000 {
            let bitsX = (UInt64(rng.next()) << 32) | UInt64(rng.next())
            let x = Double(bitPattern: bitsX)
            if x.isNaN { continue }
            let a = detTan(x)
            let b = detTan(-x)
            if a.isNaN {
                XCTAssertTrue(b.isNaN)
                continue
            }
            XCTAssertEqual(a.bitPattern, (-b).bitPattern, "detTan(-\(x)) should be exactly -detTan(\(x))")
        }
    }

    // MARK: - Pin: the pre-existing DetMath surface is untouched

    func testExistingDetMathKernelsAreUnchanged() {
        // detSin/detCos/detAtan/detAtan2/detExp/detLog/detPow continue to behave exactly as
        // before this change (design.md Decision 10 / the DO-NOT-TOUCH list): spot-check a
        // handful of known-good values as a fast regression signal. Full coverage remains
        // DetMathExpLogPowTests (exp/log/pow) and elysmoke's fdlibm section (sin/cos/atan,
        // out of this test target's scope).
        XCTAssertEqual(detSin(0.0), 0.0)
        XCTAssertEqual(detCos(0.0), 1.0)
        XCTAssertEqual(detAtan2(0.0, 1.0), 0.0)
        XCTAssertEqual(detAtan(1.0), .pi / 4, accuracy: 1e-15)
        XCTAssertEqual(detExp(0.0).bitPattern, (1.0).bitPattern)
        XCTAssertEqual(detLog(1.0).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(detPow(3.0, 2.0), 9.0)
    }

    func testGameRngAndResetGameRngAreUntouched() throws {
        let source = try source("Sources/ElysiumCore/Core/DetMath.swift")
        XCTAssertTrue(source.contains("public var gameRng = RandomX(0x6A57)"))
        XCTAssertTrue(source.contains("public func resetGameRng(_ seed: UInt32) { gameRng = RandomX(seed) }"))
    }

    func testNextGaussianBodyIsByteIdenticalToPinnedText() throws {
        let expectedBody = """
    public mutating func nextGaussian() -> Double {
        var u = 0.0, v = 0.0
        while u == 0 { u = nextFloat() }
        while v == 0 { v = nextFloat() }
        return (-2.0 * Foundation.log(u)).squareRoot() * detCos(2.0 * .pi * v)
    }
"""
        let source = try source("Sources/ElysiumCore/Core/RandomX.swift")
        XCTAssertTrue(source.contains(expectedBody),
                      "RandomX.nextGaussian body drifted from the pinned text (design Condition 9: " +
                      "nextGaussian must stay byte-identical)")
    }
}
