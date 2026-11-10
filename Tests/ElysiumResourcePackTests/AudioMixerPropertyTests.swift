// AudioMixerPropertyTests.swift — seeded property, fuzz and non-functional coverage for the voice
// mixer, as an extension of `AudioMixerTests` so the same test filter selects it: quickselect
// against sorting, the scheduler's admission/cap/steal/compaction invariants under random
// traffic, steal ranks for extreme voices, the limiter under adversarial input, engine-level
// disc generations, slider steps, block-size invariance and render-thread allocation.
// Every generator is seeded; a failure message names its seed so it replays.

import AVFoundation
import Darwin
import ElysiumCore
import XCTest
@testable import Elysium

extension AudioMixerTests {

    // MARK: - selectNth

    /// Quickselect returns exactly `sorted()[k]` and only permutes its input, for random sizes,
    /// heavy duplicates, all-equal, sorted, reversed and special-value inputs, with k at both
    /// ends and in between.
    func testSelectNthMatchesSortingForSeededInputs() {
        let specials: [Double] = [-.infinity, .infinity, 0, -0.0, .leastNonzeroMagnitude,
                                  -.leastNonzeroMagnitude, -1e308, 1e308, 1, -1]
        for seed in UInt64(1)...600 {
            var rng = MixerRNG(seed: seed)
            let count = rng.int(1...300)
            let shape = rng.int(0...5)
            let values: [Double] = (0..<count).map { i in
                switch shape {
                case 0: return rng.uniform(-1e6...1e6)
                case 1: return Double(rng.int(-3...3))
                case 2: return 7
                case 3: return Double(i)
                case 4: return Double(count - i)
                default: return specials[rng.int(0...(specials.count - 1))]
                }
            }
            let sorted = values.sorted()
            for k in [0, count - 1, rng.int(0...(count - 1))] {
                var work = values
                let picked = work.withUnsafeMutableBufferPointer { selectNth($0, k) }
                XCTAssertEqual(picked, sorted[k], "seed \(seed) shape \(shape) count \(count) k \(k)")
                XCTAssertEqual(work.sorted(), sorted, "seed \(seed): selectNth must only permute")
            }
        }
    }

    /// Sizes 1 and 2 in every order, and an out-of-range k clamps to the ends rather than
    /// reading outside the buffer.
    func testSelectNthSmallSizesAndOutOfRangeK() {
        func select(_ values: [Double], _ k: Int) -> Double {
            var work = values
            return work.withUnsafeMutableBufferPointer { selectNth($0, k) }
        }
        XCTAssertEqual(select([3], 0), 3)
        XCTAssertEqual(select([3], -4), 3)
        XCTAssertEqual(select([3], 9), 3)
        for pair in [[1.0, 2.0], [2.0, 1.0]] {
            XCTAssertEqual(select(pair, 0), 1, "\(pair)")
            XCTAssertEqual(select(pair, 1), 2, "\(pair)")
            XCTAssertEqual(select(pair, -1), 1, "\(pair): k below range clamps to the minimum")
            XCTAssertEqual(select(pair, 5), 2, "\(pair): k above range clamps to the maximum")
        }
        XCTAssertEqual(select([2, 2], 1), 2)
        XCTAssertEqual(select([5, 5, 5, 5, 5], 2), 5)
        XCTAssertEqual(select([.infinity, -.infinity], 0), -.infinity)
    }

    /// NaN is outside the documented contract, but it must never trap or spin: the partition
    /// stays in bounds (bounds-checked in debug) and the result is one of the inputs.
    func testSelectNthWithNaNTerminatesInBounds() {
        for seed in UInt64(1)...300 {
            var rng = MixerRNG(seed: seed)
            let count = rng.int(1...200)
            let values: [Double] = (0..<count).map { _ in rng.bool(0.3) ? .nan : Double(rng.int(-5...5)) }
            var work = values
            let k = rng.int(0...(count - 1))
            let picked = work.withUnsafeMutableBufferPointer { selectNth($0, k) }
            XCTAssertTrue(picked.isNaN || values.contains(picked), "seed \(seed)")
            XCTAssertEqual(work.filter(\.isNaN).count, values.filter(\.isNaN).count, "seed \(seed)")
        }
    }

    // MARK: - VoiceScheduler properties

    private struct VoiceFacts {
        let id: Double
        let start: Double
        let dur: Double
        let done: Bool
        let protected: Bool
        let rank: Double
    }

