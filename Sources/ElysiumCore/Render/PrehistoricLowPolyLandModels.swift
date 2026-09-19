// Species-specific native faceted models for the remaining land families.
//
// The geometry is authored from the bounded primitive vocabulary in
// PrehistoricLowPolyModels.swift.  These models deliberately preserve the
// established animation-facing part names while giving each taxon a visible
// anatomical silhouette rather than a scale/paint-only variation.

import Foundation

func lowPolyHerbivoreModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let id = recipe.id
    let dryosaur = id.hasSuffix("dryosaurus")
    let pachycephalosaur = id.hasSuffix("pachycephalosaurus")
    let gallimimus = id.hasSuffix("gallimimus")
    let oviraptor = id.hasSuffix("oviraptor")
    let parasaurolophus = id.hasSuffix("parasaurolophus")
    let edmontosaurus = id.hasSuffix("edmontosaurus")
    let iguanodon = id.hasSuffix("iguanodon")
    let hadrosaur = parasaurolophus || edmontosaurus

    let bodyW: Double = hadrosaur ? 11.8 : (iguanodon ? 10.8 : (pachycephalosaur ? 8.0 : (gallimimus ? 6.4 : (oviraptor ? 5.9 : 6.1))))
    let bodyL: Double = hadrosaur ? 22.0 : (iguanodon ? 20.5 : (pachycephalosaur ? 16.0 : (gallimimus ? 18.5 : (oviraptor ? 13.5 : 15.5))))
    let legH: Double = hadrosaur ? 15.0 : (iguanodon ? 14.0 : (gallimimus ? 16.5 : (pachycephalosaur ? 12.0 : (oviraptor ? 10.5 : 11.0))))
    let headL: Double = hadrosaur ? 9.0 : (iguanodon ? 9.5 : (gallimimus ? 7.2 : (oviraptor ? 6.2 : 6.8)))
    let headRadius: Double = hadrosaur ? 4.4 : (iguanodon ? 4.3 : (pachycephalosaur ? 3.8 : (gallimimus ? 2.7 : (oviraptor ? 2.9 : 3.0))))
    let beakLength: Double = hadrosaur ? 8.0 : (iguanodon ? 6.2 : (oviraptor ? 4.8 : (gallimimus ? 4.0 : 3.6)))
    let neckRise: Double = gallimimus ? 15.5 : (hadrosaur ? 12.5 : (iguanodon ? 11.5 : (oviraptor ? 11.0 : 9.0)))
    let bodyPivot = (0.0, legH + 6.6, 0.0)
    // Mesh presentation has a taller torso than its gameplay collision
    // capsule.  Derive a hip that touches the lowermost torso ring so every
    // slender biped remains anatomically joined while its feet stay on y=0.
    let hipY = bodyPivot.1 + 0.5 - bodyW * 0.52
    let headPivot = (0.0, legH + neckRise, -bodyL * 0.40)

    let body = lpTube(.z, [
        lpr(0, -0.4, -bodyL * 0.50, bodyW * 0.30, bodyW * 0.34),
        lpr(0, 0.5, -bodyL * 0.14, bodyW * 0.52, bodyW * 0.50),
        lpr(0, 0.2, bodyL * 0.22, bodyW * 0.49, bodyW * 0.45),
        lpr(0, -0.5, bodyL * 0.49, bodyW * 0.26, bodyW * 0.25),
    ], sides: 8)
    let neck = lpTube(.z, [
        lpr(0, 0, 4.0, bodyW * 0.30, bodyW * 0.29),
        lpr(0, neckRise * 0.36, -bodyL * 0.09, bodyW * 0.25, bodyW * 0.24),
        lpr(0, neckRise * 0.62, -bodyL * 0.18, headRadius * 0.58, headRadius * 0.62),
    ], sides: 7)

    var headMeshes: [ModelMesh] = [
        lpTube(.z, [
            lpr(0, 0.2, 2.0, headRadius * 0.82, headRadius * 0.72),
            lpr(0, 0.1, -headL * 0.42, headRadius, headRadius * 0.70),
            lpr(0, -0.35, -headL, headRadius * 0.64, headRadius * 0.48),
        ], sides: 7),
        lpTube(.z, [
            lpr(0, -headRadius * 0.36, -headL * 0.82, headRadius * 0.57, headRadius * 0.23),
            lpr(0, -headRadius * 0.50, -headL - beakLength, headRadius * 0.38, headRadius * 0.12),
        ], sides: 6),
    ]
    if pachycephalosaur {
        // A fused low-poly dome and rear shelf, not a floating rectangular cap.
        headMeshes.append(lpTube(.y, [
            lpr(0, headRadius * 0.58, -headL * 0.10, headRadius * 0.72, headRadius * 0.62),
            lpr(0, headRadius * 1.42, -headL * 0.06, headRadius * 0.58, headRadius * 0.50),
            lpr(0, headRadius * 2.18, -headL * 0.02, 0.32, 0.32),
        ], sides: 8))
        headMeshes.append(lpBlade([
            lp(0, headRadius * 0.58, 1.5),
            lp(0, headRadius * 1.18, 4.0),
            lp(0, headRadius * 0.56, 5.3),
        ], thickness: lp(headRadius * 1.20, 0.28, 0.24)))
    }
    if oviraptor {
        headMeshes.append(lpBlade([
            lp(0, headRadius * 0.42, -headL * 0.14),
            lp(0, headRadius * 2.75, -headL * 0.04),
            lp(0, headRadius * 1.42, headL * 0.35),
        ], thickness: lp(0.92, 0.25, 0.32)))
    }
    if parasaurolophus {
        // The tube starts inside the rear skull and sweeps back as one continuous crest.
        headMeshes.append(lpTube(.z, [
            lpr(0, headRadius * 0.55, 0.8, 2.3, 2.0),
            lpr(0, headRadius * 1.38, 5.0, 1.85, 1.65),
            lpr(0, headRadius * 2.08, 10.5, 1.25, 1.15),
            lpr(0, headRadius * 2.35, 15.0, 0.30, 0.30),
        ], sides: 7))
    }
    if gallimimus {
        headMeshes.append(lpBlade([
            lp(0, 0.3, -headL * 0.42),
            lp(0, headRadius * 0.58, -headL * 0.10),
            lp(0, 0.2, headL * 0.46),
        ], thickness: lp(0.65, 0.18, 0.24)))
    }

    let tailLength = hadrosaur ? bodyL * 1.08 : (gallimimus ? bodyL * 1.38 : (oviraptor ? bodyL * 1.10 : (dryosaur ? bodyL * 1.42 : bodyL * 1.16)))
    var tailMeshes: [ModelMesh] = [
        lpTube(.z, [
            lpr(0, 0, 0, bodyW * 0.28, bodyW * 0.25),
            lpr(0, 0.2, tailLength * 0.28, bodyW * 0.20, bodyW * 0.18),
            lpr(0, 0.1, tailLength * 0.68, bodyW * 0.10, bodyW * 0.09),
            lpr(0, -0.1, tailLength, 0.28, 0.28),
        ], sides: 7),
    ]
    if oviraptor || gallimimus {
        tailMeshes.append(lpBlade([
            lp(0, 0, tailLength * 0.66),
            lp(0, 4.0, tailLength * 0.90),
            lp(0, 0.4, tailLength * 1.12),
            lp(0, -2.2, tailLength * 0.88),
        ], thickness: lp(0.72, 0.24, 0.28)))
    }

    let armLength = iguanodon ? 9.5 : (hadrosaur ? 8.0 : (gallimimus ? 8.8 : (oviraptor ? 7.6 : 6.2)))
    let armReach = iguanodon ? 6.4 : (hadrosaur ? 4.8 : (gallimimus ? 5.8 : (oviraptor ? 5.4 : 4.0)))
    var armMeshes = lpArm(armLength, reach: armReach, feathered: oviraptor)
    if iguanodon {
        // Iguanodon's thumb spike rises and reaches ahead from the hand in
        // the arm's local profile plane.  A broad tapered blade is visible
        // from the booth side camera without becoming a detached ornament.
        armMeshes.append(lpBlade([
            lp(0, -armLength * 0.98, -armReach * 0.92),
            lp(0, -armLength * 0.76, -armReach * 1.14),
            lp(0, -armLength * 0.34, -armReach * 1.62),
        ], thickness: lp(1.10, 0.20, 0.22)))
    }
    let legFoot = hadrosaur ? 7.0 : (iguanodon ? 6.4 : (gallimimus ? 6.0 : 4.8))
    let heavyLeg = hadrosaur || iguanodon || pachycephalosaur
    let tailPivot = (0.0, legH + 8.2, bodyL * 0.42)
    let armY = legH + (hadrosaur ? 11.4 : 10.2)
    let parts: [ModelPart] = [
        lpPart("body", bodyPivot, body),
        lpPart("neck", (0, legH + 8.5, -bodyL * 0.22), neck),
        lpPart("head", headPivot, headMeshes),
        ModelPart(name: "tail", pivot: tailPivot, rot: (-0.14, 0, 0), boxes: [], meshes: tailMeshes),
        lpPart("armR", (-bodyW * 0.55, armY, -bodyL * 0.20), armMeshes),
        lpPart("armL", (bodyW * 0.55, armY, -bodyL * 0.20), armMeshes),
        lpPart("legR", (-bodyW * 0.29, hipY, bodyL * 0.16), lpLeg(hipY, footLength: legFoot, footWidth: heavyLeg ? 2.8 : 1.9, heavy: heavyLeg, biped: true)),
        lpPart("legL", (bodyW * 0.29, hipY, bodyL * 0.16), lpLeg(hipY, footLength: legFoot, footWidth: heavyLeg ? 2.8 : 1.9, heavy: heavyLeg, biped: true)),
    ]
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "biped", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: Int(headL + beakLength), eyeX: 2, eyeY: 3, eyeGap: 4))
}

func lowPolyArmoredModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let stegosaur = recipe.form == "stegosaur"
    let bodyW: Double = stegosaur ? 13.8 : 16.2
    let bodyL: Double = stegosaur ? 25.0 : 22.0
    let legH: Double = stegosaur ? 12.0 : 9.8
    let headL: Double = stegosaur ? 8.8 : 11.0
    let headW: Double = stegosaur ? 3.6 : 5.5
    let bodyPivot = (0.0, legH + 6.1, 0.0)
    let headPivot = (0.0, legH + (stegosaur ? 5.0 : 5.7), -bodyL * 0.47)
    let body = lpTube(.z, [
        lpr(0, -0.4, -bodyL * 0.48, bodyW * 0.36, bodyW * 0.38),
        lpr(0, 0.4, -bodyL * 0.10, bodyW * 0.54, bodyW * 0.52),
        lpr(0, 0.1, bodyL * 0.25, bodyW * 0.49, bodyW * 0.45),
        lpr(0, -0.7, bodyL * 0.49, bodyW * 0.28, bodyW * 0.25),
    ], sides: 8)
    let head = lpTube(.z, [
        lpr(0, 0.0, 1.5, headW, headW * 0.62),
        lpr(0, -0.25, -headL * 0.55, headW * 0.74, headW * 0.44),
        lpr(0, -0.45, -headL, stegosaur ? 1.2 : headW * 0.52, stegosaur ? 0.75 : headW * 0.28),
    ], sides: 7)

    let tailLength = stegosaur ? 35.0 : 23.0
    var tailMeshes: [ModelMesh] = []
    if stegosaur {
        tailMeshes.append(lpTube(.z, [
            lpr(0, 0, 0, bodyW * 0.26, bodyW * 0.22),
            lpr(0, 0.1, tailLength * 0.24, 2.6, 2.3),
            lpr(0, 0.0, tailLength * 0.62, 1.35, 1.25),
            lpr(0, -0.2, tailLength, 0.25, 0.25),
        ], sides: 7))
        // Four points live in the tail part, so all remain connected during the quad tail pose.
        for (x, y) in [(-3.0, 2.6), (3.0, 2.6), (-3.0, -1.1), (3.0, -1.1)] {
            tailMeshes.append(lpConeZ(tailLength * 0.67, tailLength * 1.12, 0.95, 0.15, y: y, x: x, sides: 5))
        }
    } else {
        // A continuous taper-to-club profile prevents the club from becoming a detached box.
        tailMeshes.append(lpTube(.z, [
            lpr(0, 0, 0, bodyW * 0.30, bodyW * 0.26),
            lpr(0, -0.1, tailLength * 0.38, 2.25, 2.0),
            lpr(0, -0.2, tailLength * 0.68, 1.45, 1.30),
            lpr(0, -0.1, tailLength * 0.85, 4.20, 3.10),
            lpr(0, -0.2, tailLength * 1.03, 4.75, 3.45),
            lpr(0, -0.4, tailLength * 1.18, 0.38, 0.38),
        ], sides: 8))
    }

    var parts: [ModelPart] = [
        lpPart("body", bodyPivot, body),
        lpPart("head", headPivot, head),
        ModelPart(name: "tail", pivot: (0, legH + 6.9, bodyL * 0.42), rot: (-0.12, 0, 0), boxes: [], meshes: tailMeshes),
        lpPart("legFR", (-bodyW * 0.33, legH, -bodyL * 0.29), lpLeg(legH, footLength: stegosaur ? 5.4 : 4.8, footWidth: 3.2, heavy: true)),
        lpPart("legFL", (bodyW * 0.33, legH, -bodyL * 0.29), lpLeg(legH, footLength: stegosaur ? 5.4 : 4.8, footWidth: 3.2, heavy: true)),
        lpPart("legBR", (-bodyW * 0.34, legH, bodyL * 0.29), lpLeg(legH * (stegosaur ? 0.91 : 0.95), footLength: stegosaur ? 5.0 : 4.5, footWidth: 3.2, heavy: true)),
        lpPart("legBL", (bodyW * 0.34, legH, bodyL * 0.29), lpLeg(legH * (stegosaur ? 0.91 : 0.95), footLength: stegosaur ? 5.0 : 4.5, footWidth: 3.2, heavy: true)),
    ]
    if stegosaur {
        let plateHeights = [7.5, 10.5, 13.0, 15.0, 16.2, 14.5, 11.5, 8.8, 6.5]
        let plateMeshes = plateHeights.enumerated().map { index, height in
            let progress = Double(index) / Double(plateHeights.count - 1)
            let z = -bodyL * 0.45 + progress * bodyL * 0.88
            let x = index.isMultiple(of: 2) ? -0.95 : 0.95
            return lpBlade([
                lp(x, 0, z - 1.8),
                lp(x, height, z),
                lp(x, 0, z + 2.2),
            ], thickness: lp(1.15, 0.24, 0.34))
        }
        parts.append(lpPart("plates", (0, legH + 11.1, 0), plateMeshes))
    } else {
        let armorMeshes = (0..<7).map { index in
            let progress = Double(index) / 6
            let z = -bodyL * 0.42 + progress * bodyL * 0.84
            let height = 3.2 + (1 - abs(progress - 0.5) * 2) * 3.1
            return lpBlade([
                lp(0, -0.4, z - 2.1),
                lp(0, height, z - 0.2),
                lp(0, height * 0.70, z + 2.0),
                lp(0, -0.2, z + 3.1),
            ], thickness: lp(bodyW * 0.86, 0.30, 0.36))
        }
        parts.append(lpPart("armor", (0, legH + 11.2, 0), armorMeshes))
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "prehistoricQuad", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: Int(headL), eyeX: 2, eyeY: 2, eyeGap: 4))
}

func lowPolySauropodModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let brachiosaur = recipe.form == "brachiosaur"
    let bodyW: Double = brachiosaur ? 16.5 : 14.5
    let bodyL: Double = brachiosaur ? 24.5 : 28.0
    let legH: Double = brachiosaur ? 22.0 : 18.0
    let headL: Double = brachiosaur ? 10.5 : 8.0
    let headW: Double = brachiosaur ? 4.8 : 3.6
    let bodyY = legH + 8.0
    let baseRise: Double = brachiosaur ? 15.5 : 7.5
    let baseRun: Double = brachiosaur ? 11.0 : 17.0
    let midRise: Double = brachiosaur ? 18.5 : 7.0
    let midRun: Double = brachiosaur ? 13.0 : 19.0
    let neckBasePivot = (0.0, bodyY + 5.0, -bodyL * 0.34)
    let neckMidPivot = (0.0, neckBasePivot.1 + baseRise, neckBasePivot.2 - baseRun)
    let headPivot = (0.0, neckMidPivot.1 + midRise, neckMidPivot.2 - midRun)

    let body = lpTube(.z, [
        lpr(0, -0.5, -bodyL * 0.50, bodyW * 0.38, bodyW * 0.42),
        lpr(0, 0.5, -bodyL * 0.15, bodyW * 0.55, bodyW * 0.54),
        lpr(0, 0.4, bodyL * 0.22, bodyW * 0.53, bodyW * 0.50),
        lpr(0, -0.5, bodyL * 0.50, bodyW * 0.31, bodyW * 0.28),
    ], sides: 8)
    let neckBase = lpTube(.z, [
        lpr(0, 0, 4.5, 4.8, 4.9),
        lpr(0, baseRise * 0.42, -baseRun * 0.42, 4.2, 4.1),
        lpr(0, baseRise, -baseRun, 3.45, 3.35),
    ], sides: 8)
    let neckMid = lpTube(.z, [
        lpr(0, 0, 0, 3.45, 3.35),
        lpr(0, midRise * 0.44, -midRun * 0.45, 2.85, 2.75),
        lpr(0, midRise, -midRun, 2.25, 2.15),
    ], sides: 8)
    var headMeshes: [ModelMesh] = [
        lpTube(.z, [
            lpr(0, 0.2, 2.0, headW * 0.90, headW * 0.75),
            lpr(0, 0.2, -headL * 0.45, headW, headW * 0.70),
            lpr(0, -0.25, -headL, headW * 0.62, headW * 0.40),
        ], sides: 7),
        lpTube(.z, [
            lpr(0, -headW * 0.34, -headL * 0.82, headW * 0.53, headW * 0.20),
            lpr(0, -headW * 0.44, -headL * 1.38, headW * 0.36, headW * 0.12),
        ], sides: 6),
    ]
    if brachiosaur {
        // A raised nasal/forehead profile differentiates the tall-browser head.
        headMeshes.append(lpTube(.y, [
            lpr(0, headW * 0.45, -headL * 0.16, headW * 0.58, headW * 0.48),
            lpr(0, headW * 1.22, -headL * 0.12, 0.28, 0.28),
        ], sides: 7))
    }
    let tailLength = brachiosaur ? 42.0 : 68.0
    let tail = lpTube(.z, [
        lpr(0, 0, 0, bodyW * 0.31, bodyW * 0.28),
        lpr(0, 0.1, tailLength * 0.22, bodyW * 0.24, bodyW * 0.21),
        lpr(0, 0.0, tailLength * 0.58, brachiosaur ? 1.65 : 1.05, brachiosaur ? 1.50 : 0.95),
        lpr(0, -0.1, tailLength, 0.26, 0.26),
    ], sides: 8)
    var parts: [ModelPart] = [
        lpPart("body", (0, bodyY, 0), body),
        lpPart("neckBase", neckBasePivot, neckBase),
        lpPart("neckMid", neckMidPivot, neckMid),
        lpPart("head", headPivot, headMeshes),
        lpRotatedPart("tail", (0, bodyY + 1.0, bodyL * 0.42), (-0.10, 0, 0), tail),
        lpPart("legFR", (-bodyW * 0.32, legH, -bodyL * 0.28), lpLeg(legH, footLength: brachiosaur ? 7.2 : 6.3, footWidth: 4.0, heavy: true)),
        lpPart("legFL", (bodyW * 0.32, legH, -bodyL * 0.28), lpLeg(legH, footLength: brachiosaur ? 7.2 : 6.3, footWidth: 4.0, heavy: true)),
        lpPart("legBR", (-bodyW * 0.32, legH, bodyL * 0.30), lpLeg(legH * (brachiosaur ? 0.73 : 0.93), footLength: brachiosaur ? 5.2 : 6.0, footWidth: 4.0, heavy: true)),
        lpPart("legBL", (bodyW * 0.32, legH, bodyL * 0.30), lpLeg(legH * (brachiosaur ? 0.73 : 0.93), footLength: brachiosaur ? 5.2 : 6.0, footWidth: 4.0, heavy: true)),
    ]
    if brachiosaur {
        let shoulderRise = lpTube(.z, [
            lpr(0, 0, -5.0, bodyW * 0.42, bodyW * 0.42),
            lpr(0, 4.5, -1.0, bodyW * 0.38, bodyW * 0.35),
            lpr(0, 2.0, 4.5, bodyW * 0.30, bodyW * 0.28),
        ], sides: 7)
        parts.append(lpPart("shoulderRise", (0, bodyY + 6.5, -bodyL * 0.15), shoulderRise))
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "prehistoricQuad", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: Int(headL), eyeX: 2, eyeY: 3, eyeGap: 4))
}

func lowPolyMicroraptorModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let body = lpTube(.z, [
        lpr(0, 0.0, -5.5, 2.35, 2.50),
        lpr(0, 0.2, -1.0, 3.10, 3.00),
        lpr(0, -0.1, 4.4, 2.15, 2.00),
    ], sides: 7)
    let head = lpTube(.z, [
        lpr(0, 0.0, 1.4, 2.55, 2.35),
        lpr(0, -0.1, -3.5, 2.15, 1.75),
        lpr(0, -0.35, -6.5, 1.25, 0.72),
    ], sides: 7)
    let tail = [
        lpTube(.z, [
            lpr(0, 0, 0, 1.45, 1.35),
            lpr(0, 0.1, 8.0, 0.92, 0.85),
            lpr(0, 0.0, 16.5, 0.26, 0.26),
        ], sides: 6),
        lpBlade([
            lp(0, 0.0, 8.0),
            lp(0, 4.5, 15.0),
            lp(0, 0.5, 20.0),
            lp(0, -3.0, 15.5),
        ], thickness: lp(0.82, 0.20, 0.28)),
    ]
    // Each wing pairs a genuine lateral flight surface with a trailing feather
    // fan.  The previous fan-only form lay entirely in the sagittal plane,
    // which made a four-winged animal look like it had hanging panels in a
    // three-quarter view and gave the parrot flap rotation no actual span.
    func foreWing(_ side: Double) -> [ModelMesh] {
        let flightSurface = lpBlade([
            lp(0, 1.0, -3.0),
            lp(side * 5.2, 0.0, -4.7),
            lp(side * 12.5, -0.9, -0.2),
            lp(side * 11.2, -1.4, 7.8),
            lp(side * 5.5, -0.5, 11.8),
            lp(side * 0.8, 0.6, 5.0),
        ], thickness: lp(0.18, 0.30, 0.22))
        let featherFan = lpBlade([
            lp(side * 0.5, 0.8, -2.7),
            lp(side * 3.5, -2.8, -5.0),
            lp(side * 7.2, -8.8, -0.3),
            lp(side * 7.0, -11.0, 7.5),
            lp(side * 3.1, -5.3, 11.6),
            lp(side * 0.5, 0.5, 5.0),
        ], thickness: lp(0.38, 0.22, 0.22))
        return [flightSurface, featherFan]
    }
    func hindWing(_ side: Double) -> [ModelMesh] {
        let flightSurface = lpBlade([
            lp(0, 0.8, -1.5),
            lp(side * 3.4, -0.2, -3.2),
            lp(side * 8.5, -1.0, 2.0),
            lp(side * 7.8, -1.5, 8.8),
            lp(side * 3.0, -0.6, 11.0),
            lp(side * 0.5, 0.7, 5.8),
        ], thickness: lp(0.18, 0.26, 0.20))
        let featherFan = lpBlade([
            lp(side * 0.4, 0.6, -1.3),
            lp(side * 2.4, -2.3, -3.1),
            lp(side * 5.1, -6.8, 2.0),
            lp(side * 5.0, -8.0, 8.7),
            lp(side * 2.2, -3.0, 10.9),
            lp(side * 0.4, 0.6, 5.7),
        ], thickness: lp(0.34, 0.20, 0.20))
        return [flightSurface, featherFan]
    }
    let legMeshes = lpLeg(5.2, footLength: 3.5, footWidth: 1.25)
    let parts: [ModelPart] = [
        lpPart("body", (0, 8.0, 0), body),
        lpPart("head", (0, 10.5, -5.0), head),
        ModelPart(name: "tail", pivot: (0, 8.2, 5.0), rot: (-0.10, 0, 0), boxes: [], meshes: tail),
        lpPart("wingR", (-2.6, 9.2, -1.0), foreWing(-1)),
        lpPart("wingL", (2.6, 9.2, -1.0), foreWing(1)),
        lpPart("hindWingR", (-2.0, 5.2, 3.0), hindWing(-1)),
        lpPart("hindWingL", (2.0, 5.2, 3.0), hindWing(1)),
        lpPart("legR", (-1.55, 5.2, 2.0), legMeshes),
        lpPart("legL", (1.55, 5.2, 2.0), legMeshes),
    ]
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "parrot", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 7, eyeX: 1, eyeY: 2, eyeGap: 2))
}
