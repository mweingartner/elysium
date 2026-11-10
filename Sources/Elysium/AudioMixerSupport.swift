// AudioMixerSupport — the pieces of Audio.swift's mixer that are not synthesis: the voice
// record, the render thread's voice scheduler (admission, the sounding cap, compaction, all
// without steady-state allocation), live per-category gains, the master-bus limiter, and the
// output device with its configuration-change and start-retry handling.

import AVFoundation
import Foundation

// ---------------------------------------------------------------------------
// voices
// ---------------------------------------------------------------------------
enum OscType {
    case sine, square, sawtooth, triangle
}

/// One volume slider per category; `.unscaled` (always gain 1) covers recipes outside them.
/// The raw value indexes `MixSettings.categoryGains`.
enum AudioCategory: Int, CaseIterable {
    case music, blocks, hostile, friendly, players, ambient, records, ui, unscaled

    static let sliders = allCases.filter { $0 != .unscaled }
    private static let keys = ["music", "blocks", "hostile", "friendly", "players", "ambient", "records", "ui", ""]

    /// The `Settings.volumes` key of this slider.
    var settingsKey: String { Self.keys[rawValue] }

    init(settingsKey: String) {
        self = Self.sliders.first { $0.settingsKey == settingsKey } ?? .unscaled
    }
}

/// Everything the render thread reads from the main thread, copied once per block under the
/// engine lock: a slider, environment or device-rate change reaches every voice — including
/// music and discs scheduled a minute ahead — within one block.
struct MixSettings {
    var master = 1.0
    var categoryGains = SIMD16<Double>(repeating: 1)
    var lowpassTarget = 20_000.0
    var reverbAmount = 0.0
    var sampleRate = 48_000.0

    func gain(_ category: AudioCategory) -> Double { categoryGains[category.rawValue] }

    /// The one test for an output rate the mixer will render at; the device falls back to
    /// 48 kHz outside it, so the graph and the mixer can never disagree about the rate.
    static func isPlausibleSampleRate(_ rate: Double) -> Bool {
        rate.isFinite && rate >= 8_000 && rate <= 768_000
    }
}

extension CreatureSoundPosition {
    func isWithinOneBlock(_ x: Double, _ y: Double, _ z: Double) -> Bool {
        abs(self.x - x) <= 1 && abs(self.y - y) <= 1 && abs(self.z - z) <= 1
    }
}

struct Voice {
    /// Seconds a voice keeps its slot after `dur`, so its release never cuts off.
    static let tail = 0.05
    /// How far a prehistoric creature's call carries, in blocks.
    static let creatureRange = 40.0
    var isNoise = false
    var type = OscType.sine
    var freq = 440.0
    var endFreq = 0.0           // 0 = constant
    var vibrato = 0.0           // Hz, depth = freq*0.04
    var dur = 0.2
    var attack = 0.01
    var vol = 0.3
    var pitchRate = 1.0         // noise playback rate
    var filterFreq = 0.0        // noise: biquad center
    var filterQ = 1.0
    var lowpassFilter = false   // else bandpass
    var start = 0.0             // engine-time seconds
    var pan = 0.0               // -1..1
    var gain = 1.0              // caller volume × distance; the category slider applies live
    var category = AudioCategory.unscaled
    var reverbSend = 0.0
    // runtime state
    var phase = 0.0
    var lfoPhase = 0.0
    var noisePos = 0.0
    var z1 = 0.0, z2 = 0.0      // biquad state (transposed direct form II)
    var done = false
    var sample: DinosaurSample?
    var sampleCursor = 0.0
    /// A tracked source (creature calls, jukebox discs): gain and pan are recomputed from this
    /// emission point every block as the listener moves, silent at `sourceRange` and beyond.
    var sourcePosition: CreatureSoundPosition?
    var sourceVolume = 1.0
    var sourceRange = Voice.creatureRange
    var isDisc = false          // jukebox voices — stopDisc cuts ONLY these
    var discGeneration = 0      // stopDisc cuts generations up to its own, not a disc started after it
}

// ---------------------------------------------------------------------------
// scheduling
// ---------------------------------------------------------------------------
/// The render thread's voice list. Only the render thread touches it; the main thread's inbox
/// is swapped with `incoming` under the engine lock (O(1)), so nothing is copied there.
///
/// Policy:
/// - A voice whose start lies after the current block is *pending*: it costs nothing, never
///   counts against the sounding cap and is never stolen. Pending voices are bounded on their
///   own (`maxPending`); past that bound the latest-starting pending voices are dropped first.
/// - At most `maxSounding` voices sound at once. When more would, the sounding voices with the
///   lowest "seconds left × level" are stolen: a quiet voice about to end goes before a loud
///   fresh one, and a muted voice goes first. Music and jukebox-disc voices are stolen only once
///   no other sounding voice is left to take.
///
/// Arrays keep their capacity; scratch space grows only if the list outgrows its reservation.
struct VoiceScheduler {
    static let maxSounding = 512
    static let maxPending = 8_192
    /// Bound on the main thread's inbox, reached only while nothing renders (stopped device).
    static let maxInbox = 8_192