    /// Random traffic — bursts past both bounds, past and future starts, muted and protected
    /// voices, slider changes — checked block by block against the scheduler's contract:
    /// (a) no pending voice is retired while pending ≤ maxPending, and past it only the
    ///     latest-starting go; (b) exactly min(sounding, 512) voices sound afterwards and no
    ///     sounding voice is dropped for the pending bound; (c) a music/disc voice is stolen only
    ///     once no unprotected sounding voice survives, and every stolen voice ranks at or below
    ///     every survivor; (d) compact keeps the survivors in order and keeps capacity.
    func testSchedulerInvariantsHoldUnderSeededTraffic() {
        var exercisedPendingBound = false, exercisedSteal = false, exercisedProtectedSteal = false
        for seed in UInt64(1)...40 {
            var rng = MixerRNG(seed: seed)
            var scheduler = VoiceScheduler()
            var gains = SIMD16<Double>(repeating: 1)
            var nextID = 0.0
            var t = 0.0
            for block in 0..<40 {
                let blockEnd = t + [0.001, 0.01, 0.1][rng.int(0...2)]
                if rng.bool(0.15) { gains[rng.int(0...8)] = [0, 0.5, 1, 2][rng.int(0...3)] }
                let burst = rng.int(0...3) == 0 ? rng.int(300...2_500) : rng.int(0...40)
                let protectedHeavy = rng.bool(0.2)
                for _ in 0..<burst {
                    var v = Voice()
                    v.freq = nextID          // the scheduler never reads freq: use it as an identity
                    nextID += 1
                    v.start = rng.bool(0.6) ? t + rng.uniform(0...30) : t - rng.uniform(0...2)
                    v.dur = rng.uniform(0...5)
                    v.vol = rng.bool(0.1) ? 0 : rng.uniform(0...1)
                    v.gain = rng.uniform(0...1.5)
                    v.category = protectedHeavy && rng.bool(0.9)
                        ? .music : AudioCategory(rawValue: rng.int(0...8))!
                    v.isDisc = v.category == .records && rng.bool(0.5)
                    scheduler.incoming.append(v)
                }
                scheduler.admitIncoming()
                XCTAssertTrue(scheduler.incoming.isEmpty)
                let g = gains, start = t
                let before = scheduler.voices.map {
                    VoiceFacts(id: $0.freq, start: $0.start, dur: $0.dur, done: $0.done,
                               protected: $0.isDisc || $0.category == .music,
                               rank: VoiceScheduler.stealRank($0, at: start, g))
                }
                scheduler.enforceLimits(blockStart: t, blockEnd: blockEnd, gains: gains)
                let doneAfter = scheduler.voices.map(\.done)
                let label = "seed \(seed) block \(block)"
                XCTAssertEqual(doneAfter.count, before.count, label)
                XCTAssertEqual(scheduler.voices.map(\.freq), before.map(\.id), "\(label): enforce never reorders")

                let live = before.indices.filter { !before[$0].done && !(t >= before[$0].start + before[$0].dur + 0.05) }
                let pendingBefore = live.filter { before[$0].start >= blockEnd }
                let soundingBefore = live.filter { before[$0].start < blockEnd }

                // (a)
                let droppedPending = pendingBefore.filter { doneAfter[$0] }
                if pendingBefore.count <= VoiceScheduler.maxPending {
                    XCTAssertTrue(droppedPending.isEmpty, "\(label): \(droppedPending.count) pending voices retired")
                } else {
                    exercisedPendingBound = true
                    XCTAssertEqual(droppedPending.count, pendingBefore.count - VoiceScheduler.maxPending, label)
                    let latestKept = pendingBefore.filter { !doneAfter[$0] }.map { before[$0].start }.max() ?? -.infinity
                    let earliestDropped = droppedPending.map { before[$0].start }.min() ?? .infinity
                    XCTAssertLessThanOrEqual(latestKept, earliestDropped, "\(label): only the latest-starting go")
                }
                XCTAssertEqual(scheduler.pending, min(pendingBefore.count, VoiceScheduler.maxPending), label)

                // (b)
                let survivors = soundingBefore.filter { !doneAfter[$0] }
                let stolen = soundingBefore.filter { doneAfter[$0] }
                XCTAssertEqual(survivors.count, min(soundingBefore.count, VoiceScheduler.maxSounding), label)
                XCTAssertEqual(scheduler.sounding, survivors.count, label)
                XCTAssertEqual(stolen.count, max(0, soundingBefore.count - VoiceScheduler.maxSounding),
                               "\(label): no sounding voice is dropped beyond the cap")

                // (c)
                if !stolen.isEmpty { exercisedSteal = true }
                if stolen.contains(where: { before[$0].protected }) {
                    exercisedProtectedSteal = true
                    XCTAssertTrue(survivors.allSatisfy { before[$0].protected },
                                  "\(label): music/disc stolen while an effect still sounds")
                }
                if let maxStolen = stolen.map({ before[$0].rank }).max(),
                   let minKept = survivors.map({ before[$0].rank }).min() {
                    XCTAssertLessThanOrEqual(maxStolen, minKept, "\(label): steal order follows rank")
                }

                // (d)
                let expectedOrder = before.indices.filter { !doneAfter[$0] }.map { before[$0].id }
                let capacity = scheduler.voices.capacity
                scheduler.compact()
                XCTAssertEqual(scheduler.voices.map(\.freq), expectedOrder, "\(label): compact keeps order")
                XCTAssertEqual(scheduler.voices.capacity, capacity, "\(label): compact keeps capacity")
                t = blockEnd
            }
        }
        XCTAssertTrue(exercisedPendingBound, "the generator must push past maxPending")
        XCTAssertTrue(exercisedSteal, "the generator must push past maxSounding")
        XCTAssertTrue(exercisedProtectedSteal, "the generator must reach the all-protected steal")
    }

