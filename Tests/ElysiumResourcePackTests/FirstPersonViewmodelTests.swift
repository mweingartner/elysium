import Foundation
import Metal
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class FirstPersonViewmodelTests: XCTestCase {
    private static let faithfulPack: ResourcePack? = {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return ResourcePack(url: repository.appendingPathComponent(
            "packaging/Faithful 64x - December 2025 Release.zip"))
    }()

    private let simpleProfile = ViewmodelProfile(action: .generic, length: 0.5,
                                                  grip: SIMD2(0.5, 0.5), straighten: 0)

    private func image(width: Int, height: Int, occupied: [(Int, Int)],
                       color: [UInt8] = [190, 125, 61, 255]) -> RGBAImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (x, y) in occupied {
            for channel in 0..<4 { pixels[(y * width + x) * 4 + channel] = color[channel] }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    private func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

    private func assertValidTriangles(_ mesh: ViewmodelMesh, label: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(mesh.vertices.isEmpty, label, file: file, line: line)
        XCTAssertEqual(mesh.vertices.count % 3, 0, label, file: file, line: line)
        XCTAssertLessThan(mesh.vertices.count, 250_000, label, file: file, line: line)
        for v in mesh.vertices {
            for value in [v.position.x, v.position.y, v.position.z,
                          v.normal.x, v.normal.y, v.normal.z,
                          v.color.x, v.color.y, v.color.z, v.color.w] {
                XCTAssertTrue(value.isFinite, label, file: file, line: line)
            }
            XCTAssertEqual(v.position.w, 1, label, file: file, line: line)
            XCTAssertEqual(v.normal.w, 0, label, file: file, line: line)
            XCTAssertEqual(simd_length(xyz(v.normal)), 1, accuracy: 0.0001,
                           label, file: file, line: line)
            XCTAssertLessThan(simd_length(xyz(v.position)), 2.5, label, file: file, line: line)
            for channel in [v.color.x, v.color.y, v.color.z, v.color.w] {
                XCTAssertTrue((0...1).contains(channel), label, file: file, line: line)
            }
        }
        for i in stride(from: 0, to: mesh.vertices.count, by: 3) {
            let a = mesh.vertices[i], b = mesh.vertices[i + 1], c = mesh.vertices[i + 2]
            let areaNormal = simd_cross(xyz(b.position - a.position), xyz(c.position - a.position))
            XCTAssertGreaterThan(simd_length(areaNormal), 1e-10,
                                 "\(label): triangle \(i / 3) is degenerate", file: file, line: line)
            XCTAssertGreaterThan(simd_dot(areaNormal, xyz(a.normal)), 0,
                                 "\(label): winding opposes its outward normal", file: file, line: line)
        }
    }

    private func assertClosedEdges(_ mesh: ViewmodelMesh,
                                   file: StaticString = #filePath, line: UInt = #line) {
        func key(_ p: SIMD4<Float>) -> String {
            [p.x, p.y, p.z].map { String(Int(($0 * 1_000_000).rounded())) }.joined(separator: ",")
        }
        var edges: [String: Int] = [:]
        for i in stride(from: 0, to: mesh.vertices.count, by: 3) {
            let triangle = (0..<3).map { key(mesh.vertices[i + $0].position) }
            for edge in [(0, 1), (1, 2), (2, 0)] {
                let undirected = [triangle[edge.0], triangle[edge.1]].sorted().joined(separator: "/")
                edges[undirected, default: 0] += 1
            }
        }
        XCTAssertTrue(edges.values.allSatisfy { $0 == 2 },
                      "solid shell edges must have exactly two incident triangles: \(edges.filter { $0.value != 2 })",
                      file: file, line: line)
    }

    func testExtrusionBuildsClosedFrontBackAndSilhouetteWithoutInternalSidewalls() {
        let mesh = ViewmodelMesh.extruded(image(width: 2, height: 1, occupied: [(0, 0), (1, 0)]),
                                         profile: simpleProfile)
        // Two front + two back quads, six silhouette quads. Per-texel boxes would
        // incorrectly add two internal, overlapping sidewalls at the central seam.
        XCTAssertEqual(mesh.vertices.count, 60)
        XCTAssertEqual(mesh.vertices.filter { $0.normal.z == 1 }.count, 12)
        XCTAssertEqual(mesh.vertices.filter { $0.normal.z == -1 }.count, 12)
        XCTAssertFalse(mesh.vertices.contains { abs($0.position.x) < 1e-6 && abs($0.normal.x) > 0.9 })
        assertValidTriangles(mesh, label: "two connected texels")
        assertClosedEdges(mesh)
    }

    func testConcaveSilhouetteClosesItsNotchAndRetainsNativeTexelColors() {
        var source = image(width: 2, height: 2, occupied: [(0, 0), (0, 1), (1, 1)])
        source.pixels[0] = 60
        source.pixels[1] = 180
        let mesh = ViewmodelMesh.extruded(source, profile: simpleProfile)
        XCTAssertEqual(mesh.vertices.count, 84) // six face quads + eight silhouette quads
        assertValidTriangles(mesh, label: "concave silhouette")
        assertClosedEdges(mesh)
        let colors = Set(mesh.vertices.map { "\($0.color.x),\($0.color.y),\($0.color.z)" })
        XCTAssertEqual(colors.count, 2, "native texel colors must not blur into a low-resolution average")
    }

    func testSingleDetachedSpecksAndTransparentTexelsDoNotBecomeHandFragments() {
        var source = image(width: 8, height: 8, occupied: [(2, 2), (3, 2), (7, 7)])
        source.pixels[(5 * 8 + 5) * 4 + 3] = 127
        let mesh = ViewmodelMesh.extruded(source, profile: simpleProfile)
        let clean = ViewmodelMesh.extruded(image(width: 8, height: 8, occupied: [(2, 2), (3, 2)]),
                                          profile: simpleProfile)
        XCTAssertEqual(mesh.vertices.count, clean.vertices.count)
        for (a, b) in zip(mesh.vertices, clean.vertices) { XCTAssertEqual(a.position, b.position) }
    }

    func testExtrusionRejectsMalformedAndOversizedImages() {
        for source in [RGBAImage(width: 0, height: 1, pixels: []),
                       RGBAImage(width: -1, height: 1, pixels: []),
                       RGBAImage(width: 65, height: 1, pixels: [UInt8](repeating: 255, count: 260)),
                       RGBAImage(width: 2, height: 2, pixels: [0, 0, 0, 255])] {
            XCTAssertTrue(ViewmodelMesh.extruded(source, profile: simpleProfile).vertices.isEmpty)
        }
        XCTAssertTrue(ViewmodelMesh([Float](repeating: 0, count: 10)).vertices.isEmpty)
    }

    func testDiagonalMinecraftHaftsBecomeVerticalAndPassThroughGripOrigin() {
        registerAllBlocks(); registerAllItems()
        for family in ["axe", "shovel", "hoe", "sword", "pickaxe"] {
            // The authored axe/shovel/hoe shaft is offset one base texel from the
            // canvas diagonal; sword/pickaxe use the centered diagonal. The real
            // Faithful image test below independently verifies these profiles.
            let diagonal = ["axe", "shovel", "hoe"].contains(family) ? 16 : 15
            let source = image(width: 16, height: 16, occupied: (1...12).map { ($0, diagonal - $0) })
            let definition = itemDef(iid("iron_\(family)"))
            let profile = ViewmodelProfile.item(definition)
            let mesh = ViewmodelMesh.extruded(source, profile: profile)
            let front = mesh.vertices.filter { $0.normal.z > 0.99 }
            XCTAssertEqual(front.count, 12 * 6)
            var centers: [SIMD3<Float>] = []
            for i in stride(from: 0, to: front.count, by: 6) {
                let center = front[i..<i + 6].reduce(SIMD3<Float>.zero) { $0 + xyz($1.position) } / 6
                centers.append(center)
                XCTAssertEqual(center.x, 0, accuracy: 0.000001,
                               "\(family)'s authored diagonal shaft must align with the hand's +Y grip axis")
            }
            XCTAssertLessThan(centers.map(\.y).min()!, 0, "\(family) must continue below the fist")
            XCTAssertGreaterThan(centers.map(\.y).max()!, 0.4, "\(family) must extend above the fist")
            assertValidTriangles(mesh, label: family)
        }
    }

    func testBlockPropIsClosedThreeDimensionalGeometryWithAtlasFaces() {
        registerAllBlocks(); registerAllItems()
        let mesh = ViewmodelMesh.block(Int(bid("stone")))
        XCTAssertEqual(mesh.vertices.count, 36)
        XCTAssertTrue(mesh.vertices.allSatisfy { $0.surface.z >= 0 })
        XCTAssertEqual(Set(mesh.vertices.map { $0.normal }).count, 6)
        assertValidTriangles(mesh, label: "stone block")
        assertClosedEdges(mesh)
        XCTAssertTrue(ViewmodelMesh.block(-1).vertices.isEmpty)
        XCTAssertTrue(ViewmodelMesh.block(blockDefs.count).vertices.isEmpty)
    }

    func testAuthoredArmHandShieldAndAllPickaxeMaterialsAreFiniteBoundedAndOutwardWound() {
        let models: [(String, [Float])] = [
            ("forearm", FirstPersonModelAssets.forearm), ("upper arm", FirstPersonModelAssets.upperArm),
            ("hand", FirstPersonModelAssets.hand),
            ("narrow hand", FirstPersonModelAssets.handNarrow),
            ("shield hand", FirstPersonModelAssets.handShield), ("round hand", FirstPersonModelAssets.handRound),
            ("drawing hand", FirstPersonModelAssets.handDraw), ("wrist joint", FirstPersonModelAssets.wristJoint),
            ("shield", FirstPersonModelAssets.shield),
        ] + ["wooden", "stone", "iron", "copper", "golden", "diamond", "netherite"].map {
            ("\($0) pickaxe", FirstPersonModelAssets.pickaxe(material: $0))
        }
        for (name, data) in models { assertValidTriangles(ViewmodelMesh(data), label: name) }
    }

    func testPickaxeMaterialChangesOnlyColorNotGeometryOrGrip() {
        let iron = ViewmodelMesh(FirstPersonModelAssets.pickaxe(material: "iron"))
        for material in ["wooden", "stone", "copper", "golden", "diamond", "netherite"] {
            let model = ViewmodelMesh(FirstPersonModelAssets.pickaxe(material: material))
            XCTAssertEqual(model.vertices.count, iron.vertices.count)
            var changedColors = 0
            for (a, b) in zip(model.vertices, iron.vertices) {
                XCTAssertEqual(a.position, b.position)
                XCTAssertEqual(a.normal, b.normal)
                if a.color != b.color { changedColors += 1 }
            }
            XCTAssertGreaterThan(changedColors, 0, "\(material) must have a distinct material head")
        }
    }

    func testActionCurvesHaveSafeEndpointsForwardContactAndRecovery() {
        let rest = ViewmodelPlacement.grip(left: false, logicalWidth: 960, aspect: 16.0/9)
        let working = SIMD3<Float>(-0.31,0.56,0), target = SIMD3<Float>(0,0,-1.75)
        func pose(_ progress: Double?, _ action: ViewmodelAction) -> simd_float4x4 {
            FirstPersonStrike.pose(rest: rest, progress: progress, action: action,
                                   workingPoint: working, target: target, reducedMotion: false)
        }
        for action in ViewmodelAction.allCases {
            for progress in [nil, -1, 0, 1, 2, Double.nan, .infinity] as [Double?] {
                XCTAssertEqual(pose(progress, action), rest)
            }
            let windup = pose(0.24, action), contact = pose(0.48, action), recovery = pose(0.85, action)
            XCTAssertGreaterThan(windup.columns.3.z, rest.columns.3.z)
            XCTAssertEqual(simd_distance(xyz(contact * SIMD4(working,1)), target), 0, accuracy: 1e-6)
            XCTAssertLessThan(simd_distance(recovery.columns.3, rest.columns.3),
                              simd_distance(contact.columns.3, rest.columns.3))
        }
    }

    func testEveryActionIsContinuousAtPhaseBoundariesAndLoopSeam() {
        let rest = ViewmodelPlacement.grip(left: false, logicalWidth: 960, aspect: 16.0/9)
        func pose(_ progress: Double, _ action: ViewmodelAction) -> simd_float4x4 {
            FirstPersonStrike.pose(rest: rest, progress: progress, action: action,
                workingPoint: SIMD3(-0.31,0.56,0), target: SIMD3(0,0,-1.75), reducedMotion: false)
        }
        func distance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
            (0..<4).reduce(0) { $0 + simd_distance(a[$1],b[$1]) }
        }
        for action in ViewmodelAction.allCases {
            for boundary in [0.24, 0.43, 0.49] {
                XCTAssertLessThan(distance(pose(boundary - 0.000001,action), pose(boundary + 0.000001,action)), 0.00001)
            }
            XCTAssertLessThan(distance(pose(0.000001,action), pose(0.999999,action)), 0.00001)
            var previous = pose(0,action)
            for frame in 1...1200 {
                let next = pose(Double(frame) / 1200,action)
                XCTAssertLessThan(distance(previous,next), 0.06)
                previous = next
            }
        }
    }

    func testReducedMotionPreservesForwardActionWithSmallerExcursion() {
        let rest = ViewmodelPlacement.grip(left: false, logicalWidth: 960, aspect: 16.0/9)
        for action in ViewmodelAction.allCases {
            for progress in [0.12, 0.24, 0.36, 0.48, 0.75] {
                let full = FirstPersonStrike.pose(rest: rest, progress: progress, action: action,
                    workingPoint: SIMD3(-0.31,0.56,0), target: SIMD3(0,0,-1.75), reducedMotion: false)
                let reduced = FirstPersonStrike.pose(rest: rest, progress: progress, action: action,
                    workingPoint: SIMD3(-0.31,0.56,0), target: SIMD3(0,0,-1.75), reducedMotion: true)
                let expected = rest.columns.3 + (full.columns.3-rest.columns.3)*0.22
                XCTAssertEqual(simd_distance(reduced.columns.3, expected), 0, accuracy: 1e-6)
                XCTAssertLessThan(simd_length((simd_quatf(rest).inverse * simd_quatf(reduced)).imag),
                                  simd_length((simd_quatf(rest).inverse * simd_quatf(full)).imag))
            }
        }
    }

    func testRigidTransformKeepsPropScaleAndGripPosition() {
        let origin = SIMD4<Float>(0, 0, 0, 1)
        let grip = SIMD3<Float>(0.65, -0.55, -1.5)
        for frame in 0...120 {
            let angle = Float(frame) / 120 * .pi * 2
            let matrix = vmTranslation(grip) * vmRotation(SIMD3(0, angle, 0))
            XCTAssertEqual(simd_distance(xyz(matrix * origin), grip), 0, accuracy: 0.000001)
            XCTAssertEqual(simd_determinant(matrix), 1, accuracy: 0.00001)
            let tip = matrix * SIMD4<Float>(0.2, 0.8, 0.1, 1)
            XCTAssertEqual(simd_distance(xyz(tip), grip), sqrt(0.69), accuracy: 0.00001)
        }
    }

    func testLeftArmReflectionPreservesOutwardWindingAndIsReversible() {
        for (label, data) in [("arm", FirstPersonModelAssets.arm), ("hand", FirstPersonModelAssets.hand),
                              ("narrow hand", FirstPersonModelAssets.handNarrow)] {
            let right = ViewmodelMesh(data)
            let left = right.reflectedX()
            assertValidTriangles(left, label: "left \(label)")
            let restored = left.reflectedX()
            XCTAssertEqual(restored.vertices.count, right.vertices.count)
            for (a, b) in zip(right.vertices, restored.vertices) {
                XCTAssertEqual(a.position, b.position)
                XCTAssertEqual(a.normal, b.normal)
                XCTAssertEqual(a.color, b.color)
            }
            XCTAssertEqual(left.vertices.map { $0.position.x }.min()!,
                           -right.vertices.map { $0.position.x }.max()!, accuracy: 0.00001)
        }
    }

    func testActualGripPlacementIsMirroredAndClearOfTheQuickbar() {
        for width in [320.0, 480, 640, 960, 1440] {
            let aspect = Float(width / 540)
            let right = ViewmodelPlacement.grip(left: false, logicalWidth: width, aspect: aspect)
            let left = ViewmodelPlacement.grip(left: true, logicalWidth: width, aspect: aspect)
            XCTAssertEqual(right.columns.3.x, -left.columns.3.x, accuracy: 0.00001)
            XCTAssertEqual(right.columns.3.y, left.columns.3.y, accuracy: 0.00001)
            XCTAssertEqual(right.columns.3.z, left.columns.3.z, accuracy: 0.00001)
            XCTAssertEqual(simd_determinant(right), 1, accuracy: 0.00001)
            XCTAssertEqual(simd_determinant(left), 1, accuracy: 0.00001)
            let projection = Elysium.mat4Perspective(fovYRad: 70 * .pi / 180, aspect: aspect,
                                             near: 0.035, far: 12)
            let clip = projection * right.columns.3
            let screenX = Double(clip.x / clip.w + 1) / 2
            XCTAssertGreaterThan(screenX, 0.5 + 91 / width,
                                 "physical grip should enter on the quickbar's right side")
            XCTAssertLessThan(screenX, 0.85)
        }
    }

    func testAuthoredAssemblyStaysSafelyBeyondNearPlaneDuringAllActions() {
        let hand = ViewmodelMesh(FirstPersonModelAssets.hand)
        let pickaxe = ViewmodelMesh(FirstPersonModelAssets.pickaxe)
        let forearm = ViewmodelMesh(FirstPersonModelAssets.forearm)
        let upperArm = ViewmodelMesh(FirstPersonModelAssets.upperArm)
        for left in [false, true] {
            let grip = ViewmodelPlacement.grip(left: left, logicalWidth: 960, aspect: 16.0 / 9)
            for action in ViewmodelAction.allCases {
                for frame in 0...60 {
                    let transform = FirstPersonStrike.pose(rest: grip, progress: Double(frame)/60, action: action,
                        workingPoint: SIMD3(-0.31,0.56,0), target: SIMD3(0,0,-1.75), reducedMotion: false)
                    let bones = FirstPersonArmPose.solve(hand: transform, left: left)
                    let meshes = [(hand,transform),(pickaxe,transform * vmScale(0.98/0.85)),
                                  (forearm,bones.forearm),(upperArm,bones.upperArm)]
                    var nearestZ: Float = -.infinity
                    for (mesh,matrix) in meshes {
                        for vertex in mesh.vertices {
                            nearestZ = max(nearestZ, (matrix * vertex.position).z)
                        }
                    }
                    XCTAssertLessThan(nearestZ, -0.06,
                                      "\(action), frame \(frame), left=\(left): geometry risks camera/near-plane fragments")
                }
            }
        }
    }

    func testExtrudedTexelsUseSameLinearColorConventionAsBlenderAssets() {
        XCTAssertEqual(viewmodelLinearChannel(0.5), 0.21404114, accuracy: 0.000001)
        XCTAssertEqual(viewmodelLinearChannel(0.04045), 0.003130805, accuracy: 0.0000001)
        XCTAssertEqual(viewmodelLinearChannel(-0.2), 0)
        XCTAssertEqual(viewmodelLinearChannel(1.2), 1)
        XCTAssertEqual(viewmodelLinearColor(SIMD4(0.5, 0.5, 0.5, 0.3)).w, 0.3)
        let mesh = ViewmodelMesh.extruded(image(width: 2, height: 1, occupied: [(0, 0), (1, 0)],
                                                color: [128, 128, 128, 255]), profile: simpleProfile)
        for vertex in mesh.vertices {
            XCTAssertEqual(vertex.color.x, 0.2158605, accuracy: 0.000001)
            XCTAssertEqual(vertex.color.y, vertex.color.x)
            XCTAssertEqual(vertex.color.z, vertex.color.x)
        }
    }

    func testActualFaithfulToolHaftsMeetTheGripWithoutASecondAngle() throws {
        registerAllBlocks(); registerAllItems()
        let pack = try XCTUnwrap(Self.faithfulPack)
        for family in ["axe", "shovel", "hoe", "sword"] {
            let definition = itemDef(iid("iron_\(family)"))
            let source = try XCTUnwrap(decodePNG(try XCTUnwrap(pack.file(
                "assets/minecraft/textures/item/iron_\(family).png"))))
            XCTAssertEqual(source.width, 64)
            let mesh = ViewmodelMesh.extruded(source, profile: ViewmodelProfile.item(definition))
            // Sample the real brown haft near the grip, excluding the steel head
            // and far-away trim. This checks the shipped art, not just an idealized diagonal.
            let haft = mesh.vertices.filter {
                $0.normal.z > 0.99 && abs($0.position.y) < 0.07 &&
                    $0.color.x > $0.color.y * 1.2 && $0.color.y > $0.color.z * 1.2
            }
            XCTAssertGreaterThan(haft.count, 12, "\(family) should have visible shaft geometry at the grip")
            guard !haft.isEmpty else { continue }
            let centerX = haft.reduce(Float(0)) { $0 + $1.position.x } / Float(haft.count)
            XCTAssertEqual(centerX, 0, accuracy: 0.025,
                           "\(family)'s real Faithful haft must meet the grip axis without a second offset")
        }
    }

    func testOtherGenuineFaithfulShaftToolsHaveCorrectGripAngleAndUsefulSize() throws {
        registerAllBlocks(); registerAllItems()
        let pack = try XCTUnwrap(Self.faithfulPack)
        let cases: [(name: String, centerline: Float, minimumLength: Float)] = [
            ("fishing_rod", 1.0625, 1.0), ("carrot_on_a_stick", 1.0625, 1.0),
            ("warped_fungus_on_a_stick", 1.0625, 1.0), ("brush", 1.0, 0.5),
            ("trident", 1.0, 1.15), ("spyglass", 1.015625, 0.55),
        ]
        for entry in cases {
            let definition = itemDef(iid(entry.name))
            let profile = ViewmodelProfile.item(definition)
            XCTAssertEqual(profile.straighten, .pi / 4, accuracy: 0.000001, entry.name)
            XCTAssertEqual(profile.grip.x + profile.grip.y, entry.centerline,
                           accuracy: 0.008, "\(entry.name): anchor must follow its measured authored shaft")
            XCTAssertGreaterThanOrEqual(profile.length, entry.minimumLength, entry.name)
            let source = try XCTUnwrap(decodePNG(try XCTUnwrap(pack.file(
                "assets/minecraft/textures/item/\(entry.name).png"))))
            let mesh = ViewmodelMesh.extruded(source, profile: profile)
            assertValidTriangles(mesh, label: entry.name)
            let shaft = mesh.vertices.filter { vertex in
                guard vertex.normal.z > 0.99, abs(vertex.position.y) < 0.035 else { return false }
                let c = vertex.color
                if entry.name == "trident" { return c.y > c.x * 1.2 && c.z > c.x * 1.2 }
                return c.x > c.y * 1.2 && c.y > c.z * 1.2
            }
            XCTAssertGreaterThan(shaft.count, 12, "\(entry.name): the actual shaft must pass through the hand")
            guard !shaft.isEmpty else { continue }
            let center = shaft.reduce(Float(0)) { $0 + $1.position.x } / Float(shaft.count)
            XCTAssertEqual(center, 0, accuracy: entry.name == "spyglass" ? 0.035 : 0.025,
                           "\(entry.name): real source pixels must remain aligned to the grip axis")
        }
    }

    func testPickaxeRemainsProportionalToTheHandAndExtendsThroughIt() {
        let tool = ViewmodelMesh(FirstPersonModelAssets.pickaxe)
        let hand = ViewmodelMesh(FirstPersonModelAssets.hand)
        let toolLength = tool.vertices.map { $0.position.y }.max()! - tool.vertices.map { $0.position.y }.min()!
        let palmWidth = hand.vertices.map { $0.position.x }.max()! - hand.vertices.map { $0.position.x }.min()!
        XCTAssertGreaterThanOrEqual(toolLength / palmWidth, 4,
                                    "the pickaxe must not regress to a miniature prop beside the palm")
        XCTAssertLessThan(tool.vertices.map { $0.position.y }.min()!, -0.08)
        XCTAssertGreaterThan(tool.vertices.map { $0.position.y }.max()!, 0.6)
    }

    func testFlyingWandUsesItsUprightVisualProfileInsteadOfSwordCombatMetadata() {
        registerAllBlocks(); registerAllItems()
        let definition = itemDef(iid("flying_wand"))
        XCTAssertEqual(definition.tool?.type, "sword")
        let profile = ViewmodelProfile.item(definition)
        XCTAssertEqual(profile.straighten, 0)
        XCTAssertEqual(profile.grip.x, 0.5)
        XCTAssertEqual(profile.action, .generic)
        XCTAssertGreaterThanOrEqual(profile.length, 0.7)
    }

    func testProductionMetalViewmodelShaderCompilesWithRealPipelineLayout() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: FirstPersonRenderer.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "viewmodelVertex"))
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "viewmodelFragment"))
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
        XCTAssertEqual(MemoryLayout<ViewmodelVertex>.stride, 64,
                       "the Metal vertex layout is four contiguous float4 values")
    }
}
