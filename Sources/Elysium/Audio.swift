// Audio — WebAudio graph → a voice-based synth on one
// AVAudioSourceNode: oscillator/noise voices with RBJ biquads, envelopes,
// vibrato and scheduled sub-sounds; positional stereo, underwater lowpass,
// cave feedback-delay reverb, generative music and jukebox discs.

import AVFoundation
import Foundation
import os

// ---------------------------------------------------------------------------
// voices
// ---------------------------------------------------------------------------
private enum OscType {
    case sine, square, sawtooth, triangle
}

private struct Voice {
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
    var gain = 1.0              // category × distance gain at spawn
    var reverbSend = 0.0
    // runtime state
    var phase = 0.0
    var lfoPhase = 0.0
    var noisePos = 0.0
    var z1 = 0.0, z2 = 0.0      // biquad state (transposed direct form II)
    var done = false
    var isDisc = false          // jukebox voices — stopDisc cuts ONLY these
}

// ---------------------------------------------------------------------------
// engine
// ---------------------------------------------------------------------------
final class AudioEngineM {
    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private var sampleRate = 48000.0
    private var lock = os_unfair_lock()
    /// owned by the render thread after pickup — main thread only appends to
    /// the inbox (a snapshot/write-back scheme silently dropped any voice
    /// added while the render callback was running)
    private var voices: [Voice] = []
    private var voiceInbox: [Voice] = []
    private var discCutAt: Double? = nil
    private var engineTime = 0.0          // seconds, advanced by the render thread

    // shared noise table
    private var noise = [Float](repeating: 0, count: 1 << 16)

    // env / mix state (written main thread, read audio thread — floats, benign races)
    private var masterGain = 0.8
    private var catGains: [String: Double] = [:]
    private var lowpassTarget = 20000.0
    private var lowpassCur = 20000.0
    private var lpZ1 = 0.0, lpZ2 = 0.0
    private var reverbAmt = 0.0
    private var delayL = [Float](repeating: 0, count: 24000)
    private var delayR = [Float](repeating: 0, count: 26000)
    private var delayPos = 0
    private var delayPosR = 0   // R line is longer — its own wrap, or the tap spacing jumps

    var listenerX = 0.0, listenerY = 0.0, listenerZ = 0.0, listenerYaw = 0.0
    var underwater = false
    var caveFactor = 0.0
    var volumes: [String: Double] = [:]
    var onSubtitle: ((String) -> Void)?
    var musicTimer = 600
    private var musicPlayingUntil = 0.0
    private var discUntil = 0.0
    private var inited = false

