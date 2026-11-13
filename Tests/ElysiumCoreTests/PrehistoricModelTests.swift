import Foundation
import XCTest
@testable import ElysiumCore

final class PrehistoricModelTests: XCTestCase {
    /// The animator profiles of the jointed rigs (`PrehistoricRig.Plan`).
    private let jointedPlans = PrehistoricRigPlan.allCases.map(\.rawValue)
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
        for (wingName, tipName) in [("wingR", "wingTipR"), ("wingL", "wingTipL")] {
            let wing = try meshBackedPart(pteranodon, named: wingName, id: "prehistoric.pteranodon")
            XCTAssertGreaterThanOrEqual(wing.meshes.count, 2, "\(wingName) needs its arm and its inner membrane")
            let tip = try meshBackedPart(pteranodon, named: tipName, id: "prehistoric.pteranodon")
            XCTAssertGreaterThanOrEqual(tip.meshes.count, 2, "\(tipName) needs its wing finger and its outer membrane")
            XCTAssertEqual(tip.parent, wingName, "the outer wing hangs from the inner wing at the wrist")
        }

        let ichthyosaurus = getModel("prehistoric.ichthyosaurus")
        for part in ["tail", "dorsalFin", "flipperR", "flipperL"] {
            _ = try meshBackedPart(ichthyosaurus, named: part, id: "prehistoric.ichthyosaurus")
        }
        XCTAssertTrue(hasVerticalTailFluke(ichthyosaurus),
                      "Ichthyosaurus needs a vertical tail fluke, not a dolphin-like horizontal tail")

