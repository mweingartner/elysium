import XCTest
@testable import PebbleAppSupport

final class PebbleAppSupportTests: XCTestCase {
    private func revealPredicates(
        opaque: Bool = true, visible: Bool = true, ordinaryLevel: Bool = true,
        mouseAccepting: Bool = true, finitePositiveGeometry: Bool = true,
        onScreen: Bool = true, fullscreenEntered: Bool = false,
        fullscreenStyle: Bool = false, keyWindow: Bool = false
    ) -> PebbleLaunchRevealPredicates {
        PebbleLaunchRevealPredicates(
            opaque: opaque, visible: visible, ordinaryLevel: ordinaryLevel,
            mouseAccepting: mouseAccepting, finitePositiveGeometry: finitePositiveGeometry,
            onScreen: onScreen, fullscreenEntered: fullscreenEntered,
            fullscreenStyle: fullscreenStyle, keyWindow: keyWindow)
    }

    func testLaunchRevealRequestsExactlyOnceForEitherValidInactiveKind() {
        for kind in [PebbleLaunchRevealKind.fullscreen, .windowedFallback] {
            var state = PebbleLaunchActivationState(windowIdentity: 7, generation: 9)
            let token = state.token(kind: kind, windowIdentity: 7, generation: 9)
            let predicates = revealPredicates(
                fullscreenEntered: kind == .fullscreen,
                fullscreenStyle: kind == .fullscreen)
            XCTAssertEqual(
                state.consume(token, predicates: predicates, applicationActive: false),
                .request)
            XCTAssertTrue(state.isClosed)
            for _ in 0..<4 {
                XCTAssertEqual(
                    state.consume(token, predicates: predicates, applicationActive: false),
                    .noRequest)
            }
        }
    }

    func testLaunchRevealAlreadyActiveRequestsZeroAndCloses() {
        var state = PebbleLaunchActivationState(windowIdentity: 7, generation: 9)
        let token = state.token(kind: .fullscreen, windowIdentity: 7, generation: 9)
        XCTAssertEqual(state.consume(
            token,
            predicates: revealPredicates(
                fullscreenEntered: true, fullscreenStyle: true, keyWindow: true),
            applicationActive: true), .noRequest)
        XCTAssertTrue(state.isClosed)
    }

    func testLaunchRevealEveryInvalidOrTransitionalPredicateFailsClosed() {
        let invalid: [PebbleLaunchRevealPredicates] = [
            revealPredicates(opaque: false),
            revealPredicates(visible: false),
            revealPredicates(ordinaryLevel: false),
            revealPredicates(mouseAccepting: false),
            revealPredicates(finitePositiveGeometry: false),
            revealPredicates(onScreen: false),
            revealPredicates(fullscreenEntered: true, fullscreenStyle: false),
            revealPredicates(fullscreenEntered: false, fullscreenStyle: true),
            revealPredicates(keyWindow: true),
        ]
        for predicates in invalid {
            var state = PebbleLaunchActivationState(windowIdentity: 7, generation: 9)
            let token = state.token(kind: .windowedFallback, windowIdentity: 7, generation: 9)
            XCTAssertEqual(
                state.consume(token, predicates: predicates, applicationActive: false),
                .noRequest)
            XCTAssertTrue(state.isClosed)
            XCTAssertEqual(state.consume(
                token, predicates: revealPredicates(), applicationActive: false), .noRequest)
        }
        for (identity, generation) in [(8, UInt64(9)), (7, UInt64(10))] {
            var state = PebbleLaunchActivationState(windowIdentity: 7, generation: 9)
            let stale = state.token(
                kind: .windowedFallback, windowIdentity: identity, generation: generation)
            XCTAssertEqual(state.consume(
                stale, predicates: revealPredicates(), applicationActive: false), .noRequest)
            XCTAssertTrue(state.isClosed)
        }
    }

