// AudioMixerTests.swift — offline renders of the voice mixer: scheduling and the sounding-voice
// cap, live category volumes, the output limiter, device-rate seams, jukebox routing and the
// end-of-world reset. Everything renders through `AudioEngineM.render` without an audio device,
// at the fixed 48 kHz offline rate.

import AVFoundation
import XCTest
@testable import Elysium

final class AudioMixerTests: XCTestCase {
    static let rate = 48_000.0
    static let blockFrames = 4_800        // 0.1 s per render callback
    private static let discs = ["jukebox.play.music_disc_wander", "jukebox.play.music_disc_descent",
                                "jukebox.play.music_disc_aurora"]

    // MARK: - A1 voice scheduling

    /// Every disc pre-schedules hundreds of notes. None of them may be dropped by the sounding
    /// cap before it starts, so each disc is audible from its first second to its last bucket.
    func testEveryDiscIsAudibleFromItsFirstSecondToItsEnd() throws {
        for disc in Self.discs {
            let audio = makeEngine()
            audio.playDisc(disc, 0, 0, 1)
            let out = try render(audio, seconds: 60)
            XCTAssertGreaterThan(out.rms(from: 0, to: 1), 0.005, "\(disc): first second")
            let buckets = out.rmsBuckets(seconds: 5)
            XCTAssertEqual(buckets.count, 12)
            for (i, rms) in buckets.enumerated() {
                XCTAssertGreaterThan(rms, 0.005, "\(disc): \(i * 5)-\(i * 5 + 5) s")
            }
        }
    }

    /// A sound already playing when a disc starts keeps playing exactly as if no disc had started
    /// (the disc itself is muted with the Jukebox slider so the comparison is sample-exact).
    func testStartingADiscDoesNotCutASoundAlreadyPlaying() throws {
        func capture(startDisc: Bool) throws -> Capture {
            let audio = makeEngine(volumes: ["records": 0])
            audio.play("entity.prehistoric.triceratops.browse", 0, 0, 0)
            var out = try render(audio, seconds: 0.1)
            if startDisc { audio.playDisc("jukebox.play.music_disc_wander", 0, 0, 1) }
            out.append(try render(audio, seconds: 1))
            return out
        }
        let reference = try capture(startDisc: false)
        XCTAssertGreaterThan(reference.peak(from: 0.1, to: 1.1), 0.001, "the clip is still sounding")
        let subject = try capture(startDisc: true)
        XCTAssertEqual(subject.left.count, reference.left.count)
        for i in reference.left.indices {
            XCTAssertEqual(subject.left[i], reference.left[i], accuracy: 1e-6, "frame \(i)")
            if abs(subject.left[i] - reference.left[i]) > 1e-6 { break }
        }
    }

    /// 100 sound effects during a disc must not delete any upcoming disc notes: once the effects
    /// have ended, every 5 s bucket keeps at least half the energy of an undisturbed disc.
    func testSoundEffectsDuringADiscDoNotRemoveLaterDiscNotes() throws {
        func buckets(effects: Bool) throws -> [Double] {
            let audio = makeEngine()
            audio.playDisc("jukebox.play.music_disc_wander", 0, 0, 1)
            var out = Capture()
            for block in 0..<600 {
                if effects && (10..<110).contains(block) { audio.play("block.stone.break", 0, 0, 1) }
                out.append(try render(audio, seconds: 0.1))
            }
            return out.rmsBuckets(seconds: 5)
        }
        let clean = try buckets(effects: false)
        let busy = try buckets(effects: true)
        for i in 3..<12 {       // from 15 s: the effects (1-11 s) are long over
            XCTAssertGreaterThan(clean[i], 0.005, "undisturbed disc bucket \(i)")
            XCTAssertGreaterThan(busy[i], clean[i] * 0.5, "bucket \(i * 5)-\(i * 5 + 5) s lost disc notes")
        }
    }

