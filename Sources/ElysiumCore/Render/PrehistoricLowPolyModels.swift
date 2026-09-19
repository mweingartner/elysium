// Native low-poly presentation for the opt-in Prehistoric Worlds roster.
//
// These are immutable source-authored rigid meshes.  They intentionally reuse
// the existing 24-part entity rig and procedural skin painter; no runtime
// mesh importer, skeletal palette, external asset, or simulation state is
// introduced here.

import Foundation

enum LowPolyAxis {
    case x, y, z
}

struct LowPolyPoint {
    let x: Double
    let y: Double
    let z: Double

    static func + (lhs: LowPolyPoint, rhs: LowPolyPoint) -> LowPolyPoint {
        LowPolyPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: LowPolyPoint, rhs: LowPolyPoint) -> LowPolyPoint {
        LowPolyPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static func * (lhs: LowPolyPoint, rhs: Double) -> LowPolyPoint {
        LowPolyPoint(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }
}

struct LowPolyRing {
    let center: LowPolyPoint
    let radiusA: Double
    let radiusB: Double
}

func lp(_ x: Double, _ y: Double, _ z: Double) -> LowPolyPoint {
    LowPolyPoint(x: x, y: y, z: z)
}

func lpr(_ x: Double, _ y: Double, _ z: Double, _ radiusA: Double, _ radiusB: Double) -> LowPolyRing {
    LowPolyRing(center: lp(x, y, z), radiusA: radiusA, radiusB: radiusB)
}

func lpDot(_ a: LowPolyPoint, _ b: LowPolyPoint) -> Double {
    a.x * b.x + a.y * b.y + a.z * b.z
}

func lpCross(_ a: LowPolyPoint, _ b: LowPolyPoint) -> LowPolyPoint {
    lp(a.y * b.z - a.z * b.y,
       a.z * b.x - a.x * b.z,
       a.x * b.y - a.y * b.x)
}

func lpUV(_ point: LowPolyPoint, _ index: Int) -> (Double, Double) {
    // Repeating source-owned UVs keep every procedural skin fully in bounds.
    // The painter owns colour/detail; the mesh only needs stable valid samples.
    let u = 4 + (abs(point.x * 3.7 + point.z * 1.1) + Double(index) * 7)
        .truncatingRemainder(dividingBy: 120)
    let v = 4 + (abs(point.y * 3.1 + point.z * 0.9) + Double(index) * 11)
        .truncatingRemainder(dividingBy: 120)
    return (u, v)
}

func lpFace(_ points: [LowPolyPoint], outward: LowPolyPoint) -> ModelMeshFace {
    guard points.count >= 3 else { return ModelMeshFace([]) }
    var ordered = points
    let normal = lpCross(ordered[1] - ordered[0], ordered[2] - ordered[0])
    if lpDot(normal, outward) < 0 {
        ordered.reverse()
    }
    return ModelMeshFace(ordered.enumerated().map { index, point in
        let uv = lpUV(point, index)
        return ModelMeshVertex(point.x, point.y, point.z, uv.0, uv.1)
    })
}

func lpTube(_ axis: LowPolyAxis, _ rings: [LowPolyRing], sides: Int = 8) -> ModelMesh {
    guard rings.count >= 2, sides >= 3 else { return ModelMesh(faces: []) }
    let angleStep = Double.pi * 2 / Double(sides)
    func point(_ ring: Int, _ side: Int) -> LowPolyPoint {
        let source = rings[ring]
        let angle = Double(side) * angleStep
        let a = Foundation.cos(angle) * source.radiusA
        let b = Foundation.sin(angle) * source.radiusB
        switch axis {
        case .x: return lp(source.center.x, source.center.y + a, source.center.z + b)
        case .y: return lp(source.center.x + a, source.center.y, source.center.z + b)
        case .z: return lp(source.center.x + a, source.center.y + b, source.center.z)
        }
    }
    var faces: [ModelMeshFace] = []
    for ring in 0..<(rings.count - 1) {
        let middle = (rings[ring].center + rings[ring + 1].center) * 0.5
        for side in 0..<sides {
            let next = (side + 1) % sides
            let p0 = point(ring, side)
            let p1 = point(ring, next)
            let p2 = point(ring + 1, next)
            let p3 = point(ring + 1, side)
            let faceCenter = (p0 + p1 + p2 + p3) * 0.25
            faces.append(lpFace([p0, p1, p2, p3], outward: faceCenter - middle))
        }
    }
    let startDirection = rings[0].center - rings[1].center
    let endDirection = rings[rings.count - 1].center - rings[rings.count - 2].center
    let start = (0..<sides).map { point(0, $0) }
    let end = (0..<sides).map { point(rings.count - 1, $0) }
    faces.append(lpFace(start, outward: startDirection))
    faces.append(lpFace(end, outward: endDirection))
    return ModelMesh(faces: faces)
}

func lpBlade(_ outline: [LowPolyPoint], thickness: LowPolyPoint) -> ModelMesh {
    guard outline.count >= 3 else { return ModelMesh(faces: []) }
    let half = thickness * 0.5
    let front = outline.map { $0 - half }
    let back = outline.map { $0 + half }
    var center = lp(0, 0, 0)
    for point in outline { center = center + point }
    center = center * (1 / Double(outline.count))
    var faces: [ModelMeshFace] = [
        lpFace(front, outward: lp(-thickness.x, -thickness.y, -thickness.z)),
        lpFace(back, outward: thickness),
    ]
    for index in outline.indices {
        let next = (index + 1) % outline.count
        let a = front[index], b = front[next], c = back[next], d = back[index]
        let sideCenter = (a + b + c + d) * 0.25
        faces.append(lpFace([a, b, c, d], outward: sideCenter - center))
    }
    return ModelMesh(faces: faces)
}

func lpPart(_ name: String, _ pivot: (Double, Double, Double), _ meshes: ModelMesh...) -> ModelPart {
    ModelPart(name: name, pivot: pivot, boxes: [], meshes: meshes)
}

func lpPart(_ name: String, _ pivot: (Double, Double, Double), _ meshes: [ModelMesh]) -> ModelPart {
    ModelPart(name: name, pivot: pivot, boxes: [], meshes: meshes)
}

/// Adds source meshes to an existing rigid pose slot.  Landmark geometry such
/// as jaws, crests, horns, and claws must share its anchor's matrix; a separate
/// part would otherwise remain behind when that head or limb animates.
func lpAppending(_ meshes: [ModelMesh], to part: ModelPart) -> ModelPart {
    ModelPart(name: part.name, pivot: part.pivot, rot: part.rot,
              boxes: part.boxes, meshes: part.meshes + meshes)
}

/// Rebase a rigid source mesh into its animated anchor's local coordinates
/// while retaining its authored skin samples.
func lpTranslated(_ mesh: ModelMesh, by offset: LowPolyPoint) -> ModelMesh {
    ModelMesh(faces: mesh.faces.map { face in
        ModelMeshFace(face.vertices.map { vertex in
            ModelMeshVertex(vertex.x + offset.x, vertex.y + offset.y, vertex.z + offset.z,
                            vertex.u, vertex.v)
        })
    })
}

func lpRotatedPart(_ name: String, _ pivot: (Double, Double, Double),
                           _ rot: (Double, Double, Double), _ meshes: ModelMesh...) -> ModelPart {
    ModelPart(name: name, pivot: pivot, rot: rot, boxes: [], meshes: meshes)
}

func lpConeZ(_ startZ: Double, _ endZ: Double, _ startRadius: Double, _ endRadius: Double,
                     y: Double = 0, x: Double = 0, sides: Int = 6) -> ModelMesh {
    lpTube(.z, [lpr(x, y, startZ, startRadius, startRadius),
                lpr(x, y, endZ, max(0.16, endRadius), max(0.16, endRadius))], sides: sides)
}

func lpLeg(_ length: Double, footLength: Double, footWidth: Double = 1.8,
           forward: Double = -1.4, heavy: Bool = false, biped: Bool = false) -> [ModelMesh] {
    let hipRadius = heavy ? 2.2 : 1.7
    let kneeRadius = heavy ? 1.7 : 1.25
    let ankleRadius = heavy ? 1.45 : 0.95
    // Theropod legs need a visibly articulated hip → knee → ankle chain.
    // Quadrupeds keep the stronger near-vertical stance used by their wider
    // bodies.  Every ring remains one rigid pose influence, so the existing
    // gait animator still moves an entire attached limb safely.
    let kneeZ = biped ? -min(length * 0.24, 4.2) : forward * 0.4
    let ankleZ = biped ? min(length * 0.10, 1.8) : forward
    let footZ = biped ? -min(length * 0.10, 1.8) : forward
    let shin = lpTube(.y, [
        lpr(0, 0, 0, hipRadius, heavy ? 2.0 : 1.5),
        lpr(0, -length * (biped ? 0.34 : 0.55), kneeZ, kneeRadius, heavy ? 1.55 : 1.1),
        lpr(0, -length * (biped ? 0.82 : 1.0), ankleZ, ankleRadius, heavy ? 1.35 : 0.85),
        lpr(0, -length, footZ, ankleRadius * 0.78, (heavy ? 1.35 : 0.85) * 0.72),
    ], sides: 7)
    let foot = lpTube(.z, [
        lpr(0, -length, footZ - 0.5, footWidth, heavy ? 1.25 : 0.85),
        lpr(0, -length + 0.1, footZ - footLength, footWidth * 0.78, heavy ? 0.9 : 0.58),
    ], sides: 6)
    return [shin, foot]
}

func lpArm(_ length: Double, reach: Double, feathered: Bool = false, tiny: Bool = false) -> [ModelMesh] {
    let upperRadius = tiny ? 1.0 : 1.35
    var meshes = [lpTube(.y, [
        lpr(0, 0, 0, upperRadius, upperRadius),
        lpr(0, -length * 0.55, -reach * 0.40, upperRadius * 0.72, upperRadius * 0.68),
        lpr(0, -length, -reach, max(0.38, upperRadius * 0.42), max(0.38, upperRadius * 0.38)),
    ], sides: 6)]
    if feathered {
        meshes.append(lpBlade([
            lp(-0.35, -length * 0.16, -reach * 0.18),
            lp(-0.30, -length * 0.86, -reach * 0.86),
            lp(-0.22, -length * 0.54, -reach * 1.35),
        ], thickness: lp(0.70, 0.26, 0.18)))
    }
    return meshes
}

func lowPolyPrehistoricModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    switch recipe.family {
    case .theropod: return lowPolyTheropodModel(recipe)
    case .herbivoreBiped: return lowPolyHerbivoreModel(recipe)
    case .ceratopsian: return lowPolyCeratopsianModel(recipe)
    case .armoredQuad: return lowPolyArmoredModel(recipe)
    case .sauropod: return lowPolySauropodModel(recipe)
    case .pterosaur: return lowPolyPterosaurModel(recipe)
    case .microraptor: return lowPolyMicroraptorModel(recipe)
    case .ichthyosaur: return lowPolyIchthyosaurModel(recipe)
    case .plesiosaur: return lowPolyPlesiosaurModel(recipe)
    case .mosasaur: return lowPolyMosasaurModel(recipe)
    case .crocodilian: return lowPolyCrocodilianModel(recipe)
    }
}

private func lowPolyTheropodModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let id = recipe.id
    let isComp = id.hasSuffix("compsognathus")
    let isCoelo = id.hasSuffix("coelophysis")
    let isDeinonychus = id.hasSuffix("deinonychus")
    let raptor = recipe.form == "raptor"
    let tyrant = recipe.form == "tyrannosaur"
    let spinosaur = recipe.form == "spinosaur"
    let therizinosaur = recipe.form == "therizinosaur"
    let carnotaur = recipe.form == "bull"
    let ceratosaur = recipe.form == "horned"
    let dilophosaur = recipe.form == "crested"
    let allosaur = recipe.form == "large"
    let bodyW = tyrant ? 13.0 : (spinosaur ? 11.5 : (therizinosaur ? 11.0 : (allosaur ? 10.0 : (carnotaur ? 9.5 : (isComp ? 5.1 : (isCoelo ? 5.9 : 7.2))))))
    let bodyL = tyrant ? 22.0 : (spinosaur ? 22.0 : (therizinosaur ? 19.0 : (allosaur ? 20.0 : (isCoelo ? 17.0 : (isComp ? 12.5 : 15.0)))))
    let legH = tyrant ? 17.0 : (spinosaur ? 13.0 : (therizinosaur ? 14.5 : (isCoelo ? 12.0 : (isComp ? 8.0 : 11.5))))
    let headL = tyrant ? 15.5 : (spinosaur ? 17.0 : (allosaur ? 12.5 : (carnotaur ? 10.0 : (isCoelo ? 9.5 : 8.5))))
    let headW = tyrant ? 6.6 : (spinosaur ? 4.8 : (allosaur ? 4.6 : (carnotaur ? 5.0 : 3.7)))
    let tailLength = spinosaur ? bodyL * 1.34 : (isComp ? bodyL * 1.90 : (isCoelo ? bodyL * 1.72 : bodyL * 1.48))
    let neckHeight = legH + (spinosaur ? 11.0 : (therizinosaur ? 15.5 : (isCoelo ? 13.0 : 11.5)))
    let headPivot = (0.0, neckHeight, -bodyL * 0.44)
    let headMeshes: [ModelMesh] = [
        lpTube(.z, [
            lpr(0, 0.3, 1.2, headW, headW * 0.76),
            lpr(0, 0.1, -headL * 0.42, headW * 0.95, headW * 0.70),
            lpr(0, -0.45, -headL, spinosaur ? headW * 0.55 : headW * 0.68, spinosaur ? headW * 0.37 : headW * 0.42),
        ], sides: 7),
        // The lower jaw is local to the head so biped look/attack rotations
        // cannot leave it behind in world space.
        lpTube(.z, [
            lpr(0, -headW * 0.36, -headL * 0.70 + 1.0, headW * 0.72, headW * 0.18),
            lpr(0, -headW * 0.36 - 0.15, -headL * 1.12, headW * 0.62, headW * 0.15),
        ], sides: 6),
    ]
    let bodyPivot = (0.0, legH + 6.5, 0.0)
    // The hip is derived from the lowermost torso ring, rather than the
    // gameplay collision height.  That prevents narrow theropod bodies from
    // floating above their presentation legs while their feet still reach 0.
    let hipY = bodyPivot.1 + 0.4 - bodyW * 0.53
    var parts: [ModelPart] = [
        lpPart("body", bodyPivot, lpTube(.z, [
            lpr(0, 0, -bodyL * 0.48, bodyW * 0.34, bodyW * 0.37),
            lpr(0, 0.4, -bodyL * 0.12, bodyW * 0.53, bodyW * 0.50),
            lpr(0, 0.2, bodyL * 0.28, bodyW * 0.48, bodyW * 0.44),
            lpr(0, -0.3, bodyL * 0.48, bodyW * 0.29, bodyW * 0.27),
        ])),
        lpPart("neck", (0, legH + 8.5, -bodyL * 0.27), lpTube(.z, [
            lpr(0, 0, 4, bodyW * 0.30, bodyW * 0.30),
            lpr(0, 2.2, -2, bodyW * 0.26, bodyW * 0.27),
            lpr(0, 5.2, -7, bodyW * 0.20, bodyW * 0.22),
        ], sides: 7)),
        lpPart("head", headPivot, headMeshes),
        lpRotatedPart("tail", (0, legH + 7.7, bodyL * 0.42), (-0.14, 0, 0), lpTube(.z, [
            lpr(0, 0, 0, bodyW * 0.34, bodyW * 0.30),
            lpr(0, 0.2, tailLength * 0.22, bodyW * 0.24, bodyW * 0.22),
            lpr(0, 0.1, tailLength * 0.57, bodyW * 0.12, bodyW * 0.11),
            lpr(0, 0, tailLength, 0.28, 0.28),
        ], sides: 7)),
        lpPart("armR", (-bodyW * 0.53, legH + 10.4, -bodyL * 0.20), lpArm(therizinosaur ? 10.5 : (allosaur ? 8.5 : (tyrant ? 4.0 : 6.5)), reach: therizinosaur ? 9.0 : (allosaur ? 7.0 : (tyrant ? 3.0 : 5.0)), feathered: raptor || therizinosaur, tiny: tyrant || carnotaur)),
        lpPart("armL", (bodyW * 0.53, legH + 10.4, -bodyL * 0.20), lpArm(therizinosaur ? 10.5 : (allosaur ? 8.5 : (tyrant ? 4.0 : 6.5)), reach: therizinosaur ? 9.0 : (allosaur ? 7.0 : (tyrant ? 3.0 : 5.0)), feathered: raptor || therizinosaur, tiny: tyrant || carnotaur)),
        lpPart("legR", (-bodyW * 0.29, hipY, bodyL * 0.18), lpLeg(hipY, footLength: tyrant ? 7.2 : (spinosaur ? 6.3 : 5.2), footWidth: tyrant ? 3.0 : 2.0, heavy: tyrant || spinosaur || therizinosaur, biped: true)),
        lpPart("legL", (bodyW * 0.29, hipY, bodyL * 0.18), lpLeg(hipY, footLength: tyrant ? 7.2 : (spinosaur ? 6.3 : 5.2), footWidth: tyrant ? 3.0 : 2.0, heavy: tyrant || spinosaur || therizinosaur, biped: true)),
    ]
    if raptor {
        let fan = lpBlade([lp(0, 0, -3), lp(0, 4, 2), lp(0, 0, 8), lp(0, -2, 3)], thickness: lp(0.44, 0.26, 0.18))
        // The fan must share the tail's baked rest angle and any walk sway.
        // A separate rigid part looks aligned only while idle, then drifts
        // away because this renderer deliberately has no parent hierarchy.
        parts[3] = lpAppending([lpTranslated(fan, by: lp(0, 0.3, tailLength * 0.74))], to: parts[3])
    }
    if dilophosaur {
        let crestL = lpBlade([lp(-2.9, 1, -3), lp(-2.2, 8, -1), lp(-0.8, 2, 3)], thickness: lp(0.55, 0.40, 0.24))
        let crestR = lpBlade([lp(2.9, 1, -3), lp(2.2, 8, -1), lp(0.8, 2, 3)], thickness: lp(0.55, 0.40, 0.24))
        parts[2] = lpAppending([crestL, crestR], to: parts[2])
    }
    if ceratosaur {
        parts[2] = lpAppending([
            lpConeZ(-headL * 0.72, -headL * 1.12, 1.45, 0.20, y: 2.5, sides: 6),
        ], to: parts[2])
    }
    if carnotaur {
        let hornR = lpConeZ(-headL * 0.55, -headL * 0.82, 1.35, 0.18, y: 3.0, x: -headW * 0.77, sides: 6)
        let hornL = lpConeZ(-headL * 0.55, -headL * 0.82, 1.35, 0.18, y: 3.0, x: headW * 0.77, sides: 6)
        parts[2] = lpAppending([hornR, hornL], to: parts[2])
    }
    if allosaur || tyrant {
        let ridgeR = lpBlade([lp(-headW * 0.92, 2.2, -headL * 0.72), lp(-headW * 0.55, 4.3, -headL * 0.52), lp(-headW * 0.28, 2.2, -headL * 0.12)], thickness: lp(0.45, 0.28, 0.18))
        let ridgeL = lpBlade([lp(headW * 0.92, 2.2, -headL * 0.72), lp(headW * 0.55, 4.3, -headL * 0.52), lp(headW * 0.28, 2.2, -headL * 0.12)], thickness: lp(0.45, 0.28, 0.18))
        parts[2] = lpAppending([ridgeR, ridgeL], to: parts[2])
    }
    if spinosaur {
        let sail = lpBlade([
            lp(0, 1, -bodyL * 0.48), lp(0, 15, -bodyL * 0.23), lp(0, 18, bodyL * 0.08),
            lp(0, 12, bodyL * 0.38), lp(0, 1, bodyL * 0.52),
        ], thickness: lp(0.75, 0.20, 0.25))
        // The sail was originally authored from a root 3.7 units above the
        // torso pivot. Rebase it into the body slot so the feature keeps its
        // intended dorsal placement while sharing the torso pose.
        parts[0] = lpAppending([lpTranslated(sail, by: lp(0, 3.7, 0))], to: parts[0])
    }
    if therizinosaur {
        // A fan of three long, swept hand claws is the taxon's readable
        // profile landmark.  Each blade starts inside the forearm's terminal
        // ring, then drops and reaches forward in the arm's local Y/Z plane.
        // Keeping the fan on the arm slots means a gait cannot strand the
        // claws beneath an otherwise moving wrist.
        func handClaws(_ side: Double) -> [ModelMesh] {
            [-1.0, 0.0, 1.0].map { spread in
                lpBlade([
                    lp(side * (0.18 + abs(spread) * 0.18), -9.1, -7.0 + spread * 1.10),
                    lp(side * (0.18 + abs(spread) * 0.18), -11.4, -9.5 + spread * 1.10),
                    lp(side * (0.18 + abs(spread) * 0.18), -16.5, -21.0 + spread * 1.85),
                ], thickness: lp(0.72, 0.22, 0.20))
            }
        }
        parts[4] = lpAppending(handClaws(-1), to: parts[4])
        parts[5] = lpAppending(handClaws(1), to: parts[5])
    }
    if isDeinonychus {
        let sickleR = lpConeZ(-bodyL * 0.16 - 2.0, -bodyL * 0.16 - 6.5, 1.0, 0.14,
                               y: -legH + 1.4, x: -bodyW * 0.01, sides: 5)
        let sickleL = lpConeZ(-bodyL * 0.16 - 2.0, -bodyL * 0.16 - 6.5, 1.0, 0.14,
                               y: -legH + 1.4, x: bodyW * 0.01, sides: 5)
        parts[6] = lpAppending([sickleR], to: parts[6])
        parts[7] = lpAppending([sickleL], to: parts[7])
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "biped", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: Int(headL), eyeX: 2, eyeY: 3, eyeGap: 4))
}