    var voices: [Voice] = []
    var incoming: [Voice] = []
    private var scratch: [Double] = []
    private(set) var sounding = 0
    private(set) var pending = 0

    init(capacity: Int = 2_048) {
        voices.reserveCapacity(capacity)
        incoming.reserveCapacity(capacity / 2)
        scratch = [Double](repeating: 0, count: capacity)
    }

    /// Moves the swapped-in inbox onto the voice list; both arrays keep their storage.
    mutating func admitIncoming() {
        guard !incoming.isEmpty else { return }
        voices.append(contentsOf: incoming)
        incoming.removeAll(keepingCapacity: true)
    }

    /// Cuts not-yet-started disc voices of `generation` and older that start after `time`;
    /// already-sounding notes ring out.
    mutating func cutDiscs(after time: Double, through generation: Int) {
        for i in voices.indices where voices[i].isDisc && voices[i].discGeneration <= generation
            && voices[i].start > time {
            voices[i].done = true
        }
    }

    /// Retires finished voices and applies the pending bound and the sounding cap for the block
    /// [blockStart, blockEnd), stealing as documented on the type.
    mutating func enforceLimits(blockStart: Double, blockEnd: Double, gains: SIMD16<Double>) {
        sounding = 0
        pending = 0
        for i in voices.indices where !voices[i].done {
            if blockStart >= voices[i].start + voices[i].dur + Voice.tail {
                voices[i].done = true
            } else if voices[i].start < blockEnd {
                sounding += 1
            } else {
                pending += 1
            }
        }
        if pending > Self.maxPending {
            retire(pending - Self.maxPending, matching: { !$0.done && $0.start >= blockEnd },
                   rank: { -$0.start })
            pending = Self.maxPending
        }
        if sounding > Self.maxSounding {
            retire(sounding - Self.maxSounding, matching: { !$0.done && $0.start < blockEnd },
                   rank: { Self.stealRank($0, at: blockStart, gains) })
            sounding = Self.maxSounding
        }
    }

    /// Lower ranks are stolen first; music and disc voices sit above every possible effect rank.
    static func stealRank(_ v: Voice, at time: Double, _ gains: SIMD16<Double>) -> Double {
        let remaining = max(0, v.start + v.dur - time)
        let level = abs(v.vol * v.gain) * gains[v.category.rawValue]
        let rank = remaining * level
        let protected = v.isDisc || v.category == .music
        return (rank.isFinite ? min(rank, 1e9) : 0) + (protected ? 1e12 : 0)
    }

    /// Removes finished voices in place, preserving order; capacity is kept.
    mutating func compact() {
        var kept = 0
        for i in voices.indices where !voices[i].done {
            if kept != i { voices.swapAt(kept, i) }
            kept += 1
        }
        voices.removeLast(voices.count - kept)
    }

    /// Marks done the `count` matching voices of lowest rank; equal ranks go latest-added first.
    private mutating func retire(_ count: Int, matching: (Voice) -> Bool, rank: (Voice) -> Double) {
        if scratch.count < voices.count { scratch = [Double](repeating: 0, count: voices.capacity) }
        var m = 0
        for i in voices.indices where matching(voices[i]) {
            scratch[m] = rank(voices[i])
            m += 1
        }
        guard count > 0, m > 0 else { return }
        let threshold = scratch.withUnsafeMutableBufferPointer {
            selectNth(UnsafeMutableBufferPointer(rebasing: $0[0..<m]), min(count, m) - 1)
        }
        var remaining = count
        for i in voices.indices where remaining > 0 && matching(voices[i]) && rank(voices[i]) < threshold {
            voices[i].done = true
            remaining -= 1
        }
        var i = voices.count - 1
        while remaining > 0 && i >= 0 {
            if matching(voices[i]) && rank(voices[i]) == threshold {
                voices[i].done = true
                remaining -= 1
            }
            i -= 1
        }
    }
}

/// The k-th smallest (0-based) of `values`, reordering them in place (Hoare quickselect):
/// average O(n), no allocation. Values must not be NaN.
func selectNth(_ values: UnsafeMutableBufferPointer<Double>, _ k: Int) -> Double {
    guard !values.isEmpty else { return 0 }
    let k = min(max(0, k), values.count - 1)
    var lo = 0, hi = values.count - 1
    while lo < hi {
        let pivot = values[lo + (hi - lo) / 2]
        var i = lo, j = hi
        while i <= j {
            while values[i] < pivot { i += 1 }
            while values[j] > pivot { j -= 1 }
            if i <= j {
                values.swapAt(i, j)
                i += 1
                j -= 1
            }
        }
        if k <= j { hi = j } else if k >= i { lo = i } else { break }
    }
    return values[k]
}