    // MARK: - A2 live category volumes

    func testMusicSliderSilencesATrackAlreadyScheduled() throws {
        let audio = makeEngine()
        audio.musicTimer = 1
        audio.tickMusic("overworld", true)
        XCTAssertGreaterThan(try render(audio, seconds: 10).rms(from: 0, to: 10), 0.001)
        audio.applyVolumes(["master": 1, "music": 0])
        XCTAssertEqual(try render(audio, seconds: 10).peak, 0, "Music 0 silences the playing track")
        audio.applyVolumes(["master": 1, "music": 1])
        XCTAssertGreaterThan(try render(audio, seconds: 10).peak, 0, "and raising it brings it back")
    }

    func testJukeboxSliderSilencesADiscAlreadyPlaying() throws {
        let audio = makeEngine()
        audio.playDisc("jukebox.play.music_disc_aurora", 0, 0, 1)
        XCTAssertGreaterThan(try render(audio, seconds: 5).rms(from: 0, to: 5), 0.001)
        audio.applyVolumes(["master": 1, "records": 0])
        XCTAssertEqual(try render(audio, seconds: 5).peak, 0, "Jukebox 0 silences the playing disc")
    }

    /// Positional effects follow their slider mid-sound, both an ordinary positional sound and a
    /// creature call whose mix is recomputed every block.
    func testPositionalCategorySlidersApplyToSoundsAlreadyPlaying() throws {
        let creature = "entity.prehistoric.parasaurolophus.browse"
        let creatureCategory = try XCTUnwrap(prehistoricSynthesizedSoundRecipes().first { $0.name == creature }).category
        XCTAssertEqual(creatureCategory, "friendly")
        for (name, category) in [("event.raid.horn", "hostile"), (creature, creatureCategory)] {
            let audio = makeEngine()
            audio.play(name, 0, 0, 2)
            XCTAssertGreaterThan(try render(audio, seconds: 0.2).peak, 0.001, name)
            audio.applyVolumes(["master": 1, category: 0])
            XCTAssertEqual(try render(audio, seconds: 0.3).peak, 0, "\(name): \(category) 0")
            audio.applyVolumes(["master": 1, category: 0.5])
            XCTAssertGreaterThan(try render(audio, seconds: 0.2).peak, 0, "\(name): restored")
        }
    }

    // MARK: - A3 output limiter