    func initEngine() {
        if inited { return }
        inited = true
        for i in 0..<noise.count { noise[i] = Float.random(in: -1...1) }
        let format = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate > 0 ? format.sampleRate : 48000
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        srcNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.render(frameCount, audioBufferList)
            return noErr
        }
        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: renderFormat)
        try? engine.start()
        applyVolumes(volumes)
    }

    func applyVolumes(_ v: [String: Double]) {
        volumes = v
        masterGain = v["master"] ?? 1
        for cat in ["music", "blocks", "hostile", "friendly", "players", "ambient", "records", "ui"] {
            catGains[cat] = v[cat] ?? 1
        }
    }

    func setEnvironment(_ underwater: Bool, _ caveFactor: Double) {
        self.underwater = underwater
        self.caveFactor = caveFactor
        lowpassTarget = underwater ? 700 : 20000
        reverbAmt = caveFactor * 0.35
    }
    func setListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {
        listenerX = x
        listenerY = y
        listenerZ = z
        listenerYaw = yaw
    }

    /// play a positional game sound
    func play(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double = 1, _ pitch: Double = 1) {
        guard inited else { return }
        let dx = x - listenerX, dy = y - listenerY, dz = z - listenerZ
        let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
        let maxDist = 18 * max(1, volume)
        if dist > maxDist { return }
        let atten = min(1, max(0, 1 - dist / maxDist))
        let angle = Foundation.atan2(-dx, dz) - listenerYaw
        let pan = min(1, max(-1, -Foundation.sin(angle))) * min(1, max(0, dist / 4))
        playRecipe(name, volume * atten * atten, pitch, pan, true)
    }
    func playUI(_ name: String) {
        playRecipe(name, 0.8, 1, 0, false)
    }

    private func playRecipe(_ name: String, _ volume: Double, _ pitch: Double, _ pan: Double, _ allowReverb: Bool) {
        guard inited, volume > 0.001 else { return }
        guard let recipe = resolveRecipe(name) else { return }
        var seed = UInt32(truncatingIfNeeded: Int.random(in: 0..<1_000_000_000)) &+ 12345
        let rng: () -> Double = {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed) / 4294967296.0
        }
        let gain = min(1.5, volume) * (catGains[recipe.cat] ?? 1)
        let reverbSend = allowReverb && caveFactor > 0.05 ? caveFactor * 0.6 : 0
        var sink = VoiceSink(start: now(), pan: pan, gain: gain, reverbSend: reverbSend)
        recipe.build(&sink, pitch, rng)
        addVoices(sink.voices)
        if let sub = recipe.subtitle { onSubtitle?(sub) }
    }

    private func now() -> Double {
        os_unfair_lock_lock(&lock)
        let t = engineTime
        os_unfair_lock_unlock(&lock)
        return t
    }
    private func addVoices(_ vs: [Voice]) {
        os_unfair_lock_lock(&lock)
        voiceInbox.append(contentsOf: vs)
        os_unfair_lock_unlock(&lock)
    }

    // ---- generative music ------------------------------------------------------
    func tickMusic(_ mood: String, _ enabled: Bool) {
        guard inited else { return }
        if !enabled || now() < musicPlayingUntil {
            if musicTimer > 0 { musicTimer -= 1 }
            return
        }
        musicTimer -= 1
        if musicTimer <= 0 {
            musicTimer = 2400 + Int.random(in: 0..<3600)
            playGenerativeTrack(mood)
        }
    }

    private func playGenerativeTrack(_ mood: String) {
        let scales: [String: [Double]] = [
            "overworld": [0, 2, 4, 7, 9, 12, 14, 16],
            "lush": [0, 2, 4, 7, 9, 12, 14, 16],
            "water": [0, 3, 5, 7, 10, 12, 15],
            "menu": [0, 2, 4, 7, 9, 12],
            "nether": [0, 1, 4, 5, 8, 12, 13],
            "dark": [0, 3, 5, 6, 10, 12],
            "end": [0, 2, 3, 7, 8, 12, 14],
        ]
        let scale = scales[mood] ?? scales["overworld"]!
        let baseFreq = mood == "nether" ? 110.0 : mood == "end" ? 130.8 : 220.0
        let length = 60 + Double.random(in: 0..<30)
        let start = now()
        musicPlayingUntil = start + length
        let gain = 0.32 * (catGains["music"] ?? 1)
        var vs: [Voice] = []
        let dark = mood == "nether" || mood == "dark" || mood == "end"

        // chord progression: slow pad triads over scale degrees, 8s per chord,
        // with a sub-octave bass root under each
        let progs = dark ? [[0, 3, 5, 4], [0, 5, 1, 4]] : [[0, 5, 3, 4], [0, 4, 5, 3]]
        let prog = progs[Int.random(in: 0..<progs.count)]
        let chordDur = 8.0
        var ct = start
        var ci = 0
        while ct < start + length - 4 {
            let rootDeg = prog[ci % prog.count]
            for (di, vol) in [(0, 0.05), (2, 0.038), (4, 0.03)] {
                let deg = (rootDeg + di) % scale.count
                var v = Voice()
                v.freq = baseFreq / 2 * Foundation.pow(2, scale[deg] / 12)
                v.dur = chordDur + 2
                v.attack = 2.5
                v.vol = vol
                v.vibrato = 0.15
                v.reverbSend = 0.12
                v.start = ct
                v.gain = gain
                vs.append(v)
            }
            var b = Voice()
            b.freq = baseFreq / 4 * Foundation.pow(2, scale[rootDeg] / 12)
            b.dur = chordDur
            b.attack = 0.8
            b.vol = 0.06
            b.start = ct
            b.gain = gain
            vs.append(b)
            ct += chordDur
            ci += 1
        }

        // melody: random-walk over the scale in short phrases with rests —
        // stepwise motion with rare leaps reads as a tune, not dice rolls
        let steps = [-2, -1, -1, -1, 0, 1, 1, 1, 2]
        var t = start + 4
        var deg = scale.count / 2
        while t < start + length - 6 {
            let phraseLen = 6 + Int.random(in: 0..<5)
            for _ in 0..<phraseLen {
                if t >= start + length - 6 { break }
                deg = max(0, min(scale.count - 1, deg + steps[Int.random(in: 0..<steps.count)]))
                let freq = baseFreq * Foundation.pow(2, scale[deg] / 12)
                vs.append(contentsOf: pluck(freq, t, 2.4, 0.15, gain))
                if Double.random(in: 0..<1) < 0.22 {
                    // sparkle: a high slow-vibrato bell shimmering over the note
                    var sp = Voice()
                    sp.freq = freq * 2
                    sp.dur = 3.0
                    sp.attack = 0.05
                    sp.vol = 0.035
                    sp.vibrato = 0.4
                    sp.reverbSend = 0.2
                    sp.start = t + 0.04
                    sp.gain = gain
                    vs.append(sp)
                }
                t += [0.5, 0.75, 1, 1, 1.5][Int.random(in: 0..<5)] * (dark ? 1.5 : 1.15)
            }
            t += 1.5 + Double.random(in: 0..<2)
        }
        addVoices(vs)
    }

    private func pluck(_ freq: Double, _ when: Double, _ decay: Double, _ vol: Double, _ gain: Double) -> [Voice] {
        var out: [Voice] = []
        for (mult, v) in [(1.0, 1.0), (2.0, 0.4), (3.0, 0.15)] {
            var voice = Voice()
            voice.freq = freq * mult
            voice.dur = decay
            voice.attack = 0.02
            voice.vol = vol * v
            voice.start = when
            voice.gain = gain
            out.append(voice)
        }
        return out
    }

    /// jukebox discs: longer structured generative pieces
    func playDisc(_ discName: String, _ x: Double, _ y: Double, _ z: Double) {
        guard inited else { return }
        stopDisc()
        let cfg: (scale: [Double], base: Double, bpm: Double, bass: Bool) = discName.contains("wander")
            ? ([0, 2, 4, 7, 9, 12, 14], 220, 100, true)
            : discName.contains("aurora")
                ? ([0, 3, 5, 7, 10, 12, 15], 261.6, 70, false)
                : ([0, 1, 4, 5, 8, 12], 146.8, 120, true)
        let beat = 60 / cfg.bpm
        let length = 60.0
        let start = now()
        os_unfair_lock_lock(&lock)
        discUntil = start + length
        os_unfair_lock_unlock(&lock)
        let gain = 0.5 * (catGains["records"] ?? 1)
        var vs: [Voice] = []
        var t = start + 0.2
        var step = 0
        while t < start + length {
            let note = cfg.scale[(step * 3 + Int.random(in: 0..<3)) % cfg.scale.count]
            vs.append(contentsOf: pluck(cfg.base * Foundation.pow(2, note / 12), t, 1.4, 0.2, gain))
            if cfg.bass && step % 4 == 0 {
                vs.append(contentsOf: pluck(cfg.base / 2 * Foundation.pow(2, cfg.scale[step % cfg.scale.count] / 12), t, 2.2, 0.22, gain))
            }
            if step % 8 == 4 { vs.append(contentsOf: pluck(cfg.base * 2, t, 0.8, 0.08, gain)) }
            t += beat / 2
            step += 1
        }
        for i in 0..<vs.count { vs[i].isDisc = true }
        addVoices(vs)
    }
    func stopDisc() {
        guard inited else { return }
        // request the cut — the render thread owns `voices`, so mutating the
        // array here raced (and the old duration heuristic also silenced
        // generative-music tails scheduled inside the disc window)
        os_unfair_lock_lock(&lock)
        if discUntil > engineTime { discCutAt = engineTime }
        discUntil = 0
        os_unfair_lock_unlock(&lock)
    }

    // ---- render ---------------------------------------------------------------
    private func render(_ frameCount: AVAudioFrameCount, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard buffers.count >= 2,
              let outL = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let n = Int(frameCount)
        let dt = 1.0 / sampleRate

        os_unfair_lock_lock(&lock)
        let t = engineTime
        engineTime += Double(n) * dt
        var local = voices
        if !voiceInbox.isEmpty {
            local.append(contentsOf: voiceInbox)
            voiceInbox.removeAll()
            // generous cap — a full generative track schedules ~250 voices
            // up front (most start in the future and cost nothing until then)
            if local.count > 512 { local.removeFirst(local.count - 512) }
        }
        if let cut = discCutAt {
            discCutAt = nil
            for i in 0..<local.count where local[i].isDisc && local[i].start > cut {
                local[i].done = true
            }
        }
        os_unfair_lock_unlock(&lock)

        for i in 0..<n {
            outL[i] = 0
            outR[i] = 0
        }
        let noiseMask = noise.count - 1

        for vi in 0..<local.count {
            var v = local[vi]
            let end = v.start + v.dur + 0.05
            if t >= end {
                local[vi].done = true
                continue
            }
            // scheduled in a future block — skip the whole sample loop
            if v.start >= t + Double(n) * dt { continue }
            // biquad coefficients (recomputed per block — voices are short)
            var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
            if v.isNoise {
                let f0 = min(sampleRate * 0.45, max(20, v.filterFreq))
                let w0 = 2 * Double.pi * f0 / sampleRate
                let alpha = Foundation.sin(w0) / (2 * max(0.01, v.filterQ))
                let cw = Foundation.cos(w0)
                let a0: Double
                if v.lowpassFilter {
                    b0 = (1 - cw) / 2
                    b1 = 1 - cw
                    b2 = (1 - cw) / 2
                    a0 = 1 + alpha
                } else {
                    b0 = alpha
                    b1 = 0
                    b2 = -alpha
                    a0 = 1 + alpha
                }
                b0 /= a0; b1 /= a0; b2 /= a0
                a1 = -2 * cw / a0
                a2 = (1 - alpha) / a0
            }
            var lt = t
            let panL = Float(min(1, 1 - v.pan) * v.gain)
            let panR = Float(min(1, 1 + v.pan) * v.gain)
            for i in 0..<n {
                let rel = lt - v.start
                lt += dt
                if rel < 0 { continue }
                if rel > v.dur + 0.05 { break }
                // envelope: linear attack → exponential decay to 0.001 at dur
                var env: Double
                if rel < v.attack {
                    env = rel / v.attack * v.vol
                } else if rel >= v.dur {
                    env = 0
                } else {
                    let f = (rel - v.attack) / max(0.001, v.dur - v.attack)
                    env = v.vol * Foundation.pow(0.001 / max(0.001, v.vol), f)
                }
                if env <= 0 { continue }
                var sample: Double
                if v.isNoise {
                    v.noisePos += v.pitchRate
                    let s = Double(noise[Int(v.noisePos) & noiseMask])
                    // TDF-II biquad
                    let y = b0 * s + v.z1
                    v.z1 = b1 * s - a1 * y + v.z2
                    v.z2 = b2 * s - a2 * y
                    sample = y
                } else {
                    var f = v.freq
                    if v.endFreq > 0 && v.dur > 0 {
                        f = v.freq * Foundation.pow(max(20, v.endFreq) / v.freq, min(1, rel / v.dur))
                    }
                    if v.vibrato > 0 {
                        v.lfoPhase += v.vibrato * dt
                        f += Foundation.sin(v.lfoPhase * 2 * .pi) * v.freq * 0.04
                    }
                    v.phase += f * dt
                    let ph = v.phase - v.phase.rounded(.down)
                    switch v.type {
                    case .sine: sample = Foundation.sin(ph * 2 * .pi)
                    case .square: sample = ph < 0.5 ? 1 : -1
                    case .sawtooth: sample = ph * 2 - 1
                    case .triangle: sample = ph < 0.5 ? ph * 4 - 1 : 3 - ph * 4
                    }
                }
                let s = Float(sample * env)
                outL[i] += s * panL
                outR[i] += s * panR
                // reverb send into the delay lines
                if v.reverbSend > 0 {
                    delayL[(delayPos + i) % delayL.count] += s * Float(v.reverbSend)
                    delayR[(delayPosR + i) % delayR.count] += s * Float(v.reverbSend)
                }
            }
            local[vi] = v
        }

        // cave reverb: two feedback delay taps (each line wraps on its OWN
        // length — sharing one cursor made the longer line's tap spacing jump
        // at every wrap, defeating the coprime-length design)
        if reverbAmt > 0.001 || delayL[delayPos] != 0 {
            let fb: Float = 0.45
            let amt = Float(reverbAmt)
            for i in 0..<n {
                let li = (delayPos + i) % delayL.count
                let ri = (delayPosR + i) % delayR.count
                let l = delayL[li]
                let r = delayR[ri]
                outL[i] += l * amt
                outR[i] += r * amt
                delayL[li] = 0
                delayR[ri] = 0
                let fl = (li + 11200) % delayL.count
                let fr = (ri + 13900) % delayR.count
                delayL[fl] += l * fb
                delayR[fr] += r * fb
            }
        }
        delayPos = (delayPos + n) % delayL.count
        delayPosR = (delayPosR + n) % delayR.count

        // master gain + underwater one-pole-ish lowpass (smoothed biquad)
        lowpassCur += (lowpassTarget - lowpassCur) * min(1, Double(n) / sampleRate * 10)
        let master = Float(masterGain)
        if lowpassCur < 19000 {
            let w0 = 2 * Double.pi * min(sampleRate * 0.45, lowpassCur) / sampleRate
            let alpha = Foundation.sin(w0) / 1.4142
            let cw = Foundation.cos(w0)
            let a0 = 1 + alpha
            let b0 = (1 - cw) / 2 / a0, b1 = (1 - cw) / a0, b2 = (1 - cw) / 2 / a0
            let a1 = -2 * cw / a0, a2 = (1 - alpha) / a0
            for i in 0..<n {
                let s = Double(outL[i] + outR[i]) * 0.5
                let y = b0 * s + lpZ1
                lpZ1 = b1 * s - a1 * y + lpZ2
                lpZ2 = b2 * s - a2 * y
                outL[i] = Float(y) * master
                outR[i] = Float(y) * master
            }
        } else {
            for i in 0..<n {
                outL[i] *= master
                outR[i] *= master
            }
        }

        // write back voice state, prune finished
        os_unfair_lock_lock(&lock)
        voices = local.filter { !$0.done }
        os_unfair_lock_unlock(&lock)
    }
}

