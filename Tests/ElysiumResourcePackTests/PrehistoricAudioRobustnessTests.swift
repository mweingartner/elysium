import AVFoundation
import Foundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// White-box coverage for the recorded dinosaur voice path in `Audio.swift`:
/// `DinosaurSampleBank` routing and fail-closed decoding, the fixed 40-block creature range in
/// `positionalSoundMix`/`gameSoundMix`, and the per-block re-spatialisation of recorded voices
/// inside `AudioEngineM.render`. None of these tests start an audio device.
final class PrehistoricAudioRobustnessTests: XCTestCase {
    // MARK: - Routing: DinosaurSampleBank.assetKey

    /// Every cue of every species: the three recorded actions are mapped, every other cue keeps
    /// its synthesized recipe (nil key), and the key always names the emitting species.
    func testAssetKeyForEveryCueOfEverySpecies() {
        let recorded: [PrehistoricSoundCue: String] = [
            .ambient: "grazing", .idle: "grazing", .browse: "grazing", .eat: "grazing",
            .attack: "attack", .hurt: "injured",
        ]
        XCTAssertEqual(PrehistoricCreatureDefinition.all.count, 36)
        var mapped = Set<String>()
        for definition in PrehistoricCreatureDefinition.all {
            let species = String(definition.id.dropFirst("prehistoric.".count))
            for cue in PrehistoricSoundCue.allCases {
                let name = definition.soundName(for: cue)
                let key = DinosaurSampleBank.assetKey(for: name)
                if let action = recorded[cue] {
                    XCTAssertEqual(key, "\(species)-\(action)", name)
                    if let key { mapped.insert(key) }
                } else {
                    XCTAssertNil(key, "\(name) must stay synthesized")
                }
            }
        }
        XCTAssertEqual(mapped.count, 108, "36 species x grazing/attack/injured")
    }

    func testAssetKeyRejectsMalformedAndForeignNames() {
        let rejected = [
            "",
            "entity",
            "entity.prehistoric",
            "entity.prehistoric.triceratops",                    // 3 segments
            "entity.prehistoric.triceratops.hurt.extra",         // 5 segments
            "entity.prehistoric.triceratops.hurt.hurt",
            "entity.triceratops.hurt",                           // missing namespace
            "entity.cow.hurt", "entity.zombie.ambient",          // non-prehistoric entities
            "entity.player.hurt", "block.stone.break",
            "mob.prehistoric.triceratops.hurt",                  // wrong root
            "Entity.prehistoric.triceratops.hurt",               // case-sensitive
            "entity.Prehistoric.triceratops.hurt",
            "entity.prehistoric.Triceratops.hurt",
            "entity.prehistoric.TRICERATOPS.hurt",
            "entity.prehistoric.triceratops.HURT",
            "entity.prehistoric.unicorn.hurt",                   // unknown species
            "entity.prehistoric.prehistoric.hurt",
            "entity.prehistoric.triceratops-grazing.hurt",
            "entity.prehistoric.triceratops.grazing",            // asset action, not a cue
            "entity.prehistoric.triceratops.injured",
            "entity.prehistoric.triceratops.death",
            "entity.prehistoric.../../etc/passwd.hurt",
            "entity.prehistoric.triceratops/../tyrannosaurus.hurt",
            "entity.prehistoric.triceratops\u{0}.hurt",
            "entity.prehistoric.triceratops .hurt",
            "entity.prehistoric. triceratops.hurt",
            "../packaging/DinosaurSounds/triceratops-grazing.wav",
            "triceratops-grazing",
        ]
        for name in rejected {
            XCTAssertNil(DinosaurSampleBank.assetKey(for: name), name)
            XCTAssertNil(DinosaurSampleBank.loadBundled().sample(for: name), name)
        }
    }

    /// `split(separator:)` drops empty segments, so doubled/leading/trailing dots still map. That
    /// is harmless because `playRecipe` resolves the recipe first, and no recipe exists for those
    /// spellings: the engine must stay silent rather than play the recording.
    func testMalformedDottedSpellingsNeverReachTheRecording() throws {
        for name in ["entity..prehistoric.triceratops.browse",
                     ".entity.prehistoric.triceratops.browse",
                     "entity.prehistoric.triceratops.browse."] {
            XCTAssertEqual(DinosaurSampleBank.assetKey(for: name), "triceratops-grazing")
            let audio = makeEngine()
            audio.play(name, 0, 0, 1)
            let out = try renderBlocks(audio, blocks: 2)
            XCTAssertEqual(out.peak, 0, "\(name) has no recipe and must not play anything")
        }
    }

    // MARK: - Bundled bank