    func testTwentyFourExplosionsNeverExceedFullScale() throws {
        let audio = makeEngine()
        for _ in 0..<24 { audio.play("entity.generic.explode", 0, 0, 1) }
        let out = try render(audio, seconds: 2)
        XCTAssertTrue(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(out.peak, 0.5, "the burst is loud")
        XCTAssertLessThanOrEqual(out.peak, 1.0)
    }

    /// Below the limiter threshold the mix is linear in master gain, to within 1e-6.
    func testAQuietSoundPassesThroughUnchanged() throws {
        func capture(master: Double) throws -> Capture {
            let audio = makeEngine(volumes: ["master": master])
            audio.play("entity.prehistoric.triceratops.browse", 0, 0, 0)
            return try render(audio, seconds: 1)
        }
        let full = try capture(master: 1), quarter = try capture(master: 0.25)
        XCTAssertGreaterThan(full.peak, 0.01)
        for i in full.left.indices {
            XCTAssertEqual(quarter.left[i], full.left[i] * 0.25, accuracy: 1e-6, "frame \(i)")
            if abs(quarter.left[i] - full.left[i] * 0.25) > 1e-6 { break }
        }
    }

    // MARK: - A4 device seams

    /// Offline engines never build an AVAudioEngine graph and always render at 48 kHz, whatever
    /// the machine's output device runs at.
    func testOfflineEngineLeavesTheDeviceAloneAndRendersAt48kHz() {
        let audio = makeEngine()
        XCTAssertFalse(audio.isDeviceGraphBuilt)
        XCTAssertEqual(audio.renderSampleRate, 48_000)
    }

    /// The rate handed over by a device change reaches the render thread: a recording lasts the
    /// same wall time, so twice as many frames at 96 kHz. Invalid rates are ignored.
    func testReconfigureMovesTheRenderThreadToTheNewRate() throws {
        func audibleFrames(rate: Double?) throws -> Int {
            let audio = makeEngine()
            for bad in [0, -1, .nan, .infinity] { audio.reconfigure(sampleRate: bad) }
            XCTAssertEqual(audio.renderSampleRate, 48_000)
            if let rate { audio.reconfigure(sampleRate: rate) }
            audio.play("entity.prehistoric.triceratops.hurt", 0, 0, 0)
            let out = try render(audio, seconds: 8)
            return (out.left.lastIndex { $0 != 0 } ?? -1) + 1
        }
        let base = try audibleFrames(rate: nil)
        XCTAssertGreaterThan(base, 0)
        XCTAssertEqual(Double(try audibleFrames(rate: 96_000)), Double(base) * 2, accuracy: 4)
    }

    /// With no render callback running (a stopped or failed device), the inbox stays bounded.
    func testInboxStaysBoundedWhileNothingRenders() {
        let audio = makeEngine()
        for _ in 0..<25 { audio.playDisc("jukebox.play.music_disc_descent", 0, 0, 1) }
        for _ in 0..<2_000 { audio.play("entity.generic.explode", 0, 0, 1) }
        XCTAssertLessThanOrEqual(audio.pendingInboxCount, 8_192)
        XCTAssertGreaterThan(audio.pendingInboxCount, 0)
    }

    // MARK: - A5 jukebox

    /// Ejecting a different jukebox clicks but leaves the playing disc alone; only the jukebox
    /// that holds the playing disc stops it.
    func testJukeboxStopFromAnotherJukeboxLeavesThePlayingDiscAlone() throws {
        let audio = makeEngine()
        audio.playGameSound("jukebox.play.music_disc_aurora", 0, 0, 1, 4, 1)
        _ = try render(audio, seconds: 1)
        audio.playGameSound("jukebox.stop", 20, 0, 1, 1, 1)        // a jukebox 20 blocks away
        _ = try render(audio, seconds: 3)                          // its click and ringing notes pass
        XCTAssertGreaterThan(try render(audio, seconds: 10).rms(from: 0, to: 10), 0.005, "the disc keeps playing")
        audio.playGameSound("jukebox.stop", 0, 0, 1, 1, 1)         // the playing jukebox itself
        _ = try render(audio, seconds: 3)
        XCTAssertEqual(try render(audio, seconds: 10).peak, 0, "its own eject stops it")
    }

    /// A pitch far outside any recipe's range is clamped instead of overrunning the noise cursor.
    func testExtremePitchIsClampedAndRendersSafely() throws {
        for pitch in [1e16, 1e-12, 4.0, 0.25] {
            let audio = makeEngine()
            audio.play("block.stone.break", 0, 0, 1, 1, pitch)
            let out = try render(audio, seconds: 0.5)
            XCTAssertTrue(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite), "pitch \(pitch)")
            XCTAssertLessThanOrEqual(out.peak, 1, "pitch \(pitch)")
        }
        let audio = makeEngine()
        for pitch in [Double.nan, .infinity, 0, -1] { audio.play("block.stone.break", 0, 0, 1, 1, pitch) }
        XCTAssertEqual(audio.pendingInboxCount, 0, "a non-finite or non-positive pitch is refused")
    }