// ---------------------------------------------------------------------------
// recipes — the full sound-effect registry
// ---------------------------------------------------------------------------
private struct VoiceSink {
    var voices: [Voice] = []
    let start: Double
    let pan: Double
    let gain: Double
    let reverbSend: Double

    init(start: Double, pan: Double, gain: Double, reverbSend: Double) {
        self.start = start
        self.pan = pan
        self.gain = gain
        self.reverbSend = reverbSend
    }

    mutating func noiseBurst(dur: Double, freq: Double, q: Double = 1, lowpass: Bool = false,
                             vol: Double = 0.8, attack: Double = 0.005, pitch: Double = 1, delay: Double = 0) {
        var v = Voice()
        v.isNoise = true
        v.dur = dur
        v.filterFreq = freq * pitch
        v.filterQ = q
        v.lowpassFilter = lowpass
        v.vol = vol
        v.attack = attack
        v.pitchRate = pitch
        v.start = start + delay
        v.pan = pan
        v.gain = gain
        v.reverbSend = reverbSend
        voices.append(v)
    }
    mutating func tone(freq: Double, endFreq: Double = 0, dur: Double, type: OscType = .sine,
                       vol: Double = 0.3, attack: Double = 0.01, vibrato: Double = 0, delay: Double = 0) {
        var v = Voice()
        v.freq = freq
        v.endFreq = endFreq
        v.dur = dur
        v.type = type
        v.vol = vol
        v.attack = attack
        v.vibrato = vibrato
        v.start = start + delay
        v.pan = pan
        v.gain = gain
        v.reverbSend = reverbSend
        voices.append(v)
    }
}

private struct SoundRecipe {
    let cat: String
    let subtitle: String?
    let build: (inout VoiceSink, Double, () -> Double) -> Void
}

private var RECIPES: [String: SoundRecipe] = [:]
private var recipesBuilt = false

private func R(_ name: String, _ cat: String, _ subtitle: String?,
               _ build: @escaping (inout VoiceSink, Double, () -> Double) -> Void) {
    RECIPES[name] = SoundRecipe(cat: cat, subtitle: subtitle, build: build)
}

private func mobVoice(_ name: String, _ cat: String, _ subtitle: String?, _ base: Double,
                      _ type: OscType, _ dur: Double, _ slide: Double, _ vib: Double = 0) {
    R(name, cat, subtitle) { s, pitch, _ in
        s.tone(freq: base * pitch, endFreq: base * slide * pitch, dur: dur, type: type, vol: 0.35, vibrato: vib)
    }
}

