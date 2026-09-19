// Faceted native meshes for Elysium's airborne and aquatic prehistoric families.
//
// These retain the established rigid part names so the renderer's bounded
// phantom, fish, and quadruped pose paths keep working.  Geometry is authored
// directly from the safe primitive vocabulary in PrehistoricLowPolyModels.swift.

private func airWaterRotatedPart(_ name: String, _ pivot: (Double, Double, Double),
                                 _ rot: (Double, Double, Double), _ meshes: [ModelMesh]) -> ModelPart {
    ModelPart(name: name, pivot: pivot, rot: rot, boxes: [], meshes: meshes)
}

private func airWaterWingMeshes(side: Double, span: Double, chord: Double,
                                tipSweep: Double, rootRadius: Double) -> [ModelMesh] {
    let bone = lpTube(.x, [
        lpr(0, 0, 0, rootRadius, rootRadius * 0.82),
        lpr(side * span * 0.38, -0.18, tipSweep * 0.20, rootRadius * 0.72, rootRadius * 0.58),
        lpr(side * span * 0.72, -0.38, tipSweep * 0.55, rootRadius * 0.38, rootRadius * 0.31),
    ], sides: 6)
    let membrane = lpBlade([
        lp(0, 0.30, -chord * 0.44),
        lp(side * span * 0.23, 0.06, -chord * 0.57 + tipSweep * 0.12),
        lp(side * span * 0.86, -0.50, tipSweep * 0.84),
        lp(side * span * 0.63, -0.84, chord * 0.58 + tipSweep * 0.24),
        lp(side * span * 0.10, -0.26, chord * 0.44),
    ], thickness: lp(0.20, 0.26, 0.16))
    return [bone, membrane]
}

private func airWaterPaddleMeshes(side: Double, span: Double, chord: Double,
                                  sweep: Double = 0) -> [ModelMesh] {
    let arm = lpTube(.x, [
        lpr(0, 0, 0, chord * 0.18, chord * 0.18),
        lpr(side * span * 0.30, -0.30, sweep * 0.18, chord * 0.16, chord * 0.15),
        lpr(side * span * 0.58, -0.52, sweep * 0.43, chord * 0.11, chord * 0.10),
    ], sides: 6)
    let blade = lpBlade([
        lp(0, 0.04, -chord * 0.44),
        lp(side * span * 0.28, -0.17, -chord * 0.62 + sweep * 0.10),
        lp(side * span, -0.58, sweep),
        lp(side * span * 0.67, -0.62, chord * 0.60 + sweep * 0.13),
        lp(side * span * 0.12, -0.18, chord * 0.42),
    ], thickness: lp(0.18, 0.24, 0.16))
    return [arm, blade]
}

private func airWaterVerticalTailMeshes(length: Double, rootWidth: Double, rootHeight: Double,
                                        flukeHeight: Double, flukeReach: Double) -> [ModelMesh] {
    let shaft = lpTube(.z, [
        lpr(0, 0, 0, rootWidth, rootHeight),
        lpr(0, 0.10, length * 0.38, rootWidth * 0.66, rootHeight * 0.66),
        lpr(0, 0, length * 0.70, rootWidth * 0.34, rootHeight * 0.34),
        lpr(0, 0, length, rootWidth * 0.16, rootHeight * 0.16),
    ], sides: 7)
    // A vertical diamond fluke is kept in the animated tail part, unlike a
    // separate decorative child which this intentionally non-hierarchical rig
    // could not make follow the swimming motion.
    let fluke = lpBlade([
        lp(0, -flukeHeight, length * 0.73),
        lp(0, 0, length + flukeReach),
        lp(0, flukeHeight, length * 0.73),
        lp(0, 0, length * 0.50),
    ], thickness: lp(max(0.42, rootWidth * 0.16), 0.16, 0.18))
    return [shaft, fluke]
}

