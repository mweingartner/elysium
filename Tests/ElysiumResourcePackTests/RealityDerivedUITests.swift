import XCTest
@testable import Elysium
@testable import ElysiumCore

final class RealityDerivedUITests: XCTestCase {
    func testBBoxValidationCanonicalizesArnisLatitudeLongitudeOrder() {
        XCTAssertEqual(
            RealityDerivedRequestValidation.canonicalBBox("21.300000 -157.860000 21.305000 -157.855000"),
            "21.300000,-157.860000,21.305000,-157.855000")
    }

    func testBBoxValidationRejectsNonFiniteInvertedAndOversizedSelections() {
        XCTAssertNil(RealityDerivedRequestValidation.canonicalBBox("nan,0,1,1"))
        XCTAssertNil(RealityDerivedRequestValidation.canonicalBBox("2,1,1,2"))
        XCTAssertNil(RealityDerivedRequestValidation.canonicalBBox("21,-158,22,-157"))
    }

    func testSizeTiersExpandCapacityThroughArnisMaximum() {
        let mediumSelection = "0,0,0.02,0.02"
        XCTAssertNil(RealityDerivedRequestValidation.canonicalBBox(
            mediumSelection, mapSize: .small))
        XCTAssertNotNil(RealityDerivedRequestValidation.canonicalBBox(
            mediumSelection, mapSize: .medium))

        // About 249.8 km² at the equator: accepted only by Max and still below the
        // authoritative one-million imported-chunk / 1,048,576 total-row limits.
        let maximumSelection = "0,0,0.142,0.142"
        XCTAssertNil(RealityDerivedRequestValidation.canonicalBBox(
            maximumSelection, mapSize: .extraLarge))
        XCTAssertNotNil(RealityDerivedRequestValidation.canonicalBBox(
            maximumSelection, mapSize: .max))
        XCTAssertNil(RealityDerivedRequestValidation.canonicalBBox(
            maximumSelection, scale: 3, mapSize: .max),
            "scale expansion must not bypass the Max block-column budget")
    }

    func testWorldCreatorExposesAllSharedMapSizeLabels() {
        XCTAssertEqual(WorldMapSize.allCases.map(\.displayName),
                       ["Small", "Medium", "Large", "Extra-Large", "Max"])
        XCTAssertEqual(WorldMapSize.max.sideBlocks, 15_811)
        XCTAssertLessThanOrEqual(
            Double(WorldMapSize.max.sideBlocks * WorldMapSize.max.sideBlocks),
            REALITY_DERIVED_MAX_PHYSICAL_AREA_SQUARE_METRES)
    }

    func testBuildingCheckboxMapsToExplicitHelperArguments() {
        XCTAssertEqual(RealityDerivedRequestValidation.helperBuildingArgument(includeBuildings: true),
                       "--include-buildings=true")
        XCTAssertEqual(RealityDerivedRequestValidation.helperBuildingArgument(includeBuildings: false),
                       "--include-buildings=false")
    }
}