private func buildRecipes() {
    if recipesBuilt { return }
    recipesBuilt = true

    // material step/dig sounds
    let MATERIALS: [(String, Double, Double, Double)] = [
        ("stone", 800, 0.8, 0.1), ("deepslate", 600, 0.8, 0.11),
        ("wood", 450, 1.2, 0.12), ("grass", 1400, 0.5, 0.09),
        ("gravel", 1100, 0.4, 0.12), ("sand", 2200, 0.4, 0.1),
        ("snow", 1800, 0.4, 0.12), ("cloth", 900, 0.4, 0.1),
        ("glass", 2600, 3, 0.12), ("metal", 1300, 4, 0.14),
        ("slime", 500, 1, 0.18), ("honey", 400, 1, 0.2),
        ("netherrack", 700, 0.7, 0.1), ("soulsand", 500, 0.5, 0.16),
        ("bone", 1000, 2, 0.1), ("amethyst", 2200, 6, 0.25),
        ("sculk", 350, 1.5, 0.2), ("mud", 450, 0.5, 0.16),
        ("water", 1200, 0.6, 0.2), ("lava", 300, 0.6, 0.3),
        ("bamboo", 600, 2, 0.1), ("cherry", 500, 1.2, 0.12),
        ("copper", 1500, 3.5, 0.13), ("chain", 1700, 5, 0.16),
    ]
    for (mat, freq, q, dur) in MATERIALS {
        R("block.\(mat).break", "blocks", "Block broken") { s, pitch, _ in
            s.noiseBurst(dur: dur * 1.8, freq: freq * 0.8, q: q, vol: 0.7, pitch: pitch)
        }
        R("block.\(mat).place", "blocks", "Block placed") { s, pitch, _ in
            s.noiseBurst(dur: dur, freq: freq, q: q, vol: 0.6, pitch: pitch)
        }
        R("block.\(mat).step", "blocks", nil) { s, pitch, _ in
            s.noiseBurst(dur: dur * 0.7, freq: freq * 1.1, q: q, vol: 0.25, pitch: pitch)
        }
        R("block.\(mat).hit", "blocks", nil) { s, pitch, _ in
            s.noiseBurst(dur: dur * 0.5, freq: freq, q: q, vol: 0.3, pitch: pitch)
        }
    }

    // note block instruments
    let NOTE_BASE: [(String, OscType, Double)] = [
        ("harp", .sine, 1), ("bass", .triangle, 0.25), ("basedrum", .sine, 0.3),
        ("snare", .sine, 1), ("hat", .square, 2), ("guitar", .triangle, 0.5),
        ("flute", .sine, 2), ("bell", .sine, 4), ("chime", .sine, 4),
        ("xylophone", .sine, 2), ("iron_xylophone", .triangle, 1), ("cow_bell", .square, 1.5),
        ("didgeridoo", .sawtooth, 0.25), ("bit", .square, 1), ("banjo", .sawtooth, 1), ("pling", .sine, 1),
    ]
    for note in 0..<25 {
        for (inst, type, mult) in NOTE_BASE {
            R("note.\(inst).\(note)", "records", nil) { s, _, _ in
                let freq = 185 * mult * Foundation.pow(2, Double(note - 12) / 12)
                if inst == "snare" {
                    s.noiseBurst(dur: 0.15, freq: 2000, q: 0.5, vol: 0.5)
                } else if inst == "basedrum" {
                    s.tone(freq: 90, endFreq: 40, dur: 0.2, vol: 0.7)
                } else if inst == "hat" {
                    s.noiseBurst(dur: 0.05, freq: 6000, q: 1, vol: 0.3)
                } else {
                    s.tone(freq: freq, dur: inst == "bell" || inst == "chime" ? 1.2 : 0.6, type: type, vol: 0.4)
                    if inst == "pling" || inst == "harp" { s.tone(freq: freq * 2, dur: 0.3, vol: 0.1) }
                }
            }
        }
    }

    // generic events
    R("entity.item.pickup", "players", nil) { s, pitch, _ in
        s.tone(freq: 600 * pitch, endFreq: 1200 * pitch, dur: 0.1, vol: 0.25)
    }
    R("entity.player.levelup", "players", nil) { s, _, _ in
        for i in 0..<4 { s.tone(freq: 500 + Double(i) * 200, dur: 0.3, vol: 0.2, delay: Double(i) * 0.07) }
    }
    R("entity.experience_orb.pickup", "players", nil) { s, pitch, _ in
        s.tone(freq: 1200 * pitch, endFreq: 2200 * pitch, dur: 0.12, vol: 0.18)
    }
    R("entity.item.break", "players", "Item breaks") { s, _, _ in
        s.noiseBurst(dur: 0.18, freq: 1400, q: 2, vol: 0.5)
        s.tone(freq: 400, endFreq: 150, dur: 0.2, type: .square, vol: 0.2)
    }
    R("entity.generic.eat", "players", "Eating") { s, _, rng in
        for i in 0..<3 { s.noiseBurst(dur: 0.08, freq: 600 + rng() * 400, q: 1.5, vol: 0.4, delay: Double(i) * 0.09) }
    }
    R("entity.generic.drink", "players", "Drinking") { s, _, _ in
        for i in 0..<4 { s.tone(freq: 400 + Double(i) * 80, endFreq: 300, dur: 0.07, vol: 0.2, delay: Double(i) * 0.08) }
    }
    R("entity.player.burp", "players", "Burp") { s, _, _ in
        s.tone(freq: 180, endFreq: 90, dur: 0.25, type: .sawtooth, vol: 0.3)
    }
    R("entity.generic.explode", "blocks", "Explosion") { s, pitch, _ in
        s.noiseBurst(dur: 0.8, freq: 150, q: 0.3, lowpass: true, vol: 1.2, pitch: pitch)
        s.tone(freq: 100, endFreq: 30, dur: 0.6, vol: 0.8)
    }
    R("entity.generic.big_fall", "players", nil) { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 500, q: 0.6, vol: 0.5)
    }
    R("entity.generic.small_fall", "players", nil) { s, _, _ in
        s.noiseBurst(dur: 0.08, freq: 700, q: 0.6, vol: 0.3)
    }
    R("entity.player.attack.strong", "players", nil) { s, pitch, _ in
        s.noiseBurst(dur: 0.12, freq: 900, q: 0.6, vol: 0.4, pitch: pitch)
    }
    R("entity.player.attack.weak", "players", nil) { s, pitch, _ in
        s.noiseBurst(dur: 0.08, freq: 1200, q: 0.8, vol: 0.25, pitch: pitch)
    }
    R("entity.player.attack.crit", "players", "Critical hit") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 1600, q: 1.5, vol: 0.45)
        s.tone(freq: 800, endFreq: 1400, dur: 0.1, vol: 0.2)
    }
    R("entity.player.attack.sweep", "players", nil) { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 2400, q: 0.7, vol: 0.3, attack: 0.04)
    }
    R("entity.player.death", "players", "Player dies") { s, _, _ in
        s.tone(freq: 400, endFreq: 100, dur: 0.5, type: .square, vol: 0.3)
    }
    R("entity.player.hurt", "players", "Player hurts") { s, _, _ in
        s.tone(freq: 350, endFreq: 220, dur: 0.18, type: .square, vol: 0.25)
    }

    // mob voices
    mobVoice("entity.cow.ambient", "friendly", "Cow moos", 160, .sawtooth, 0.6, 0.75, 5)
    mobVoice("entity.cow.hurt", "friendly", "Cow hurts", 200, .sawtooth, 0.3, 0.7)
    mobVoice("entity.cow.death", "friendly", "Cow dies", 180, .sawtooth, 0.5, 0.5)
    R("entity.cow.milk", "friendly", "Cow gets milked") { s, _, _ in
        for i in 0..<2 { s.noiseBurst(dur: 0.1, freq: 900, q: 1, vol: 0.3, delay: Double(i) * 0.12) }
    }
    mobVoice("entity.pig.ambient", "friendly", "Pig oinks", 320, .square, 0.18, 1.3)
    mobVoice("entity.pig.hurt", "friendly", "Pig hurts", 380, .square, 0.25, 1.4)
    mobVoice("entity.pig.death", "friendly", "Pig dies", 350, .square, 0.4, 0.6)
    mobVoice("entity.sheep.ambient", "friendly", "Sheep baahs", 420, .sawtooth, 0.5, 0.95, 9)
    mobVoice("entity.sheep.hurt", "friendly", "Sheep hurts", 460, .sawtooth, 0.3, 0.9, 9)
    mobVoice("entity.sheep.death", "friendly", "Sheep dies", 420, .sawtooth, 0.45, 0.6, 9)
    R("entity.sheep.shear", "friendly", "Shears click") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 3000, q: 2, vol: 0.4)
    }
    mobVoice("entity.chicken.ambient", "friendly", "Chicken clucks", 700, .square, 0.12, 1.25)
    mobVoice("entity.chicken.hurt", "friendly", "Chicken hurts", 800, .square, 0.15, 1.3)
    mobVoice("entity.chicken.death", "friendly", "Chicken dies", 750, .square, 0.3, 0.6)
    R("entity.chicken.egg", "friendly", "Chicken plops") { s, _, _ in
        s.tone(freq: 500, endFreq: 900, dur: 0.1, vol: 0.25)
    }
    mobVoice("entity.zombie.ambient", "hostile", "Zombie groans", 140, .sawtooth, 0.7, 0.8, 3)
    mobVoice("entity.zombie.hurt", "hostile", "Zombie hurts", 160, .sawtooth, 0.3, 0.75, 3)
    mobVoice("entity.zombie.death", "hostile", "Zombie dies", 150, .sawtooth, 0.6, 0.5, 3)
    mobVoice("entity.husk.ambient", "hostile", "Husk groans", 120, .sawtooth, 0.7, 0.8, 3)
    mobVoice("entity.drowned.ambient", "hostile", "Drowned gurgles", 130, .sawtooth, 0.6, 0.7, 8)
    R("entity.skeleton.ambient", "hostile", "Skeleton rattles") { s, _, rng in
        for i in 0..<4 { s.noiseBurst(dur: 0.05, freq: 1800 + rng() * 800, q: 4, vol: 0.3, delay: Double(i) * 0.06) }
    }
    R("entity.skeleton.hurt", "hostile", "Skeleton hurts") { s, _, _ in
        s.noiseBurst(dur: 0.1, freq: 1500, q: 3, vol: 0.4)
    }
    R("entity.skeleton.death", "hostile", "Skeleton dies") { s, _, rng in
        for i in 0..<6 { s.noiseBurst(dur: 0.06, freq: 1400 + rng() * 1000, q: 4, vol: 0.35, delay: Double(i) * 0.05) }
    }
    R("entity.skeleton.shoot", "hostile", "Arrow fired") { s, _, _ in
        s.noiseBurst(dur: 0.12, freq: 2000, q: 1, vol: 0.35)
    }
    R("entity.creeper.primed", "hostile", "Creeper hisses") { s, _, _ in
        s.noiseBurst(dur: 1.4, freq: 3500, q: 0.4, vol: 0.5, attack: 0.3)
    }
    mobVoice("entity.creeper.hurt", "hostile", "Creeper hurts", 300, .triangle, 0.2, 0.7)
    mobVoice("entity.creeper.death", "hostile", "Creeper dies", 280, .triangle, 0.4, 0.5)
    R("entity.spider.ambient", "hostile", "Spider hisses") { s, _, _ in
        s.noiseBurst(dur: 0.3, freq: 2600, q: 1.2, vol: 0.3)
    }
    mobVoice("entity.spider.hurt", "hostile", "Spider hurts", 900, .square, 0.15, 0.8)
    mobVoice("entity.spider.death", "hostile", "Spider dies", 800, .square, 0.35, 0.5)
    R("entity.enderman.ambient", "hostile", "Enderman vwoops") { s, pitch, _ in
        s.tone(freq: 90 * pitch, endFreq: 50 * pitch, dur: 0.8, vol: 0.4, vibrato: 2)
        s.tone(freq: 180 * pitch, endFreq: 80, dur: 0.6, type: .triangle, vol: 0.15)
    }
    R("entity.enderman.teleport", "hostile", "Enderman teleports") { s, _, _ in
        s.tone(freq: 1800, endFreq: 200, dur: 0.3, vol: 0.35)
    }
    R("entity.enderman.stare", "hostile", "Enderman cries out") { s, _, _ in
        s.tone(freq: 600, endFreq: 100, dur: 1.0, type: .sawtooth, vol: 0.4, vibrato: 6)
    }
    mobVoice("entity.enderman.hurt", "hostile", "Enderman hurts", 200, .sine, 0.3, 0.5)
    mobVoice("entity.enderman.death", "hostile", "Enderman dies", 160, .sine, 0.7, 0.3)
    R("entity.ghast.ambient", "hostile", "Ghast cries") { s, pitch, _ in
        s.tone(freq: 700 * pitch, endFreq: 400 * pitch, dur: 1.2, vol: 0.35, vibrato: 4)
    }
    R("entity.ghast.warn", "hostile", "Ghast shrieks") { s, _, _ in
        s.tone(freq: 500, endFreq: 1200, dur: 0.5, type: .sawtooth, vol: 0.4)
    }
    R("entity.ghast.shoot", "hostile", "Fireball whooshes") { s, _, _ in
        s.noiseBurst(dur: 0.4, freq: 800, q: 0.5, vol: 0.5)
    }
    mobVoice("entity.ghast.hurt", "hostile", "Ghast hurts", 800, .sine, 0.4, 1.3, 6)
    mobVoice("entity.ghast.death", "hostile", "Ghast dies", 700, .sine, 1.0, 0.4, 6)
    mobVoice("entity.blaze.ambient", "hostile", "Blaze breathes", 200, .sawtooth, 0.5, 1.1, 12)
    R("entity.blaze.shoot", "hostile", "Blaze shoots") { s, _, _ in
        s.noiseBurst(dur: 0.25, freq: 1200, q: 0.6, vol: 0.45)
    }
    mobVoice("entity.blaze.hurt", "hostile", "Blaze hurts", 300, .sawtooth, 0.25, 0.8, 10)
    mobVoice("entity.blaze.death", "hostile", "Blaze dies", 260, .sawtooth, 0.5, 0.4, 10)
    mobVoice("entity.slime.jump", "hostile", "Slime squishes", 250, .sine, 0.15, 0.6)
    mobVoice("entity.slime.hurt", "hostile", "Slime hurts", 280, .sine, 0.15, 0.5)
    mobVoice("entity.slime.death", "hostile", "Slime dies", 240, .sine, 0.25, 0.4)
    mobVoice("entity.witch.ambient", "hostile", "Witch giggles", 500, .square, 0.4, 1.4, 10)
    R("entity.witch.throw", "hostile", "Witch throws") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 1400, q: 1, vol: 0.3)
    }
    R("entity.witch.drink", "hostile", "Witch drinks") { s, _, _ in
        for i in 0..<3 { s.tone(freq: 450, endFreq: 350, dur: 0.07, vol: 0.2, delay: Double(i) * 0.09) }
    }
    mobVoice("entity.witch.hurt", "hostile", "Witch hurts", 550, .square, 0.25, 0.8)
    mobVoice("entity.witch.death", "hostile", "Witch dies", 500, .square, 0.5, 0.4)
    mobVoice("entity.wolf.ambient", "friendly", "Wolf pants", 600, .sawtooth, 0.12, 1.1)
    mobVoice("entity.wolf.hurt", "friendly", "Wolf yelps", 800, .sawtooth, 0.2, 1.5)
    mobVoice("entity.wolf.death", "friendly", "Wolf whines", 700, .sawtooth, 0.6, 0.4, 6)
    mobVoice("entity.cat.ambient", "friendly", "Cat meows", 700, .sine, 0.45, 1.3, 7)
    mobVoice("entity.cat.hurt", "friendly", "Cat hisses", 900, .sawtooth, 0.25, 1.1)
    mobVoice("entity.villager.ambient", "friendly", "Villager mumbles", 280, .sawtooth, 0.35, 1.2, 4)
    mobVoice("entity.villager.yes", "friendly", "Villager agrees", 280, .sawtooth, 0.3, 1.5, 4)
    mobVoice("entity.villager.no", "friendly", "Villager disagrees", 300, .sawtooth, 0.35, 0.7, 4)
    mobVoice("entity.villager.trade", "friendly", nil, 280, .sawtooth, 0.3, 1.3, 4)
    mobVoice("entity.villager.hurt", "friendly", "Villager hurts", 320, .sawtooth, 0.25, 0.8, 4)
    mobVoice("entity.villager.death", "friendly", "Villager dies", 280, .sawtooth, 0.5, 0.5, 4)
    mobVoice("entity.villager.work", "friendly", nil, 350, .square, 0.1, 1.1)
    mobVoice("entity.iron_golem.attack", "friendly", "Iron Golem attacks", 150, .square, 0.25, 0.6)
    R("entity.iron_golem.repair", "friendly", "Iron Golem repaired") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 1600, q: 3, vol: 0.4)
    }
    mobVoice("entity.zombified_piglin.angry", "hostile", "Zombified Piglin angers", 350, .sawtooth, 0.4, 1.4, 8)
    mobVoice("entity.piglin.admiring_item", "hostile", "Piglin admires item", 400, .square, 0.3, 1.3, 5)
    mobVoice("entity.warden.ambient", "hostile", "Warden whines", 60, .sawtooth, 1.0, 0.8, 2)
    R("entity.warden.heartbeat", "hostile", "Warden's heart beats") { s, _, _ in
        s.tone(freq: 55, endFreq: 35, dur: 0.18, vol: 0.7)
        s.tone(freq: 50, endFreq: 32, dur: 0.15, vol: 0.5, delay: 0.2)
    }
    R("entity.warden.sonic_boom", "hostile", "Sonic boom") { s, _, _ in
        s.tone(freq: 120, endFreq: 60, dur: 0.7, type: .sawtooth, vol: 0.8)
        s.noiseBurst(dur: 0.5, freq: 400, q: 0.4, vol: 0.6)
    }
    R("entity.warden.sonic_charge", "hostile", "Warden charges") { s, _, _ in
        s.tone(freq: 80, endFreq: 300, dur: 0.5, type: .sawtooth, vol: 0.4)
    }
    R("entity.warden.emerge", "hostile", "Warden emerges") { s, _, _ in
        s.noiseBurst(dur: 1.2, freq: 200, q: 0.4, lowpass: true, vol: 0.7)
        s.tone(freq: 50, endFreq: 90, dur: 1.2, type: .sawtooth, vol: 0.5)
    }
    R("entity.warden.dig", "hostile", nil) { s, _, _ in
        s.noiseBurst(dur: 0.3, freq: 350, q: 0.5, vol: 0.4)
    }
    R("entity.warden.sniff", "hostile", "Warden sniffs") { s, _, _ in
        s.noiseBurst(dur: 0.4, freq: 500, q: 0.6, vol: 0.3, attack: 0.15)
    }
    R("entity.warden.listening", "hostile", "Warden takes notice") { s, _, _ in
        s.tone(freq: 200, endFreq: 150, dur: 0.4, vol: 0.3, vibrato: 4)
    }
    R("entity.warden.angry", "hostile", "Warden roars") { s, _, _ in
        s.tone(freq: 90, endFreq: 140, dur: 0.9, type: .sawtooth, vol: 0.7, vibrato: 8)
    }
    R("entity.ender_dragon.growl", "hostile", "Dragon roars") { s, _, _ in
        s.tone(freq: 110, endFreq: 70, dur: 1.4, type: .sawtooth, vol: 0.8, vibrato: 6)
        s.noiseBurst(dur: 1.2, freq: 350, q: 0.5, vol: 0.4)
    }
    mobVoice("entity.ender_dragon.hurt", "hostile", "Dragon hurts", 180, .sawtooth, 0.5, 0.6, 6)
    R("entity.ender_dragon.death", "hostile", "Dragon dies") { s, _, _ in
        s.tone(freq: 200, endFreq: 40, dur: 3.0, type: .sawtooth, vol: 0.8, vibrato: 4)
    }
    R("entity.ender_dragon.shoot", "hostile", "Dragon shoots") { s, _, _ in
        s.noiseBurst(dur: 0.3, freq: 900, q: 0.6, vol: 0.5)
    }
    R("entity.wither.spawn", "hostile", "Wither released") { s, _, _ in
        s.tone(freq: 60, endFreq: 220, dur: 1.5, type: .sawtooth, vol: 0.7)
        s.noiseBurst(dur: 1.5, freq: 300, q: 0.4, vol: 0.5)
    }
    mobVoice("entity.wither.ambient", "hostile", "Wither angers", 220, .sawtooth, 0.5, 0.7, 10)
    R("entity.wither.shoot", "hostile", "Wither attacks") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 1000, q: 0.8, vol: 0.45)
    }
    R("entity.wither.break_block", "hostile", nil) { s, _, _ in
        s.noiseBurst(dur: 0.25, freq: 600, q: 0.6, vol: 0.4)
    }
    mobVoice("entity.bat.ambient", "ambient", "Bat squeaks", 2400, .square, 0.08, 1.3)
    mobVoice("entity.bee.ambient", "friendly", "Bee buzzes", 220, .sawtooth, 0.4, 1.05, 25)
    mobVoice("entity.fox.ambient", "friendly", "Fox squeaks", 800, .square, 0.2, 1.4)
    mobVoice("entity.frog.ambient", "friendly", "Frog croaks", 180, .square, 0.2, 0.8, 14)
    R("entity.frog.eat", "friendly", "Frog eats") { s, _, _ in
        s.tone(freq: 500, endFreq: 200, dur: 0.15, vol: 0.3)
    }
    mobVoice("entity.goat.ambient", "friendly", "Goat bleats", 500, .sawtooth, 0.4, 1.1, 12)
    R("entity.goat.ram_impact", "friendly", "Goat rams") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 500, q: 0.6, vol: 0.5)
    }
    mobVoice("entity.horse.ambient", "friendly", "Horse neighs", 400, .sawtooth, 0.6, 1.3, 10)
    mobVoice("entity.parrot.ambient", "friendly", "Parrot talks", 1200, .square, 0.2, 1.4, 8)
    mobVoice("entity.dolphin.ambient", "friendly", "Dolphin chirps", 1800, .sine, 0.2, 1.6, 12)
    mobVoice("entity.axolotl.ambient", "friendly", "Axolotl chirps", 900, .sine, 0.12, 1.3)
    mobVoice("entity.allay.ambient", "friendly", "Allay hums", 900, .sine, 0.4, 1.2, 6)
    R("entity.allay.item_given", "friendly", "Allay chortles") { s, _, _ in
        for i in 0..<3 { s.tone(freq: 800 + Double(i) * 200, dur: 0.15, vol: 0.2, delay: Double(i) * 0.08) }
    }
    R("entity.allay.item_taken", "friendly", nil) { s, _, _ in
        s.tone(freq: 1000, endFreq: 1400, dur: 0.15, vol: 0.2)
    }
    mobVoice("entity.shulker.shoot", "hostile", "Shulker shoots", 600, .sine, 0.2, 1.4)
    mobVoice("entity.shulker.teleport", "hostile", "Shulker teleports", 1200, .sine, 0.25, 0.4)
    mobVoice("entity.phantom.swoop", "hostile", "Phantom swoops", 1400, .sawtooth, 0.4, 0.5)
    mobVoice("entity.guardian.attack", "hostile", "Guardian charges", 300, .sawtooth, 0.8, 1.6, 4)
    mobVoice("entity.elder_guardian.curse", "hostile", "Elder Guardian curses", 200, .sine, 1.2, 0.5, 3)
    mobVoice("entity.ravager.roar", "hostile", "Ravager roars", 130, .sawtooth, 0.8, 0.7, 7)
    mobVoice("entity.evoker.cast_spell", "hostile", "Evoker casts spell", 600, .square, 0.4, 0.8, 9)
    mobVoice("entity.evoker.prepare_summon", "hostile", "Evoker prepares summoning", 400, .square, 0.6, 1.4, 9)
    R("entity.evoker_fangs.attack", "hostile", "Fangs snap") { s, _, _ in
        s.noiseBurst(dur: 0.12, freq: 800, q: 1.5, vol: 0.4)
    }
    mobVoice("entity.vex.ambient", "hostile", "Vex vexes", 1000, .square, 0.25, 1.3, 14)
    mobVoice("entity.pillager.ambient", "hostile", "Pillager murmurs", 250, .sawtooth, 0.4, 0.9, 3)
    mobVoice("entity.vindicator.ambient", "hostile", "Vindicator mutters", 230, .sawtooth, 0.4, 0.85, 3)
    R("entity.turtle.egg_crack", "friendly", "Egg cracks") { s, _, _ in
        s.noiseBurst(dur: 0.08, freq: 2000, q: 3, vol: 0.3)
    }
    R("entity.turtle.egg_hatch", "friendly", "Egg hatches") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 1800, q: 2, vol: 0.35)
    }
    R("entity.sniffer.digging", "friendly", "Sniffer digs") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 400, q: 0.5, vol: 0.35)
    }
    R("entity.sniffer.egg_hatch", "friendly", "Sniffer hatches") { s, _, _ in
        s.noiseBurst(dur: 0.3, freq: 1200, q: 1.5, vol: 0.4)
    }
    R("entity.sniffer.egg_crack", "friendly", "Egg cracks") { s, _, _ in
        s.noiseBurst(dur: 0.1, freq: 1800, q: 2, vol: 0.3)
    }
    mobVoice("entity.camel.dash", "friendly", "Camel dashes", 300, .sawtooth, 0.3, 1.3, 6)
    mobVoice("entity.goat.milk", "friendly", nil, 500, .sine, 0.2, 1.1)
    mobVoice("entity.mooshroom.milk", "friendly", nil, 400, .sine, 0.25, 1.1)
    mobVoice("entity.mooshroom.shear", "friendly", "Mooshroom transforms", 600, .sine, 0.3, 1.4)
    mobVoice("entity.cod.flop", "friendly", "Fish flops", 700, .sine, 0.1, 1.4)
    mobVoice("entity.llama.spit", "friendly", "Llama spits", 900, .square, 0.12, 0.7)
    mobVoice("entity.strider.ambient", "friendly", "Strider chirps", 500, .square, 0.3, 1.5, 18)
    mobVoice("entity.zombie_villager.cure", "friendly", "Zombie Villager sizzles", 300, .sawtooth, 0.8, 1.6, 12)
    mobVoice("entity.hoglin.ambient", "hostile", "Hoglin growls", 200, .sawtooth, 0.4, 0.8, 8)
    mobVoice("entity.horse.angry", "friendly", "Horse neighs", 450, .sawtooth, 0.5, 1.5, 12)
    R("entity.horse.saddle", "friendly", nil) { s, _, _ in
        s.noiseBurst(dur: 0.12, freq: 1100, q: 1, vol: 0.3)
    }
    R("entity.pig.saddle", "friendly", nil) { s, _, _ in
        s.noiseBurst(dur: 0.12, freq: 1100, q: 1, vol: 0.3)
    }

    // projectiles & misc
    R("entity.arrow.shoot", "players", "Arrow fired") { s, pitch, _ in
        s.noiseBurst(dur: 0.12, freq: 1800, q: 1, vol: 0.35, pitch: pitch)
    }
    R("entity.arrow.hit", "players", "Arrow hits") { s, _, _ in
        s.noiseBurst(dur: 0.06, freq: 2400, q: 2, vol: 0.3)
    }
    R("entity.arrow.hit_player", "players", "Arrow hits") { s, _, _ in
        s.tone(freq: 1200, endFreq: 600, dur: 0.08, vol: 0.3)
    }
    R("entity.snowball.throw", "players", nil) { s, _, _ in
        s.noiseBurst(dur: 0.1, freq: 1500, q: 0.8, vol: 0.25)
    }
    R("entity.fishing_bobber.throw", "players", nil) { s, _, _ in
        s.noiseBurst(dur: 0.1, freq: 1400, q: 1, vol: 0.25)
    }
    R("entity.fishing_bobber.splash", "players", "Fish bites") { s, _, _ in
        s.noiseBurst(dur: 0.25, freq: 1000, q: 0.5, vol: 0.45)
    }
    R("entity.tnt.primed", "blocks", "TNT fizzes") { s, _, _ in
        s.noiseBurst(dur: 0.5, freq: 3000, q: 0.4, vol: 0.4)
    }
    R("entity.lightning_bolt.thunder", "ambient", "Thunder roars") { s, pitch, _ in
        s.noiseBurst(dur: 2.2, freq: 120, q: 0.3, lowpass: true, vol: 1.1, attack: 0.02, pitch: pitch)
    }
    R("entity.lightning_bolt.impact", "ambient", "Lightning strikes") { s, _, _ in
        s.noiseBurst(dur: 0.4, freq: 4000, q: 0.3, vol: 0.7)
    }
    R("entity.firework_rocket.launch", "ambient", "Firework launches") { s, _, _ in
        s.noiseBurst(dur: 0.5, freq: 2200, q: 0.5, vol: 0.4, attack: 0.05)
    }
    R("entity.firework_rocket.blast", "ambient", "Firework blasts") { s, _, _ in
        s.noiseBurst(dur: 0.4, freq: 600, q: 0.5, vol: 0.6)
        s.noiseBurst(dur: 0.3, freq: 2400, q: 1, vol: 0.3, delay: 0.06)
    }
    R("entity.ender_eye.launch", "players", "Eye of Ender shoots") { s, _, _ in
        s.tone(freq: 600, endFreq: 1400, dur: 0.4, vol: 0.3)
    }
    R("entity.ender_eye.death", "players", "Eye of Ender breaks") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 2200, q: 2, vol: 0.35)
    }
    R("item.totem.use", "players", "Totem activates") { s, _, _ in
        for i in 0..<5 { s.tone(freq: 600 + Double(i) * 150, dur: 0.4, vol: 0.25, delay: Double(i) * 0.06) }
    }
    R("item.trident.throw", "players", "Trident clangs") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 1600, q: 2, vol: 0.4)
    }
    R("item.trident.hit_ground", "players", "Trident vibrates") { s, _, _ in
        s.tone(freq: 800, endFreq: 600, dur: 0.3, type: .triangle, vol: 0.3, vibrato: 20)
    }
    R("item.trident.riptide_1", "players", "Trident zooms") { s, _, _ in
        s.noiseBurst(dur: 0.5, freq: 1200, q: 0.5, vol: 0.5)
    }
    R("item.flintandsteel.use", "blocks", "Flint and Steel click") { s, _, _ in
        s.noiseBurst(dur: 0.07, freq: 3000, q: 3, vol: 0.4)
    }
    R("item.bucket.fill", "blocks", "Bucket fills") { s, _, _ in
        s.tone(freq: 500, endFreq: 900, dur: 0.25, vol: 0.3)
        s.noiseBurst(dur: 0.2, freq: 1200, q: 0.7, vol: 0.25)
    }
    R("item.bucket.empty", "blocks", "Bucket empties") { s, _, _ in
        s.tone(freq: 900, endFreq: 400, dur: 0.3, vol: 0.3)
        s.noiseBurst(dur: 0.3, freq: 1000, q: 0.6, vol: 0.3)
    }
    R("item.bucket.fill_lava", "blocks", nil) { s, _, _ in
        s.noiseBurst(dur: 0.3, freq: 400, q: 0.6, vol: 0.4)
    }
    R("item.bucket.empty_lava", "blocks", nil) { s, _, _ in
        s.noiseBurst(dur: 0.35, freq: 350, q: 0.6, vol: 0.4)
    }
    R("item.bucket.fill_fish", "friendly", "Fish captured") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 1100, q: 0.7, vol: 0.35)
    }
    R("item.bottle.fill", "blocks", "Bottle fills") { s, _, _ in
        s.tone(freq: 700, endFreq: 1300, dur: 0.2, vol: 0.25)
    }
    R("item.hoe.till", "blocks", "Hoe tills") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 900, q: 0.6, vol: 0.4)
    }
    R("item.shovel.flatten", "blocks", "Shovel flattens") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 1000, q: 0.6, vol: 0.4)
    }
    R("item.axe.strip", "blocks", "Axe strips") { s, _, _ in
        s.noiseBurst(dur: 0.18, freq: 700, q: 0.9, vol: 0.45)
    }
    R("item.axe.scrape", "blocks", "Axe scrapes") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 1800, q: 1.5, vol: 0.4)
    }
    R("item.armor.equip_generic", "players", "Gear equips") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 1100, q: 1, vol: 0.3)
    }
    R("item.armor.equip_elytra", "players", "Gear equips") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 1100, q: 1, vol: 0.3)
    }
    R("item.chorus_fruit.teleport", "players", "Player teleports") { s, _, _ in
        s.tone(freq: 1600, endFreq: 300, dur: 0.3, vol: 0.3)
    }
    R("item.goat_horn.sound", "records", "Goat horn sounds") { s, _, _ in
        s.tone(freq: 311, dur: 1.8, type: .sawtooth, vol: 0.35, vibrato: 3)
        s.tone(freq: 466, dur: 1.8, vol: 0.15)
    }
    R("item.brush.brushing", "blocks", "Brushing") { s, _, _ in
        s.noiseBurst(dur: 0.25, freq: 1900, q: 0.7, vol: 0.3)
    }

    // blocks & machines
    R("block.chest.open", "blocks", "Chest opens") { s, _, _ in
        s.tone(freq: 200, endFreq: 350, dur: 0.3, type: .triangle, vol: 0.3)
        s.noiseBurst(dur: 0.2, freq: 600, q: 0.8, vol: 0.2)
    }
    R("block.chest.close", "blocks", "Chest closes") { s, _, _ in
        s.tone(freq: 350, endFreq: 180, dur: 0.2, type: .triangle, vol: 0.3)
    }
    R("block.barrel.open", "blocks", "Barrel opens") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 500, q: 1, vol: 0.3)
    }
    R("block.ender_chest.open", "blocks", "Ender Chest opens") { s, _, _ in
        s.tone(freq: 300, endFreq: 600, dur: 0.4, vol: 0.3)
    }
    R("block.wooden_door.open", "blocks", "Door creaks") { s, _, rng in
        s.noiseBurst(dur: 0.15, freq: 400 + rng() * 200, q: 2, vol: 0.4)
    }
    R("block.wooden_door.close", "blocks", "Door slams") { s, _, _ in
        s.noiseBurst(dur: 0.12, freq: 350, q: 1.5, vol: 0.4)
    }
    R("block.wooden_trapdoor.open", "blocks", "Trapdoor creaks") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 450, q: 2, vol: 0.4)
    }
    R("block.wooden_trapdoor.close", "blocks", "Trapdoor slams") { s, _, _ in
        s.noiseBurst(dur: 0.12, freq: 380, q: 1.5, vol: 0.4)
    }
    R("block.fence_gate.open", "blocks", "Gate creaks") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 500, q: 2, vol: 0.35)
    }
    R("block.fence_gate.close", "blocks", "Gate slams") { s, _, _ in
        s.noiseBurst(dur: 0.12, freq: 420, q: 1.5, vol: 0.35)
    }
    R("block.lever.click", "blocks", "Lever clicks") { s, pitch, _ in
        s.noiseBurst(dur: 0.05, freq: 1400 * pitch, q: 4, vol: 0.35)
    }
    R("block.stone_button.click_on", "blocks", "Button clicks") { s, _, _ in
        s.noiseBurst(dur: 0.05, freq: 1600, q: 4, vol: 0.3)
    }
    R("block.stone_button.click_off", "blocks", nil) { s, _, _ in
        s.noiseBurst(dur: 0.05, freq: 1300, q: 4, vol: 0.25)
    }
    R("block.stone_pressure_plate.click_on", "blocks", nil) { s, _, _ in
        s.noiseBurst(dur: 0.05, freq: 1200, q: 3, vol: 0.25)
    }
    R("block.stone_pressure_plate.click_off", "blocks", nil) { s, _, _ in
        s.noiseBurst(dur: 0.05, freq: 1000, q: 3, vol: 0.2)
    }
    R("block.piston.extend", "blocks", "Piston moves") { s, _, _ in
        s.noiseBurst(dur: 0.18, freq: 700, q: 0.8, vol: 0.4)
        s.tone(freq: 300, endFreq: 500, dur: 0.15, type: .triangle, vol: 0.2)
    }
    R("block.piston.contract", "blocks", "Piston moves") { s, _, _ in
        s.noiseBurst(dur: 0.18, freq: 600, q: 0.8, vol: 0.4)
        s.tone(freq: 500, endFreq: 300, dur: 0.15, type: .triangle, vol: 0.2)
    }
    R("block.comparator.click", "blocks", nil) { s, pitch, _ in
        s.noiseBurst(dur: 0.04, freq: 1800 * pitch, q: 5, vol: 0.25)
    }
    R("block.dispenser.dispense", "blocks", "Dispensed item") { s, _, _ in
        s.noiseBurst(dur: 0.1, freq: 1100, q: 1, vol: 0.35)
    }
    R("block.dispenser.fail", "blocks", nil) { s, _, _ in
        s.noiseBurst(dur: 0.08, freq: 700, q: 2, vol: 0.3)
    }
    R("block.furnace.fire_crackle", "blocks", "Fire crackles") { s, _, rng in
        for _ in 0..<3 { s.noiseBurst(dur: 0.05, freq: 2500 + rng() * 2000, q: 2, vol: 0.15, delay: rng() * 0.2) }
    }
    R("block.portal.trigger", "blocks", "Portal whooshes") { s, _, _ in
        s.tone(freq: 150, endFreq: 700, dur: 1.2, vol: 0.4, vibrato: 5)
    }
    R("block.portal.ambient", "ambient", "Portal whooshes") { s, _, rng in
        s.tone(freq: 100 + rng() * 100, endFreq: 250, dur: 1.5, vol: 0.2, vibrato: 3)
    }
    R("block.portal.travel", "ambient", "Portal noise fades") { s, _, _ in
        s.tone(freq: 700, endFreq: 120, dur: 1.0, vol: 0.4, vibrato: 6)
    }
    R("block.end_portal.spawn", "ambient", "End portal opens") { s, _, _ in
        s.tone(freq: 80, endFreq: 800, dur: 2, vol: 0.5)
    }
    R("block.end_portal_frame.fill", "blocks", "Eye of Ender attaches") { s, _, _ in
        s.tone(freq: 800, endFreq: 1400, dur: 0.3, vol: 0.35)
    }
    R("block.brewing_stand.brew", "blocks", "Brewing Stand bubbles") { s, _, rng in
        for i in 0..<4 { s.tone(freq: 600 + rng() * 600, endFreq: 1200, dur: 0.1, vol: 0.2, delay: Double(i) * 0.08) }
    }
    R("block.enchantment_table.use", "blocks", "Enchanting") { s, _, rng in
        for i in 0..<4 { s.tone(freq: 900 + rng() * 800, dur: 0.3, vol: 0.2, delay: Double(i) * 0.09) }
    }
    R("block.anvil.use", "blocks", "Anvil used") { s, _, _ in
        s.tone(freq: 1100, dur: 0.5, type: .square, vol: 0.3)
        s.noiseBurst(dur: 0.15, freq: 1800, q: 4, vol: 0.4)
    }
    R("block.anvil.land", "blocks", "Anvil lands") { s, _, _ in
        s.tone(freq: 900, dur: 0.6, type: .square, vol: 0.4)
    }
    R("block.anvil.destroy", "blocks", "Anvil destroyed") { s, _, _ in
        s.noiseBurst(dur: 0.4, freq: 800, q: 0.7, vol: 0.5)
    }
    R("block.grindstone.use", "blocks", "Grindstone used") { s, _, _ in
        s.noiseBurst(dur: 0.4, freq: 1500, q: 1.5, vol: 0.4)
    }
    R("block.smithing_table.use", "blocks", "Smithing Table used") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 1300, q: 2, vol: 0.4)
    }
    R("ui.stonecutter.take_result", "blocks", "Stonecutter used") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 2400, q: 1.5, vol: 0.35)
    }
    R("ui.stonecutter.select_recipe", "ui", nil) { s, _, _ in
        s.noiseBurst(dur: 0.05, freq: 1600, q: 3, vol: 0.2)
    }
    R("block.bell.use", "blocks", "Bell rings") { s, _, _ in
        s.tone(freq: 932, dur: 2.2, vol: 0.4)
        s.tone(freq: 1864, dur: 1.4, vol: 0.15)
    }
    R("block.campfire.crackle", "blocks", "Campfire crackles") { s, _, rng in
        s.noiseBurst(dur: 0.06, freq: 3000 + rng() * 1500, q: 2, vol: 0.2)
    }
    R("block.fire.extinguish", "blocks", "Fire extinguishes") { s, _, _ in
        s.noiseBurst(dur: 0.25, freq: 3500, q: 0.5, vol: 0.4)
    }
    R("block.respawn_anchor.charge", "blocks", "Respawn Anchor charges") { s, _, _ in
        s.tone(freq: 400, endFreq: 900, dur: 0.4, vol: 0.35)
    }
    R("block.respawn_anchor.set_spawn", "blocks", "Respawn point set") { s, _, _ in
        s.tone(freq: 600, endFreq: 1200, dur: 0.3, vol: 0.3)
    }
    R("block.amethyst_cluster.step", "blocks", "Amethyst chimes") { s, _, rng in
        s.tone(freq: 1800 + rng() * 1200, dur: 0.4, vol: 0.2)
    }
    R("block.sculk_sensor.clicking", "blocks", "Sculk Sensor clicks") { s, _, _ in
        for i in 0..<3 { s.tone(freq: 500 - Double(i) * 80, dur: 0.06, type: .square, vol: 0.25, delay: Double(i) * 0.05) }
    }
    R("block.sculk_shrieker.shriek", "hostile", "Sculk Shrieker shrieks") { s, _, _ in
        s.tone(freq: 300, endFreq: 900, dur: 0.8, type: .sawtooth, vol: 0.5, vibrato: 15)
    }
    R("block.sculk_catalyst.bloom", "blocks", "Sculk blooms") { s, _, _ in
        s.tone(freq: 250, endFreq: 120, dur: 0.6, vol: 0.3, vibrato: 8)
    }
    R("block.beacon.power_select", "blocks", "Beacon hums") { s, _, _ in
        s.tone(freq: 500, endFreq: 1000, dur: 0.8, vol: 0.3)
    }
    R("block.conduit.ambient", "ambient", "Conduit pulses") { s, _, _ in
        s.tone(freq: 250, endFreq: 350, dur: 0.6, vol: 0.15, vibrato: 4)
    }
    R("block.spawner.spawn", "hostile", "Mob spawns") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 900, q: 1.2, vol: 0.35)
    }
    R("block.composter.fill", "blocks", nil) { s, _, _ in
        s.noiseBurst(dur: 0.12, freq: 800, q: 0.7, vol: 0.3)
    }
    R("block.composter.fill_success", "blocks", "Composter fills") { s, _, _ in
        s.noiseBurst(dur: 0.15, freq: 900, q: 0.7, vol: 0.35)
    }
    R("block.composter.empty", "blocks", "Composter empties") { s, _, _ in
        s.noiseBurst(dur: 0.18, freq: 700, q: 0.7, vol: 0.35)
    }
    R("block.beehive.shear", "blocks", "Scraping") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 2200, q: 1.5, vol: 0.4)
    }
    R("block.pumpkin.carve", "blocks", "Carving") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 1000, q: 1, vol: 0.4)
    }
    R("block.chiseled_bookshelf.insert", "blocks", "Book placed") { s, _, _ in
        s.noiseBurst(dur: 0.1, freq: 600, q: 1, vol: 0.3)
    }
    R("block.chiseled_bookshelf.pickup", "blocks", "Book taken") { s, _, _ in
        s.noiseBurst(dur: 0.1, freq: 700, q: 1, vol: 0.3)
    }
    R("block.suspicious_sand.break", "blocks", "Block broken") { s, _, _ in
        s.noiseBurst(dur: 0.2, freq: 1800, q: 0.4, vol: 0.6)
    }
    R("jukebox.stop", "records", nil) { s, _, _ in
        s.tone(freq: 400, endFreq: 200, dur: 0.15, vol: 0.2)
    }
    R("event.raid.horn", "hostile", "Raid horn sounds") { s, _, _ in
        s.tone(freq: 220, dur: 1.6, type: .sawtooth, vol: 0.5, vibrato: 2)
        s.tone(freq: 330, dur: 1.6, type: .sawtooth, vol: 0.25)
    }
    R("ui.toast.challenge_complete", "ui", nil) { s, _, _ in
        for i in 0..<5 { s.tone(freq: 520 + Double(i) * 130, dur: 0.4, vol: 0.2, delay: Double(i) * 0.09) }
    }
    R("ui.button.click", "ui", nil) { s, _, _ in
        s.tone(freq: 500, dur: 0.06, type: .square, vol: 0.15)
    }
    R("ui.toast.in", "ui", nil) { s, _, _ in
        s.tone(freq: 800, endFreq: 1200, dur: 0.15, vol: 0.2)
    }
    R("entity.fishing_bobber.retrieve", "players", nil) { s, _, _ in
        s.noiseBurst(dur: 0.1, freq: 1300, q: 1, vol: 0.3)
    }
}

