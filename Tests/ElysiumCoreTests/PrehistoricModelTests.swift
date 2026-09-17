import XCTest
@testable import ElysiumCore

final class PrehistoricModelTests: XCTestCase {
    private let expectedIDs = [
        "prehistoric.compsognathus", "prehistoric.coelophysis", "prehistoric.velociraptor",
        "prehistoric.dilophosaurus", "prehistoric.deinonychus", "prehistoric.allosaurus",
        "prehistoric.ceratosaurus", "prehistoric.carnotaurus", "prehistoric.tyrannosaurus",
        "prehistoric.spinosaurus", "prehistoric.dryosaurus", "prehistoric.pachycephalosaurus",
        "prehistoric.gallimimus", "prehistoric.oviraptor", "prehistoric.parasaurolophus",
        "prehistoric.edmontosaurus", "prehistoric.iguanodon", "prehistoric.triceratops",
        "prehistoric.styracosaurus", "prehistoric.stegosaurus", "prehistoric.ankylosaurus",
        "prehistoric.diplodocus", "prehistoric.brachiosaurus", "prehistoric.therizinosaurus",
        "prehistoric.dimorphodon", "prehistoric.rhamphorhynchus", "prehistoric.pteranodon",
        "prehistoric.tapejara", "prehistoric.quetzalcoatlus", "prehistoric.microraptor",
        "prehistoric.ichthyosaurus", "prehistoric.plesiosaurus", "prehistoric.elasmosaurus",
        "prehistoric.liopleurodon", "prehistoric.mosasaurus", "prehistoric.deinosuchus",
    ]

    func testBoundedNativeCatalogRegistersEveryRosterModel() {
        XCTAssertEqual(prehistoricModelIDs, expectedIDs)
        XCTAssertEqual(prehistoricModelValidationErrors(), [])

        for id in expectedIDs {
            let geometry = buildEntityGeometry(id)
            XCTAssertEqual(geometry.model.packTex, [], "\(id) must not borrow a resource-pack skin")
            XCTAssertLessThanOrEqual(geometry.model.parts.count, 24, "\(id) must fit EntityUniforms")
            XCTAssertFalse(geometry.partNames.isEmpty, "\(id) must emit drawable parts")
            XCTAssertGreaterThan(geometry.vertexCount, 0, "\(id) must emit geometry")
            for index in stride(from: 0, to: geometry.verts.count, by: 9) {
                XCTAssertTrue(geometry.verts[index..<index + 9].allSatisfy(\.isFinite), "\(id) emitted non-finite geometry")
                XCTAssertTrue((0...1).contains(geometry.verts[index + 6]), "\(id) emitted an invalid U")
                XCTAssertTrue((0...1).contains(geometry.verts[index + 7]), "\(id) emitted an invalid V")
            }
        }
    }

    func testInitialThreeCarryTheirRequiredSilhouetteLandmarks() throws {
        let triceratops = getModel("prehistoric.triceratops")
        let triceratopsHead = try XCTUnwrap(triceratops.parts.first { $0.name == "head" })
        XCTAssertGreaterThanOrEqual(triceratopsHead.boxes.count, 4, "head includes skull plus three horns")
        XCTAssertTrue(triceratops.parts.contains { $0.name == "frill" })

        let pteranodon = getModel("prehistoric.pteranodon")
        XCTAssertTrue(pteranodon.parts.contains { $0.name == "crest" })
        XCTAssertTrue(pteranodon.parts.contains { $0.name == "beak" })
        XCTAssertTrue(pteranodon.parts.contains { $0.name == "wingR" })
        XCTAssertTrue(pteranodon.parts.contains { $0.name == "wingL" })

        let ichthyosaurus = getModel("prehistoric.ichthyosaurus")
        let tail = try XCTUnwrap(ichthyosaurus.parts.first { $0.name == "tail" })
        XCTAssertTrue(tail.boxes.contains { $0.h > $0.d }, "ichthyosaur uses a vertical tail fluke, not a dolphin copy")
        XCTAssertTrue(ichthyosaurus.parts.contains { $0.name == "dorsalFin" })
        XCTAssertTrue(ichthyosaurus.parts.contains { $0.name == "flipperR" })
        XCTAssertTrue(ichthyosaurus.parts.contains { $0.name == "flipperL" })
    }
}
