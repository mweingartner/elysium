import AVFoundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class PrehistoricAudioTests: XCTestCase {
    func testActualSampleRenderFallsSilentWhenListenerLeavesRange() throws {
        let audio = AudioEngineM()
        audio.initEngine(startDevice: false)
        audio.setEnvironment(false, 1) // shared cave tails must not leak outside the radius
        audio.setListener(0, 0, 0, 0)
        audio.play("entity.prehistoric.triceratops.browse", 0, 0, 0)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        buffer.frameLength = 4_096
        audio.render(buffer.frameLength, buffer.mutableAudioBufferList)
        let left = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertGreaterThan((0..<4_096).map { abs(left[$0]) }.max() ?? 0, 0.001,
                             "the bundled recording must produce real PCM through the game mixer")
        audio.setListener(40, 0, 0, 0)
        audio.render(buffer.frameLength, buffer.mutableAudioBufferList)
        XCTAssertTrue((0..<4_096).allSatisfy { left[$0] == 0 },
                      "an already-playing call must become silent outside the fixed radius")
        audio.setListener(0, 0, 0, 0)
        audio.render(buffer.frameLength, buffer.mutableAudioBufferList)
        XCTAssertGreaterThan((0..<4_096).map { abs(left[$0]) }.max() ?? 0, 0.001,
                             "returning inside range resumes the still-active call")
    }

    func testSampleRoutingAndBoundedBundledDecode() throws {
        let bank = DinosaurSampleBank.loadBundled()
        for definition in PrehistoricCreatureDefinition.all {
            for cue in ["browse", "attack", "hurt"] {
                let recording = try XCTUnwrap(bank.sample(for: "entity.\(definition.id).\(cue)"))
                XCTAssertEqual(recording.sampleRate, 24_000)
                XCTAssertTrue(recording.frames.allSatisfy { $0.isFinite && abs($0) <= 0.52 })
            }
        }
        let sample = try XCTUnwrap(bank.sample(for: "entity.prehistoric.triceratops.browse"))
        XCTAssertEqual(sample.sampleRate, 24_000)
        XCTAssertGreaterThan(sample.frames.count, 24_000)
        XCTAssertLessThanOrEqual(sample.frames.count, 24_000 * 8)
        XCTAssertGreaterThan(sample.frames.map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertNil(DinosaurSampleBank.assetKey(for: "entity.prehistoric.unknown.hurt"))
        XCTAssertNil(DinosaurSampleBank.assetKey(for: "../../triceratops-grazing"))
        XCTAssertNil(DinosaurSampleBank.assetKey(for: "entity.prehistoric.triceratops.step"))
        XCTAssertEqual(DinosaurSampleBank.assetKey(for: "entity.prehistoric.triceratops.attack"), "triceratops-attack")
        XCTAssertEqual(DinosaurSampleBank.assetKey(for: "entity.prehistoric.triceratops.hurt"), "triceratops-injured")
    }

    func testCreatureRangeAndFalloffForEntireRoster() throws {
        let audio = AudioEngineM()
        audio.setListener(0, 0, 0, 0)
        for name in PrehistoricCreatureDefinition.all.flatMap(\.soundNames) +
            ["entity.cow.ambient", "entity.zombie.hurt"] {
            for volume in [0.25, 1.0, 4.0] {
                for distance in [0.0, 10, 20, 30, 39] {
                    let mix = try XCTUnwrap(audio.gameSoundMix(name, 0, 0, distance, volume))
                    XCTAssertEqual(mix.volume, volume * pow(1 - distance / 40, 2), accuracy: 1e-12)
                }
                XCTAssertNil(audio.gameSoundMix(name, 0, 0, 40, volume))
                XCTAssertNil(audio.gameSoundMix(name, 0, 50, 0, volume))
                XCTAssertNil(audio.gameSoundMix(name, 100, 0, 0, volume))
            }
        }
    }

    func testListenerMovementAndPanAndNonCreatureRange() throws {
        let audio = AudioEngineM()
        let name = "entity.prehistoric.triceratops.hurt"
        audio.setListener(0, 0, 0, 0)
        XCTAssertEqual(try XCTUnwrap(audio.gameSoundMix(name, 20, 0, 0, 1)).pan, 1, accuracy: 1e-12)
        audio.setListener(20, 0, 0, 0)
        XCTAssertEqual(try XCTUnwrap(audio.gameSoundMix(name, 20, 0, 0, 1)).volume, 1)
        audio.setListener(60, 0, 0, 0)
        XCTAssertNil(audio.gameSoundMix(name, 20, 0, 0, 1))
        audio.setListener(0, 0, 0, .pi)
        XCTAssertEqual(try XCTUnwrap(audio.gameSoundMix(name, 20, 0, 0, 1)).pan, -1, accuracy: 1e-12)
        XCTAssertNil(audio.gameSoundMix("block.stone.break", 20, 0, 0, 1))
        XCTAssertNil(audio.gameSoundMix("entity.player.hurt", 20, 0, 0, 1))
        XCTAssertNil(audio.gameSoundMix(name, .nan, 0, 0, 1))
        XCTAssertNil(audio.gameSoundMix(name, 0, 0, 0, .infinity))
        XCTAssertNil(audio.gameSoundMix(name, 0, 0, 0, 0))
    }

    func testEveryPrehistoricCueHasAnExplicitUniqueSynthesizedRecipe() {
        let roster = PrehistoricCreatureDefinition.all
        let expectedNames = Set(roster.flatMap(\.soundNames))
        let recipes = prehistoricSynthesizedSoundRecipes()

        XCTAssertEqual(recipes.count, roster.count * PrehistoricSoundCue.allCases.count)
        XCTAssertEqual(Set(recipes.map(\.name)), expectedNames,
                       "the audio bank must include every direct Core cue, not a fallback")
        XCTAssertEqual(Set(recipes.map(\.acousticSignature)).count, recipes.count,
                       "each creature/action pair must retain its own synthesis motif")

        for definition in roster {
            let prefix = "entity.\(definition.id)."
            let speciesRecipes = recipes.filter { $0.name.hasPrefix(prefix) }
            XCTAssertEqual(speciesRecipes.count, PrehistoricSoundCue.allCases.count)
            XCTAssertTrue(speciesRecipes.allSatisfy {
                $0.subtitle?.contains(definition.displayName) == true
            })
            XCTAssertEqual(
                Set(speciesRecipes.compactMap(\.subtitle)).count,
                PrehistoricSoundCue.allCases.count,
                "each action must have a separately described species cue"
            )
            let expectedCategory = (definition.isPredatory || definition.canCharge) ? "hostile" : "friendly"
            XCTAssertTrue(speciesRecipes.allSatisfy { $0.category == expectedCategory })
        }
    }

    /// End to end: a live dinosaur ticking in a world emits its own call, and that exact sound
    /// renders as the bundled recording through the game mixer from 30 blocks away — beyond the
    /// 18-block reach that made earlier synthesized calls inaudible at herd distances.
    func testLiveDinosaurCallReachesTheMixerAsItsRecording() throws {
        let world = World(dim: .overworld, seed: 0xC0DE,
                          generationSettings: .init(preset: .prehistoricLostWorld))
        for cz in -1...1 {
            for cx in -1...1 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                for z in 0..<CHUNK_W {
                    for x in 0..<CHUNK_W {
                        chunk.set(x, 62, z, cell(B.stone))
                        chunk.set(x, 63, z, cell(B.grass_block))
                    }
                }
                chunk.buildHeightmap()
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        let rex = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.tyrannosaurus"))
        let creature = PrehistoricCreature(world: world, definition: rex)
        creature.setPos(8.5, 64, 8.5)
        world.addEntity(creature)
        var emitted: [String] = []
        world.hooks.playSound = { name, _, _, _, _, _ in emitted.append(name) }
        for _ in 0..<600 where !emitted.contains(rex.soundName(for: .ambient)) {
            creature.tick()
        }
        let call = rex.soundName(for: .ambient)
        XCTAssertTrue(emitted.contains(call), "a live tyrannosaurus must call within 30 seconds")
        XCTAssertNotNil(DinosaurSampleBank.loadBundled().sample(for: call),
                        "its call must resolve to the approved recording, not synthesis")

        let audio = AudioEngineM()
        audio.initEngine(startDevice: false)
        audio.setEnvironment(false, 0)
        audio.setListener(38.5, 64, 8.5, 0) // 30 blocks away
        audio.play(call, 8.5, 64, 8.5)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        buffer.frameLength = 8_192
        audio.render(buffer.frameLength, buffer.mutableAudioBufferList)
        let left = try XCTUnwrap(buffer.floatChannelData?[0])
        let right = try XCTUnwrap(buffer.floatChannelData?[1])
        let peak = (0..<8_192).map { max(abs(left[$0]), abs(right[$0])) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.0005, "a call 30 blocks away must be audible")
    }
}