// ---------------------------------------------------------------------------
// master-bus limiter
// ---------------------------------------------------------------------------
/// Stereo-linked peak limiter, last on the master bus. While no sample exceeds `threshold` the
/// gain is exactly 1, so the mix passes bit-for-bit; above it the gain falls with a ~1 ms attack
/// and recovers with a ~150 ms release, and a final clamp keeps every sample within ±1.
/// Non-finite samples become silence. Plain value state owned by the render thread. The gain
/// runs in Double: in Float the per-sample release step drops below an ulp near 1 and the
/// gain would stall short of 1, never transparent again after the first overload.
struct OutputLimiter {
    static let threshold: Float = 0.9
    private(set) var gain = 1.0
    private(set) var sampleRate = 0.0
    private var attack = 0.0
    private var release = 0.0

    init(sampleRate: Double) { configure(sampleRate) }

    mutating func configure(_ rate: Double) {
        sampleRate = rate
        attack = Foundation.exp(-1 / (0.001 * rate))
        release = Foundation.exp(-1 / (0.15 * rate))
    }

    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int) {
        var g = gain
        for i in 0..<count {
            let l = left[i].isFinite ? left[i] : 0
            let r = right[i].isFinite ? right[i] : 0
            let peak = max(abs(l), abs(r))
            let target = peak > Self.threshold ? Double(Self.threshold / peak) : 1
            if target < g {
                g = target + (g - target) * attack
            } else if g < 1 {
                g = target - (target - g) * release
                if g > 0.999_999 { g = 1 }
            }
            let gf = Float(g)
            left[i] = min(1, max(-1, l * gf))
            right[i] = min(1, max(-1, r * gf))
        }
        gain = g
    }
}

// ---------------------------------------------------------------------------
// output device
// ---------------------------------------------------------------------------
/// When to retry a failed device start: never more than once a second, backing off to every
/// 8 s, with a log line only for the first failure of a streak.
struct DeviceStartBackoff {
    private(set) var failures = 0
    private(set) var nextAttempt = -Double.infinity

    var retryDelay: Double { min(8, Foundation.pow(2, Double(max(0, failures - 1)))) }

    func mayAttempt(at now: Double) -> Bool { now >= nextAttempt }

    /// Records a failed start at `now`; true when this failure should be logged.
    mutating func recordFailure(at now: Double) -> Bool {
        failures += 1
        nextAttempt = now + retryDelay
        return failures == 1
    }

    mutating func recordSuccess() {
        failures = 0
        nextAttempt = -.infinity
    }
}

/// The live output: an AVAudioEngine driving the mixer's source node. Main thread only.
/// AVAudioEngine stops itself when the output device or its sample rate changes; this rebuilds
/// the connection at the new rate, hands the rate to the mixer, and restarts. Failed starts
/// (at launch or after a change) retry under `DeviceStartBackoff`.
final class AudioOutputDevice {
    private let engine = AVAudioEngine()
    private let sourceNode: AVAudioSourceNode
    private let rateChanged: (Double) -> Void
    private let runningChanged: (Bool) -> Void
    private var observer: NSObjectProtocol?
    private var backoff = DeviceStartBackoff()
    private var retryPending = false
    private(set) var sampleRate = 48_000.0

    init(render: @escaping (AVAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> Void,
         rateChanged: @escaping (Double) -> Void,
         runningChanged: @escaping (Bool) -> Void) {
        sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            render(frameCount, audioBufferList)
            return noErr
        }
        self.rateChanged = rateChanged
        self.runningChanged = runningChanged
        engine.attach(sourceNode)
        connect()
        // posted on an arbitrary thread; the graph is rebuilt on main
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.configurationChanged() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.stop()
    }

    /// Starts the engine unless it is running; a failure logs once per streak and retries.
    func start() {
        guard !engine.isRunning else {
            backoff.recordSuccess()
            runningChanged(true)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard backoff.mayAttempt(at: now) else {
            scheduleRetry()
            return
        }
        do {
            try engine.start()
            backoff.recordSuccess()
            runningChanged(true)
        } catch {
            runningChanged(false)
            if backoff.recordFailure(at: now) {
                FileHandle.standardError.write(Data(
                    "[audio] output did not start (\(error.localizedDescription)); retrying\n".utf8))
            }
            scheduleRetry()
        }
    }

    /// (Re)connects the source node at the output device's current rate.
    private func connect() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = MixSettings.isPlausibleSampleRate(rate) ? rate : 48_000
        engine.disconnectNodeOutput(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
    }

    private func configurationChanged() {
        engine.stop()       // normally already stopped by AVAudioEngine; never rewire a running graph
        runningChanged(false)
        connect()
        rateChanged(sampleRate)
        start()
    }

    private func scheduleRetry() {
        guard !retryPending else { return }
        retryPending = true
        let delay = max(0.05, backoff.nextAttempt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryPending = false
            self.start()
        }
    }
}