private let hostileNames = ["zombie", "skeleton", "creeper", "spider", "blaze", "ghast", "witch", "pillager",
                            "vindicator", "evoker", "vex", "ravager", "guardian", "shulker", "phantom", "wither",
                            "warden", "hoglin", "piglin", "silverfish", "endermite", "stray", "husk", "drowned",
                            "magma", "slime", "zoglin"]

private func resolveRecipe(_ name: String) -> SoundRecipe? {
    buildRecipes()
    if let r = RECIPES[name] { return r }
    if name.hasPrefix("jukebox.play.") { return nil }  // handled via playDisc
    // block sound fallbacks: block.<material>.<action>
    let parts = name.split(separator: ".").map(String.init)
    if parts.count == 3 && parts[0] == "block" && ["break", "place", "step", "hit", "fall"].contains(parts[2]) {
        return RECIPES["block.stone.\(parts[2] == "fall" ? "step" : parts[2])"]
    }
    // entity fallbacks
    if parts.count == 3 && parts[0] == "entity" && ["ambient", "hurt", "death"].contains(parts[2]) {
        let hostile = hostileNames.contains { parts[1].contains($0) }
        return RECIPES[hostile ? "entity.zombie.\(parts[2])" : "entity.pig.\(parts[2])"]
    }
    return nil
}
