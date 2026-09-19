import Foundation
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

    /// The entity stream is intentionally non-indexed. A triangle ceiling keeps
    /// the source-authored assets bounded without depending on a GPU timing test.
    private let maximumTrianglesPerModel = 4_096

    private func meshBackedPart(_ model: MobModel, named name: String, id: String,
                                file: StaticString = #filePath, line: UInt = #line) throws -> ModelPart {
        let part = try XCTUnwrap(model.parts.first { $0.name == name },
                                 "\(id) is missing its \(name) landmark", file: file, line: line)
        XCTAssertFalse(part.meshes.isEmpty, "\(id).\(name) must be native mesh geometry", file: file, line: line)
        return part
    }

    private func sourceTriangleAreaSquared(_ a: ModelMeshVertex, _ b: ModelMeshVertex,
                                           _ c: ModelMeshVertex) -> Double {
        let abx = b.x - a.x, aby = b.y - a.y, abz = b.z - a.z
        let acx = c.x - a.x, acy = c.y - a.y, acz = c.z - a.z
        let nx = aby * acz - abz * acy
        let ny = abz * acx - abx * acz
        let nz = abx * acy - aby * acx
        return nx * nx + ny * ny + nz * nz
    }

    private func emittedTriangleAreaSquared(_ vertices: [Float], at offset: Int) -> Double {
        let ax = Double(vertices[offset]), ay = Double(vertices[offset + 1]), az = Double(vertices[offset + 2])
        let bx = Double(vertices[offset + 9]), by = Double(vertices[offset + 10]), bz = Double(vertices[offset + 11])
        let cx = Double(vertices[offset + 18]), cy = Double(vertices[offset + 19]), cz = Double(vertices[offset + 20])
        let abx = bx - ax, aby = by - ay, abz = bz - az
        let acx = cx - ax, acy = cy - ay, acz = cz - az
        let nx = aby * acz - abz * acy
        let ny = abz * acx - abx * acz
        let nz = abx * acy - aby * acx
        return nx * nx + ny * ny + nz * nz
    }

    private func hasVerticalTailFluke(_ model: MobModel) -> Bool {
        let tailParts = model.parts.filter {
            $0.name == "tail" || $0.name == "tailFluke" || $0.name == "verticalTailFluke"
        }
        return tailParts.flatMap(\.meshes).contains { mesh in
            mesh.faces.contains { face in
                guard face.vertices.count >= 3 else { return false }
                let ys = face.vertices.map(\.y)
                let zs = face.vertices.map(\.z)
                guard let minY = ys.min(), let maxY = ys.max(),
                      let minZ = zs.min(), let maxZ = zs.max() else { return false }
                return maxY - minY > maxZ - minZ && maxY - minY > 0.5
            }
        }
    }

    /// The original block roster reused several complete rigs.  This keeps a
    /// future visual refactor from reintroducing a paint/scale-only alias: the
    /// rigid source geometry (not the runtime entity ID or display scale) must
    /// remain distinguishable for every catalog entry.
    private func sourceMeshSignature(_ model: MobModel) -> String {
        model.parts.map { part in
            let transform = [part.pivot.0, part.pivot.1, part.pivot.2,
                             part.rot.0, part.rot.1, part.rot.2]
                .map { String(format: "%.4f", $0) }
                .joined(separator: ",")
            let faces = part.meshes.flatMap(\.faces).map { face in
                face.vertices.map { vertex in
                    [vertex.x, vertex.y, vertex.z, vertex.u, vertex.v]
                        .map { String(format: "%.4f", $0) }
                        .joined(separator: ",")
                }.joined(separator: ";")
            }.joined(separator: "/")
            return "\(part.name):\(transform):\(faces)"
        }.joined(separator: "|")
    }

    private func localXSpan(_ part: ModelPart) -> Double {
        let xs = part.meshes.flatMap(\.faces).flatMap(\.vertices).map(\.x)
        guard let minX = xs.min(), let maxX = xs.max() else { return 0 }
        return maxX - minX
    }

    private func localMaximumY(_ part: ModelPart) -> Double {
        part.meshes.flatMap(\.faces).flatMap(\.vertices).map(\.y).max() ?? -.infinity
    }

    private func partWorldYBounds(_ part: ModelPart) -> (min: Double, max: Double)? {
        let meshY = part.meshes.flatMap(\.faces).flatMap(\.vertices).map { $0.y + part.pivot.1 }
        let boxY = part.boxes.flatMap { box in
            [part.pivot.1 + box.y - box.grow,
             part.pivot.1 + box.y + box.h + box.grow]
        }
        let ys = meshY + boxY
        guard let min = ys.min(), let max = ys.max() else { return nil }
        return (min, max)
    }

    private func localAxisSpan(_ mesh: ModelMesh, keyPath: KeyPath<ModelMeshVertex, Double>) -> Double {
        let values = mesh.faces.flatMap(\.vertices).map { $0[keyPath: keyPath] }
        guard let min = values.min(), let max = values.max() else { return 0 }
        return max - min
    }

    func testBoundedNativeCatalogRegistersEveryRosterModelWithMeshGeometry() throws {
        XCTAssertEqual(prehistoricModelIDs, expectedIDs)
        XCTAssertEqual(prehistoricModelValidationErrors(), [])

        for id in expectedIDs {
            let geometry = buildEntityGeometry(id)
            let model = geometry.model
            XCTAssertEqual(model.packTex, [], "\(id) must not borrow a resource-pack skin")
            XCTAssertLessThanOrEqual(model.parts.count, 24, "\(id) must fit EntityUniforms")
            XCTAssertFalse(geometry.partNames.isEmpty, "\(id) must emit drawable parts")
            XCTAssertFalse(model.parts.flatMap(\.meshes).isEmpty,
                           "\(id) must use source-owned rigid mesh geometry")
            _ = try meshBackedPart(model, named: "body", id: id)
            _ = try meshBackedPart(model, named: "head", id: id)

            for (partIndex, part) in model.parts.enumerated() {
                for (meshIndex, mesh) in part.meshes.enumerated() {
                    XCTAssertFalse(mesh.faces.isEmpty, "\(id).\(part.name).meshes[\(meshIndex)] has no faces")
                    for (faceIndex, face) in mesh.faces.enumerated() {
                        XCTAssertGreaterThanOrEqual(face.vertices.count, 3,
                                                      "\(id).\(part.name).meshes[\(meshIndex)].faces[\(faceIndex)] is not a face")
                        guard face.vertices.count >= 3 else { continue }
                        for vertex in face.vertices {
                            XCTAssertTrue(vertex.x.isFinite && vertex.y.isFinite && vertex.z.isFinite,
                                          "\(id).\(part.name) has a non-finite mesh coordinate")
                            XCTAssertTrue(vertex.u.isFinite && vertex.v.isFinite,
                                          "\(id).\(part.name) has a non-finite mesh UV")
                            XCTAssertTrue((0...Double(model.texW)).contains(vertex.u),
                                          "\(id).\(part.name) has an out-of-skin mesh U")
                            XCTAssertTrue((0...Double(model.texH)).contains(vertex.v),
                                          "\(id).\(part.name) has an out-of-skin mesh V")
                        }
                        for triangle in 1..<(face.vertices.count - 1) {
                            XCTAssertGreaterThan(sourceTriangleAreaSquared(
                                face.vertices[0], face.vertices[triangle], face.vertices[triangle + 1]
                            ), 1e-12, "\(id).\(part.name) has a degenerate source mesh triangle")
                        }
                    }
                }
                XCTAssertLessThan(partIndex, 24, "\(id) emitted an unposeable part")
            }

            XCTAssertEqual(geometry.verts.count % 9, 0, "\(id) must preserve the entity vertex layout")
            XCTAssertEqual(geometry.vertexCount, geometry.verts.count / 9)
            XCTAssertEqual(geometry.vertexCount % 3, 0, "\(id) must emit whole triangles")
            XCTAssertLessThanOrEqual(geometry.vertexCount / 3, maximumTrianglesPerModel,
                                     "\(id) exceeds the native entity mesh budget")
            XCTAssertGreaterThan(geometry.vertexCount, 0, "\(id) must emit geometry")
            for index in stride(from: 0, to: geometry.verts.count, by: 9) {
                XCTAssertTrue(geometry.verts[index..<index + 9].allSatisfy(\.isFinite), "\(id) emitted non-finite geometry")
                XCTAssertTrue((0...1).contains(geometry.verts[index + 6]), "\(id) emitted an invalid U")
                XCTAssertTrue((0...1).contains(geometry.verts[index + 7]), "\(id) emitted an invalid V")
                let normalLength = Foundation.sqrt(
                    Double(geometry.verts[index + 3] * geometry.verts[index + 3]
                           + geometry.verts[index + 4] * geometry.verts[index + 4]
                           + geometry.verts[index + 5] * geometry.verts[index + 5])
                )
                XCTAssertEqual(normalLength, 1, accuracy: 0.0001,
                               "\(id) emitted a non-unit normal")
                let partIndex = geometry.verts[index + 8]
                XCTAssertEqual(partIndex, partIndex.rounded(), "\(id) emitted a fractional part index")
                XCTAssertTrue((0..<Float(model.parts.count)).contains(partIndex),
                              "\(id) emitted a part index outside its rigid pose slots")
            }
            for offset in stride(from: 0, to: geometry.verts.count, by: 27) {
                XCTAssertGreaterThan(emittedTriangleAreaSquared(geometry.verts, at: offset), 1e-12,
                                         "\(id) emitted a degenerate triangle")
            }
        }
    }

    func testRequiredSilhouetteLandmarksAreMeshBacked() throws {
        let triceratops = getModel("prehistoric.triceratops")
        let triceratopsHead = try meshBackedPart(triceratops, named: "head", id: "prehistoric.triceratops")
        XCTAssertGreaterThanOrEqual(triceratopsHead.meshes.count, 5,
                                    "Triceratops needs a head-local frill plus two brow horns and a nasal horn")

        let pteranodon = getModel("prehistoric.pteranodon")
        let pteranodonHead = try meshBackedPart(pteranodon, named: "head", id: "prehistoric.pteranodon")
        XCTAssertGreaterThanOrEqual(pteranodonHead.meshes.count, 3,
                                    "Pteranodon's skull, beak, and crest must share one head pose")
        XCTAssertFalse(pteranodon.parts.contains { ["beak", "crest", "skullCrest", "crown"].contains($0.name) },
                       "Pterosaur skull landmarks cannot be independently rooted")
        for wingName in ["wingR", "wingL"] {
            let wing = try meshBackedPart(pteranodon, named: wingName, id: "prehistoric.pteranodon")
            XCTAssertGreaterThanOrEqual(wing.meshes.count, 2,
                                        "\(wingName) needs one complete arm/finger/membrane pose, not a disconnected outer wing")
        }

        let ichthyosaurus = getModel("prehistoric.ichthyosaurus")
        for part in ["tail", "dorsalFin", "flipperR", "flipperL"] {
            _ = try meshBackedPart(ichthyosaurus, named: part, id: "prehistoric.ichthyosaurus")
        }
        XCTAssertTrue(hasVerticalTailFluke(ichthyosaurus),
                      "Ichthyosaurus needs a vertical tail fluke, not a dolphin-like horizontal tail")

        // Each landmark is carried by the rigid slot which its animation moves.
        // The renderer has no parent transform hierarchy, so split decorative
        // parts would otherwise detach during look, browse, or walk poses.
        let taxonLandmarks: [(String, String, Int)] = [
            ("prehistoric.dilophosaurus", "head", 4),
            ("prehistoric.velociraptor", "tail", 2),
            ("prehistoric.deinonychus", "legR", 3),
            ("prehistoric.deinonychus", "legL", 3),
            ("prehistoric.ceratosaurus", "head", 3),
            ("prehistoric.carnotaurus", "head", 4),
            ("prehistoric.spinosaurus", "body", 2),
            ("prehistoric.therizinosaurus", "armR", 5),
            ("prehistoric.therizinosaurus", "armL", 5),
            ("prehistoric.iguanodon", "armR", 2),
            ("prehistoric.iguanodon", "armL", 2),
            ("prehistoric.styracosaurus", "head", 9),
        ]
        for (id, partName, minimumMeshCount) in taxonLandmarks {
            let model = getModel(id)
            let part = try meshBackedPart(model, named: partName, id: id)
            XCTAssertGreaterThanOrEqual(part.meshes.count, minimumMeshCount,
                                        "\(id)'s distinguishing geometry must travel with \(partName)")
        }
        let velociraptor = getModel("prehistoric.velociraptor")
        XCTAssertFalse(velociraptor.parts.contains { $0.name == "tailFan" },
                       "Velociraptor's tail fan must travel with the animated tail slot")
        let spinosaurusBody = try meshBackedPart(getModel("prehistoric.spinosaurus"), named: "body",
                                                  id: "prehistoric.spinosaurus")
        XCTAssertGreaterThan(localMaximumY(spinosaurusBody), 20,
                             "Spinosaurus's sail must rise above its torso rather than sink into it")

        let deinosuchus = getModel("prehistoric.deinosuchus")
        let deinosuchusHead = try meshBackedPart(deinosuchus, named: "head", id: "prehistoric.deinosuchus")
        XCTAssertGreaterThanOrEqual(deinosuchusHead.meshes.count, 3,
                                    "Deinosuchus needs its skull, long snout, and jaw in the pitched head slot")
        XCTAssertFalse(deinosuchus.parts.contains { $0.name == "snout" || $0.name == "jaw" },
                       "Deinosuchus's head attachments cannot be independently rooted")

        let microraptor = getModel("prehistoric.microraptor")
        for partName in ["wingR", "wingL", "hindWingR", "hindWingL"] {
            let wing = try meshBackedPart(microraptor, named: partName, id: "prehistoric.microraptor")
            XCTAssertGreaterThan(localXSpan(wing), 6,
                                 "Microraptor's \(partName) needs a real lateral feathered span")
        }

        let signatures = expectedIDs.map { sourceMeshSignature(getModel($0)) }
        XCTAssertEqual(Set(signatures).count, expectedIDs.count,
                       "every prehistoric type needs its own source silhouette, not a shared rig with recolor/scale")

        for (left, right) in [
            ("prehistoric.compsognathus", "prehistoric.coelophysis"),
            ("prehistoric.velociraptor", "prehistoric.deinonychus"),
            ("prehistoric.parasaurolophus", "prehistoric.edmontosaurus"),
            ("prehistoric.dimorphodon", "prehistoric.rhamphorhynchus"),
            ("prehistoric.plesiosaurus", "prehistoric.elasmosaurus"),
        ] {
            XCTAssertNotEqual(sourceMeshSignature(getModel(left)), sourceMeshSignature(getModel(right)),
                              "\(left) and \(right) must be recognizable as different source silhouettes")
        }
    }

    func testBipedHipsJoinTheirPresentationTorsosAndCeratopsianFrillsAreTransverse() throws {
        let bipedIDs = expectedIDs.filter { getModel($0).anim == "biped" }
        XCTAssertFalse(bipedIDs.isEmpty)
        for id in bipedIDs {
            let model = getModel(id)
            let body = try meshBackedPart(model, named: "body", id: id)
            let bodyBounds = try XCTUnwrap(partWorldYBounds(body), "\(id) needs torso bounds")
            for legName in ["legR", "legL"] {
                let leg = try meshBackedPart(model, named: legName, id: id)
                let legBounds = try XCTUnwrap(partWorldYBounds(leg), "\(id) needs \(legName) bounds")
                XCTAssertGreaterThanOrEqual(legBounds.max, bodyBounds.min - 0.45,
                                            "\(id).\(legName) must meet the torso hip instead of floating below it")
            }
        }

        for id in ["prehistoric.triceratops", "prehistoric.styracosaurus"] {
            let head = try meshBackedPart(getModel(id), named: "head", id: id)
            XCTAssertTrue(head.meshes.contains { mesh in
                let lateral = localAxisSpan(mesh, keyPath: \.x)
                let foreAft = localAxisSpan(mesh, keyPath: \.z)
                return lateral > 10 && lateral > foreAft * 3.5
            }, "\(id) needs a broad transverse frill, not a sagittal dorsal sail")
        }
    }
}