private func lowPolyCeratopsianModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let triceratops = recipe.form == "triceratops"
    let bodyW = triceratops ? 16.5 : 13.0
    let bodyL = triceratops ? 24.0 : 19.0
    let legH = triceratops ? 13.0 : 11.5
    let headL = triceratops ? 14.0 : 11.0
    let headPivot = (0.0, legH + 7.5, -bodyL * 0.43)
    let body = lpTube(.z, [
        lpr(0, 0, -bodyL * 0.48, bodyW * 0.42, bodyW * 0.42),
        lpr(0, 0.4, -bodyL * 0.12, bodyW * 0.56, bodyW * 0.51),
        lpr(0, 0.1, bodyL * 0.30, bodyW * 0.50, bodyW * 0.45),
        lpr(0, -0.5, bodyL * 0.50, bodyW * 0.30, bodyW * 0.28),
    ])
    let head = lpTube(.z, [
        lpr(0, 0.1, 1.5, bodyW * 0.45, bodyW * 0.40),
        lpr(0, 0.2, -headL * 0.42, bodyW * 0.41, bodyW * 0.36),
        lpr(0, -0.5, -headL, bodyW * 0.30, bodyW * 0.23),
    ], sides: 7)
    // The frill is rebased into the head pose instead of being a decorative
    // independent plate.  It therefore lowers and turns with the skull.
    let frillZ = bodyL * 0.14
    let frill = lpBlade([
        lp(-bodyW * 0.65, -1.5, frillZ),
        lp(-bodyW * 0.61, 4.5, frillZ),
        lp(-bodyW * 0.30, 8.5, frillZ),
        lp(0, 10.0, frillZ),
        lp(bodyW * 0.30, 8.5, frillZ),
        lp(bodyW * 0.61, 4.5, frillZ),
        lp(bodyW * 0.65, -1.5, frillZ),
    ], thickness: lp(0.18, 0.18, 4.0))
    let tail = lpTube(.z, [
        lpr(0, 0, 0, bodyW * 0.30, bodyW * 0.24),
        lpr(0, -0.1, bodyL * 0.47, bodyW * 0.16, bodyW * 0.14),
        lpr(0, -0.2, bodyL * 0.80, 0.32, 0.32),
    ], sides: 7)
    var parts: [ModelPart] = [
        lpPart("body", (0, legH + 6.0, 0), body),
        lpPart("head", headPivot, head),
        lpRotatedPart("tail", (0, legH + 6.8, bodyL * 0.42), (-0.12, 0, 0), tail),
        lpPart("legFR", (-bodyW * 0.33, legH, -bodyL * 0.28), lpLeg(legH, footLength: 5.2, footWidth: 3.0, heavy: true)),
        lpPart("legFL", (bodyW * 0.33, legH, -bodyL * 0.28), lpLeg(legH, footLength: 5.2, footWidth: 3.0, heavy: true)),
        lpPart("legBR", (-bodyW * 0.34, legH, bodyL * 0.28), lpLeg(legH * 0.92, footLength: 4.8, footWidth: 3.0, heavy: true)),
        lpPart("legBL", (bodyW * 0.34, legH, bodyL * 0.28), lpLeg(legH * 0.92, footLength: 4.8, footWidth: 3.0, heavy: true)),
    ]
    parts[1] = lpAppending([frill], to: parts[1])
    // The horns rise and sweep forward instead of projecting as three flat
    // horizontal cones.  Their local Y/Z arcs remain legible in a true side
    // screenshot, while the offset roots retain the paired brow anatomy.
    let browR = lpTube(.y, [
        lpr(-bodyW * 0.34, 2.6, -headL * 0.42, 1.70, 1.70),
        lpr(-bodyW * 0.34, 5.7, -headL * 0.73, 0.96, 0.96),
        lpr(-bodyW * 0.34, 8.5, -headL * 1.23, 0.16, 0.16),
    ], sides: 6)
    let browL = lpTube(.y, [
        lpr(bodyW * 0.34, 2.6, -headL * 0.42, 1.70, 1.70),
        lpr(bodyW * 0.34, 5.1, -headL * 0.70, 0.96, 0.96),
        lpr(bodyW * 0.34, 7.7, -headL * 1.16, 0.16, 0.16),
    ], sides: 6)
    let nasal = lpTube(.y, [
        lpr(0, triceratops ? -0.6 : 0.4, -headL * 0.80, 1.65, 1.65),
        lpr(0, triceratops ? 1.6 : 2.2, -headL * 1.01, 0.88, 0.88),
        lpr(0, triceratops ? 3.8 : 5.2, -headL * (triceratops ? 1.25 : 1.54), 0.16, 0.16),
    ], sides: 6)
    parts[1] = lpAppending([browR, browL, nasal], to: parts[1])
    if !triceratops {
        let spikeOffsetZ = frillZ + 1.5
        let spikes = [
            lpConeZ(spikeOffsetZ, spikeOffsetZ + 6.8, 1.1, 0.15, y: 8.9, x: -bodyW * 0.54, sides: 5),
            lpConeZ(spikeOffsetZ, spikeOffsetZ + 6.8, 1.1, 0.15, y: 10.9, x: -bodyW * 0.25, sides: 5),
            lpConeZ(spikeOffsetZ, spikeOffsetZ + 6.8, 1.1, 0.15, y: 10.9, x: bodyW * 0.25, sides: 5),
            lpConeZ(spikeOffsetZ, spikeOffsetZ + 6.8, 1.1, 0.15, y: 8.9, x: bodyW * 0.54, sides: 5),
        ]
        parts[1] = lpAppending(spikes, to: parts[1])
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "prehistoricQuad", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: Int(headL), eyeX: 2, eyeY: 3, eyeGap: 5))
}