    func testExhaustedDispositionMatrix() {
        let latch = PebbleAppInputExhaustionLatch()
        XCTAssertNil(latch.disposition(source: .keyDown, protectedEquivalent: false))
        XCTAssertTrue(latch.recordFlagsChanged(mask: 1))
        latch.exhaust()
        XCTAssertFalse(latch.mayDispatchRelease())
        XCTAssertEqual(latch.disposition(source: .keyDown, protectedEquivalent: false), .consume)
        XCTAssertEqual(latch.disposition(source: .performKeyEquivalent, protectedEquivalent: true), .consume)
        XCTAssertEqual(latch.disposition(source: .performKeyEquivalent, protectedEquivalent: false), .passThrough)
        for mask in [UInt64(2), 3, 4, 5] {
            XCTAssertFalse(latch.recordFlagsChanged(mask: mask))
            XCTAssertEqual(latch.lastModifierMask, mask)
        }
        XCTAssertTrue(latch.isExhausted)
        latch.resetInputSession()
        XCTAssertFalse(latch.isExhausted)
        XCTAssertTrue(latch.mayDispatchRelease())
        XCTAssertEqual(latch.lastModifierMask, 0)
        XCTAssertTrue(latch.recordFlagsChanged(mask: 8))
    }
    func testStructuralKeySeparatesEveryIdentityDimension() {
        let value = PebbleRetainedDescriptorKey(id: "a", role: "cell", parentID: "root", actionable: true, focusable: true)
        let base = PebbleRetainedStructureKey(screenIdentity: 1, generation: 2, orderedDescriptors: [value])
        XCTAssertNotEqual(base, .init(screenIdentity: 2, generation: 2, orderedDescriptors: [value]))
        XCTAssertNotEqual(base, .init(screenIdentity: 1, generation: 3, orderedDescriptors: [value]))
        for changed in [
            PebbleRetainedDescriptorKey(id: "b", role: "cell", parentID: "root", actionable: true, focusable: true),
            PebbleRetainedDescriptorKey(id: "a", role: "button", parentID: "root", actionable: true, focusable: true),
            PebbleRetainedDescriptorKey(id: "a", role: "cell", parentID: "other", actionable: true, focusable: true),
            PebbleRetainedDescriptorKey(id: "a", role: "cell", parentID: "root", actionable: false, focusable: true),
            PebbleRetainedDescriptorKey(id: "a", role: "cell", parentID: "root", actionable: true, focusable: false),
        ] { XCTAssertNotEqual(base, .init(screenIdentity: 1, generation: 2, orderedDescriptors: [changed])) }
    }

    func testRetainedTreeStorePreservesReferencesForScalarsAndReplacesEveryStructure() {
        final class Node {}
        let descriptor = PebbleRetainedDescriptorKey(
            id: "a", role: "cell", parentID: "root", actionable: true, focusable: true)
        let base = PebbleRetainedStructureKey(
            screenIdentity: 1, generation: 2, orderedDescriptors: [descriptor])
        let store = PebbleRetainedTreeStore<Node>()
        let original = Node()
        guard case .structuralReplacement(let old, let current) = store.update(
            key: base, makeNodes: { [original] }) else { return XCTFail("initial replacement") }
        XCTAssertTrue(old.isEmpty)
        XCTAssertTrue(current[0] === original)
        var allocations = 0
        guard case .scalarRefresh(let retained) = store.update(key: base, makeNodes: {
            allocations += 1; return [Node()]
        }) else { return XCTFail("scalar refresh") }
        XCTAssertEqual(allocations, 0)
        XCTAssertTrue(retained[0] === original)

        let structuralKeys = [
            PebbleRetainedStructureKey(screenIdentity: 9, generation: 2, orderedDescriptors: [descriptor]),
            PebbleRetainedStructureKey(screenIdentity: 1, generation: 9, orderedDescriptors: [descriptor]),
            PebbleRetainedStructureKey(screenIdentity: 1, generation: 2, orderedDescriptors: [
                .init(id: "b", role: "cell", parentID: "root", actionable: true, focusable: true)]),
            PebbleRetainedStructureKey(screenIdentity: 1, generation: 2, orderedDescriptors: [
                .init(id: "a", role: "button", parentID: "root", actionable: true, focusable: true)]),
            PebbleRetainedStructureKey(screenIdentity: 1, generation: 2, orderedDescriptors: [
                .init(id: "a", role: "cell", parentID: "other", actionable: true, focusable: true)]),
            PebbleRetainedStructureKey(screenIdentity: 1, generation: 2, orderedDescriptors: [
                .init(id: "a", role: "cell", parentID: "root", actionable: false, focusable: true)]),
            PebbleRetainedStructureKey(screenIdentity: 1, generation: 2, orderedDescriptors: [
                .init(id: "a", role: "cell", parentID: "root", actionable: true, focusable: false)]),
        ]
        var prior = original
        for key in structuralKeys {
            let replacement = Node()
            guard case .structuralReplacement(let retired, let current) = store.update(
                key: key, makeNodes: { [replacement] }) else { return XCTFail("replacement") }
            XCTAssertTrue(retired[0] === prior)
            XCTAssertFalse(current[0] === prior)
            prior = replacement
        }
        XCTAssertTrue(store.invalidate()[0] === prior)
    }
}