    /// Steal ranks stay finite for every combination of extreme timing, volume and gain the
    /// type can hold (with sliders in the range `applyVolumes` produces): unprotected ranks lie
    /// in [0, 1e9] and protected ranks in [1e12, 1e12 + 1e9], so music and discs always outrank
    /// every effect. A non-finite product ranks 0 — an infinitely loud or never-ending voice is
    /// stolen first, never NaN.
    func testStealRankIsFiniteAndOrderedForExtremeVoices() {
        let extremes: [Double] = [0, -0.0, -1, 1, 1e-300, 1e300, .greatestFiniteMagnitude,
                                  -.greatestFiniteMagnitude, .infinity, -.infinity, .nan]
        let sliders: [Double] = [0, 0.5, 1, 1e300]
        var checked = 0
        for start in extremes {
            for dur in extremes {
                for vol in extremes {
                    for gain in [0, 1, 1e300, .infinity, .nan, -2] as [Double] {
                        for slider in sliders {
                            var gains = SIMD16<Double>(repeating: 1)
                            for c in AudioCategory.allCases { gains[c.rawValue] = slider }
                            for category in [AudioCategory.blocks, .music, .records] {
                                var v = Voice()
                                v.start = start
                                v.dur = dur
                                v.vol = vol
                                v.gain = gain
                                v.category = category
                                v.isDisc = category == .records
                                let rank = VoiceScheduler.stealRank(v, at: 0, gains)
                                let what = "start \(start) dur \(dur) vol \(vol) gain \(gain) slider \(slider) \(category)"
                                XCTAssertTrue(rank.isFinite, what)
                                if category == .blocks {
                                    XCTAssertTrue((0...1e9).contains(rank), "\(what): \(rank)")
                                } else {
                                    XCTAssertTrue((1e12...(1e12 + 1e9)).contains(rank), "\(what): \(rank)")
                                }
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 11 * 11 * 11 * 6 * 4 * 3)

        var loud = Voice()
        loud.vol = .infinity
        XCTAssertEqual(VoiceScheduler.stealRank(loud, at: 0, Self.unityGains), 0, "non-finite ranks are stolen first")
        var endless = Voice()
        endless.dur = .infinity
        XCTAssertEqual(VoiceScheduler.stealRank(endless, at: 0, Self.unityGains), 0)
    }

    /// Voices with non-finite timing (never produced by the engine's recipes, but representable)
    /// cannot break the scheduler's guarantees: the sounding cap holds, nothing hangs, and the
    /// pending bound never retires a sounding voice even when NaN start times reach quickselect.
    func testSchedulerKeepsItsGuaranteesWithNonFiniteVoiceTiming() {
        var scheduler = VoiceScheduler()
        let weirdDurations: [Double] = [.infinity, .nan, -.infinity, .greatestFiniteMagnitude]
        scheduler.incoming = (0..<700).map { i in voice(start: 0, dur: weirdDurations[i % 4], vol: 0.3) }
            + (0..<(VoiceScheduler.maxPending + 50)).map { i in voice(start: i % 40 == 0 ? .nan : 1 + Double(i) * 1e-3) }
        scheduler.admitIncoming()
        scheduler.enforceLimits(blockStart: 0, blockEnd: 0.1, gains: Self.unityGains)
        let sounding = scheduler.voices.filter { !$0.done && $0.start < 0.1 }
        XCTAssertLessThanOrEqual(sounding.count, VoiceScheduler.maxSounding)
        XCTAssertEqual(scheduler.sounding, VoiceScheduler.maxSounding)
        // -inf durations are already over; the other 525 compete for 512 slots
        XCTAssertEqual(sounding.count, VoiceScheduler.maxSounding)
        scheduler.compact()
        XCTAssertLessThanOrEqual(scheduler.voices.filter { $0.start < 0.1 }.count, VoiceScheduler.maxSounding)
    }

    /// `cutDiscs` marks exactly the disc voices of the given generation or older that start after
    /// the cut time, leaving every other voice — ringing disc notes, newer discs, effects — as is.
    func testCutDiscsMarksExactlyOlderUnstartedDiscVoices() {
        for seed in UInt64(1)...100 {
            var rng = MixerRNG(seed: seed)
            var scheduler = VoiceScheduler()
            scheduler.incoming = (0..<rng.int(0...300)).map { _ in
                var v = voice(start: rng.uniform(0...10), disc: rng.bool(0.6), generation: rng.int(0...6))
                v.done = rng.bool(0.1)
                return v
            }
            scheduler.admitIncoming()
            let before = scheduler.voices
            let time = rng.uniform(0...10), generation = rng.int(-1...7)
            scheduler.cutDiscs(after: time, through: generation)
            for (old, new) in zip(before, scheduler.voices) {
                let expected = old.done || (old.isDisc && old.discGeneration <= generation && old.start > time)
                XCTAssertEqual(new.done, expected, "seed \(seed): start \(old.start) gen \(old.discGeneration)")
            }
        }
    }

    // MARK: - limiter

    /// Whatever arrives — random loud material, ±inf, NaN, ±greatestFinite, denormals, ±0,
    /// alternating full scale — every output sample is finite and within ±1 and the gain stays
    /// in (0, 1], across random block sizes.
    func testLimiterOutputStaysWithinFullScaleForAdversarialInput() {
        let specials: [Float] = [.nan, .signalingNaN, .infinity, -.infinity, .greatestFiniteMagnitude,
                                 -.greatestFiniteMagnitude, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
                                 0, -0.0, 1, -1, 0.9, -0.9, OutputLimiter.threshold.nextUp, 1e30]
        for seed in UInt64(1)...60 {
            var rng = MixerRNG(seed: seed)
            var limiter = OutputLimiter(sampleRate: [44_100, 48_000, 96_000][rng.int(0...2)])
            for block in 0..<20 {
                let n = rng.int(1...4_096)
                let style = rng.int(0...3)
                let amplitude = Float([0.5, 1, 10, 1e30][rng.int(0...3)])
                func sample(_ i: Int) -> Float {
                    switch style {
                    case 0: return Float(rng.uniform(-1...1)) * amplitude
                    case 1: return specials[rng.int(0...(specials.count - 1))]
                    case 2: return i % 2 == 0 ? 1 : -1
                    default: return rng.bool(0.01) ? specials[rng.int(0...(specials.count - 1))] : Float(rng.uniform(-1...1))
                    }
                }
                var left = (0..<n).map(sample), right = (0..<n).map(sample)
                limiter.process(&left, &right, n)
                for i in 0..<n {
                    XCTAssertTrue(left[i].isFinite && abs(left[i]) <= 1, "seed \(seed) block \(block) L[\(i)] = \(left[i])")
                    XCTAssertTrue(right[i].isFinite && abs(right[i]) <= 1, "seed \(seed) block \(block) R[\(i)] = \(right[i])")
                    if !(left[i].isFinite && abs(left[i]) <= 1 && right[i].isFinite && abs(right[i]) <= 1) { return }
                }
                XCTAssertTrue(limiter.gain > 0 && limiter.gain <= 1, "seed \(seed) block \(block): gain \(limiter.gain)")
            }
        }
    }

    /// Below the threshold the limiter is the identity bit for bit — including -0, denormals and
    /// exactly ±threshold — across hundreds of random-sized blocks, and again after it has
    /// limited an overload and fully released.
    func testLimiterIsBitTransparentAcrossManyBlocksAndAfterRecovery() {
        let edge: [Float] = [-0.0, 0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
                             .leastNormalMagnitude, OutputLimiter.threshold, -OutputLimiter.threshold]
        var rng = MixerRNG(seed: 42)
        var limiter = OutputLimiter(sampleRate: 48_000)
        func quietBlocks(_ count: Int, _ phase: String) {
            for block in 0..<count {
                let n = rng.int(1...2_048)
                var left: [Float] = (0..<n).map { _ in rng.bool(0.05) ? edge[rng.int(0...(edge.count - 1))]
                    : Float(rng.uniform(-1...1)) * OutputLimiter.threshold }
                var right: [Float] = (0..<n).map { _ in Float(rng.uniform(-1...1)) * OutputLimiter.threshold }
                let (l0, r0) = (left.map(\.bitPattern), right.map(\.bitPattern))
                limiter.process(&left, &right, n)
                XCTAssertEqual(left.map(\.bitPattern), l0, "\(phase) block \(block)")
                XCTAssertEqual(right.map(\.bitPattern), r0, "\(phase) block \(block)")
                if left.map(\.bitPattern) != l0 { return }
            }
        }
        quietBlocks(300, "fresh")
        XCTAssertEqual(limiter.gain, 1)

        var loudL = [Float](repeating: 5, count: 4_800), loudR = loudL
        limiter.process(&loudL, &loudR, 4_800)
        XCTAssertLessThan(limiter.gain, 0.2)
        var silenceL = [Float](repeating: 0, count: 48_000 * 3), silenceR = silenceL
        limiter.process(&silenceL, &silenceR, silenceL.count)
        XCTAssertEqual(limiter.gain, 1, "3 s of silence fully releases")
        quietBlocks(300, "after recovery")
    }

    /// After an overload the gain recovers monotonically, sample by sample, to exactly 1 in
    /// ~2 s (the 150 ms release snapping at 1 - 1e-6). A device-rate change mid-recovery keeps
    /// the current gain (no jump) and keeps the release time in seconds: twice the samples at
    /// 96 kHz.
    func testLimiterRecoversMonotonicallyToExactlyOneAndKeepsReleaseTimeAcrossRates() {
        func samplesToRecover(rate: Double, switchTo second: Double? = nil) -> Int {
            var limiter = OutputLimiter(sampleRate: rate)
            var loudL = [Float](repeating: 20, count: Int(rate / 10)), loudR = loudL
            limiter.process(&loudL, &loudR, loudL.count)
            XCTAssertLessThan(limiter.gain, 0.05)
            if let second {
                let held = limiter.gain
                limiter.configure(second)
                XCTAssertEqual(limiter.gain, held, "reconfigure keeps the current gain")
                XCTAssertEqual(limiter.sampleRate, second)
            }
            var previous = limiter.gain
            var l: Float = 0.3, r: Float = -0.3
            for n in 1...(Int(limiter.sampleRate) * 4) {
                l = 0.3; r = -0.3
                limiter.process(&l, &r, 1)
                XCTAssertGreaterThanOrEqual(limiter.gain, previous, "sample \(n): release must not dip")
                if limiter.gain < previous { return -1 }
                previous = limiter.gain
                if limiter.gain == 1 {
                    XCTAssertEqual(l, 0.3, "transparent from the sample the gain reaches 1")
                    return n
                }
            }
            XCTFail("never recovered at \(rate) Hz")
            return -1
        }
        let at48 = samplesToRecover(rate: 48_000)
        XCTAssertEqual(Double(at48) / 48_000, 2.07, accuracy: 0.05, "≈ 13.8 release time constants")
        let at96 = samplesToRecover(rate: 48_000, switchTo: 96_000)
        XCTAssertEqual(Double(at96) / Double(at48), 2, accuracy: 0.02, "same release in seconds at 96 kHz")
    }

    /// A sustained loud tone settles to a steady gain instead of pumping: after 50 ms, the mean
    /// gain of successive 50 ms windows varies by under 0.01 %, the within-cycle ripple stays
    /// under 1 % of the gain, and every cycle's output peak sits just under full scale.
    func testLimiterDoesNotPumpOnASustainedLoudPassage() {
        let rate = 48_000.0
        var limiter = OutputLimiter(sampleRate: rate)
        let frames = Int(rate * 3)
        var gains = [Double](), outputs = [Float]()
        gains.reserveCapacity(frames)
        outputs.reserveCapacity(frames)
        for i in 0..<frames {
            var l = Float(2 * Foundation.sin(2 * Double.pi * 440 * Double(i) / rate)), r = l
            limiter.process(&l, &r, 1)
            gains.append(limiter.gain)
            outputs.append(l)
        }
        let window = Int(rate * 0.05)
        let means = stride(from: window, to: frames - window + 1, by: window).map { start in
            gains[start..<(start + window)].reduce(0, +) / Double(window)
        }
        let settled = Array(gains[window...])
        let ripple = (settled.max()! - settled.min()!) / settled.max()!
        let drift = (means.max()! - means.min()!) / means.max()!
        print("[limiter] sustained 2.0 sine: gain \(means.last!), window drift \(drift * 100) %, ripple \(ripple * 100) %")
        // measured 2026-11: drift 0.0005 %, ripple 0.41 % (≈ 0.04 dB)
        XCTAssertLessThan(drift, 0.0001, "no slow gain modulation on a steady passage")
        XCTAssertLessThan(ripple, 0.01)
        let cycle = Int(rate / 440) + 1
        for start in stride(from: window, to: frames - cycle, by: cycle) {
            let peak = outputs[start..<(start + cycle)].map(abs).max()!
            XCTAssertTrue((0.85...1.0).contains(peak), "cycle at \(start): peak \(peak)")
            if !(0.85...1.0).contains(peak) { break }
        }
    }

    // MARK: - categories

    /// Core's default `Settings.volumes` and the mixer's `AudioCategory` name the same sliders.
    /// A key Core adds without a category silently maps to `.unscaled` and would never respond
    /// to its slider; a category Core does not persist would always read the default.
    func testCoreVolumeSettingsMatchTheMixerSliders() {
        XCTAssertEqual(Set(Settings().volumes.keys).subtracting(["master"]),
                       Set(AudioCategory.sliders.map(\.settingsKey)))
    }

    // MARK: - engine: discs

    /// Ejecting one disc and inserting another before the next render block (the host route:
    /// `jukebox.stop` then `jukebox.play.*`) cuts only the old disc. The old jukebox is due west
    /// (left channel only) and the new one due east (right only): the left channel falls
    /// silent once the old notes have rung out, and the new disc plays from its first second
    /// to its end.
    func testDiscStartedInTheSameBlockAsAStopSurvives() throws {
        for explicitStop in [true, false] {
            let audio = makeEngine()
            audio.playGameSound("jukebox.play.music_disc_wander", -8, 0, 0, 4, 1)
            let first = try render(audio, seconds: 3)
            XCTAssertGreaterThan(first.leftPeak, 0.01)
            XCTAssertEqual(first.rightPeak, 0)
            if explicitStop { audio.playGameSound("jukebox.stop", -8, 0, 0, 1, 1) }
            audio.playGameSound("jukebox.play.music_disc_aurora", 8, 0, 0, 4, 1)
            let after = try render(audio, seconds: 60)
            let label = explicitStop ? "eject then insert" : "insert over a playing disc"
            XCTAssertEqual(after.left[Int(2.5 * Self.rate)...].map(abs).max() ?? 0, 0,
                           "\(label): the old disc's later notes are cut")
            let right = Capture(left: after.right, right: after.right)
            for (i, rms) in right.rmsBuckets(seconds: 5).enumerated() {
                XCTAssertGreaterThan(rms, 0.005, "\(label): new disc \(i * 5)-\(i * 5 + 5) s")
            }
        }
    }

    /// `stopDisc` with no disc playing — before any disc, repeatedly, mid-sound — changes
    /// nothing audible, and the next disc still plays from its first second.
    func testStopDiscWithoutADiscIsHarmless() throws {
        func capture(stops: Bool) throws -> Capture {
            let audio = makeEngine()
            if stops { for _ in 0..<3 { audio.stopDisc() } }
            audio.play("entity.prehistoric.triceratops.browse", 0, 0, 0)
            var out = try render(audio, seconds: 0.3)
            if stops { audio.stopDisc(); audio.worldAudioDidEnd() }
            out.append(try render(audio, seconds: 1.2))
            return out
        }
        let reference = try capture(stops: false), subject = try capture(stops: true)
        XCTAssertGreaterThan(reference.peak, 0.01)
        XCTAssertEqual(subject.left, reference.left)
        XCTAssertEqual(subject.right, reference.right)

        let audio = makeEngine()
        for _ in 0..<5 { audio.stopDisc() }
        audio.playDisc("jukebox.play.music_disc_descent", 0, 0, 1)
        let disc = try render(audio, seconds: 10)
        XCTAssertGreaterThan(disc.rms(from: 0, to: 1), 0.005, "a disc after idle stops still starts")
        XCTAssertTrue(disc.rmsBuckets(seconds: 1).allSatisfy { $0 > 0.001 })
    }

    /// Leaving the world twice in a row (and on an engine that never initialised) is harmless;
    /// a disc started afterwards plays normally.
    func testWorldAudioDidEndTwiceAndBeforeInitIsHarmless() throws {
        let cold = AudioEngineM()
        cold.worldAudioDidEnd()
        cold.stopDisc()
        cold.tickMusic("overworld", true)
        cold.playDisc("jukebox.play.music_disc_aurora", 0, 0, 1)
        cold.playGameSound("jukebox.stop", 0, 0, 1, 1, 1)
        cold.play("entity.generic.explode", 0, 0, 1)
        cold.playUI("ui.toast.in")
        XCTAssertEqual(cold.pendingInboxCount, 0, "nothing is queued before initEngine")
        XCTAssertEqual(try render(cold, seconds: 0.5).peak, 0)
        cold.initEngine(startDevice: false)
        cold.setListener(0, 0, 0, 0)
        cold.playDisc("jukebox.play.music_disc_aurora", 0, 0, 1)
        XCTAssertGreaterThan(try render(cold, seconds: 2).rms(from: 0, to: 2), 0.005)

        let audio = makeEngine()
        audio.setEnvironment(true, 1)
        audio.playDisc("jukebox.play.music_disc_wander", 0, 0, 1)
        _ = try render(audio, seconds: 1)
        audio.worldAudioDidEnd()
        audio.worldAudioDidEnd()
        _ = try render(audio, seconds: 2.5)
        XCTAssertEqual(try render(audio, seconds: 5).peak, 0, "the disc stays stopped")
        audio.playDisc("jukebox.play.music_disc_wander", 0, 0, 1)
        let next = try render(audio, seconds: 5)
        XCTAssertGreaterThan(next.rms(from: 0, to: 1), 0.005, "a new disc after two world exits plays")
    }

    // MARK: - engine: sounding cap and music

    /// 700 loud, long creature calls land while generative music plays. That is past the
    /// 512-voice cap and every call outranks a music pad on "seconds left x level", so only the
    /// music protection keeps the pads. The calls are due west (left only) and the master is low
    /// enough that the limiter stays transparent, so the right channel is the music alone, and
    /// its first 3.8 s (pads and bass only, before the random melody) must be sample-identical
    /// to an undisturbed render.
    func testMoreThan512EffectsDuringMusicLeaveTheMusicUntouched() throws {
        let call = "entity.prehistoric.tyrannosaurus.ambient"
        func capture(flood: Bool) throws -> Capture {
            let audio = makeEngine(volumes: ["master": 0.001])
            audio.musicTimer = 1
            audio.tickMusic("overworld", true)
            var out = try render(audio, seconds: 0.5)
            if flood { for _ in 0..<700 { audio.play(call, -10, 0, 0, 1.5, 0.5) } }
            out.append(try render(audio, seconds: 3.3))
            return out
        }
        let clean = try capture(flood: false), busy = try capture(flood: true)
        XCTAssertGreaterThan(clean.rightPeak, 0, "the music is audible")
        XCTAssertGreaterThan(busy.leftPeak, clean.leftPeak * 2, "the flood is audible on the left")
        XCTAssertLessThan(busy.leftPeak, OutputLimiter.threshold, "premise: the limiter stays transparent")
        XCTAssertEqual(busy.right, clean.right, "no music voice was stolen")

        // premise: without protection the pads would have been the first to go
        var pad = voice(start: 0, dur: 10, vol: 0.05, category: .blocks)
        pad.gain = 0.32
        var effect = voice(start: 0.5, dur: 2, vol: 1, category: .hostile)
        effect.gain = 1.5 * 0.75 * 0.75 * 0.5     // 10 of 40 blocks, rough lower bound
        XCTAssertLessThan(VoiceScheduler.stealRank(pad, at: 0.5, Self.unityGains),
                          VoiceScheduler.stealRank(effect, at: 0.5, Self.unityGains))
    }

    // MARK: - engine: live sliders

    /// A slider move lands as one step at the next block boundary: every frame before it is
    /// bit-identical to an untouched render, every frame after it is exactly the scaled render
    /// (no ramp across blocks, no late apply), for a category slider and for master.
    func testSliderChangeLandsAsOneStepAtTheNextBlockBoundary() throws {
        let name = "entity.prehistoric.triceratops.browse"
        let category = try XCTUnwrap(prehistoricSynthesizedSoundRecipes().first { $0.name == name }).category
        for key in [category, "master"] {
            func capture(change: Bool) throws -> Capture {
                let audio = makeEngine()
                audio.play(name, 0, 0, 0)
                var out = try render(audio, seconds: 0.3)
                if change { audio.applyVolumes([key: 0.5]) }
                out.append(try render(audio, seconds: 0.7))
                return out
            }
            let reference = try capture(change: false), subject = try capture(change: true)
            XCTAssertGreaterThan(reference.peak(from: 0.3, to: 1), 0.01, "\(key): still sounding")
            XCTAssertLessThan(reference.peak, OutputLimiter.threshold, "premise: limiter transparent")
            let boundary = Int(0.3 * Self.rate)
            XCTAssertEqual(Array(subject.left[..<boundary]), Array(reference.left[..<boundary]), key)
            XCTAssertEqual(Array(subject.left[boundary...]), reference.left[boundary...].map { $0 * 0.5 }, key)
            XCTAssertEqual(Array(subject.right[boundary...]), reference.right[boundary...].map { $0 * 0.5 }, key)
        }
    }

    // MARK: - engine: device rate

    /// Only rates in [8 kHz, 768 kHz] are adopted; everything else, however close, is ignored.
    /// Rendering at both accepted extremes and switching rates mid-disc stays finite and within
    /// full scale.
    func testReconfigureAcceptsOnlyPlausibleRatesAndRendersAtTheExtremes() throws {
        let audio = makeEngine()
        for bad in [7_999.999, 768_000.001, -.infinity, -0.0, .leastNonzeroMagnitude, -48_000,
                    .greatestFiniteMagnitude, .signalingNaN] {
            audio.reconfigure(sampleRate: bad)
            XCTAssertEqual(audio.renderSampleRate, 48_000, "\(bad) must be ignored")
        }
        audio.setEnvironment(true, 1)                   // underwater lowpass + cave reverb too
        audio.playDisc("jukebox.play.music_disc_wander", 0, 0, 1)
        audio.play("entity.generic.explode", 0, 0, 1)
        for rate in [8_000.0, 768_000, 44_100, 96_000, 48_000] {
            audio.reconfigure(sampleRate: rate)
            XCTAssertEqual(audio.renderSampleRate, rate)
            let out = try render(audio, seconds: 0.5)
            XCTAssertTrue(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite), "\(rate)")
            XCTAssertLessThanOrEqual(out.peak, 1, "\(rate)")
            XCTAssertGreaterThan(out.peak, 0, "\(rate): still audible")
        }
    }

    // MARK: - engine: block-size invariance

    /// The device chooses the callback size. Rendering the same deterministic mix (a recording,
    /// a panned creature call, a synthesized sweep, and a call started mid-stream) in blocks of
    /// 1, 7 or 4,096 frames gives the same audio as large blocks. Block size only changes how
    /// engine time is summed (n x dt per block versus dt per sample), so at most a handful of
    /// samples on an envelope edge may land one sample apart: the synth tone ends at
    /// 0.001 x its volume, a step of at most ~1.6e-4. Every other sample matches to 1e-6.
    func testOddBlockSizesRenderTheSameAudioAsLargeBlocks() throws {
        let half = 28_672                                // a multiple of 1, 7 and 4,096
        func capture(block: Int) throws -> (left: [Float], right: [Float]) {
            let audio = makeEngine()
            audio.play("entity.prehistoric.triceratops.browse", 0, 0, 0)
            audio.play("entity.prehistoric.parasaurolophus.browse", 3, 0, 4)
            audio.playUI("ui.toast.in")
            var left: [Float] = [], right: [Float] = []
            left.reserveCapacity(2 * half)
            right.reserveCapacity(2 * half)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)))
            buffer.frameLength = AVAudioFrameCount(block)
            for part in 0..<2 {
                if part == 1 { audio.play("entity.prehistoric.triceratops.hurt", -2, 0, 1) }
                for _ in 0..<(half / block) {
                    audio.render(buffer.frameLength, buffer.mutableAudioBufferList)
                    left.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: block))
                    right.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![1], count: block))
                }
            }
            return (left, right)
        }
        let reference = try capture(block: half)
        XCTAssertGreaterThan(reference.left.map(abs).max() ?? 0, 0.01)
        XCTAssertGreaterThan(reference.left[half...].map(abs).max() ?? 0, 0.01, "the mid-stream call sounds")
        for block in [1, 7, 4_096] {
            let subject = try capture(block: block)
            XCTAssertEqual(subject.left.count, reference.left.count)
            var worst: Float = 0, edgeSamples = 0
            for i in reference.left.indices {
                let diff = max(abs(subject.left[i] - reference.left[i]), abs(subject.right[i] - reference.right[i]))
                worst = max(worst, diff)
                if diff > 1e-6 { edgeSamples += 1 }
            }
            print("[block-size] \(block)-frame blocks vs \(half): max |diff| \(worst), \(edgeSamples) samples > 1e-6")
            XCTAssertLessThanOrEqual(edgeSamples, 4, "\(block)-frame blocks: only envelope-edge samples may differ")
            XCTAssertLessThan(worst, 2e-4, "\(block)-frame blocks")
        }
    }

    // MARK: - engine: inbox

    /// When the inbox overflows (nothing rendering), the oldest voices go and the newest stay:
    /// a UI sound queued after 25 muted discs renders exactly like on a fresh engine.
    func testInboxOverflowKeepsTheNewestVoices() throws {
        let audio = makeEngine(volumes: ["records": 0])
        for _ in 0..<25 { audio.playDisc("jukebox.play.music_disc_wander", 0, 0, 1) }
        XCTAssertEqual(audio.pendingInboxCount, VoiceScheduler.maxInbox, "overflowed and capped")
        audio.playUI("ui.toast.in")
        XCTAssertEqual(audio.pendingInboxCount, VoiceScheduler.maxInbox)
        let subject = try render(audio, seconds: 0.1)
        XCTAssertEqual(audio.pendingInboxCount, 0)

        let fresh = makeEngine()
        fresh.playUI("ui.toast.in")
        let reference = try render(fresh, seconds: 0.1)
        XCTAssertGreaterThan(reference.peak, 0.01)
        XCTAssertEqual(subject.left, reference.left, "the newest voice survived the overflow")
    }

    // MARK: - engine: concurrency

    /// The main-thread API (sliders, environment, rate, discs, effects, listener) hammered while
    /// another thread renders: no crash, every sample finite and within full scale.
    func testMainThreadControlsDuringRenderStayFiniteAndBounded() throws {
        let audio = makeEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let done = DispatchSemaphore(value: 0)
        final class Result: @unchecked Sendable { var ok = true; var blocks = 0 }
        let result = Result()
        let renderer = Thread {
            for _ in 0..<1_000 {
                audio.render(buffer.frameLength, buffer.mutableAudioBufferList)
                for c in 0..<2 {
                    let p = buffer.floatChannelData![c]
                    for i in 0..<256 where !(p[i].isFinite && abs(p[i]) <= 1) { result.ok = false }
                }
                result.blocks += 1
            }
            done.signal()
        }
        renderer.start()
        var rng = MixerRNG(seed: 7)
        var finished = false
        while !finished {
            switch rng.int(0...39) {
            case 0..<8: audio.applyVolumes(["master": rng.uniform(0...2), "records": rng.uniform(0...1), "music": rng.uniform(0...1)])
            case 8..<14: audio.setEnvironment(rng.bool(0.5), rng.uniform(0...1))
            case 14..<20: audio.reconfigure(sampleRate: [44_100, 48_000, 96_000][rng.int(0...2)])
            case 20..<28: audio.play("entity.generic.explode", rng.uniform(-5...5), 0, 1)
            case 28..<36: audio.setListener(rng.uniform(-30...30), 0, rng.uniform(-30...30), rng.uniform(-3...3))
            case 36: audio.playGameSound("jukebox.play.music_disc_wander", 0, 0, 1, 4, 1)   // ~800 voices each
            case 37: audio.playGameSound("jukebox.stop", 0, 0, 1, 1, 1)
            case 38: audio.stopDisc()
            default: audio.worldAudioDidEnd()
            }
            usleep(100)
            finished = done.wait(timeout: .now()) == .success
        }
        XCTAssertEqual(result.blocks, 1_000)
        XCTAssertTrue(result.ok)
    }

    // MARK: - non-functional: render-thread allocation

    /// The render callback must not allocate in steady state. With a disc, generative music,
    /// a steady stream of effects and one 700-call flood past the cap (exercising admission,
    /// stealing and compaction), every `render` call is wrapped in a malloc-logger hook that
    /// counts allocations on this thread only. A positive control proves the hook sees
    /// allocations on this OS; if it cannot be installed the test is skipped, not passed.
    /// Only meaningful optimized: at -Onone every `for i in 0..<n` runs libswiftCore's
    /// unspecialized `IndexingIterator<Range<Int>>.next()`, which mallocs per iteration (an
    /// empty engine shows 3 x 512 per block), so unoptimized builds skip. Run it with
    /// `swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter
    /// AudioMixerTests/testRenderDoesNot` (-DDEBUG: Core's test hooks, and the sample bank's
    /// development path so recordings load).
    func testRenderDoesNotAllocateInSteadyState() throws {
        try XCTSkipIf(_isDebugAssertConfiguration(),
                      "-Onone allocates in unspecialized stdlib iteration; measured in optimized builds only")
        guard let control = countAllocationsOnThisThread({ blackHole(Array(repeating: 1, count: 257)) }) else {
            throw XCTSkip("malloc_logger is unavailable or already owned (MallocStackLogging): not measured")
        }
        guard control > 0 else { throw XCTSkip("malloc_logger saw no allocations on this OS: not measured") }

        let audio = makeEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        audio.playDisc("jukebox.play.music_disc_aurora", 0, 0, 2)
        audio.musicTimer = 1
        audio.tickMusic("overworld", true)
        for _ in 0..<50 { audio.render(buffer.frameLength, buffer.mutableAudioBufferList) }   // warm-up

        var allocations = 0, worstBlock = -1
        for block in 0..<3_000 {
            if block % 10 == 0 { audio.play("entity.prehistoric.triceratops.browse", 2, 0, 1) }
            if block % 25 == 0 { audio.play("block.stone.break", 0, 0, 1) }
            if block == 1_000 { for _ in 0..<700 { audio.play("entity.prehistoric.tyrannosaurus.ambient", 1, 0, 1, 1, 0.5) } }
            let count = countAllocationsOnThisThread {
                audio.render(buffer.frameLength, buffer.mutableAudioBufferList)
            } ?? 0
            if count > 0 && worstBlock < 0 { worstBlock = block }
            allocations += count
        }
        print("[render-alloc] positive control \(control) allocations; 3000 steady-state blocks: \(allocations) allocations (first at block \(worstBlock))")
        XCTAssertEqual(allocations, 0, "render allocated; first at block \(worstBlock)")
    }
}