    /// While the output device is down nothing is queued, so nothing stale plays when it returns.
    func testNothingQueuesWhileTheOutputDeviceIsDown() throws {
        let audio = makeEngine()
        audio.outputRunning = false
        for _ in 0..<50 { audio.play("block.stone.break", 0, 0, 1) }
        audio.playGameSound("jukebox.play.music_disc_wander", 0, 0, 1, 4, 1)
        XCTAssertEqual(audio.pendingInboxCount, 0)
        audio.outputRunning = true
        XCTAssertEqual(try render(audio, seconds: 1).peak, 0, "nothing stale plays once it is back")
        audio.play("block.stone.break", 0, 0, 1)
        XCTAssertGreaterThan(audio.pendingInboxCount, 0)
        XCTAssertGreaterThan(try render(audio, seconds: 0.5).peak, 0)
    }

    /// The device graph and the mixer share one notion of a usable output rate.
    func testPlausibleSampleRateBoundsAreShared() {
        for rate in [8_000.0, 44_100, 48_000, 96_000, 768_000] { XCTAssertTrue(MixSettings.isPlausibleSampleRate(rate), "\(rate)") }
        for rate in [0.0, -48_000, 7_999, 768_001, .nan, .infinity] { XCTAssertFalse(MixSettings.isPlausibleSampleRate(rate), "\(rate)") }
    }

    /// The core's `jukebox.stop` (eject or break) stops the disc: after the ringing notes and the
    /// click have decayed, the output is silent.
    func testJukeboxStopNameSilencesThePlayingDisc() throws {
        let audio = makeEngine()
        audio.playGameSound("jukebox.play.music_disc_aurora", 0, 0, 1, 4, 1)
        XCTAssertGreaterThan(try render(audio, seconds: 3).peak, 0.01)
        audio.playGameSound("jukebox.stop", 0, 0, 1, 1, 1)
        _ = try render(audio, seconds: 2.5)
        XCTAssertEqual(try render(audio, seconds: 10).peak, 0, "no disc notes after jukebox.stop")
    }

    /// Disc voices are positioned at the jukebox: louder near, quieter at 40 blocks, silent from
    /// 64, panned to its side, and re-evaluated as the listener walks away mid-disc.
    func testDiscIsPositionedAtTheJukebox() throws {
        func rms(at x: Double, _ z: Double) throws -> Double {
            let audio = makeEngine()
            audio.playDisc("jukebox.play.music_disc_aurora", x, 0, z)
            return try render(audio, seconds: 10).rms(from: 0, to: 10)
        }
        let near = try rms(at: 0, 2), mid = try rms(at: 0, 40), far = try rms(at: 0, 64.5)
        XCTAssertGreaterThan(near, 0.005)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, near * 0.4)
        XCTAssertEqual(far, 0, "beyond 64 blocks the disc is inaudible")