private func airWaterHorizontalTailMeshes(length: Double, rootWidth: Double, rootHeight: Double,
                                          flukeSpan: Double) -> [ModelMesh] {
    let shaft = lpTube(.z, [
        lpr(0, 0, 0, rootWidth, rootHeight),
        lpr(0, 0.05, length * 0.48, rootWidth * 0.54, rootHeight * 0.54),
        lpr(0, 0, length, rootWidth * 0.18, rootHeight * 0.18),
    ], sides: 7)
    let fluke = lpBlade([
        lp(-flukeSpan, 0, length * 0.74),
        lp(0, 0, length * 1.10),
        lp(flukeSpan, 0, length * 0.74),
        lp(0, 0, length * 0.46),
    ], thickness: lp(0.16, 0.24, 0.18))
    return [shaft, fluke]
}

func lowPolyPterosaurModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let dimorphodon = recipe.id.hasSuffix("dimorphodon")
    let rhamphorhynchus = recipe.id.hasSuffix("rhamphorhynchus")
    let pteranodon = recipe.form == "pteranodon"
    let tapejara = recipe.form == "tapejara"
    let azhdarchid = recipe.form == "azhdarchid"
    let longTail = recipe.form == "longTail"

    let bodyRadius = azhdarchid ? 5.2 : (pteranodon ? 4.7 : (tapejara ? 4.2 : (dimorphodon ? 3.5 : 3.0)))
    let bodyHeight = azhdarchid ? 5.7 : (pteranodon ? 5.0 : (tapejara ? 4.7 : 3.9))
    let bodyLength = azhdarchid ? 20.0 : (pteranodon ? 16.0 : (tapejara ? 14.0 : (dimorphodon ? 12.5 : 11.5)))
    let legHeight = azhdarchid ? 18.0 : (pteranodon ? 11.0 : (tapejara ? 10.0 : 7.5))
    let neckLength = azhdarchid ? 22.0 : (pteranodon ? 9.0 : (tapejara ? 8.0 : 5.5))
    let neckRise = azhdarchid ? 16.0 : (pteranodon ? 6.5 : (tapejara ? 6.0 : 3.2))
    let headLength = azhdarchid ? 11.0 : (pteranodon ? 9.2 : (tapejara ? 7.4 : (dimorphodon ? 7.8 : 6.4)))
    let beakLength = azhdarchid ? 22.0 : (pteranodon ? 18.0 : (tapejara ? 10.0 : (dimorphodon ? 5.4 : 9.0)))
    let wingSpan = azhdarchid ? 37.0 : (pteranodon ? 28.0 : (tapejara ? 23.0 : (dimorphodon ? 15.0 : 18.0)))
    let wingChord = azhdarchid ? 17.0 : (pteranodon ? 16.0 : (tapejara ? 13.0 : 10.5))
    let chestY = legHeight + bodyHeight * 0.58
    let shoulderZ = -bodyLength * 0.18
    let headPivot = (0.0, chestY + neckRise, -bodyLength * 0.36 - neckLength)

    let body = lpTube(.z, [
        lpr(0, -0.20, -bodyLength * 0.50, bodyRadius * 0.66, bodyHeight * 0.64),
        lpr(0, 0.20, -bodyLength * 0.12, bodyRadius, bodyHeight),
        lpr(0, 0.08, bodyLength * 0.26, bodyRadius * 0.84, bodyHeight * 0.80),
        lpr(0, -0.20, bodyLength * 0.50, bodyRadius * 0.46, bodyHeight * 0.46),
    ], sides: 7)
    let neck = lpTube(.z, [
        lpr(0, 0, 3.0, bodyRadius * 0.43, bodyHeight * 0.42),
        lpr(0, neckRise * 0.40, -neckLength * 0.44, bodyRadius * 0.30, bodyHeight * 0.30),
        lpr(0, neckRise, -neckLength, bodyRadius * 0.22, bodyHeight * 0.23),
    ], sides: 7)
    let headWidth = azhdarchid ? 3.3 : (pteranodon ? 4.0 : (tapejara ? 3.9 : (dimorphodon ? 4.3 : 3.0)))
    let head = lpTube(.z, [
        lpr(0, 0.15, 1.8, headWidth, headWidth * 0.76),
        lpr(0, 0.04, -headLength * 0.43, headWidth * 0.93, headWidth * 0.62),
        lpr(0, -0.42, -headLength, headWidth * 0.54, headWidth * 0.37),
    ], sides: 7)
    let beak = lpTube(.z, [
        lpr(0, 0, 1.0, headWidth * 0.52, headWidth * 0.25),
        lpr(0, -0.10, -beakLength * 0.52, headWidth * 0.30, headWidth * 0.16),
        lpr(0, -0.18, -beakLength, 0.22, 0.20),
    ], sides: 6)
    // The renderer deliberately has no parent transform hierarchy.  Keep
    // every skull landmark in the head slot so looking or browsing cannot
    // leave an otherwise detailed beak or crest behind.
    var headMeshes: [ModelMesh] = [
        head,
        lpTranslated(beak, by: lp(0, -0.35, -headLength * 0.72)),
    ]
    let tailLength = rhamphorhynchus ? 28.0 : (dimorphodon ? 20.0 : (azhdarchid ? 4.8 : (pteranodon ? 5.6 : 5.0)))
    let tail = lpTube(.z, [
        lpr(0, 0, 0, bodyRadius * 0.42, bodyHeight * 0.38),
        lpr(0, 0.05, tailLength * 0.35, bodyRadius * 0.23, bodyHeight * 0.21),
        lpr(0, 0, tailLength, 0.22, 0.22),
    ], sides: 7)
    var tailMeshes: [ModelMesh] = [tail]
    var parts: [ModelPart] = [
        lpPart("body", (0, chestY, 0), body),
        lpPart("neck", (0, chestY + bodyHeight * 0.26, -bodyLength * 0.34), neck),
        lpPart("head", headPivot, headMeshes),
        // The complete arm/finger/membrane span is one rigid wing pose.  The
        // previous split roots could not compose transforms in this renderer
        // and visibly opened a gap while flapping or folding.
        lpPart("wingR", (-bodyRadius * 0.78, chestY + bodyHeight * 0.36, shoulderZ),
               airWaterWingMeshes(side: -1, span: wingSpan * 0.95, chord: wingChord, tipSweep: wingChord * 0.42, rootRadius: bodyRadius * 0.22)),
        lpPart("wingL", (bodyRadius * 0.78, chestY + bodyHeight * 0.36, shoulderZ),
               airWaterWingMeshes(side: 1, span: wingSpan * 0.95, chord: wingChord, tipSweep: wingChord * 0.42, rootRadius: bodyRadius * 0.22)),
        lpPart("legR", (-bodyRadius * 0.45, legHeight, bodyLength * 0.20),
               lpLeg(legHeight, footLength: azhdarchid ? 9.0 : 5.0, footWidth: azhdarchid ? 2.2 : 1.5)),
        lpPart("legL", (bodyRadius * 0.45, legHeight, bodyLength * 0.20),
               lpLeg(legHeight, footLength: azhdarchid ? 9.0 : 5.0, footWidth: azhdarchid ? 2.2 : 1.5)),
        airWaterRotatedPart("tail", (0, chestY - bodyHeight * 0.08, bodyLength * 0.43), (-0.10, 0, 0), tailMeshes),
    ]
    if longTail {
        let vaneWidth = rhamphorhynchus ? 6.2 : 4.8
        let vaneHeight = rhamphorhynchus ? 5.6 : 4.2
        let vane = lpBlade([
            lp(0, -vaneHeight, 0), lp(0, 0, vaneWidth),
            lp(0, vaneHeight, 0), lp(0, 0, -vaneWidth * 0.72),
        ], thickness: lp(0.52, 0.20, 0.22))
        tailMeshes.append(lpTranslated(vane, by: lp(0, 0, tailLength)))
    }
    if dimorphodon {
        let crest = lpBlade([
            lp(0, 0.6, -2.5), lp(0, 6.0, -1.0), lp(0, 3.4, 3.5), lp(0, 0.5, 2.2),
        ], thickness: lp(0.72, 0.22, 0.20))
        headMeshes.append(crest)
    }
    if pteranodon {
        // Pteranodon's crest is a long, low rear spar.  The old tall triangular
        // slab overwhelmed the profile and read as a folded wing instead.
        let crest = lpBlade([
            lp(0, 0.3, 0), lp(0, 2.3, 3.6), lp(0, 2.0, 13.5),
            lp(0, 0.65, 23.5), lp(0, -0.45, 15.0), lp(0, -0.25, 4.0),
        ], thickness: lp(0.78, 0.26, 0.24))
        headMeshes.append(crest)
    }
    if tapejara {
        let crest = lpBlade([
            lp(0, -1.2, -2.5), lp(0, 11.5, -5.4), lp(0, 18.0, 0.8),
            lp(0, 7.0, 5.4), lp(0, 0.8, 3.5),
        ], thickness: lp(0.82, 0.28, 0.24))
        headMeshes.append(crest)
    }
    if azhdarchid {
        let crown = lpBlade([
            lp(0, 0.5, -2.6), lp(0, 5.0, -1.0), lp(0, 5.8, 3.5), lp(0, 0.8, 4.6),
        ], thickness: lp(0.72, 0.24, 0.20))
        headMeshes.append(crown)
    }
    parts[2] = lpPart("head", headPivot, headMeshes)
    parts[7] = airWaterRotatedPart("tail", (0, chestY - bodyHeight * 0.08, bodyLength * 0.43), (-0.10, 0, 0), tailMeshes)
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "prehistoricPterosaur", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: Int(headLength + beakLength * 0.32), eyeX: 1, eyeY: 2, eyeGap: 4))
}

func lowPolyIchthyosaurModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let bodyLength = 22.0
    let bodyWidth = 4.6
    let bodyHeight = 4.2
    let body = lpTube(.z, [
        lpr(0, 0, -bodyLength * 0.50, bodyWidth * 0.48, bodyHeight * 0.50),
        lpr(0, 0.10, -bodyLength * 0.13, bodyWidth, bodyHeight),
        lpr(0, 0, bodyLength * 0.25, bodyWidth * 0.85, bodyHeight * 0.82),
        lpr(0, -0.22, bodyLength * 0.50, bodyWidth * 0.42, bodyHeight * 0.42),
    ], sides: 8)
    let head = lpTube(.z, [
        lpr(0, 0.15, 1.8, 4.9, 3.8),
        lpr(0, 0.02, -4.5, 4.4, 3.3),
        lpr(0, -0.35, -8.8, 2.7, 1.9),
    ], sides: 8)
    let snout = lpTube(.z, [
        lpr(0, 0, 1, 2.5, 1.6),
        lpr(0, -0.10, -6.5, 1.2, 0.82),
        lpr(0, -0.12, -10.5, 0.24, 0.24),
    ], sides: 7)
    let dorsal = lpBlade([
        lp(0, 0, -3.5), lp(0, 7.3, 0.4), lp(0, 1.2, 5.8), lp(0, 0, 5.4),
    ], thickness: lp(0.42, 0.18, 0.20))
    let parts: [ModelPart] = [
        lpPart("body", (0, 8, 0), body),
        lpPart("head", (0, 8, -bodyLength * 0.43), head),
        lpPart("snout", (0, 7.6, -bodyLength * 0.43 - 7.2), snout),
        lpPart("tail", (0, 8, bodyLength * 0.43),
               airWaterVerticalTailMeshes(length: 11.0, rootWidth: 2.8, rootHeight: 2.7, flukeHeight: 8.0, flukeReach: 2.0)),
        lpPart("dorsalFin", (0, 11.6, 1.2), dorsal),
        lpPart("flipperR", (-bodyWidth * 0.84, 6.6, -1.7), airWaterPaddleMeshes(side: -1, span: 10.0, chord: 7.6, sweep: -1.5)),
        lpPart("flipperL", (bodyWidth * 0.84, 6.6, -1.7), airWaterPaddleMeshes(side: 1, span: 10.0, chord: 7.6, sweep: -1.5)),
    ]
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "fish", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 12, eyeX: 1, eyeY: 2, eyeGap: 5))
}

func lowPolyPlesiosaurModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let longNeck = recipe.form == "longNeck"
    let pliosaur = recipe.form == "pliosaur"
    let bodyLength = pliosaur ? 23.0 : (longNeck ? 19.0 : 17.0)
    let bodyWidth = pliosaur ? 7.5 : (longNeck ? 6.8 : 6.1)
    let bodyHeight = pliosaur ? 5.6 : 4.9
    let body = lpTube(.z, [
        lpr(0, -0.15, -bodyLength * 0.50, bodyWidth * 0.58, bodyHeight * 0.60),
        lpr(0, 0.12, -bodyLength * 0.13, bodyWidth, bodyHeight),
        lpr(0, 0.05, bodyLength * 0.28, bodyWidth * 0.87, bodyHeight * 0.83),
        lpr(0, -0.20, bodyLength * 0.50, bodyWidth * 0.40, bodyHeight * 0.40),
    ], sides: 8)
    var parts: [ModelPart] = [
        lpPart("body", (0, 8, 0), body),
        lpPart("tail", (0, 8, bodyLength * 0.44),
               airWaterHorizontalTailMeshes(length: pliosaur ? 10.0 : 8.2, rootWidth: pliosaur ? 2.7 : 2.2, rootHeight: 1.9, flukeSpan: pliosaur ? 4.8 : 3.8)),
        lpPart("flipperFR", (-bodyWidth * 0.82, 6.6, -bodyLength * 0.25), airWaterPaddleMeshes(side: -1, span: pliosaur ? 13.0 : 10.0, chord: pliosaur ? 9.5 : 8.2, sweep: -2.0)),
        lpPart("flipperFL", (bodyWidth * 0.82, 6.6, -bodyLength * 0.25), airWaterPaddleMeshes(side: 1, span: pliosaur ? 13.0 : 10.0, chord: pliosaur ? 9.5 : 8.2, sweep: -2.0)),
        lpPart("flipperBR", (-bodyWidth * 0.80, 6.5, bodyLength * 0.25), airWaterPaddleMeshes(side: -1, span: pliosaur ? 11.0 : 8.7, chord: pliosaur ? 8.2 : 7.0, sweep: 1.2)),
        lpPart("flipperBL", (bodyWidth * 0.80, 6.5, bodyLength * 0.25), airWaterPaddleMeshes(side: 1, span: pliosaur ? 11.0 : 8.7, chord: pliosaur ? 8.2 : 7.0, sweep: 1.2)),
    ]
    if pliosaur {
        let neck = lpTube(.z, [
            lpr(0, 0.30, 2.0, bodyWidth * 0.48, bodyHeight * 0.52),
            lpr(0, 1.5, -5.4, bodyWidth * 0.38, bodyHeight * 0.42),
        ], sides: 7)
        let head = lpTube(.z, [
            lpr(0, 0.12, 2.0, 6.4, 4.8),
            lpr(0, 0.04, -6.5, 6.0, 4.1),
            lpr(0, -0.42, -13.2, 3.7, 2.1),
        ], sides: 8)
        let jaw = lpTube(.z, [
            lpr(0, 0, 1.0, 5.7, 1.15),
            lpr(0, -0.10, -9.4, 3.9, 0.76),
            lpr(0, -0.12, -13.0, 0.30, 0.24),
        ], sides: 7)
        parts.append(lpPart("neck", (0, 9.5, -bodyLength * 0.35), neck))
        parts.append(lpPart("head", (0, 11.0, -bodyLength * 0.57), head))
        parts.append(lpPart("jaw", (0, 8.2, -bodyLength * 0.57 - 8.0), jaw))
    } else {
        let segments = longNeck ? 7 : 3
        let segmentLength = longNeck ? 7.2 : 6.4
        let rise = longNeck ? 18.0 : 7.0
        let neckRadius = longNeck ? 2.4 : 2.8
        for index in 0..<segments {
            let progress = Double(index) / Double(max(1, segments - 1))
            let z = -bodyLength * 0.39 - Double(index) * segmentLength
            let y = 10.0 + progress * rise
            let segment = lpTube(.z, [
                lpr(0, 0, 3.4, neckRadius * (1 - progress * 0.20), neckRadius * (1 - progress * 0.16)),
                lpr(0, 1.4 + progress * 0.75, -4.0, neckRadius * (0.88 - progress * 0.18), neckRadius * (0.88 - progress * 0.16)),
            ], sides: 7)
            parts.append(airWaterRotatedPart("neck\(index)", (0, y, z), (-0.15, 0, 0), [segment]))
        }
        let headZ = -bodyLength * 0.39 - Double(segments) * segmentLength
        let headY = 10.0 + rise
        let head = lpTube(.z, [
            lpr(0, 0.1, 1.8, longNeck ? 2.7 : 3.2, longNeck ? 2.3 : 2.7),
            lpr(0, 0, -4.4, longNeck ? 2.2 : 2.7, longNeck ? 1.7 : 2.0),
            lpr(0, -0.28, -8.5, 0.32, 0.28),
        ], sides: 7)
        parts.append(lpPart("head", (0, headY, headZ), head))
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "fish", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: pliosaur ? 14 : 9, eyeX: 1, eyeY: 1, eyeGap: 3))
}

func lowPolyMosasaurModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let bodyLength = 28.0
    let bodyWidth = 6.8
    let bodyHeight = 5.2
    let body = lpTube(.z, [
        lpr(0, -0.20, -bodyLength * 0.50, bodyWidth * 0.52, bodyHeight * 0.54),
        lpr(0, 0.12, -bodyLength * 0.12, bodyWidth, bodyHeight),
        lpr(0, 0.10, bodyLength * 0.28, bodyWidth * 0.86, bodyHeight * 0.80),
        lpr(0, -0.18, bodyLength * 0.50, bodyWidth * 0.40, bodyHeight * 0.38),
    ], sides: 8)
    let head = lpTube(.z, [
        lpr(0, 0.12, 1.8, 6.0, 4.5),
        lpr(0, 0, -7.8, 5.7, 3.7),
        lpr(0, -0.35, -14.0, 3.2, 1.9),
    ], sides: 8)
    let jaw = lpTube(.z, [
        lpr(0, 0, 1.2, 5.3, 1.05),
        lpr(0, -0.12, -9.0, 3.8, 0.72),
        lpr(0, -0.18, -14.5, 0.26, 0.20),
    ], sides: 7)
    let ridge = lpBlade([
        lp(0, 0, -7.4), lp(0, 3.8, -2.2), lp(0, 4.5, 5.8), lp(0, 0, 9.0),
    ], thickness: lp(0.48, 0.20, 0.20))
    let parts: [ModelPart] = [
        lpPart("body", (0, 9, 0), body),
        lpPart("head", (0, 9, -bodyLength * 0.42), head),
        lpPart("jaw", (0, 6.4, -bodyLength * 0.42 - 10.0), jaw),
        lpPart("tail", (0, 9, bodyLength * 0.44),
               airWaterVerticalTailMeshes(length: 16.5, rootWidth: 3.9, rootHeight: 3.1, flukeHeight: 9.0, flukeReach: 3.5)),
        lpPart("flipperR", (-bodyWidth * 0.86, 7.1, -2.8), airWaterPaddleMeshes(side: -1, span: 12.5, chord: 9.0, sweep: -1.8)),
        lpPart("flipperL", (bodyWidth * 0.86, 7.1, -2.8), airWaterPaddleMeshes(side: 1, span: 12.5, chord: 9.0, sweep: -1.8)),
        lpPart("dorsalRidge", (0, 13.4, 2.2), ridge),
    ]
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "fish", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 15, eyeX: 2, eyeY: 2, eyeGap: 5))
}

func lowPolyCrocodilianModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let bodyLength = 27.0
    let bodyWidth = 7.7
    let bodyHeight = 3.8
    let body = lpTube(.z, [
        lpr(0, -0.20, -bodyLength * 0.50, bodyWidth * 0.62, bodyHeight * 0.66),
        lpr(0, 0.05, -bodyLength * 0.14, bodyWidth, bodyHeight),
        lpr(0, 0, bodyLength * 0.30, bodyWidth * 0.87, bodyHeight * 0.82),
        lpr(0, -0.28, bodyLength * 0.50, bodyWidth * 0.45, bodyHeight * 0.42),
    ], sides: 8)
    let skull = lpTube(.z, [
        lpr(0, 0.10, 2.2, 6.0, 3.2),
        lpr(0, 0.02, -6.0, 5.8, 2.9),
        lpr(0, -0.18, -10.0, 4.9, 2.2),
    ], sides: 8)
    let snout = lpTube(.z, [
        lpr(0, 0, 1.0, 4.9, 1.7),
        lpr(0, -0.08, -8.5, 4.6, 1.32),
        lpr(0, -0.15, -15.0, 2.5, 0.78),
    ], sides: 7)
    let jaw = lpTube(.z, [
        lpr(0, 0, 1.0, 4.8, 0.92),
        lpr(0, -0.08, -10.0, 4.2, 0.68),
        lpr(0, -0.12, -15.2, 0.26, 0.20),
    ], sides: 7)
    // The quad rig pitches only its head slot while browsing and charging.
    // Keep the long crocodilian snout and jaw in that slot rather than
    // allowing their independently rooted meshes to separate from the skull.
    let headMeshes = [
        skull,
        lpTranslated(snout, by: lp(0, -0.7, -8.2)),
        lpTranslated(jaw, by: lp(0, -2.0, -8.2)),
    ]
    let scutes = [
        lpBlade([lp(0, 0, -10.0), lp(0, 3.8, -8.2), lp(0, 3.2, -5.8), lp(0, 0, -4.0)], thickness: lp(0.70, 0.18, 0.18)),
        lpBlade([lp(0, 0, -4.0), lp(0, 4.4, -2.0), lp(0, 3.8, 1.0), lp(0, 0, 3.0)], thickness: lp(0.70, 0.18, 0.18)),
        lpBlade([lp(0, 0, 3.0), lp(0, 4.0, 5.1), lp(0, 3.2, 7.6), lp(0, 0, 9.2)], thickness: lp(0.70, 0.18, 0.18)),
    ]
    let parts: [ModelPart] = [
        lpPart("head", (0, 8.1, -bodyLength * 0.43), headMeshes),
        lpPart("body", (0, 7.2, 0), body),
        airWaterRotatedPart("tail", (0, 7.4, bodyLength * 0.43), (-0.08, 0, 0), [
            lpTube(.z, [
                lpr(0, 0, 0, 5.2, 2.9), lpr(0, 0.10, 11.0, 3.2, 1.8),
                lpr(0, 0, 23.0, 1.35, 0.82), lpr(0, 0, 34.0, 0.22, 0.22),
            ], sides: 8),
        ]),
        lpPart("scutes", (0, 10.4, 0.5), scutes),
        lpPart("legFR", (-bodyWidth * 0.77, 6.1, -bodyLength * 0.29), lpLeg(6.1, footLength: 5.2, footWidth: 3.0, heavy: true)),
        lpPart("legFL", (bodyWidth * 0.77, 6.1, -bodyLength * 0.29), lpLeg(6.1, footLength: 5.2, footWidth: 3.0, heavy: true)),
        lpPart("legBR", (-bodyWidth * 0.77, 6.0, bodyLength * 0.31), lpLeg(6.0, footLength: 5.0, footWidth: 3.0, heavy: true)),
        lpPart("legBL", (bodyWidth * 0.77, 6.0, bodyLength * 0.31), lpLeg(6.0, footLength: 5.0, footWidth: 3.0, heavy: true)),
    ]
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "prehistoricQuad", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 16, eyeX: 2, eyeY: 2, eyeGap: 5))
}
