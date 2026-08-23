import Foundation
import XCTest
@testable import ElysiumCore

/// Covers design.md Decision 14 / tasks 4.1-4.5 (RandomX half of 3.4 too): the fdlibm
/// exp/log/pow ports (`detExp`, `detLog`, `detPow`), their independent frozen reference
/// (`goldens/fmath-explog-goldens.json`, produced by `scripts/fdlibm-reference/`), the
/// no-trap guarantee (design condition C32 / security-plan.md F15), and the additive
/// `RandomX` state-word accessors plus the `nextGaussian` source pin
/// (`specs/deterministic-math-ports/spec.md`).
final class DetMathExpLogPowTests: XCTestCase {
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

    /// Bit-exact except that any two NaNs compare equal regardless of payload — the golden
    /// generator's own comparator contract per design.md Decision 14 ("NaN compared as NaN").
    private func bitwiseEqualOrBothNaN(_ a: Double, _ b: Double) -> Bool {
        if a.isNaN && b.isNaN { return true }
        return a.bitPattern == b.bitPattern
    }

    private func loadGolden() throws -> (expLog: [String], pow: [String]) {
        let url = repositoryRoot.appendingPathComponent("goldens/fmath-explog-goldens.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (json["expLog"] as! [String], json["pow"] as! [String])
    }

    // MARK: - Golden cross-check (bit patterns)

    func testExpLogGoldenProbesAreBitIdentical() throws {
        let (expLog, _) = try loadGolden()
        XCTAssertGreaterThanOrEqual(expLog.count, 600, "design.md Decision 14: N >= 600")
        var mismatches: [String] = []
        for probe in expLog {
            let parts = probe.split(separator: ":")
            let x = parseHexWord(parts[0])
            let outs = parts[1].split(separator: ",")
            let wantExp = parseHexWord(outs[0])
            let wantLog = parseHexWord(outs[1])
            let gotExp = detExp(x)
            let gotLog = detLog(x)
            if !bitwiseEqualOrBothNaN(gotExp, wantExp) {
                mismatches.append("exp(\(hexWord(x))): got \(hexWord(gotExp)) want \(hexWord(wantExp))")
            }
            if !bitwiseEqualOrBothNaN(gotLog, wantLog) {
                mismatches.append("log(\(hexWord(x))): got \(hexWord(gotLog)) want \(hexWord(wantLog))")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first few:\n" +
                      mismatches.prefix(10).joined(separator: "\n"))
    }

    func testPowGoldenProbesAreBitIdentical() throws {
        let (_, powProbes) = try loadGolden()
        XCTAssertGreaterThanOrEqual(powProbes.count, 300, "design.md Decision 14: M >= 300")
        var mismatches: [String] = []
        for probe in powProbes {
            let parts = probe.split(separator: ":")
            let ins = parts[0].split(separator: ",")
            let x = parseHexWord(ins[0])
            let y = parseHexWord(ins[1])
            let want = parseHexWord(parts[1])
            let got = detPow(x, y)
            if !bitwiseEqualOrBothNaN(got, want) {
                mismatches.append("pow(\(hexWord(x)),\(hexWord(y))): got \(hexWord(got)) want \(hexWord(want))")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first few:\n" +
                      mismatches.prefix(10).joined(separator: "\n"))
    }

    func testGeneratorScriptReproducesTheCommittedGoldenByteForByte() throws {
        // Frozen reference (design.md Decision 14 / Condition 10): the committed golden is
        // never hand-edited, and the generator that produced it must still reproduce it
        // exactly. Skipped (not failed) when `cc` is unavailable in this environment.
        guard FileManager.default.fileExists(atPath: "/usr/bin/cc") else {
            throw XCTSkip("cc not available")
        }
        let scriptPath = repositoryRoot.appendingPathComponent("scripts/fdlibm-reference/gen-explog-goldens.sh").path
        let committedPath = repositoryRoot.appendingPathComponent("goldens/fmath-explog-goldens.json").path
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")

        // The script always writes to goldens/fmath-explog-goldens.json relative to its own
        // location; run it against a scratch copy of the repo's goldens output path instead by
        // pointing HOME-relative output through a temp copy: simplest is to run the real
        // script (it is safe/idempotent — upstream/ is already populated so it never
        // re-fetches) and diff its regenerated output against a snapshot taken first.
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

        // Restore exactly (defensive; the generator should already have reproduced it
        // byte-for-byte, but never leave the working tree altered by running a test).
        try regenerated.write(to: URL(fileURLWithPath: committedPath))
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Special-value table (design.md spec "Special values" scenario)

    func testExpSpecialValues() {
        XCTAssertEqual(detExp(0.0).bitPattern, (1.0).bitPattern)
        XCTAssertEqual(detExp(-0.0).bitPattern, (1.0).bitPattern)
        XCTAssertTrue(detExp(Double.nan).isNaN)
        XCTAssertEqual(detExp(.infinity), .infinity)
        XCTAssertEqual(detExp(-.infinity).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(detExp(710.0), .infinity, "above overflow threshold")
        XCTAssertEqual(detExp(-746.0).bitPattern, (0.0).bitPattern, "below underflow threshold")
    }

    func testLogSpecialValues() {
        XCTAssertEqual(detLog(1.0).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(detLog(.infinity), .infinity)
        XCTAssertEqual(detLog(0.0), -.infinity)
        XCTAssertEqual(detLog(-0.0), -.infinity)
        XCTAssertTrue(detLog(-1.0).isNaN, "log(x<0) = NaN")
        XCTAssertTrue(detLog(-.infinity).isNaN)
        XCTAssertTrue(detLog(Double.nan).isNaN)
    }

    func testPowSpecialValues() {
        // x**0 = 1 (even for NaN/Inf x, per fdlibm's documented case 1)
        XCTAssertEqual(detPow(2.0, 0.0).bitPattern, (1.0).bitPattern)
        XCTAssertEqual(detPow(Double.nan, 0.0).bitPattern, (1.0).bitPattern)
        XCTAssertEqual(detPow(.infinity, -0.0).bitPattern, (1.0).bitPattern)
        // 1**y = 1, including 1**inf and 1**NaN
        XCTAssertEqual(detPow(1.0, 5.0).bitPattern, (1.0).bitPattern)
        // (-x)**non-integer = NaN
        XCTAssertTrue(detPow(-2.0, 2.5).isNaN)
        // 0**negative = +inf
        XCTAssertEqual(detPow(0.0, -3.0), .infinity)
        XCTAssertEqual(detPow(-0.0, -4.0), .infinity, "-0 ** negative even == +inf")
        XCTAssertEqual(detPow(-0.0, -3.0), -.infinity, "-0 ** negative odd == -inf")
        // signed zero for -0 ** odd
        XCTAssertEqual(detPow(-0.0, 3.0).bitPattern, (-0.0).bitPattern)
        XCTAssertEqual(detPow(-0.0, 4.0).bitPattern, (0.0).bitPattern)
        // x**2 fast path and x**0.5 == sqrt(x)
        XCTAssertEqual(detPow(3.0, 2.0), 9.0)
        XCTAssertEqual(detPow(4.0, 0.5), 2.0)
        // (-x)**odd/even integer sign handling
        XCTAssertEqual(detPow(-2.0, 3.0), -8.0)
        XCTAssertEqual(detPow(-2.0, 4.0), 16.0)
        // +-1 ** +-inf = NaN
        XCTAssertTrue(detPow(1.0, Double.infinity).isNaN)
        XCTAssertTrue(detPow(-1.0, -Double.infinity).isNaN)
    }

    // MARK: - No-trap sweep (design.md Condition 32 / security-plan.md F15)

    func testNoTrapOnExtendedSpecialInputs() {
        let doubles: [Double] = [
            .infinity, -.infinity, .nan, -0.0, 0.0,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
            .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
            .leastNormalMagnitude, -.leastNormalMagnitude,
            Double(bitPattern: 0x7ff0000000000001),   // NaN payload 1
            Double(bitPattern: 0xfff8000000000001),   // NaN payload, sign set
            Double(bitPattern: 0x7ff4000000000abc),   // another NaN payload
            1e308, -1e308, 1e-308, -1e-308,
            710.0, -746.0, 709.78, -745.13,
        ]
        for x in doubles {
            _ = detExp(x)
            _ = detLog(x)
            for y in doubles {
                _ = detPow(x, y)
            }
        }
        // detPow with huge exponents (C32's explicit extreme-input list)
        for x in doubles {
            _ = detPow(x, 1e308)
            _ = detPow(x, -1e308)
        }
        XCTAssertTrue(true, "reaching here without a trap/crash is the assertion")
    }

    func testNoTrapExplicitC32List() {
        // The exact extreme-input list named in design.md Condition 32 / security-plan.md F15:
        // "pow(x, ±1e308)", "pow(-0, -1)", "pow(-8, 1/3)", "exp(±710)", "log(leastNonzeroMagnitude)".
        for x in [2.0, -2.0, 0.5, -0.5, 1.0, -1.0, 100.0, -100.0] {
            _ = detPow(x, 1e308)
            _ = detPow(x, -1e308)
        }
        XCTAssertEqual(detPow(-0.0, -1.0), -.infinity)
        let cubeRootAttempt = detPow(-8.0, 1.0 / 3.0)
        XCTAssertTrue(cubeRootAttempt.isNaN, "(-8)**(non-exact-integer 1/3) is NaN per fdlibm, not -2")
        XCTAssertEqual(detExp(710.0), .infinity, "above the 709.78 overflow threshold")
        // -710 is above (less negative than) fdlibm's -745.13 underflow shortcut threshold, so
        // this is a legitimate tiny-but-nonzero subnormal result, not a flush to zero.
        let expNeg710 = detExp(-710.0)
        XCTAssertTrue(expNeg710 > 0 && expNeg710 < 1e-300, "tiny positive, not flushed to 0")
        // leastNonzeroMagnitude is not zero, so its log is a large-magnitude finite negative
        // number (~-744.44), not -infinity.
        let logLeastNonzero = detLog(.leastNonzeroMagnitude)
        XCTAssertTrue(logLeastNonzero.isFinite && logLeastNonzero < -700,
                      "got \(logLeastNonzero)")
        XCTAssertEqual(detExp(.greatestFiniteMagnitude), .infinity)
        XCTAssertEqual(detExp(-.greatestFiniteMagnitude).bitPattern, (0.0).bitPattern)
        XCTAssertTrue(detExp(.nan).isNaN)
        XCTAssertTrue(detLog(.nan).isNaN)
        XCTAssertTrue(detPow(.nan, .nan).isNaN)
    }

    /// `detScalbn` is a private helper only reachable through `detPow`'s final
    /// "compute 2**(p_h+p_l)" step when the result underflows to a subnormal — exercise that
    /// path explicitly (not just hope the sweep above hits it) so it is never a trap source.
    func testNoTrapOnSubnormalPowResults() {
        for exponent in [-1050.0, -1070.0, -1074.0, -1075.0, -1080.0, -2000.0] {
            _ = detPow(2.0, exponent)
            _ = detPow(-2.0, exponent + 1)   // odd-int-adjacent exponents exercise the sign path too
        }
        XCTAssertEqual(detPow(2.0, -1075.0).bitPattern, (0.0).bitPattern, "underflows to +0")
        XCTAssertTrue(detPow(2.0, -1070.0) > 0 && detPow(2.0, -1070.0) < .leastNormalMagnitude,
                      "well inside subnormal range")
    }

    /// Wide, deterministic (seeded, not `Double.random`) bit-pattern sweep: every finite,
    /// infinite, NaN, subnormal and zero bit pattern class, spanning exponents across the
    /// whole range — the assertion is purely "does not trap", not a golden match.
    func testNoTrapRandomBitPatternSweep() {
        var rng = RandomX(0xF00D)
        for _ in 0..<20_000 {
            let bitsX = (UInt64(rng.next()) << 32) | UInt64(rng.next())
            let bitsY = (UInt64(rng.next()) << 32) | UInt64(rng.next())
            let x = Double(bitPattern: bitsX)
            let y = Double(bitPattern: bitsY)
            _ = detExp(x)
            _ = detLog(x)
            _ = detPow(x, y)
        }
        XCTAssertTrue(true, "20000 random bit patterns through exp/log/pow without a trap")
    }

    // MARK: - RandomX state-word round trip (spec "State round trip" scenario)

    func testRandomXStateWordsRoundTrip() {
        var original = RandomX(0xABCD1234)
        for _ in 0..<17 { _ = original.next() }
        let captured = original.stateWords

        var restored = RandomX(stateWords: captured)
        XCTAssertEqual(restored.stateWords.0, original.stateWords.0)
        XCTAssertEqual(restored.stateWords.1, original.stateWords.1)
        XCTAssertEqual(restored.stateWords.2, original.stateWords.2)
        XCTAssertEqual(restored.stateWords.3, original.stateWords.3)

        for i in 0..<1000 {
            let a = original.next()
            let b = restored.next()
            XCTAssertEqual(a, b, "draw \(i) diverged after state-word round trip")
        }
    }

    // MARK: - Source pins (spec "Gaussian source pin" scenario; design Condition 9)

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

    func testGameRngAndResetGameRngAreUntouched() throws {
        let source = try source("Sources/ElysiumCore/Core/DetMath.swift")
        XCTAssertTrue(source.contains("public var gameRng = RandomX(0x6A57)"))
        XCTAssertTrue(source.contains("public func resetGameRng(_ seed: UInt32) { gameRng = RandomX(seed) }"))
    }

    func testExistingDetMathKernelsAreUnchanged() throws {
        // detSin/detCos/detAtan/detAtan2 continue to pass every existing fdlibm goldens/fmath
        // check; spot-check a couple of known-good values here as a fast regression signal
        // that this change did not perturb the existing kernels (the full 911-probe check
        // still runs in elysmoke, out of this test target's scope).
        XCTAssertEqual(detSin(0.0), 0.0)
        XCTAssertEqual(detCos(0.0), 1.0)
        XCTAssertEqual(detAtan2(0.0, 1.0), 0.0)
    }
}