// MARK: - test support

/// Seeded SplitMix64 so every property failure replays from the seed in its message.
private struct MixerRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
    mutating func bool(_ probability: Double) -> Bool { uniform(0...1) < probability }
}

@inline(never) private func blackHole<T>(_ value: T) { withExtendedLifetime(value) {} }

/// libmalloc's logging hook (`malloc_logger`), called for every allocation once installed.
private typealias MallocLoggerHook = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
private var allocationCountingThread: pthread_t?
private var allocationCount = 0
private let allocationCounter: MallocLoggerHook = { type, _, _, _, _, _ in
    // MALLOC_LOG_TYPE_ALLOCATE = 2 (also set for realloc)
    guard type & 2 != 0, let thread = allocationCountingThread, pthread_equal(pthread_self(), thread) != 0 else { return }
    allocationCount += 1
}

/// Allocations made by `body` on the calling thread, or nil when the hook cannot be installed.
private func countAllocationsOnThisThread(_ body: () -> Void) -> Int? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
    let slot = symbol.assumingMemoryBound(to: Optional<MallocLoggerHook>.self)
    guard slot.pointee == nil else { return nil }
    allocationCount = 0
    allocationCountingThread = pthread_self()
    slot.pointee = allocationCounter
    body()
    slot.pointee = nil
    allocationCountingThread = nil
    return allocationCount
}
