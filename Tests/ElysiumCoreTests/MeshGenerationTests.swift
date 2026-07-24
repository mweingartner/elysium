import XCTest
@testable import ElysiumCore

final class MeshGenerationTests: XCTestCase {
    func testContextClockPreparesImmutableCheckedSuccessorAndFailsAtExhaustion() throws {
        var tint: [UInt8] = [0, 1]
        var texture: [UInt8] = [1, 0]
        var clock = MeshRenderContextClock()

        let prepared = try XCTUnwrap(clock.prepare(tintGate: tint, textureGate: texture))
        XCTAssertEqual(prepared.generation, 2)
        tint[0] = 1
        texture[0] = 0
        XCTAssertEqual(prepared.tintGate, [0, 1])
        XCTAssertEqual(prepared.textureGate, [1, 0])
        XCTAssertEqual(clock.live, .procedural, "preparation cannot mutate live provenance")
        XCTAssertTrue(clock.install(prepared))
        XCTAssertEqual(clock.live, prepared)
        XCTAssertFalse(clock.install(prepared), "a stale prepared generation cannot reinstall")

        let exhaustedContext = try XCTUnwrap(MeshRenderContext(
            tintGate: nil, textureGate: nil, generation: .max))
        let exhaustedClock = MeshRenderContextClock(live: exhaustedContext)
        XCTAssertNil(exhaustedClock.prepare(tintGate: [0], textureGate: [1]))
        XCTAssertNil(MeshRenderContext(tintGate: nil, textureGate: nil, generation: 0))
    }

    func testMeshInputOwnsItsContextSnapshot() throws {
        let context = try XCTUnwrap(MeshRenderContext(
            tintGate: [0], textureGate: [1], generation: 9))
        let input = MeshInput(blocks: [], skyLight: [], blockLight: [], biomes: [],
                              renderContext: context)
        XCTAssertEqual(input.renderContext, context)
        XCTAssertEqual(input.renderContext.generation, 9)
    }

    func testOldGenerationAndSameKeyReplacementCompletionHaveNoEffects() {
        let old = MeshJobState(generation: 2)
        old.dirtyAgain = true
        let replacement = MeshJobState(generation: 3)
        var jobs = ["section": replacement]
        var uploads = 0
        var counter = 0
        var requeues = 0

        XCTAssertFalse(withAdmittedMeshCompletion(
            liveGeneration: 3, liveState: jobs["section"], completedState: old
        ) {
            jobs.removeValue(forKey: "section")
            uploads += 1
            counter += 1
            if old.dirtyAgain { requeues += 1 }
        })
        XCTAssertTrue(jobs["section"] === replacement)
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(counter, 0)
        XCTAssertEqual(requeues, 0)

        let sameGenerationButObsolete = MeshJobState(generation: 3)
        XCTAssertFalse(withAdmittedMeshCompletion(
            liveGeneration: 3, liveState: jobs["section"], completedState: sameGenerationButObsolete
        ) {
            jobs.removeValue(forKey: "section")
            uploads += 1
        })
        XCTAssertTrue(jobs["section"] === replacement)
        XCTAssertEqual(uploads, 0)

        XCTAssertTrue(withAdmittedMeshCompletion(
            liveGeneration: 3, liveState: jobs["section"], completedState: replacement
        ) {
            jobs.removeValue(forKey: "section")
            uploads += 1
            counter += 1
        })
        XCTAssertNil(jobs["section"])
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(counter, 1)
    }
}