        let audio = makeEngine()
        audio.playDisc("jukebox.play.music_disc_aurora", -20, 0, 0)    // due west → hard left
        let side = try render(audio, seconds: 3)
        XCTAssertGreaterThan(side.leftPeak, 0.001)
        XCTAssertEqual(side.rightPeak, 0)
        audio.setListener(60, 0, 0, 0)                                   // 80 blocks away
        XCTAssertEqual(try render(audio, seconds: 2).peak, 0, "walking out of range silences it")
        audio.setListener(-18, 0, 0, 0)
        XCTAssertGreaterThan(try render(audio, seconds: 3).peak, 0.001, "and walking back resumes it")
    }

    /// While a disc plays, the generative music timer may run out but no track starts.
    func testTickMusicStartsNoTrackWhileADiscIsPlaying() throws {
        let audio = makeEngine(volumes: ["records": 0])   // only music could make a sound
        audio.playDisc("jukebox.play.music_disc_aurora", 0, 0, 1)
        audio.musicTimer = 1
        audio.tickMusic("overworld", true)
        XCTAssertEqual(try render(audio, seconds: 10).peak, 0, "no music track over a disc")
        audio.stopDisc()
        audio.musicTimer = 1
        audio.tickMusic("overworld", true)
        XCTAssertGreaterThan(try render(audio, seconds: 10).peak, 0, "music resumes once the disc stops")
    }

    // MARK: - A6 session hygiene

    /// Leaving a world underwater in a cave with a disc playing returns the mixer to the dry,
    /// full-bandwidth title-screen state: a UI sound afterwards renders exactly like on a fresh
    /// engine.
    func testWorldAudioDidEndResetsEnvironmentAndStopsTheDisc() throws {
        let audio = makeEngine()
        audio.setEnvironment(true, 1)
        audio.playDisc("jukebox.play.music_disc_aurora", 0, 0, 1)
        _ = try render(audio, seconds: 1)
        audio.worldAudioDidEnd()
        XCTAssertFalse(audio.underwater)
        XCTAssertEqual(audio.caveFactor, 0)
        _ = try render(audio, seconds: 3)
        audio.playUI("ui.toast.in")
        let after = try render(audio, seconds: 0.5)

        let fresh = makeEngine()
        fresh.playUI("ui.toast.in")
        let reference = try render(fresh, seconds: 0.5)
        XCTAssertGreaterThan(reference.peak, 0.01)
        for i in reference.left.indices {
            XCTAssertEqual(after.left[i], reference.left[i], accuracy: 1e-6, "frame \(i)")
            if abs(after.left[i] - reference.left[i]) > 1e-6 { break }
        }
    }

    // MARK: - scheduler policy

    static let unityGains = SIMD16<Double>(repeating: 1)

    func voice(start: Double, dur: Double = 1, vol: Double = 0.3, category: AudioCategory = .blocks,
                       disc: Bool = false, generation: Int = 0) -> Voice {
        var v = Voice()
        v.start = start
        v.dur = dur
        v.vol = vol
        v.category = category
        v.isDisc = disc
        v.discGeneration = generation
        return v
    }

    func testSchedulerNeverCountsOrStealsVoicesThatHaveNotStarted() {
        var scheduler = VoiceScheduler()
        scheduler.incoming = (0..<600).map { _ in voice(start: 0, dur: 2) }
            + (0..<3_000).map { voice(start: 10 + Double($0) * 0.01, category: .records, disc: true) }
        scheduler.admitIncoming()
        XCTAssertTrue(scheduler.incoming.isEmpty)
        scheduler.enforceLimits(blockStart: 0, blockEnd: 0.1, gains: Self.unityGains)
        XCTAssertEqual(scheduler.sounding, VoiceScheduler.maxSounding)
        XCTAssertEqual(scheduler.pending, 3_000)
        XCTAssertEqual(scheduler.voices.filter { $0.isDisc && !$0.done }.count, 3_000, "no future voice dropped")
        scheduler.compact()
        XCTAssertEqual(scheduler.voices.count, 3_512)
    }

    func testSchedulerStealsMutedThenNearlyFinishedVoicesFirst() {
        var scheduler = VoiceScheduler()
        var gains = Self.unityGains
        gains[AudioCategory.ambient.rawValue] = 0
        let loud = (0..<512).map { _ in voice(start: 0, dur: 5, vol: 0.5) }
        let ending = (0..<10).map { _ in voice(start: 0, dur: 0.15, vol: 0.5) }
        let muted = (0..<10).map { _ in voice(start: 0, dur: 5, vol: 0.5, category: .ambient) }
        scheduler.incoming = muted + loud + ending
        scheduler.admitIncoming()
        scheduler.enforceLimits(blockStart: 0.1, blockEnd: 0.2, gains: gains)
        let alive = scheduler.voices.filter { !$0.done }
        XCTAssertEqual(alive.count, 512)
        XCTAssertTrue(alive.allSatisfy { $0.dur == 5 && $0.category == .blocks }, "only the loud, long voices remain")
    }

    func testSchedulerStealsMusicAndDiscVoicesOnlyWhenNothingElseIsLeft() {
        var scheduler = VoiceScheduler()
        let music = (0..<500).map { _ in voice(start: 0, dur: 0.5, vol: 0.01, category: .music) }
        let disc = (0..<12).map { _ in voice(start: 0, dur: 0.5, vol: 0.01, category: .records, disc: true) }
        let effects = (0..<20).map { _ in voice(start: 0, dur: 8, vol: 1.0) }   // loud and fresh
        scheduler.incoming = music + disc + effects
        scheduler.admitIncoming()
        scheduler.enforceLimits(blockStart: 0, blockEnd: 0.1, gains: Self.unityGains)
        XCTAssertTrue(scheduler.voices.filter { $0.category == .blocks }.allSatisfy(\.done))
        XCTAssertEqual(scheduler.voices.filter { !$0.done }.count, 512)

        scheduler.incoming = (0..<5).map { _ in voice(start: 0, dur: 0.5, vol: 0.01, category: .music) }
        scheduler.admitIncoming()
        scheduler.enforceLimits(blockStart: 0, blockEnd: 0.1, gains: Self.unityGains)
        XCTAssertEqual(scheduler.voices.filter { !$0.done }.count, 512, "the cap still holds with only music left")
    }

    func testSchedulerDropsTheLatestStartingPendingVoicesBeyondItsBound() {
        var scheduler = VoiceScheduler()
        let extra = 100
        var starts = (0..<(VoiceScheduler.maxPending + extra)).map { 1 + Double($0) * 0.001 }
        var rng = SystemRandomNumberGenerator()
        starts.shuffle(using: &rng)
        scheduler.incoming = [voice(start: 0, dur: 30)] + starts.map { voice(start: $0) }
        scheduler.admitIncoming()
        scheduler.enforceLimits(blockStart: 0, blockEnd: 0.1, gains: Self.unityGains)
        XCTAssertEqual(scheduler.pending, VoiceScheduler.maxPending)
        XCTAssertFalse(scheduler.voices[0].done, "a sounding voice is never dropped for the pending bound")
        let cutoff = 1 + Double(VoiceScheduler.maxPending) * 0.001
        let dropped = scheduler.voices.filter(\.done)
        XCTAssertEqual(dropped.count, extra)
        XCTAssertTrue(dropped.allSatisfy { $0.start >= cutoff - 1e-9 }, "only the furthest-future voices go")
    }

    func testSchedulerCutsOnlyUnstartedVoicesOfOlderDiscGenerations() {
        var scheduler = VoiceScheduler()
        scheduler.incoming = [voice(start: 0, disc: true, generation: 0),     // ringing: keeps playing
                              voice(start: 5, disc: true, generation: 0),     // upcoming old disc: cut
                              voice(start: 5, disc: true, generation: 1),     // the new disc: kept
                              voice(start: 5)]                                // not a disc: kept
        scheduler.admitIncoming()
        scheduler.cutDiscs(after: 0.05, through: 0)
        XCTAssertEqual(scheduler.voices.map(\.done), [false, true, false, false])
    }

    /// Steady inflow and retirement never grows the voice list's storage, and compaction keeps
    /// the surviving voices in order.
    func testSchedulerSteadyStateKeepsItsStorage() {
        var scheduler = VoiceScheduler()
        let capacity = scheduler.voices.capacity
        var t = 0.0
        for block in 0..<2_000 {
            scheduler.incoming.append(contentsOf: (0..<3).map { voice(start: t + 0.02 + Double($0) * 0.001, dur: 0.3) })
            scheduler.admitIncoming()
            scheduler.enforceLimits(blockStart: t, blockEnd: t + 0.01, gains: Self.unityGains)
            scheduler.compact()
            XCTAssertEqual(scheduler.voices.capacity, capacity, "block \(block)")
            XCTAssertEqual(scheduler.voices.map(\.start), scheduler.voices.map(\.start).sorted())
            t += 0.01
        }
    }

    func testSelectNthMatchesSortedOrder() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let count = Int.random(in: 1...200, using: &rng)
            var values = (0..<count).map { _ in Double(Int.random(in: -20...20, using: &rng)) }
            let sorted = values.sorted()
            let k = Int.random(in: 0..<count, using: &rng)
            let picked = values.withUnsafeMutableBufferPointer { selectNth($0, k) }
            XCTAssertEqual(picked, sorted[k])
        }
        var empty: [Double] = []
        XCTAssertEqual(empty.withUnsafeMutableBufferPointer { selectNth($0, 0) }, 0)
    }

    // MARK: - limiter

    func testLimiterIsBitTransparentBelowItsThreshold() {
        var limiter = OutputLimiter(sampleRate: 48_000)
        var left = (0..<48_000).map { _ in Float.random(in: -OutputLimiter.threshold...OutputLimiter.threshold) }
        var right = left.reversed().map { $0 }
        let (l0, r0) = (left, right)
        limiter.process(&left, &right, left.count)
        XCTAssertEqual(left, l0)
        XCTAssertEqual(right, r0)
        XCTAssertEqual(limiter.gain, 1)
    }

    func testLimiterHoldsOverloadsWithinFullScaleAndReleasesSmoothly() {
        var limiter = OutputLimiter(sampleRate: 48_000)
        @discardableResult
        func block(_ amplitude: Float, frames: Int = 4_800) -> Float {
            var l = (0..<frames).map { amplitude * Float(Foundation.sin(Double($0) * 0.07)) }
            var r = l
            limiter.process(&l, &r, frames)
            return max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
        }
        XCTAssertLessThanOrEqual(block(8), 1.0)
        XCTAssertLessThanOrEqual(block(40), 1.0)
        XCTAssertLessThan(limiter.gain, 0.05)
        var previous = limiter.gain
        for _ in 0..<5 {                                   // 0.5 s of quiet material: steady recovery
            block(0.5)
            XCTAssertGreaterThan(limiter.gain, previous)
            XCTAssertLessThan(limiter.gain, 1)
            previous = limiter.gain
        }
        XCTAssertGreaterThan(previous, 0.9, "~150 ms release: mostly recovered after half a second")
        for _ in 0..<30 { block(0.5) }
        XCTAssertEqual(limiter.gain, 1, "fully transparent again")
    }

    func testLimiterTurnsNonFiniteSamplesIntoSilence() {
        var limiter = OutputLimiter(sampleRate: 48_000)
        var left: [Float] = [.nan, .infinity, -.infinity, 0.5, .signalingNaN]
        var right: [Float] = [0.25, .nan, 0.25, -.infinity, 0.25]
        limiter.process(&left, &right, left.count)
        XCTAssertEqual(left, [0, 0, 0, 0.5, 0])
        XCTAssertEqual(right, [0.25, 0, 0.25, 0, 0.25])
        XCTAssertEqual(limiter.gain, 1)
    }

    // MARK: - device start policy

    func testDeviceStartBackoffRetriesAtMostOncePerSecondAndLogsOncePerStreak() {
        var backoff = DeviceStartBackoff()
        XCTAssertTrue(backoff.mayAttempt(at: 0))
        XCTAssertTrue(backoff.recordFailure(at: 0), "first failure is logged")
        XCTAssertFalse(backoff.mayAttempt(at: 0.999))
        XCTAssertTrue(backoff.mayAttempt(at: 1))
        var now = 1.0
        var delays: [Double] = []
        for _ in 0..<8 {
            XCTAssertFalse(backoff.recordFailure(at: now), "later failures in the streak are quiet")
            delays.append(backoff.nextAttempt - now)
            now = backoff.nextAttempt
        }
        XCTAssertEqual(delays, [2, 4, 8, 8, 8, 8, 8, 8])
        XCTAssertTrue(delays.allSatisfy { $0 >= 1 })
        backoff.recordSuccess()
        XCTAssertTrue(backoff.mayAttempt(at: now))
        XCTAssertTrue(backoff.recordFailure(at: now), "a new streak logs again")
    }

    // MARK: - categories

    func testEverySettingsSliderHasItsOwnLiveCategory() {
        let keys = ["music", "blocks", "hostile", "friendly", "players", "ambient", "records", "ui"]
        XCTAssertEqual(AudioCategory.sliders.map(\.settingsKey), keys)
        for key in keys { XCTAssertEqual(AudioCategory(settingsKey: key).settingsKey, key) }
        XCTAssertEqual(AudioCategory(settingsKey: "master"), .unscaled)
        XCTAssertEqual(AudioCategory(settingsKey: ""), .unscaled)
        XCTAssertEqual(AudioCategory(settingsKey: "weather"), .unscaled)
        XCTAssertLessThan(AudioCategory.allCases.count, 16, "fits MixSettings.categoryGains")

        // non-finite or negative settings never reach the mix as NaN
        let audio = makeEngine(volumes: ["master": .nan, "blocks": -3])
        audio.play("event.raid.horn", 0, 0, 1)
        let out = try? render(audio, seconds: 0.2)
        XCTAssertEqual(out?.peak, 0)
    }

    // MARK: - helpers

    struct Capture {
        var left: [Float] = []
        var right: [Float] = []
        var leftPeak: Float { left.map { abs($0) }.max() ?? 0 }
        var rightPeak: Float { right.map { abs($0) }.max() ?? 0 }
        var peak: Float { max(leftPeak, rightPeak) }

        mutating func append(_ other: Capture) {
            left.append(contentsOf: other.left)
            right.append(contentsOf: other.right)
        }
        private func range(_ from: Double, _ to: Double) -> Range<Int> {
            let lo = min(left.count, Int(from * AudioMixerTests.rate))
            return lo..<max(lo, min(left.count, Int(to * AudioMixerTests.rate)))
        }
        func peak(from: Double, to: Double) -> Float {
            range(from, to).reduce(Float(0)) { max($0, abs(left[$1]), abs(right[$1])) }
        }
        /// Stereo RMS over [from, to) seconds.
        func rms(from: Double, to: Double) -> Double {
            let r = range(from, to)
            guard !r.isEmpty else { return 0 }
            let sum = r.reduce(0.0) { $0 + Double(left[$1] * left[$1]) + Double(right[$1] * right[$1]) }
            return (sum / Double(2 * r.count)).squareRoot()
        }
        func rmsBuckets(seconds: Double) -> [Double] {
            let total = Double(left.count) / AudioMixerTests.rate
            return stride(from: 0.0, to: total - 1e-9, by: seconds).map { rms(from: $0, to: $0 + seconds) }
        }
    }

    func makeEngine(volumes: [String: Double] = [:]) -> AudioEngineM {
        let audio = AudioEngineM()
        audio.initEngine(startDevice: false)
        audio.applyVolumes(volumes)
        audio.setEnvironment(false, 0)
        audio.setListener(0, 0, 0, 0)
        return audio
    }

    func render(_ audio: AudioEngineM, seconds: Double) throws -> Capture {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let frames = Self.blockFrames
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let blocks = Int((seconds * Self.rate / Double(frames)).rounded())
        var out = Capture()
        out.left.reserveCapacity(blocks * frames)
        out.right.reserveCapacity(blocks * frames)
        for _ in 0..<blocks {
            audio.render(buffer.frameLength, buffer.mutableAudioBufferList)
            let left = try XCTUnwrap(buffer.floatChannelData?[0])
            let right = try XCTUnwrap(buffer.floatChannelData?[1])
            out.left.append(contentsOf: UnsafeBufferPointer(start: left, count: frames))
            out.right.append(contentsOf: UnsafeBufferPointer(start: right, count: frames))
        }
        return out
    }
}