        // Each landmark is carried by the rigid slot which its animation moves: a crest
        // turns with the skull, a tail fan with the last tail segment, a claw with the
        // foot. (A theropod's lower jaw is its own part, hinged on the head.)
        let taxonLandmarks: [(String, String, Int)] = [
            ("prehistoric.dilophosaurus", "head", 3),
            ("prehistoric.velociraptor", "tail2", 2),
            ("prehistoric.deinonychus", "footR", 3),
            ("prehistoric.deinonychus", "footL", 3),
            ("prehistoric.ceratosaurus", "head", 2),
            ("prehistoric.carnotaurus", "head", 3),
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
        let bipedIDs = expectedIDs.filter { getModel($0).anim == PrehistoricRigPlan.biped.rawValue }
        XCTAssertEqual(bipedIDs.count, 18)
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

    /// The jointed rigs: which part hangs from which, and where each bone ends. The
    /// renderer's pose code trusts this data, so it is pinned here next to the models.
    func testJointedModelsNameTheirParentsAndTheirBonesMeetAtTheJoints() throws {
        let expectedParts: [String: Int] = [
            "compsognathus": 15, "coelophysis": 15, "velociraptor": 15, "dilophosaurus": 15, "deinonychus": 15,
            "allosaurus": 15, "ceratosaurus": 15, "carnotaurus": 15, "tyrannosaurus": 15, "spinosaurus": 15,
            "therizinosaurus": 15,
            "dryosaurus": 14, "pachycephalosaurus": 14, "gallimimus": 14, "oviraptor": 14,
            "parasaurolophus": 14, "edmontosaurus": 14, "iguanodon": 14,
            "triceratops": 16, "styracosaurus": 16, "stegosaurus": 17, "ankylosaurus": 17,
            "diplodocus": 22, "brachiosaurus": 22,
            "dimorphodon": 11, "rhamphorhynchus": 11, "pteranodon": 10, "tapejara": 10, "quetzalcoatlus": 11,
            "microraptor": 10,
            // The swimmers are not jointed and keep their part lists.
            "ichthyosaurus": 7, "plesiosaurus": 10, "elasmosaurus": 14, "liopleurodon": 9, "mosasaurus": 7,
            "deinosuchus": 8,
        ]
        XCTAssertEqual(expectedParts.count, expectedIDs.count)
        var jointed = 0
        for id in expectedIDs {
            let model = getModel(id)
            let short = String(id.dropFirst("prehistoric.".count))
            XCTAssertEqual(model.parts.count, expectedParts[short], "\(id) part count")
            guard jointedPlans.contains(model.anim) else {
                XCTAssertTrue(model.parts.allSatisfy { $0.parent == nil && $0.tip == nil },
                              "\(id) is not jointed and must not claim rig data")
                continue
            }
            jointed += 1
            var seen: [String: ModelPart] = [:]
            for part in model.parts {
                if part.name == "body" {
                    XCTAssertNil(part.parent, "\(id): the body is the root")
                    XCTAssertTrue(part.rot == (0, 0, 0), "\(id): the body carries no baked rotation")
                } else {
                    let parentName = try XCTUnwrap(part.parent, "\(id).\(part.name) hangs from nothing")
                    let parent = try XCTUnwrap(seen[parentName], "\(id).\(part.name): parent \(parentName) must come first")
                    // A segment of a limb, a neck, a tail or a wing starts where its parent's bone ends.
                    let continues = part.name.hasPrefix("shin") || part.name.hasPrefix("foot")
                        || part.name.hasPrefix("wingTip") || (part.name.last?.isNumber ?? false)
                    if continues {
                        let tip = try XCTUnwrap(parent.tip, "\(id).\(parentName) needs a bone end for \(part.name)")
                        let cosX = Foundation.cos(parent.rot.0), sinX = Foundation.sin(parent.rot.0)
                        let joint = (parent.pivot.0 + tip.0,
                                     parent.pivot.1 + tip.1 * cosX - tip.2 * sinX,
                                     parent.pivot.2 + tip.1 * sinX + tip.2 * cosX)
                        XCTAssertEqual(joint.0, part.pivot.0, accuracy: 0.001, "\(id).\(part.name) x")
                        XCTAssertEqual(joint.1, part.pivot.1, accuracy: 0.001, "\(id).\(part.name) y")
                        XCTAssertEqual(joint.2, part.pivot.2, accuracy: 0.001, "\(id).\(part.name) z")
                        XCTAssertTrue(parent.rot.1 == 0 && parent.rot.2 == 0, "\(id).\(parentName): chains bake x rotation only")
                    }
                }
                if let tip = part.tip {
                    XCTAssertTrue(tip.0.isFinite && tip.1.isFinite && tip.2.isFinite, "\(id).\(part.name) bone end")
                    XCTAssertGreaterThan(tip.0 * tip.0 + tip.1 * tip.1 + tip.2 * tip.2, 0.01, "\(id).\(part.name) has no length")
                }
                seen[part.name] = part
            }
            // Feet stand on the ground: the walking legs end within a toe's depth of y = 0.
            for part in model.parts where part.name.hasPrefix("foot") {
                let tip = try XCTUnwrap(part.tip)
                let ground = part.pivot.1 + tip.1
                XCTAssertTrue((-0.05...2.2).contains(ground), "\(id).\(part.name) ends \(ground) units above the ground")
            }
        }
        XCTAssertEqual(jointed, 30, "24 land and 6 flying species are jointed")
    }

    /// The pose code drives both sides of an animal with the same numbers, so a left limb that
    /// is not the mirror of its right one would limp or fly crooked.
    func testEveryJointedLimbMirrorsItsOtherSide() throws {
        for id in expectedIDs where jointedPlans.contains(getModel(id).anim) {
            let model = getModel(id)
            let byName = Dictionary(uniqueKeysWithValues: model.parts.map { ($0.name, $0) })
            var pairs = 0
            for part in model.parts where part.name.hasSuffix("L") {
                let rightName = String(part.name.dropLast()) + "R"
                let right = try XCTUnwrap(byName[rightName], "\(id).\(part.name) has no \(rightName)")
                pairs += 1
                XCTAssertEqual(part.pivot.0, -right.pivot.0, accuracy: 0.001, "\(id).\(part.name) pivot x")
                XCTAssertEqual(part.pivot.1, right.pivot.1, accuracy: 0.001, "\(id).\(part.name) pivot y")
                XCTAssertEqual(part.pivot.2, right.pivot.2, accuracy: 0.001, "\(id).\(part.name) pivot z")
                XCTAssertEqual(part.rot.0, right.rot.0, accuracy: 0.001, "\(id).\(part.name) pitch")
                XCTAssertEqual(part.rot.1, -right.rot.1, accuracy: 0.001, "\(id).\(part.name) yaw")
                XCTAssertEqual(part.rot.2, -right.rot.2, accuracy: 0.001, "\(id).\(part.name) roll")
                XCTAssertEqual(part.parent.map { $0.hasSuffix("L") ? String($0.dropLast()) + "R" : $0 }, right.parent,
                               "\(id).\(part.name) hangs from the mirror of \(rightName)'s parent")
                XCTAssertEqual(part.tip == nil, right.tip == nil, "\(id).\(part.name) bone end")
                if let tip = part.tip, let other = right.tip {
                    XCTAssertEqual(tip.0, -other.0, accuracy: 0.001, "\(id).\(part.name) bone end x")
                    XCTAssertEqual(tip.1, other.1, accuracy: 0.001, "\(id).\(part.name) bone end y")
                    XCTAssertEqual(tip.2, other.2, accuracy: 0.001, "\(id).\(part.name) bone end z")
                }
            }
            XCTAssertGreaterThanOrEqual(pairs, 2, "\(id) has paired limbs")
        }
    }
}