    func testEveryBundledClipDecodesNonSilentWithinContractAndMatchesManifest() throws {
        let bank = DinosaurSampleBank.loadBundled()
        XCTAssertEqual(bank.samples.count, 108)
        let manifestURL = Self.repositoryRoot.appendingPathComponent("packaging/DinosaurSounds/manifest.json")
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let assets = try XCTUnwrap(manifest["assets"] as? [[String: Any]])
        var manifestFrames: [String: Int] = [:]
        for asset in assets {
            let file = try XCTUnwrap(asset["file"] as? String)
            manifestFrames[String(file.dropLast(".wav".count))] = try XCTUnwrap(asset["frames"] as? Int)
        }
        XCTAssertEqual(Set(manifestFrames.keys), Set(bank.samples.keys))
        var fingerprints = Set<[Float]>()
        for (key, sample) in bank.samples {
            XCTAssertEqual(sample.sampleRate, 24_000, key)
            XCTAssertEqual(sample.frames.count, manifestFrames[key], "\(key) decoded length vs manifest")
            XCTAssertGreaterThanOrEqual(sample.frames.count, 12_000, key)
            XCTAssertLessThanOrEqual(sample.frames.count, 24_000 * 8, key)
            XCTAssertTrue(sample.frames.allSatisfy(\.isFinite), key)
            let peak = sample.frames.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 100.0 / 32_768, "\(key) must not be silent")
            XCTAssertLessThanOrEqual(peak, 17_000.0 / 32_768 + 1e-6, "\(key) headroom")
            // validator contract: endpoints are clean (|s| <= 1 LSB) so voices start/stop click-free
            XCTAssertLessThanOrEqual(abs(sample.frames.first ?? 1), 1.0 / 32_768 + 1e-9, key)
            XCTAssertLessThanOrEqual(abs(sample.frames.last ?? 1), 1.0 / 32_768 + 1e-9, key)
            fingerprints.insert(Array(sample.frames.prefix(4_096)))
        }
        XCTAssertEqual(fingerprints.count, 108, "every species/action pair must carry its own recording")
    }

    // MARK: - Loader: fail closed on bad files, keep loading good ones

    func testLoaderSkipsEveryMalformedFileWhileValidFilesStillLoad() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ key: String, _ data: Data) throws {
            try data.write(to: directory.appendingPathComponent(key + ".wav"))
        }
        let tone: (Int) -> Double = { 0.25 * sin(Double($0) * 0.05) }

        // valid controls, including exact boundaries
        try write("triceratops-grazing", makeWAV(frames: 24_000, value: tone))
        try write("triceratops-attack", makeWAV(frames: 24_000 * 8, value: tone))       // exactly 8 s
        try write("triceratops-injured", makeWAV(frames: 1, value: { _ in 0.5 }))        // 46 bytes
        let paddedToLimit = makeWAV(frames: 24_000, value: tone, padChunkBytes: 0)
        try write("stegosaurus-grazing",
                  makeWAV(frames: 24_000, value: tone, padChunkBytes: 512_000 - paddedToLimit.count - 8))
        try write("stegosaurus-attack", makeWAV(frames: 2_400, format: .float32, value: { $0 % 2 == 0 ? 1 : -1 }))

        // rejects
        try write("tyrannosaurus-grazing", makeWAV(frames: 24_000, channels: 2, value: tone))
        try write("tyrannosaurus-attack", makeWAV(frames: 24_000, sampleRate: 48_000, value: tone))
        try write("tyrannosaurus-injured", makeWAV(frames: 24_000, sampleRate: 44_100, value: tone))
        try write("velociraptor-grazing",
                  makeWAV(frames: 24_000, value: tone, padChunkBytes: 512_000 - paddedToLimit.count - 7))
        try write("velociraptor-attack", makeWAV(frames: 24_000 * 8 + 1, value: tone))  // 8 s + 1 frame
        try write("velociraptor-injured", Data())                                     // empty
        try write("allosaurus-grazing", makeWAV(frames: 0, value: tone))              // header only, 44 B
        try write("allosaurus-attack", makeWAV(frames: 0, value: tone) + Data([0]))   // 45 B, no frames
        try write("allosaurus-injured", Data(makeWAV(frames: 24_000, value: tone).prefix(30)) +
                  Data(repeating: 0, count: 200))                                      // truncated header
        try write("brachiosaurus-grazing", Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }))
        try write("brachiosaurus-attack",
                  makeWAV(frames: 2_400, format: .float32, value: { $0 == 1_000 ? .nan : 0.1 }))
        try write("brachiosaurus-injured",
                  makeWAV(frames: 2_400, format: .float32, value: { $0 == 1_000 ? .infinity : 0.1 }))
        try write("ankylosaurus-grazing",
                  makeWAV(frames: 2_400, format: .float32, value: { $0 == 1_000 ? 1.5 : 0.1 }))  // clipped
        try write("ankylosaurus-attack",
                  makeWAV(frames: 2_400, format: .float32, value: { $0 == 1_000 ? -1.0001 : 0.1 }))

        // a symlink to a perfectly valid clip, and a directory wearing a clip's name
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("real.wav")
        try makeWAV(frames: 24_000, value: tone).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("ankylosaurus-injured.wav"), withDestinationURL: target)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("diplodocus-grazing.wav"), withIntermediateDirectories: false)
        // unreadable regular file
        let unreadable = directory.appendingPathComponent("diplodocus-attack.wav")
        try makeWAV(frames: 24_000, value: tone).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        // names outside the fixed roster are never consulted
        try write("unicorn-grazing", makeWAV(frames: 24_000, value: tone))
        try write("triceratops-step", makeWAV(frames: 24_000, value: tone))

        let bank = DinosaurSampleBank.load(directory: directory)
        XCTAssertEqual(Set(bank.samples.keys),
                       ["triceratops-grazing", "triceratops-attack", "triceratops-injured",
                        "stegosaurus-grazing", "stegosaurus-attack"])
        XCTAssertEqual(bank.samples["triceratops-attack"]?.frames.count, 24_000 * 8)
        XCTAssertEqual(bank.samples["triceratops-injured"]?.frames.count, 1)
        XCTAssertEqual(bank.samples["triceratops-injured"]?.frames.first ?? 0, 0.5, accuracy: 1.0 / 32_768)
        XCTAssertEqual(bank.samples["stegosaurus-attack"]?.frames.prefix(2), [1, -1],
                       "full-scale (|s| == 1) is inside the accepted range")
        let decoded = try XCTUnwrap(bank.samples["triceratops-grazing"])
        XCTAssertEqual(decoded.frames.count, 24_000)
        for index in [0, 1, 777, 23_999] {
            XCTAssertEqual(Double(decoded.frames[index]), tone(index), accuracy: 1.0 / 32_768 + 1e-9)
        }
        XCTAssertNil(bank.sample(for: "entity.prehistoric.tyrannosaurus.ambient"),
                     "a rejected file leaves that cue on its synthesized recipe")
    }

    func testLoaderOnMissingOrEmptyDirectoryReturnsEmptyBank() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-no-such-dino-bank-\(UUID().uuidString)")
        XCTAssertTrue(DinosaurSampleBank.load(directory: missing).samples.isEmpty)
        let empty = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertTrue(DinosaurSampleBank.load(directory: empty).samples.isEmpty)
        // a *file* where the directory should be
        let file = empty.appendingPathComponent("DinosaurSounds")
        try Data("not a directory".utf8).write(to: file)
        XCTAssertTrue(DinosaurSampleBank.load(directory: file).samples.isEmpty)
    }

    /// Seeded fuzz: random byte mutations of a valid clip must never crash the loader, and anything
    /// it accepts must still satisfy the decode contract.
    func testLoaderSurvivesSeededByteMutations() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = makeWAV(frames: 6_000, value: { 0.3 * sin(Double($0) * 0.03) })
        let url = directory.appendingPathComponent("triceratops-grazing.wav")
        for seed in UInt64(1)...200 {
            var rng = SplitMix64(seed: seed)
            var bytes = [UInt8](original)
            let edits = 1 + Int(rng.next() % 8)
            for _ in 0..<edits {
                let position = Int(rng.next() % UInt64(bytes.count))
                // bias half the edits into the 44-byte header where parsing decisions live
                let index = rng.next() % 2 == 0 ? position % 44 : position
                bytes[index] = UInt8(truncatingIfNeeded: rng.next())
            }
            if rng.next() % 4 == 0 { bytes.removeLast(Int(rng.next() % UInt64(bytes.count - 1))) }
            try Data(bytes).write(to: url)
            let bank = DinosaurSampleBank.load(directory: directory)
            if let sample = bank.samples["triceratops-grazing"] {
                XCTAssertEqual(sample.sampleRate, 24_000, "seed \(seed)")
                XCTAssertFalse(sample.frames.isEmpty, "seed \(seed)")
                XCTAssertLessThanOrEqual(sample.frames.count, 24_000 * 8, "seed \(seed)")
                XCTAssertTrue(sample.frames.allSatisfy { $0.isFinite && abs($0) <= 1 }, "seed \(seed)")
            }
            XCTAssertLessThanOrEqual(bank.samples.count, 1, "seed \(seed)")
        }
    }

    // MARK: - positionalSoundMix: boundaries, guards, properties

    func testPositionalSoundMixBoundariesAndGuards() throws {
        func mix(_ x: Double, _ y: Double = 0, _ z: Double = 0, volume: Double = 1,
                 listener: (Double, Double, Double, Double) = (0, 0, 0, 0),
                 max: Double = 40) -> (volume: Double, pan: Double)? {
            positionalSoundMix(x, y, z, volume, listener.0, listener.1, listener.2, listener.3,
                               maxDistance: max)
        }
        XCTAssertNil(mix(40), "exactly at the radius is silent")
        XCTAssertNil(mix(0, 0, -40))
        XCTAssertNil(mix(0, 40, 0), "vertical distance counts")
        XCTAssertNil(mix(40.000_000_001))
        let inside = try XCTUnwrap(mix(39.999))
        XCTAssertGreaterThan(inside.volume, 0)
        XCTAssertEqual(inside.volume, pow(0.001 / 40, 2), accuracy: 1e-15)
        XCTAssertGreaterThan(try XCTUnwrap(mix(40.nextDown)).volume, 0, "just inside is audible")
        // 3-4-5 style diagonal: distance is Euclidean, not per-axis
        XCTAssertNil(mix(24, 0, 32))                       // = 40
        XCTAssertNotNil(mix(23.9, 0, 32))
        XCTAssertEqual(try XCTUnwrap(mix(0)).volume, 1)
        XCTAssertEqual(try XCTUnwrap(mix(0)).pan, 0)

        for bad in [0.0, -0.0, -1, -.infinity, .infinity, .nan] {
            XCTAssertNil(mix(10, volume: bad), "volume \(bad)")
        }
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(mix(bad), "x \(bad)")
            XCTAssertNil(mix(0, bad), "y \(bad)")
            XCTAssertNil(mix(0, 0, bad), "z \(bad)")
            XCTAssertNil(mix(0, listener: (bad, 0, 0, 0)), "listener x \(bad)")
            XCTAssertNil(mix(0, listener: (0, bad, 0, 0)), "listener y \(bad)")
            XCTAssertNil(mix(0, listener: (0, 0, bad, 0)), "listener z \(bad)")
            XCTAssertNil(mix(0, listener: (0, 0, 0, bad)), "listener yaw \(bad)")
            XCTAssertNil(mix(0, max: bad), "max \(bad)")
        }
        XCTAssertNil(mix(0, max: 0))
        XCTAssertNil(mix(0, max: -40))
        // overflowing distance computations must reject rather than produce NaN/inf output
        let huge = Double.greatestFiniteMagnitude
        XCTAssertNil(mix(huge, listener: (-huge, 0, 0, 0)))
        XCTAssertNil(mix(1e200, 1e200, 1e200))
        XCTAssertNil(mix(huge, volume: 1, max: huge))
    }

    /// Seeded property + metamorphic sweep with no reference implementation: bounds, translation
    /// invariance, rotation invariance (source and yaw turned together), mirror symmetry,
    /// volume linearity and monotone falloff.
    func testPositionalSoundMixProperties() {
        var rng = SplitMix64(seed: 0xD1_70_5A_0D)
        func uniform(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + Double(rng.next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
        }
        for iteration in 0..<5_000 {
            let lx = uniform(-500...500), ly = uniform(-64...320), lz = uniform(-500...500)
            let yaw = uniform(-10...10)
            let dx = uniform(-50...50), dy = uniform(-50...50), dz = uniform(-50...50)
            let volume = uniform(0.001...4)
            let maxDistance = uniform(1...60)
            let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
            let context = "iteration \(iteration) d=\(distance) max=\(maxDistance)"
            let base = positionalSoundMix(lx + dx, ly + dy, lz + dz, volume, lx, ly, lz, yaw,
                                          maxDistance: maxDistance)
            guard abs(distance - maxDistance) > 1e-6 else { continue }
            guard let base else {
                XCTAssertGreaterThan(distance, maxDistance, context)
                continue
            }
            XCTAssertLessThan(distance, maxDistance, context)
            XCTAssertTrue(base.volume.isFinite && base.pan.isFinite, context)
            XCTAssertGreaterThanOrEqual(base.volume, 0, context)
            XCTAssertLessThanOrEqual(base.volume, volume, context)
            XCTAssertLessThanOrEqual(abs(base.pan), 1, context)
            XCTAssertLessThanOrEqual(abs(base.pan), distance / 4 + 1e-12, "near sources stay centred; \(context)")
            XCTAssertEqual(base.volume, volume * pow(1 - distance / maxDistance, 2),
                           accuracy: 1e-9 * max(1, volume), context)

            // translation invariance
            let shift = (uniform(-1_000...1_000), uniform(-100...100), uniform(-1_000...1_000))
            let moved = positionalSoundMix(lx + dx + shift.0, ly + dy + shift.1, lz + dz + shift.2, volume,
                                           lx + shift.0, ly + shift.1, lz + shift.2, yaw,
                                           maxDistance: maxDistance)
            XCTAssertEqual(moved?.volume ?? -1, base.volume, accuracy: 1e-6, context)
            XCTAssertEqual(moved?.pan ?? -9, base.pan, accuracy: 1e-6, context)

            // rotating the source about the listener and the listener's yaw by the same angle
            let theta = uniform(-Double.pi...Double.pi)
            let horizontal = (dx * dx + dz * dz).squareRoot()
            let phi = atan2(-dx, dz)
            let rdx = -horizontal * sin(phi + theta), rdz = horizontal * cos(phi + theta)
            let rotated = positionalSoundMix(lx + rdx, ly + dy, lz + rdz, volume, lx, ly, lz, yaw + theta,
                                             maxDistance: maxDistance)
            XCTAssertEqual(rotated?.volume ?? -1, base.volume, accuracy: 1e-9, context)
            XCTAssertEqual(rotated?.pan ?? -9, base.pan, accuracy: 1e-9, context)

            // mirror across the listener's forward axis (yaw 0 faces +z): pan flips, volume holds
            let straight = positionalSoundMix(lx + dx, ly + dy, lz + dz, volume, lx, ly, lz, 0,
                                              maxDistance: maxDistance)
            let mirrored = positionalSoundMix(lx - dx, ly + dy, lz + dz, volume, lx, ly, lz, 0,
                                              maxDistance: maxDistance)
            XCTAssertEqual(mirrored?.volume ?? -1, straight?.volume ?? -2, accuracy: 1e-12, context)
            XCTAssertEqual(mirrored?.pan ?? -9, -(straight?.pan ?? 9), accuracy: 1e-12, context)

            // linear in caller volume when the radius is fixed (creature contract)
            let k = uniform(0.1...3)
            let scaled = positionalSoundMix(lx + dx, ly + dy, lz + dz, volume * k, lx, ly, lz, yaw,
                                            maxDistance: maxDistance)
            XCTAssertEqual(scaled?.volume ?? -1, base.volume * k, accuracy: 1e-9 * max(1, volume * k), context)

            // moving farther along the same ray never gets louder
            let farther = positionalSoundMix(lx + dx * 1.1, ly + dy * 1.1, lz + dz * 1.1, volume,
                                             lx, ly, lz, yaw, maxDistance: maxDistance)
            XCTAssertLessThanOrEqual(farther?.volume ?? 0, base.volume + 1e-12, context)

            // determinism
            let again = positionalSoundMix(lx + dx, ly + dy, lz + dz, volume, lx, ly, lz, yaw,
                                           maxDistance: maxDistance)
            XCTAssertEqual(again?.volume, base.volume, context)
            XCTAssertEqual(again?.pan, base.pan, context)
        }
    }

    // MARK: - gameSoundMix routing: creature (fixed 40) vs everything else (18 x volume)

    func testNonCreatureSoundRangeIsStillEighteenTimesVolume() throws {
        let audio = AudioEngineM()
        audio.setListener(0, 0, 0, 0)
        for name in ["block.stone.break", "entity.player.hurt", "entity.generic.explode",
                     "entity.bat.ambient", "block.lever.click", "block.grass.step",
                     // ordinary mobs: a 40-block reach let dungeon monsters buzz through rock
                     "entity.zombie.ambient", "entity.husk.ambient", "entity.drowned.ambient",
                     "entity.skeleton.ambient", "entity.spider.ambient", "entity.cow.ambient"] {
            for volume in [0.25, 0.5, 1.0, 2.0, 3.0] {
                let reach = 18 * max(1, volume)
                XCTAssertNil(audio.gameSoundMix(name, reach, 0, 0, volume), "\(name) v\(volume) at edge")
                let inside = audio.gameSoundMix(name, reach.nextDown, 0, 0, volume)
                if resolvesToRecipe(name) {
                    XCTAssertNotNil(inside, "\(name) v\(volume) just inside")
                }
                if let mix = audio.gameSoundMix(name, reach / 2, 0, 0, volume) {
                    XCTAssertEqual(mix.volume, volume * 0.25, accuracy: 1e-12, name)
                }
            }
        }
        // a loud non-creature sound reaches past 40; a loud creature does not
        XCTAssertNotNil(audio.gameSoundMix("block.stone.break", 50, 0, 0, 3))
        XCTAssertNil(audio.gameSoundMix("entity.prehistoric.tyrannosaurus.attack", 40, 0, 0, 100))
        // a quiet creature still reaches the full 40, unlike the old 18-block floor
        XCTAssertNotNil(audio.gameSoundMix("entity.prehistoric.compsognathus.ambient", 39, 0, 0, 0.1))
        XCTAssertNil(audio.gameSoundMix("block.stone.break", 19, 0, 0, 0.1))
    }

    /// The router must agree exactly with `positionalSoundMix` at radius 40 for every recorded
    /// creature cue under arbitrary listener poses.
    func testGameSoundMixMatchesFortyBlockMixForEveryCreatureCue() {
        var rng = SplitMix64(seed: 40)
        func uniform(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + Double(rng.next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
        }
        let audio = AudioEngineM()
        for definition in PrehistoricCreatureDefinition.all {
            for name in definition.soundNames {
                let pose = (uniform(-100...100), uniform(0...128), uniform(-100...100), uniform(-4...4))
                audio.setListener(pose.0, pose.1, pose.2, pose.3)
                let x = pose.0 + uniform(-45...45), y = pose.1 + uniform(-10...10), z = pose.2 + uniform(-45...45)
                let volume = uniform(0.05...5)
                let routed = audio.gameSoundMix(name, x, y, z, volume)
                let direct = positionalSoundMix(x, y, z, volume, pose.0, pose.1, pose.2, pose.3, maxDistance: 40)
                XCTAssertEqual(routed?.volume, direct?.volume, name)
                XCTAssertEqual(routed?.pan, direct?.pan, name)
            }
        }
    }

    // MARK: - Mixer: recorded voices

    /// A recorded voice at the listener renders the clip itself through the linear resampler.
    func testRecordedVoiceRendersTheClipThroughTheResampler() throws {
        let clip = try XCTUnwrap(DinosaurSampleBank.loadBundled()
            .sample(for: "entity.prehistoric.triceratops.browse"))
        let audio = makeEngine()
        let outputRate = Self.engineOutputRate
        audio.play("entity.prehistoric.triceratops.browse", 0, 0, 0)
        let out = try renderBlocks(audio, blocks: 1, frames: 4_096)
        let step = 24_000 / outputRate
        for i in 0..<4_096 {
            let cursor = Double(i) * step
            let index = Int(cursor)
            guard index + 1 < clip.frames.count else { break }
            let fraction = cursor - Double(index)
            let expected = Double(clip.frames[index]) * (1 - fraction) + Double(clip.frames[index + 1]) * fraction
            XCTAssertEqual(Double(out.left[i]), expected, accuracy: 1e-6, "frame \(i)")
            XCTAssertEqual(out.left[i], out.right[i], "a source at the listener is centred")
        }
    }

    /// ambient/idle/browse are one recording; hurt and attack are different recordings; unmapped
    /// cues still play their synthesized recipe.
    func testCueRoutingIsObservableInTheMix() throws {
        func capture(_ name: String, pitch: Double = 1) throws -> [Float] {
            let audio = makeEngine()
            audio.play(name, 0, 0, 0, 1, pitch)
            return try renderBlocks(audio, blocks: 2, frames: 4_096).left
        }
        let ambient = try capture("entity.prehistoric.triceratops.ambient")
        XCTAssertGreaterThan(ambient.map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertEqual(try capture("entity.prehistoric.triceratops.idle"), ambient)
        XCTAssertEqual(try capture("entity.prehistoric.triceratops.browse"), ambient)
        XCTAssertNotEqual(try capture("entity.prehistoric.triceratops.hurt"), ambient)
        XCTAssertNotEqual(try capture("entity.prehistoric.triceratops.attack"), ambient)
        XCTAssertNotEqual(try capture("entity.prehistoric.stegosaurus.ambient"), ambient,
                          "species must not share a grazing call")
        let step = try capture("entity.prehistoric.triceratops.step")
        XCTAssertGreaterThan(step.map { abs($0) }.max() ?? 0, 0.0001, "synthesized cues still play")
        XCTAssertNotEqual(step, ambient)
    }

    func testPitchIsClampedForRecordingsAndInvalidPitchIsRejected() throws {
        func audibleLength(pitch: Double) throws -> (frames: Int, samples: [Float]) {
            let audio = makeEngine()
            audio.play("entity.prehistoric.triceratops.hurt", 0, 0, 0, 1, pitch)
            let out = try renderBlocks(audio, blocks: Int(Self.engineOutputRate * 17) / 4_096 + 1, frames: 4_096)
            let last = out.left.lastIndex { $0 != 0 } ?? -1
            return (last + 1, out.left)
        }
        let clip = try XCTUnwrap(DinosaurSampleBank.loadBundled().sample(for: "entity.prehistoric.triceratops.hurt"))
        let clipSeconds = Double(clip.frames.count) / clip.sampleRate
        let normal = try audibleLength(pitch: 1)
        XCTAssertEqual(Double(normal.frames) / Self.engineOutputRate, clipSeconds, accuracy: 0.01)

        let fast = try audibleLength(pitch: 2)
        XCTAssertEqual(Double(fast.frames) / Self.engineOutputRate, clipSeconds / 2, accuracy: 0.01)
        XCTAssertEqual(try audibleLength(pitch: 10).samples, fast.samples, "pitch above 2 clamps to 2")
        XCTAssertEqual(try audibleLength(pitch: .greatestFiniteMagnitude).samples, fast.samples)

        let slow = try audibleLength(pitch: 0.5)
        XCTAssertEqual(Double(slow.frames) / Self.engineOutputRate, clipSeconds * 2, accuracy: 0.01)
        XCTAssertEqual(try audibleLength(pitch: 0.01).samples, slow.samples, "pitch below 0.5 clamps to 0.5")
        XCTAssertEqual(try audibleLength(pitch: .leastNonzeroMagnitude).samples, slow.samples)

        for bad in [0.0, -0.0, -1, -2, .nan, .infinity, -.infinity] {
            XCTAssertEqual(try audibleLength(pitch: bad).frames, 0, "pitch \(bad) must be rejected by play")
        }
    }

    func testCreatureVoiceTracksListenerAcrossTheFortyBlockEdgeMidPlay() throws {
        let audio = makeEngine()
        audio.setListener(0, 0, 0, 0)
        audio.play("entity.prehistoric.triceratops.browse", 0, 0, 0)
        let blockFrames = 1_024
        XCTAssertGreaterThan(try renderBlocks(audio, blocks: 1, frames: blockFrames).peak, 0.001)
        audio.setListener(39.99, 0, 0, 0)
        XCTAssertGreaterThan(try renderBlocks(audio, blocks: 1, frames: blockFrames).peak, 0, "just inside")
        audio.setListener(40, 0, 0, 0)
        XCTAssertEqual(try renderBlocks(audio, blocks: 1, frames: blockFrames).peak, 0, "exactly 40 is silent")
        audio.setListener(0, 0, 40.01, 0)
        XCTAssertEqual(try renderBlocks(audio, blocks: 1, frames: blockFrames).peak, 0, "beyond 40 on z")
        audio.setListener(0, 45, 0, 0)
        XCTAssertEqual(try renderBlocks(audio, blocks: 1, frames: blockFrames).peak, 0, "beyond 40 vertically")
        audio.setListener(0, 0, 39, 0)
        let resumed = try renderBlocks(audio, blocks: 1, frames: blockFrames).peak
        XCTAssertGreaterThan(resumed, 0, "walking back inside resumes the still-active call")
        audio.setListener(0, 0, 10, 0)
        XCTAssertGreaterThan(try renderBlocks(audio, blocks: 1, frames: blockFrames).peak, resumed,
                             "and it gets louder as the listener approaches")

        // turning the listener re-pans the same voice: source due east at full pan
        audio.setListener(20, 0, 0, 0)          // source is at -x → hard left
        let left = try renderBlocks(audio, blocks: 1, frames: blockFrames)
        XCTAssertGreaterThan(left.leftPeak, 0)
        XCTAssertEqual(left.rightPeak, 0)
        audio.setListener(20, 0, 0, .pi)        // turn around → hard right
        let right = try renderBlocks(audio, blocks: 1, frames: blockFrames)
        XCTAssertEqual(right.leftPeak, 0)
        XCTAssertGreaterThan(right.rightPeak, 0)
    }

    func testCreatureCallEmittedOutOfRangeNeverStartsEvenIfTheListenerApproaches() throws {
        let audio = makeEngine()
        audio.setListener(0, 0, 0, 0)
        audio.play("entity.prehistoric.triceratops.browse", 41, 0, 0)
        audio.setListener(41, 0, 0, 0)
        XCTAssertEqual(try renderBlocks(audio, blocks: 4).peak, 0)
    }

    /// Contrast: non-creature voices keep their spawn-time mix (pre-existing behaviour). Only
    /// creature calls follow the listener, so this pins the tracking to the creature category.
    func testNonCreatureVoiceKeepsItsSpawnMixWhenTheListenerLeaves() throws {
        let audio = makeEngine()
        audio.setListener(0, 0, 0, 0)
        audio.play("entity.player.hurt", 1, 0, 0)
        audio.setListener(500, 0, 0, 0)
        XCTAssertGreaterThan(try renderBlocks(audio, blocks: 1, frames: 2_048).peak, 0.0001)
    }

    /// Creature calls are dry: in a cave, the full output is bit-identical to the open-air output,
    /// and nothing leaks after the listener leaves the radius. The non-creature control proves the
    /// cave reverb is genuinely active in this configuration.
    func testCreatureCallsHaveNoReverbSendEvenInCaves() throws {
        func capture(cave: Double, name: String, blocks: Int) throws -> [Float] {
            let audio = makeEngine()
            audio.setEnvironment(false, cave)
            audio.setListener(0, 0, 0, 0)
            audio.play(name, 5, 0, 3)
            return try renderBlocks(audio, blocks: blocks, frames: 4_096).left
        }
        let call = "entity.prehistoric.tyrannosaurus.attack"
        XCTAssertEqual(try capture(cave: 1, name: call, blocks: 40), try capture(cave: 0, name: call, blocks: 40),
                       "no delay-line contribution from a creature voice")

        let audio = makeEngine()
        audio.setEnvironment(false, 1)
        audio.play(call, 5, 0, 3)
        XCTAssertGreaterThan(try renderBlocks(audio, blocks: 1).peak, 0.0005)
        audio.setListener(5, 0, 43, 0)          // exactly 40 blocks from the source
        XCTAssertEqual(try renderBlocks(audio, blocks: 30).peak, 0, "no cave tail at/after 40 blocks")

        // control: a short non-creature sound leaves an audible reverb tail after it ends
        let control = makeEngine()
        control.setEnvironment(false, 1)
        control.play("block.lever.click", 0, 0, 1)
        _ = try renderBlocks(control, blocks: Int(Self.engineOutputRate * 0.5) / 4_096 + 1)
        XCTAssertGreaterThan(try renderBlocks(control, blocks: 6).peak, 0,
                             "the cave reverb must be live for the dry assertion above to mean anything")
    }

    // MARK: - Load / stress / concurrency

    func testHundredsOfSimultaneousCallsStayFiniteAndBounded() throws {
        let audio = makeEngine()
        var rng = SplitMix64(seed: 0x5EED)
        let names = PrehistoricCreatureDefinition.all.flatMap { definition in
            [PrehistoricSoundCue.ambient, .attack, .hurt, .step, .death].map { definition.soundName(for: $0) }
        }
        audio.setListener(0, 64, 0, 0)
        for _ in 0..<700 {
            let name = names[Int(rng.next() % UInt64(names.count))]
            let x = Double(Int(rng.next() % 70)) - 35, z = Double(Int(rng.next() % 70)) - 35
            let pitch = [0.3, 0.5, 1, 1.7, 2, 3][Int(rng.next() % 6)]
            let volume = [0.1, 1, 1.5, 4][Int(rng.next() % 4)]
            audio.play(name, x, 64, z, volume, pitch)
        }
        var peak: Float = 0
        for block in 0..<60 {
            audio.setListener(Double(block), 64, Double(-block), Double(block) * 0.1)
            let out = try renderBlocks(audio, blocks: 1, frames: 512)
            XCTAssertTrue(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite), "block \(block)")
            peak = max(peak, out.peak)
        }
        XCTAssertGreaterThan(peak, 0)
        // 512-voice cap x max creature gain 1.5 x recording headroom 0.52 (synth voices are smaller)
        XCTAssertLessThan(peak, 512 * 1.5)
    }

    func testConcurrentListenerUpdatesAndPlaysDuringRenderStayFinite() throws {
        let audio = makeEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let done = DispatchSemaphore(value: 0)
        let finite = ManagedFlag()
        let renderThread = Thread {
            for _ in 0..<400 {
                audio.render(buffer.frameLength, buffer.mutableAudioBufferList)
                let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
                for i in 0..<512 where !left[i].isFinite || !right[i].isFinite { finite.clear() }
            }
            done.signal()
        }
        renderThread.start()
        for i in 0..<2_000 {
            let angle = Double(i) * 0.01
            audio.setListener(39 * cos(angle), 0, 39 * sin(angle), angle)
            if i % 10 == 0 { audio.play("entity.prehistoric.triceratops.browse", 0, 0, 0) }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success)
        XCTAssertTrue(finite.value)
    }

    /// Non-functional: the 512-voice worst case must render a 512-frame block without a
    /// superlinear blowup. Prints the measured cost so regressions are visible in logs.
    func testWorstCaseRenderCostIsReported() throws {
        func medianBlockSeconds(voices: Int) throws -> Double {
            let audio = makeEngine()
            for i in 0..<voices {
                audio.play("entity.prehistoric.tyrannosaurus.ambient", Double(i % 30), 0, 0, 1, 0.5)
            }
            _ = try renderBlocks(audio, blocks: 1, frames: 512) // pick up inbox
            var samples: [Double] = []
            for _ in 0..<15 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try renderBlocks(audio, blocks: 1, frames: 512)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            return samples.sorted()[samples.count / 2]
        }
        let small = try medianBlockSeconds(voices: 64)
        let large = try medianBlockSeconds(voices: 512)
        print("[dino-render] 512-frame block median: 64 voices \(small * 1000) ms, 512 voices \(large * 1000) ms")
        XCTAssertLessThan(large, 0.25, "512 recorded voices must not take a quarter second per block")
        XCTAssertLessThan(large / max(small, 1e-6), 8 * 4, "cost must scale ~linearly with voice count")
    }

    // MARK: - Validator fails closed

    func testValidatorPassesBundleAndFailsClosedOnTamperedCopies() throws {
        let root = Self.repositoryRoot
        let script = root.appendingPathComponent("scripts/verify-dinosaur-sounds.py")
        let bundle = root.appendingPathComponent("packaging/DinosaurSounds")
        func run(_ directory: URL) throws -> (status: Int32, output: String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, "--directory", directory.path]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let pristine = try run(bundle)
        XCTAssertEqual(pristine.status, 0, pristine.output)
        XCTAssertTrue(pristine.output.contains("Dinosaur sounds PASS"), pristine.output)

        let scratch = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        func copy(_ label: String) throws -> URL {
            let destination = scratch.appendingPathComponent(label)
            try FileManager.default.copyItem(at: bundle, to: destination)
            return destination
        }
        let flipped = try copy("flip")
        let victim = flipped.appendingPathComponent("triceratops-grazing.wav")
        var bytes = try Data(contentsOf: victim)
        bytes[5_000] ^= 0x01
        try bytes.write(to: victim)

        let extra = try copy("extra")
        try Data().write(to: extra.appendingPathComponent("evil.wav"))

        let missing = try copy("missing")
        try FileManager.default.removeItem(at: missing.appendingPathComponent("velociraptor-attack.wav"))

        let linked = try copy("linked")
        try FileManager.default.removeItem(at: linked.appendingPathComponent("velociraptor-attack.wav"))
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("velociraptor-attack.wav"),
            withDestinationURL: bundle.appendingPathComponent("velociraptor-attack.wav"))

        let manifest = try copy("manifest")
        let handle = try FileHandle(forWritingTo: manifest.appendingPathComponent("manifest.json"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()

        for (directory, reason) in [(flipped, "hash mismatch"), (extra, "unexpected or missing"),
                                    (missing, "unexpected or missing"), (linked, "nonregular"),
                                    (manifest, "manifest differs")] {
            let result = try run(directory)
            XCTAssertEqual(result.status, 1, "\(directory.lastPathComponent): \(result.output)")
            XCTAssertTrue(result.output.contains("Dinosaur sounds FAIL"), result.output)
            XCTAssertTrue(result.output.contains(reason), "\(directory.lastPathComponent): \(result.output)")
        }
        let absent = try run(scratch.appendingPathComponent("absent"))
        XCTAssertEqual(absent.status, 1, absent.output)
    }

    // MARK: - helpers

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Mirrors `initEngine`: the render rate is the (unstarted) output node's rate, else 48 kHz.
    private static let engineOutputRate: Double = {
        let engine = AVAudioEngine()   // outputNode does not retain its engine
        let rate = withExtendedLifetime(engine) { engine.outputNode.outputFormat(forBus: 0).sampleRate }
        return rate > 0 ? rate : 48_000
    }()

    private struct Rendered {
        var left: [Float] = []
        var right: [Float] = []
        var leftPeak: Float { left.map { abs($0) }.max() ?? 0 }
        var rightPeak: Float { right.map { abs($0) }.max() ?? 0 }
        var peak: Float { max(leftPeak, rightPeak) }
    }

    private func makeEngine() -> AudioEngineM {
        let audio = AudioEngineM()
        audio.initEngine(startDevice: false)
        audio.setEnvironment(false, 0)
        audio.setListener(0, 0, 0, 0)
        return audio
    }

    private func renderBlocks(_ audio: AudioEngineM, blocks: Int, frames: Int = 4_096) throws -> Rendered {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        var out = Rendered()
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

    private func resolvesToRecipe(_ name: String) -> Bool {
        let audio = makeEngine()
        audio.play(name, 0, 0, 0)
        return ((try? renderBlocks(audio, blocks: 1, frames: 2_048).peak) ?? 0) > 0
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-dino-bank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum SampleFormat { case pcm16, float32 }

    /// Minimal RIFF/WAVE writer. `padChunkBytes` inserts an unknown `pad ` chunk before `data`
    /// so file size can be tuned independently of duration.
    private func makeWAV(frames: Int, channels: Int = 1, sampleRate: Int = 24_000,
                         format: SampleFormat = .pcm16, value: (Int) -> Double,
                         padChunkBytes: Int = 0) -> Data {
        let bytesPerSample = format == .pcm16 ? 2 : 4
        var data = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        let dataBytes = frames * channels * bytesPerSample
        let padTotal = padChunkBytes > 0 ? 8 + padChunkBytes + (padChunkBytes & 1) : 0
        data.append(contentsOf: Array("RIFF".utf8)); u32(4 + 24 + padTotal + 8 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(format == .pcm16 ? 1 : 3); u16(channels); u32(sampleRate)
        u32(sampleRate * channels * bytesPerSample); u16(channels * bytesPerSample); u16(bytesPerSample * 8)
        if padChunkBytes > 0 {
            data.append(contentsOf: Array("pad ".utf8)); u32(padChunkBytes)
            data.append(Data(repeating: 0, count: padChunkBytes + (padChunkBytes & 1)))
        }
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for frame in 0..<frames {
            let sample = value(frame)
            for _ in 0..<channels {
                switch format {
                case .pcm16:
                    let clamped = max(-1, min(1, sample))
                    let int = Int16(max(-32_768, min(32_767, (clamped * 32_768).rounded())))
                    withUnsafeBytes(of: int.littleEndian) { data.append(contentsOf: $0) }
                case .float32:
                    withUnsafeBytes(of: Float(sample).bitPattern.littleEndian) { data.append(contentsOf: $0) }
                }
            }
        }
        return data
    }
}

/// Deterministic generator so every fuzz/property failure replays from its seed.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = true
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func clear() { lock.lock(); flag = false; lock.unlock() }
}
