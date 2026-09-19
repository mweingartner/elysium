// Original procedural creature assets for the opt-in Prehistoric Worlds profiles.
//
// The attached planning catalog deliberately contains no runtime art.  These are
// native, editable low-poly rigid-part models for the existing Metal entity
// renderer: they neither load external meshes nor borrow a resource-pack skin.
// Keep every model at 24 parts or fewer because EntityUniforms exposes exactly
// 24 pose matrices.

import Foundation

/// Exact, stable model keys for the bounded Prehistoric Worlds roster.  Entity
/// rendering resolves an entity's registered type directly through this list.
public var prehistoricModelIDs: [String] {
    prehistoricModelRecipes.map { $0.id }
}

/// Renderer-facing catalog checks.  Tests use this rather than relying on the
/// fallback pig model, which would make a missing prehistoric registration look
/// superficially successful.
public func prehistoricModelValidationErrors() -> [String] {
    ensureModels()
    var errors: [String] = []
    let ids = prehistoricModelIDs
    if ids.count != 36 {
        errors.append("expected 36 prehistoric model ids, found \(ids.count)")
    }
    if Set(ids).count != ids.count {
        errors.append("prehistoric model ids are not unique")
    }
    for id in ids {
        guard let model = MODELS[id] else {
            errors.append("missing model: \(id)")
            continue
        }
        if model.parts.isEmpty {
            errors.append("model has no parts: \(id)")
        }
        if model.parts.count > 24 {
            errors.append("model exceeds 24 parts: \(id) has \(model.parts.count)")
        }
        if !model.scale.isFinite || model.scale <= 0 {
            errors.append("model has an invalid display scale: \(id)")
        }
        if Set(model.parts.map(\.name)).count != model.parts.count {
            errors.append("model repeats a part name: \(id)")
        }
        if !model.packTex.isEmpty {
            errors.append("prehistoric model must use its native procedural skin: \(id)")
        }
        var triangleCount = 0
        for part in model.parts {
            let transform = [part.pivot.0, part.pivot.1, part.pivot.2,
                             part.rot.0, part.rot.1, part.rot.2]
            if !transform.allSatisfy(\.isFinite) {
                errors.append("model part has a non-finite rigid transform: \(id).\(part.name)")
            }
            if !part.boxes.isEmpty {
                errors.append("prehistoric model must not fall back to cuboid geometry: \(id).\(part.name)")
            }
            if part.meshes.isEmpty {
                errors.append("prehistoric model part has no faceted geometry: \(id).\(part.name)")
            }
            for box in part.boxes {
                let maxU = box.u + box.d * 2 + box.w * 2
                let maxV = box.v + box.d + box.h
                if box.u < 0 || box.v < 0 || maxU > Double(model.texW) || maxV > Double(model.texH) {
                    errors.append("model unwrap escapes its native skin: \(id).\(part.name)")
                }
            }
            for (meshIndex, mesh) in part.meshes.enumerated() {
                if mesh.faces.isEmpty {
                    errors.append("faceted mesh has no faces: \(id).\(part.name)[\(meshIndex)]")
                }
                for (faceIndex, face) in mesh.faces.enumerated() {
                    guard face.vertices.count >= 3 else {
                        errors.append("faceted face has fewer than three vertices: \(id).\(part.name)[\(meshIndex)].\(faceIndex)")
                        continue
                    }
                    for vertex in face.vertices {
                        guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite,
                              vertex.u.isFinite, vertex.v.isFinite else {
                            errors.append("faceted mesh has non-finite data: \(id).\(part.name)[\(meshIndex)].\(faceIndex)")
                            break
                        }
                        if vertex.u < 0 || vertex.v < 0 ||
                            vertex.u > Double(model.texW) || vertex.v > Double(model.texH) {
                            errors.append("faceted mesh UV escapes its native skin: \(id).\(part.name)[\(meshIndex)].\(faceIndex)")
                            break
                        }
                    }
                    let a = face.vertices[0], b = face.vertices[1], c = face.vertices[2]
                    let abx = b.x - a.x, aby = b.y - a.y, abz = b.z - a.z
                    let acx = c.x - a.x, acy = c.y - a.y, acz = c.z - a.z
                    let nx = aby * acz - abz * acy
                    let ny = abz * acx - abx * acz
                    let nz = abx * acy - aby * acx
                    let lengthSquared = nx * nx + ny * ny + nz * nz
                    if !lengthSquared.isFinite || lengthSquared <= 0.000_000_1 {
                        errors.append("faceted mesh face is degenerate: \(id).\(part.name)[\(meshIndex)].\(faceIndex)")
                    }
                    triangleCount += face.vertices.count - 2
                }
            }
        }
        if triangleCount > 4_096 {
            errors.append("prehistoric model exceeds 4,096 triangle budget: \(id) has \(triangleCount)")
        }
    }
    return errors
}

enum PrehistoricRigFamily {
    case theropod
    case herbivoreBiped
    case ceratopsian
    case armoredQuad
    case sauropod
    case pterosaur
    case microraptor
    case ichthyosaur
    case plesiosaur
    case mosasaur
    case crocodilian
}

enum PrehistoricMarking {
    case bands
    case spots
    case mottled
    case plates
    case chevrons
    case tide
}

struct PrehistoricModelRecipe {
    let id: String
    let family: PrehistoricRigFamily
    let form: String
    let scale: Double
    let base: Int
    let accent: Int
    let belly: Int
    let marking: PrehistoricMarking
}

// This is source-owned runtime data, not an import of the attached planning
// JSON.  It keeps the presentation catalog bounded, ordered, and reviewable.
private let prehistoricModelRecipes: [PrehistoricModelRecipe] = [
    .init(id: "prehistoric.compsognathus", family: .theropod, form: "slender", scale: 0.45, base: 0x9e8b4e, accent: 0x51462a, belly: 0xd8c98d, marking: .bands),
    .init(id: "prehistoric.coelophysis", family: .theropod, form: "slender", scale: 0.70, base: 0x8c7b63, accent: 0x3f342b, belly: 0xc8b99d, marking: .bands),
    .init(id: "prehistoric.velociraptor", family: .theropod, form: "raptor", scale: 0.64, base: 0x6a593f, accent: 0x2d241a, belly: 0xc0a675, marking: .chevrons),
    .init(id: "prehistoric.dilophosaurus", family: .theropod, form: "crested", scale: 1.10, base: 0xa05a38, accent: 0x4d2a24, belly: 0xd8aa78, marking: .bands),
    .init(id: "prehistoric.deinonychus", family: .theropod, form: "raptor", scale: 0.80, base: 0x8c6945, accent: 0x34271d, belly: 0xd4b67e, marking: .chevrons),
    .init(id: "prehistoric.allosaurus", family: .theropod, form: "large", scale: 1.40, base: 0x667a53, accent: 0x293a28, belly: 0xaebd85, marking: .spots),
    .init(id: "prehistoric.ceratosaurus", family: .theropod, form: "horned", scale: 1.10, base: 0x6f5947, accent: 0x30251f, belly: 0xb69d7e, marking: .mottled),
    .init(id: "prehistoric.carnotaurus", family: .theropod, form: "bull", scale: 1.28, base: 0x9b4a36, accent: 0x47231f, belly: 0xcf8f65, marking: .spots),
    .init(id: "prehistoric.tyrannosaurus", family: .theropod, form: "tyrannosaur", scale: 1.75, base: 0x667047, accent: 0x29351f, belly: 0xaeb773, marking: .mottled),
    .init(id: "prehistoric.spinosaurus", family: .theropod, form: "spinosaur", scale: 1.95, base: 0x557c76, accent: 0x1e4a4b, belly: 0xa0c1ab, marking: .bands),
    .init(id: "prehistoric.dryosaurus", family: .herbivoreBiped, form: "small", scale: 0.72, base: 0x789456, accent: 0x36522b, belly: 0xbbcf88, marking: .bands),
    .init(id: "prehistoric.pachycephalosaurus", family: .herbivoreBiped, form: "dome", scale: 0.95, base: 0x8b7952, accent: 0x493d28, belly: 0xcab97c, marking: .mottled),
    .init(id: "prehistoric.gallimimus", family: .herbivoreBiped, form: "runner", scale: 1.05, base: 0xc38b4c, accent: 0x704228, belly: 0xe2c78f, marking: .bands),
    .init(id: "prehistoric.oviraptor", family: .herbivoreBiped, form: "beaked", scale: 0.56, base: 0x9e7765, accent: 0x51372f, belly: 0xd8b2a2, marking: .spots),
    .init(id: "prehistoric.parasaurolophus", family: .herbivoreBiped, form: "hadrosaur", scale: 1.48, base: 0x777a46, accent: 0x39421f, belly: 0xb8b978, marking: .bands),
    .init(id: "prehistoric.edmontosaurus", family: .herbivoreBiped, form: "hadrosaur", scale: 1.60, base: 0x68875d, accent: 0x2f5037, belly: 0xa9c887, marking: .mottled),
    .init(id: "prehistoric.iguanodon", family: .herbivoreBiped, form: "iguanodon", scale: 1.45, base: 0x8a8b50, accent: 0x464b28, belly: 0xc5c77f, marking: .chevrons),
    .init(id: "prehistoric.triceratops", family: .ceratopsian, form: "triceratops", scale: 1.38, base: 0x736b44, accent: 0x332d1d, belly: 0xb9ac72, marking: .mottled),
    .init(id: "prehistoric.styracosaurus", family: .ceratopsian, form: "styracosaurus", scale: 1.18, base: 0x9b623d, accent: 0x4a2c20, belly: 0xd39e70, marking: .bands),
    .init(id: "prehistoric.stegosaurus", family: .armoredQuad, form: "stegosaur", scale: 1.40, base: 0x66794a, accent: 0xb36a3d, belly: 0x9bad72, marking: .plates),
    .init(id: "prehistoric.ankylosaurus", family: .armoredQuad, form: "ankylosaur", scale: 1.30, base: 0x6d7044, accent: 0x9e8b4f, belly: 0xa7a66e, marking: .plates),
    .init(id: "prehistoric.diplodocus", family: .sauropod, form: "diplodocid", scale: 2.40, base: 0x6e7558, accent: 0x39402f, belly: 0xaeb08a, marking: .mottled),
    .init(id: "prehistoric.brachiosaurus", family: .sauropod, form: "brachiosaur", scale: 2.30, base: 0x8a815b, accent: 0x4e462e, belly: 0xc3b888, marking: .spots),
    .init(id: "prehistoric.therizinosaurus", family: .theropod, form: "therizinosaur", scale: 1.40, base: 0x6e8b75, accent: 0x304c3e, belly: 0xa7c6a8, marking: .mottled),
    .init(id: "prehistoric.dimorphodon", family: .pterosaur, form: "longTail", scale: 0.55, base: 0x8c6d4e, accent: 0x3d2c22, belly: 0xcfad83, marking: .bands),
    .init(id: "prehistoric.rhamphorhynchus", family: .pterosaur, form: "longTail", scale: 0.58, base: 0x6b7d82, accent: 0x2c444c, belly: 0xa7bec2, marking: .bands),
    .init(id: "prehistoric.pteranodon", family: .pterosaur, form: "pteranodon", scale: 1.10, base: 0x8a745b, accent: 0x44372c, belly: 0xc8b291, marking: .mottled),
    .init(id: "prehistoric.tapejara", family: .pterosaur, form: "tapejara", scale: 0.92, base: 0x9c6050, accent: 0x532c36, belly: 0xdca596, marking: .spots),
    .init(id: "prehistoric.quetzalcoatlus", family: .pterosaur, form: "azhdarchid", scale: 1.60, base: 0x807660, accent: 0x403a31, belly: 0xbdb496, marking: .mottled),
    .init(id: "prehistoric.microraptor", family: .microraptor, form: "fourWing", scale: 0.40, base: 0x354c68, accent: 0x182637, belly: 0x7c98b3, marking: .chevrons),
    .init(id: "prehistoric.ichthyosaurus", family: .ichthyosaur, form: "ichthyosaur", scale: 0.75, base: 0x496f83, accent: 0x1d3f55, belly: 0x9cc2cf, marking: .tide),
    .init(id: "prehistoric.plesiosaurus", family: .plesiosaur, form: "plesiosaur", scale: 0.98, base: 0x527d75, accent: 0x244d49, belly: 0x9bc3b6, marking: .tide),
    .init(id: "prehistoric.elasmosaurus", family: .plesiosaur, form: "longNeck", scale: 1.60, base: 0x4c7182, accent: 0x203f52, belly: 0x94bdc8, marking: .tide),
    .init(id: "prehistoric.liopleurodon", family: .plesiosaur, form: "pliosaur", scale: 1.25, base: 0x58715d, accent: 0x243d30, belly: 0xa4bb92, marking: .mottled),
    .init(id: "prehistoric.mosasaurus", family: .mosasaur, form: "mosasaur", scale: 1.85, base: 0x526b6d, accent: 0x233b40, belly: 0x98b7b5, marking: .chevrons),
    .init(id: "prehistoric.deinosuchus", family: .crocodilian, form: "crocodilian", scale: 1.55, base: 0x596c45, accent: 0x283921, belly: 0x98a86e, marking: .plates),
]

private func prehistoricBox(_ x: Double, _ y: Double, _ z: Double,
                            _ w: Double, _ h: Double, _ d: Double,
                            _ u: Double, _ v: Double, _ grow: Double = 0) -> ModelBox {
    ModelBox(x, y, z, w, h, d, u, v, grow)
}

private func prehistoricPart(_ name: String, _ pivot: (Double, Double, Double),
                             _ boxes: ModelBox...) -> ModelPart {
    ModelPart(name: name, pivot: pivot, boxes: boxes)
}

private func prehistoricRotatedPart(_ name: String, _ pivot: (Double, Double, Double),
                                    _ rot: (Double, Double, Double),
                                    _ boxes: ModelBox...) -> ModelPart {
    ModelPart(name: name, pivot: pivot, rot: rot, boxes: boxes)
}

func prehistoricPaint(_ recipe: PrehistoricModelRecipe, headDepth: Int,
                      eyeX: Int = 1, eyeY: Int = 2, eyeGap: Int = 3) -> (EntitySkin) -> Void {
    { skin in
        // A complete native skin makes every UV area opaque even when a family
        // adds an accent box later.  The deterministic per-entity seed only
        // affects presentation noise, never simulation state.
        skin.fill(0, 0, skin.w, skin.h, recipe.base, 0.07)
        skin.rect(0, skin.h * 3 / 4, skin.w, skin.h / 4, recipe.belly)
        switch recipe.marking {
        case .bands:
            for x in stride(from: 4, to: skin.w, by: 14) {
                skin.rect(x, 0, 3, skin.h, recipe.accent)
            }
        case .spots:
            for i in 0..<112 where skin.rand(i, i * 7, 31) < 0.55 {
                let x = Int(skin.rand(i, 3, 47) * Double(skin.w - 3))
                let y = Int(skin.rand(i, 9, 53) * Double(skin.h - 3))
                skin.rect(x, y, 3, 3, recipe.accent)
            }
        case .mottled:
            for i in 0..<140 where skin.rand(i, i * 11, 59) < 0.42 {
                let x = Int(skin.rand(i, 5, 61) * Double(skin.w - 2))
                let y = Int(skin.rand(i, 7, 67) * Double(skin.h - 2))
                skin.rect(x, y, 2, 2, recipe.accent)
            }
        case .plates:
            for x in stride(from: 0, to: skin.w, by: 12) {
                skin.rect(x, 8, 7, 5, recipe.accent)
                skin.rect(x + 2, 13, 3, 4, shadeColor(recipe.accent, 1.12))
            }
        case .chevrons:
            for x in stride(from: 0, to: skin.w, by: 16) {
                skin.rect(x + 2, 6, 4, skin.h - 12, recipe.accent)
                skin.rect(x + 8, 12, 4, skin.h - 24, shadeColor(recipe.accent, 0.86))
            }
        case .tide:
            for y in stride(from: 4, to: skin.h, by: 13) {
                skin.rect(0, y, skin.w, 2, recipe.accent)
                skin.rect(5, y + 2, skin.w - 10, 1, shadeColor(recipe.accent, 1.13))
            }
        }
        skin.eyes(0, 0, headDepth, eyeX, eyeY, eyeGap, 1, 1, 0xf4e9c7, 0x111317)
    }
}

private func prehistoricModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    lowPolyPrehistoricModel(recipe)
}

func prehistoricTheropodModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let large = ["large", "tyrannosaur", "spinosaur", "therizinosaur"].contains(recipe.form)
    let raptor = recipe.form == "raptor"
    let tyrant = recipe.form == "tyrannosaur"
    let bodyW = tyrant ? 12.0 : (large ? 10.0 : 7.0)
    let bodyL = tyrant ? 20.0 : (large ? 18.0 : 13.0)
    let legH = tyrant ? 16.0 : (large ? 14.0 : 10.0)
    let headW = tyrant ? 10.0 : (large ? 8.0 : 6.0)
    let headD = tyrant ? 13.0 : (large ? 10.0 : 8.0)
    var parts: [ModelPart] = [
        prehistoricPart("head", (0, legH + 12, -bodyL * 0.43),
                        prehistoricBox(-headW / 2, -4, -headD, headW, 8, headD, 0, 0),
                        prehistoricBox(-headW * 0.34, -5.5, -headD - 3, headW * 0.68, 3, 4, 18, 0)),
        prehistoricPart("jaw", (0, legH + 9.5, -bodyL * 0.43 - headD),
                        prehistoricBox(-headW * 0.40, -1, -3, headW * 0.8, 2, 5, 32, 0)),
        prehistoricPart("neck", (0, legH + 12, -bodyL * 0.25),
                        prehistoricBox(-bodyW * 0.32, -4, -7, bodyW * 0.64, 9, 9, 48, 0)),
        prehistoricPart("body", (0, legH + 7, 0),
                        prehistoricBox(-bodyW / 2, -7, -bodyL / 2, bodyW, 14, bodyL, 0, 20)),
        prehistoricRotatedPart("tail", (0, legH + 8, bodyL * 0.43), (-0.20, 0, 0),
                                prehistoricBox(-bodyW * 0.24, -3, 0, bodyW * 0.48, 6, bodyL * 1.05, 48, 20)),
        prehistoricRotatedPart("tailTip", (0, legH + 10, bodyL * 1.22), (-0.12, 0, 0),
                                prehistoricBox(-bodyW * 0.14, -2, 0, bodyW * 0.28, 4, bodyL * 0.62, 80, 20)),
        prehistoricPart("armR", (-bodyW * 0.56, legH + 11, -bodyL * 0.20),
                        prehistoricBox(-2, -9, -2, 3, 10, 3, 0, 48)),
        prehistoricPart("armL", (bodyW * 0.56, legH + 11, -bodyL * 0.20),
                        prehistoricBox(-1, -9, -2, 3, 10, 3, 0, 48)),
        prehistoricPart("legR", (-bodyW * 0.30, legH, bodyL * 0.18),
                        prehistoricBox(-2.3, -legH, -2.5, 4.6, legH, 5, 18, 48)),
        prehistoricPart("legL", (bodyW * 0.30, legH, bodyL * 0.18),
                        prehistoricBox(-2.3, -legH, -2.5, 4.6, legH, 5, 18, 48)),
    ]
    if raptor {
        parts.append(prehistoricPart("featherR", (-bodyW * 0.62, legH + 12, -bodyL * 0.15),
                                     prehistoricBox(-7, -1, -4, 7, 2, 10, 48, 48)))
        parts.append(prehistoricPart("featherL", (bodyW * 0.62, legH + 12, -bodyL * 0.15),
                                     prehistoricBox(0, -1, -4, 7, 2, 10, 48, 48)))
    }
    switch recipe.form {
    case "crested":
        parts.append(prehistoricPart("crestL", (-2, legH + 19, -bodyL * 0.43),
                                     prehistoricBox(-1, 0, -3, 2, 6, 4, 80, 0)))
        parts.append(prehistoricPart("crestR", (2, legH + 19, -bodyL * 0.43),
                                     prehistoricBox(-1, 0, -3, 2, 6, 4, 80, 0)))
    case "horned":
        parts.append(prehistoricPart("noseHorn", (0, legH + 17, -bodyL * 0.43 - headD),
                                     prehistoricBox(-1, 0, -4, 2, 3, 5, 80, 0)))
    case "bull":
        parts.append(prehistoricPart("hornR", (-headW * 0.42, legH + 19, -bodyL * 0.43 - 4),
                                     prehistoricBox(-2, -1, -3, 3, 4, 5, 80, 0)))
        parts.append(prehistoricPart("hornL", (headW * 0.42, legH + 19, -bodyL * 0.43 - 4),
                                     prehistoricBox(-1, -1, -3, 3, 4, 5, 80, 0)))
    case "spinosaur":
        parts.append(prehistoricPart("sail", (0, legH + 13, 1),
                                     prehistoricBox(-1, 0, -bodyL * 0.45, 2, 17, bodyL * 0.92, 88, 0)))
        parts.append(prehistoricPart("snout", (0, legH + 12, -bodyL * 0.43 - headD),
                                     prehistoricBox(-headW * 0.30, -3, -8, headW * 0.6, 5, 9, 92, 20)))
    case "tyrannosaur":
        parts.append(prehistoricPart("brow", (0, legH + 18, -bodyL * 0.43 - 2),
                                     prehistoricBox(-headW * 0.5, -1, -4, headW, 2, 4, 92, 20)))
    case "therizinosaur":
        parts.append(prehistoricPart("clawR", (-bodyW * 0.66, legH + 4, -bodyL * 0.26),
                                     prehistoricBox(-2, -8, -8, 2, 2, 9, 92, 20)))
        parts.append(prehistoricPart("clawL", (bodyW * 0.66, legH + 4, -bodyL * 0.26),
                                     prehistoricBox(0, -8, -8, 2, 2, 9, 92, 20)))
    default:
        break
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "biped", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: Int(headD)))
}

func prehistoricHerbivoreBipedModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let hadrosaur = recipe.form == "hadrosaur"
    let runner = recipe.form == "runner"
    let bodyW = hadrosaur ? 11.0 : (runner ? 7.0 : 8.0)
    let bodyL = hadrosaur ? 19.0 : (runner ? 15.0 : 15.0)
    let legH = hadrosaur ? 15.0 : 11.0
    var parts: [ModelPart] = [
        prehistoricPart("head", (0, legH + 13, -bodyL * 0.40),
                        prehistoricBox(-bodyW * 0.38, -4, -9, bodyW * 0.76, 8, 9, 0, 0)),
        prehistoricPart("beak", (0, legH + 12, -bodyL * 0.40 - 8),
                        prehistoricBox(-bodyW * 0.32, -2, -6, bodyW * 0.64, 3, 7, 20, 0)),
        prehistoricPart("neck", (0, legH + 12, -bodyL * 0.20),
                        prehistoricBox(-bodyW * 0.30, -5, -6, bodyW * 0.60, 11, 8, 40, 0)),
        prehistoricPart("body", (0, legH + 7, 0),
                        prehistoricBox(-bodyW / 2, -7, -bodyL / 2, bodyW, 14, bodyL, 0, 20)),
        prehistoricRotatedPart("tail", (0, legH + 9, bodyL * 0.42), (-0.16, 0, 0),
                                prehistoricBox(-bodyW * 0.20, -2.5, 0, bodyW * 0.40, 5, bodyL * 1.05, 48, 20)),
        prehistoricPart("armR", (-bodyW * 0.57, legH + 11, -bodyL * 0.20),
                        prehistoricBox(-2, -8, -2, 3, 9, 3, 0, 48)),
        prehistoricPart("armL", (bodyW * 0.57, legH + 11, -bodyL * 0.20),
                        prehistoricBox(-1, -8, -2, 3, 9, 3, 0, 48)),
        prehistoricPart("legR", (-bodyW * 0.30, legH, bodyL * 0.16),
                        prehistoricBox(-2.5, -legH, -3, 5, legH, 6, 18, 48)),
        prehistoricPart("legL", (bodyW * 0.30, legH, bodyL * 0.16),
                        prehistoricBox(-2.5, -legH, -3, 5, legH, 6, 18, 48)),
    ]
    switch recipe.form {
    case "dome":
        parts.append(prehistoricPart("dome", (0, legH + 20, -bodyL * 0.40),
                                     prehistoricBox(-bodyW * 0.32, -2, -4, bodyW * 0.64, 5, 6, 80, 0)))
    case "hadrosaur":
        parts.append(prehistoricRotatedPart("crest", (0, legH + 20, -bodyL * 0.40 + 3), (-0.22, 0, 0),
                                            prehistoricBox(-2.5, -2, 0, 5, 5, 13, 80, 0)))
    case "iguanodon":
        parts.append(prehistoricPart("thumbSpikeR", (-bodyW * 0.68, legH + 6, -bodyL * 0.24),
                                     prehistoricBox(-1, -4, -6, 2, 2, 7, 80, 0)))
        parts.append(prehistoricPart("thumbSpikeL", (bodyW * 0.68, legH + 6, -bodyL * 0.24),
                                     prehistoricBox(-1, -4, -6, 2, 2, 7, 80, 0)))
    case "beaked":
        parts.append(prehistoricPart("crest", (0, legH + 19, -bodyL * 0.40),
                                     prehistoricBox(-1.5, 0, -3, 3, 6, 4, 80, 0)))
    default:
        break
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "biped", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 9))
}

func prehistoricCeratopsianModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let triceratops = recipe.form == "triceratops"
    let bodyW = triceratops ? 15.0 : 12.0
    let bodyL = triceratops ? 22.0 : 17.0
    let legH = triceratops ? 13.0 : 11.0
    let horn = triceratops ? 10.0 : 7.0
    var headBoxes = [
        prehistoricBox(-bodyW * 0.38, -5, -10, bodyW * 0.76, 10, 10, 0, 0),
        // Three deliberately separate forward horns on Triceratops: two brow
        // horns and a smaller nasal horn.  Styracosaurus uses the same clear
        // head language with a shorter pair and a pronounced nasal horn.
        prehistoricBox(-bodyW * 0.35, 1, -horn - 8, 2.5, 3, horn, 20, 0),
        prehistoricBox(bodyW * 0.35 - 2.5, 1, -horn - 8, 2.5, 3, horn, 20, 0),
        prehistoricBox(-1.6, -2, -horn - 11, 3.2, 3, horn * 0.70, 20, 0),
    ]
    if !triceratops {
        headBoxes.append(prehistoricBox(-2, 4, -10, 4, 3, 3, 20, 0))
    }
    var parts: [ModelPart] = [
        ModelPart(name: "head", pivot: (0, legH + 8, -bodyL * 0.45), boxes: headBoxes),
        prehistoricPart("frill", (0, legH + 10, -bodyL * 0.27),
                        prehistoricBox(-bodyW * 0.55, -4, -2, bodyW * 1.1, 10, 3, 48, 0)),
        prehistoricPart("body", (0, legH + 6, 0),
                        prehistoricBox(-bodyW / 2, -6, -bodyL / 2, bodyW, 13, bodyL, 0, 24)),
        prehistoricRotatedPart("tail", (0, legH + 7, bodyL * 0.42), (-0.14, 0, 0),
                                prehistoricBox(-3, -2, 0, 6, 5, bodyL * 0.63, 80, 0)),
        prehistoricPart("legFR", (-bodyW * 0.34, legH, -bodyL * 0.28),
                        prehistoricBox(-3, -legH, -3, 6, legH, 6, 0, 48)),
        prehistoricPart("legFL", (bodyW * 0.34, legH, -bodyL * 0.28),
                        prehistoricBox(-3, -legH, -3, 6, legH, 6, 0, 48)),
        prehistoricPart("legBR", (-bodyW * 0.34, legH, bodyL * 0.30),
                        prehistoricBox(-3, -legH, -3, 6, legH, 6, 0, 48)),
        prehistoricPart("legBL", (bodyW * 0.34, legH, bodyL * 0.30),
                        prehistoricBox(-3, -legH, -3, 6, legH, 6, 0, 48)),
    ]
    if !triceratops {
        parts.append(prehistoricPart("frillSpikes", (0, legH + 12, -bodyL * 0.24),
                                     prehistoricBox(-bodyW * 0.56, -1, -5, 2, 3, 7, 80, 0),
                                     prehistoricBox(-bodyW * 0.25, 2, -5, 2, 3, 7, 80, 0),
                                     prehistoricBox(bodyW * 0.25 - 2, 2, -5, 2, 3, 7, 80, 0),
                                     prehistoricBox(bodyW * 0.56 - 2, -1, -5, 2, 3, 7, 80, 0)))
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "quad", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 10, eyeX: 2, eyeY: 3, eyeGap: 5))
}

func prehistoricArmoredQuadModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let stegosaur = recipe.form == "stegosaur"
    let bodyW = stegosaur ? 13.0 : 15.0
    let bodyL = stegosaur ? 23.0 : 20.0
    let legH = stegosaur ? 12.0 : 10.0
    var parts: [ModelPart] = [
        prehistoricPart("head", (0, legH + 5, -bodyL * 0.48),
                        prehistoricBox(-4, -3, -8, 8, 6, 9, 0, 0)),
        prehistoricPart("body", (0, legH + 6, 0),
                        prehistoricBox(-bodyW / 2, -6, -bodyL / 2, bodyW, 12, bodyL, 0, 20)),
        prehistoricRotatedPart("tail", (0, legH + 7, bodyL * 0.42), (-0.16, 0, 0),
                                prehistoricBox(-3, -2, 0, 6, 5, bodyL * 0.92, 48, 20)),
        prehistoricPart("legFR", (-bodyW * 0.32, legH, -bodyL * 0.30),
                        prehistoricBox(-3, -legH, -3, 6, legH, 6, 0, 48)),
        prehistoricPart("legFL", (bodyW * 0.32, legH, -bodyL * 0.30),
                        prehistoricBox(-3, -legH, -3, 6, legH, 6, 0, 48)),
        prehistoricPart("legBR", (-bodyW * 0.32, legH, bodyL * 0.30),
                        prehistoricBox(-3, -legH, -3, 6, legH, 6, 0, 48)),
        prehistoricPart("legBL", (bodyW * 0.32, legH, bodyL * 0.30),
                        prehistoricBox(-3, -legH, -3, 6, legH, 6, 0, 48)),
    ]
    if stegosaur {
        parts.append(prehistoricPart("plates", (0, legH + 12, 0),
                                     prehistoricBox(-1, 0, -10, 2, 11, 3, 80, 0),
                                     prehistoricBox(-1, 0, -5, 2, 14, 3, 80, 0),
                                     prehistoricBox(-1, 0, 0, 2, 16, 3, 80, 0),
                                     prehistoricBox(-1, 0, 5, 2, 13, 3, 80, 0),
                                     prehistoricBox(-1, 0, 10, 2, 9, 3, 80, 0)))
        parts.append(prehistoricPart("thagomizer", (0, legH + 7, bodyL * 1.20),
                                     prehistoricBox(-6, 1, -2, 3, 3, 10, 96, 0),
                                     prehistoricBox(3, 1, -2, 3, 3, 10, 96, 0)))
    } else {
        parts.append(prehistoricPart("armor", (0, legH + 12, 0),
                                     prehistoricBox(-bodyW * 0.40, -1, -8, 3, 4, 6, 80, 0),
                                     prehistoricBox(-bodyW * 0.16, 1, -3, 4, 4, 6, 80, 0),
                                     prehistoricBox(bodyW * 0.16 - 4, 1, -3, 4, 4, 6, 80, 0),
                                     prehistoricBox(bodyW * 0.40 - 3, -1, -8, 3, 4, 6, 80, 0)))
        parts.append(prehistoricPart("club", (0, legH + 7, bodyL * 1.20),
                                     prehistoricBox(-5, -4, -2, 10, 8, 10, 88, 0)))
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "quad", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 9))
}

func prehistoricSauropodModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let brachiosaur = recipe.form == "brachiosaur"
    let bodyW = brachiosaur ? 16.0 : 14.0
    let bodyL = brachiosaur ? 24.0 : 27.0
    let legH = brachiosaur ? 22.0 : 18.0
    let neckHeight = brachiosaur ? 31.0 : 24.0
    var parts: [ModelPart] = [
        prehistoricPart("body", (0, legH + 8, 0),
                        prehistoricBox(-bodyW / 2, -8, -bodyL / 2, bodyW, 16, bodyL, 0, 20)),
        prehistoricRotatedPart("neckBase", (0, legH + 14, -bodyL * 0.36), (-0.58, 0, 0),
                                prehistoricBox(-4.5, -4, -12, 9, 10, 19, 48, 0)),
        prehistoricRotatedPart("neckMid", (0, neckHeight, -bodyL * 0.58), (-0.34, 0, 0),
                                prehistoricBox(-4, -4, -11, 8, 9, 17, 72, 0)),
        prehistoricPart("head", (0, neckHeight + 9, -bodyL * 0.72),
                        prehistoricBox(-4.5, -4, -9, 9, 8, 10, 0, 0)),
        prehistoricPart("snout", (0, neckHeight + 8, -bodyL * 0.72 - 8),
                        prehistoricBox(-4, -2, -5, 8, 4, 6, 20, 0)),
        prehistoricRotatedPart("tail", (0, legH + 9, bodyL * 0.40), (-0.10, 0, 0),
                                prehistoricBox(-3.4, -3, 0, 6.8, 7, bodyL * 1.15, 48, 20)),
        prehistoricRotatedPart("tailTip", (0, legH + 11, bodyL * 1.44), (-0.05, 0, 0),
                                prehistoricBox(-1.8, -2, 0, 3.6, 4, bodyL * 0.86, 72, 20)),
        prehistoricPart("legFR", (-bodyW * 0.32, legH, -bodyL * 0.28),
                        prehistoricBox(-4, -legH, -4, 8, legH, 8, 0, 48)),
        prehistoricPart("legFL", (bodyW * 0.32, legH, -bodyL * 0.28),
                        prehistoricBox(-4, -legH, -4, 8, legH, 8, 0, 48)),
        prehistoricPart("legBR", (-bodyW * 0.32, legH, bodyL * 0.30),
                        prehistoricBox(-4, -legH, -4, 8, legH, 8, 0, 48)),
        prehistoricPart("legBL", (bodyW * 0.32, legH, bodyL * 0.30),
                        prehistoricBox(-4, -legH, -4, 8, legH, 8, 0, 48)),
    ]
    if brachiosaur {
        parts.append(prehistoricPart("shoulderRise", (0, legH + 17, -bodyL * 0.16),
                                     prehistoricBox(-bodyW * 0.38, -3, -6, bodyW * 0.76, 9, 10, 80, 0)))
    } else {
        parts.append(prehistoricPart("whip", (0, legH + 11, bodyL * 2.15),
                                     prehistoricBox(-0.8, -1, 0, 1.6, 2, bodyL * 0.75, 80, 0)))
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "quad", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 10, eyeX: 2, eyeY: 3, eyeGap: 4))
}

func prehistoricPterosaurModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let azhdarchid = recipe.form == "azhdarchid"
    let pteranodon = recipe.form == "pteranodon"
    let tapejara = recipe.form == "tapejara"
    let longTail = recipe.form == "longTail"
    let wing = azhdarchid ? 28.0 : (pteranodon ? 21.0 : (tapejara ? 17.0 : 13.0))
    let neck = azhdarchid ? 14.0 : 7.0
    var parts: [ModelPart] = [
        prehistoricPart("body", (0, 9, 0),
                        prehistoricBox(-3.5, -3, -6, 7, 6, 12, 0, 20)),
        prehistoricPart("neck", (0, 11, -4),
                        prehistoricBox(-2.3, -2, -neck, 4.6, 6, neck + 4, 24, 0)),
        prehistoricPart("head", (0, 13, -neck - 4),
                        prehistoricBox(-3.5, -3, -7, 7, 6, 8, 0, 0)),
        // Smooth toothless beak: it is intentionally a clean wedge-like box
        // with no tooth pixels or jaw inserts on the Pteranodon family.
        prehistoricPart("beak", (0, 12, -neck - 10),
                        prehistoricBox(-2.3, -1.5, -10, 4.6, 3, 11, 20, 0)),
        prehistoricPart("wingR", (-3, 10, -1),
                        prehistoricBox(-wing, -0.4, -7, wing, 0.8, 15, 0, 64)),
        prehistoricPart("wingL", (3, 10, -1),
                        prehistoricBox(0, -0.4, -7, wing, 0.8, 15, 0, 64)),
        prehistoricPart("fingerR", (-wing - 3, 10, 2),
                        prehistoricBox(-8, -0.8, -1, 9, 1.6, 3, 48, 64)),
        prehistoricPart("fingerL", (wing + 3, 10, 2),
                        prehistoricBox(-1, -0.8, -1, 9, 1.6, 3, 48, 64)),
        prehistoricPart("legR", (-2, 8, 4),
                        prehistoricBox(-1, -6, -1, 2, 6, 2, 80, 64)),
        prehistoricPart("legL", (2, 8, 4),
                        prehistoricBox(-1, -6, -1, 2, 6, 2, 80, 64)),
    ]
    if longTail {
        parts.append(prehistoricPart("tail", (0, 9, 6),
                                     prehistoricBox(-1, -1, 0, 2, 2, 22, 75, 64)))
        parts.append(prehistoricPart("tailVane", (0, 9, 27),
                                     prehistoricBox(-4, -0.4, -2, 8, 0.8, 6, 90, 64)))
    }
    if pteranodon {
        parts.append(prehistoricPart("crest", (0, 17, -neck - 1),
                                     prehistoricBox(-1.8, -1, 0, 3.6, 5, 15, 88, 0)))
    }
    if tapejara {
        parts.append(prehistoricPart("crest", (0, 20, -neck - 4),
                                     prehistoricBox(-2, -1, -4, 4, 15, 7, 96, 0)))
    }
    if azhdarchid {
        parts.append(prehistoricPart("crown", (0, 19, -neck - 5),
                                     prehistoricBox(-2, 0, -3, 4, 5, 5, 96, 0)))
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "phantom", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 8, eyeX: 1, eyeY: 2, eyeGap: 4))
}

func prehistoricMicroraptorModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let parts: [ModelPart] = [
        prehistoricPart("body", (0, 8, 0), prehistoricBox(-2.5, -3, -5, 5, 6, 11, 0, 20)),
        prehistoricPart("head", (0, 10, -5), prehistoricBox(-2.5, -2, -5, 5, 5, 6, 0, 0)),
        prehistoricRotatedPart("tail", (0, 8, 5), (-0.10, 0, 0), prehistoricBox(-1, -1, 0, 2, 2, 14, 24, 0)),
        prehistoricPart("wingR", (-2.5, 9, -1), prehistoricBox(-10, -0.4, -4, 10, 0.8, 9, 0, 64)),
        prehistoricPart("wingL", (2.5, 9, -1), prehistoricBox(0, -0.4, -4, 10, 0.8, 9, 0, 64)),
        prehistoricPart("hindWingR", (-2, 5, 3), prehistoricBox(-8, -0.3, -3, 8, 0.6, 7, 40, 64)),
        prehistoricPart("hindWingL", (2, 5, 3), prehistoricBox(0, -0.3, -3, 8, 0.6, 7, 40, 64)),
        prehistoricPart("legR", (-1.5, 5, 2), prehistoricBox(-1, -5, -1, 2, 5, 2, 72, 64)),
        prehistoricPart("legL", (1.5, 5, 2), prehistoricBox(-1, -5, -1, 2, 5, 2, 72, 64)),
    ]
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "parrot", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 6, eyeX: 1, eyeY: 1, eyeGap: 2))
}

func prehistoricIchthyosaurModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    // Vertical tail fluke and large lateral eye deliberately distinguish this
    // marine reptile asset from the renderer's horizontal-fluked dolphin model.
    let parts: [ModelPart] = [
        prehistoricPart("body", (0, 8, 0), prehistoricBox(-4, -4, -10, 8, 8, 20, 0, 20)),
        prehistoricPart("head", (0, 8, -9), prehistoricBox(-4.5, -4, -8, 9, 8, 9, 0, 0)),
        prehistoricPart("snout", (0, 7, -16), prehistoricBox(-2.2, -1.5, -8, 4.4, 3, 9, 20, 0)),
        prehistoricPart("tail", (0, 8, 10),
                        prehistoricBox(-2.5, -2.5, -1, 5, 5, 15, 36, 0),
                        prehistoricBox(-0.7, -7, 10, 1.4, 14, 5, 56, 0)),
        prehistoricPart("dorsalFin", (0, 12, 1), prehistoricBox(-0.6, 0, -3, 1.2, 7, 7, 72, 0)),
        prehistoricPart("flipperR", (-4, 6, -1), prehistoricBox(-8, -0.5, -3, 8, 1, 7, 0, 64)),
        prehistoricPart("flipperL", (4, 6, -1), prehistoricBox(0, -0.5, -3, 8, 1, 7, 0, 64)),
    ]
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "fish", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 9, eyeX: 1, eyeY: 2, eyeGap: 5))
}

func prehistoricPlesiosaurModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let longNeck = recipe.form == "longNeck"
    let pliosaur = recipe.form == "pliosaur"
    let neckSegments = longNeck ? 5 : (pliosaur ? 1 : 3)
    let bodyL = pliosaur ? 20.0 : 16.0
    var parts: [ModelPart] = [
        prehistoricPart("body", (0, 8, 0), prehistoricBox(-6, -4, -bodyL / 2, 12, 8, bodyL, 0, 20)),
        prehistoricPart("tail", (0, 8, bodyL * 0.48),
                        prehistoricBox(-2, -2, -1, 4, 4, 13, 32, 0),
                        prehistoricBox(-4, -0.5, 9, 8, 1, 6, 48, 0)),
        prehistoricPart("flipperFR", (-5, 6, -4), prehistoricBox(-9, -0.5, -4, 9, 1, 8, 0, 64)),
        prehistoricPart("flipperFL", (5, 6, -4), prehistoricBox(0, -0.5, -4, 9, 1, 8, 0, 64)),
        prehistoricPart("flipperBR", (-5, 6, 4), prehistoricBox(-9, -0.5, -4, 9, 1, 8, 20, 64)),
        prehistoricPart("flipperBL", (5, 6, 4), prehistoricBox(0, -0.5, -4, 9, 1, 8, 20, 64)),
    ]
    if pliosaur {
        parts.append(prehistoricPart("head", (0, 9, -bodyL * 0.56),
                                     prehistoricBox(-5.5, -4, -11, 11, 8, 12, 0, 0)))
        parts.append(prehistoricPart("jaw", (0, 6.5, -bodyL * 0.56 - 9),
                                     prehistoricBox(-5, -1, -5, 10, 2, 7, 20, 0)))
    } else {
        for i in 0..<neckSegments {
            let progress = Double(i) / Double(max(1, neckSegments - 1))
            let z = -bodyL * 0.42 - Double(i) * 6.5
            let y = 10 + progress * (longNeck ? 13 : 6)
            parts.append(prehistoricRotatedPart("neck\(i)", (0, y, z), (-0.18, 0, 0),
                                                prehistoricBox(-2.4, -2.5, -5, 4.8, 5, 9, 64, 0)))
        }
        let headZ = -bodyL * 0.42 - Double(neckSegments) * 6.5
        let headY = 10.0 + (longNeck ? 13.0 : 6.0)
        parts.append(prehistoricPart("head", (0, headY, headZ),
                                     prehistoricBox(-3, -2.5, -7, 6, 5, 8, 0, 0)))
    }
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "fish", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: pliosaur ? 12 : 8, eyeX: 1, eyeY: 1, eyeGap: 3))
}

func prehistoricMosasaurModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let parts: [ModelPart] = [
        prehistoricPart("body", (0, 9, 0), prehistoricBox(-6, -4.5, -12, 12, 9, 25, 0, 20)),
        prehistoricPart("head", (0, 9, -11), prehistoricBox(-5.5, -4, -11, 11, 8, 12, 0, 0)),
        prehistoricPart("jaw", (0, 6.5, -20), prehistoricBox(-5, -1, -6, 10, 2, 8, 20, 0)),
        prehistoricPart("tail", (0, 9, 12),
                        prehistoricBox(-3.5, -3, -1, 7, 6, 19, 40, 0),
                        prehistoricBox(-1, -8, 14, 2, 16, 7, 64, 0)),
        prehistoricPart("flipperR", (-6, 7, -2), prehistoricBox(-10, -0.7, -4, 10, 1.4, 8, 0, 64)),
        prehistoricPart("flipperL", (6, 7, -2), prehistoricBox(0, -0.7, -4, 10, 1.4, 8, 0, 64)),
        prehistoricPart("dorsalRidge", (0, 14, 2), prehistoricBox(-1, 0, -6, 2, 4, 13, 84, 0)),
    ]
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "fish", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 12, eyeX: 2, eyeY: 2, eyeGap: 5))
}

func prehistoricCrocodilianModel(_ recipe: PrehistoricModelRecipe) -> MobModel {
    let parts: [ModelPart] = [
        prehistoricPart("head", (0, 7, -11),
                        prehistoricBox(-5, -3, -14, 10, 6, 15, 0, 0),
                        prehistoricBox(-4.7, -3.5, -25, 9.4, 3, 12, 22, 0)),
        prehistoricPart("body", (0, 7, 0), prehistoricBox(-7, -4, -12, 14, 8, 24, 0, 20)),
        prehistoricRotatedPart("tail", (0, 7, 11), (-0.08, 0, 0), prehistoricBox(-4, -3, -1, 8, 6, 30, 48, 20)),
        prehistoricPart("scutes", (0, 12, 1),
                        prehistoricBox(-1, 0, -10, 2, 4, 5, 80, 0),
                        prehistoricBox(-1, 0, -4, 2, 4, 5, 80, 0),
                        prehistoricBox(-1, 0, 2, 2, 4, 5, 80, 0),
                        prehistoricBox(-1, 0, 8, 2, 4, 5, 80, 0)),
        prehistoricPart("legFR", (-6, 6, -7), prehistoricBox(-3, -6, -3, 6, 6, 6, 0, 48)),
        prehistoricPart("legFL", (6, 6, -7), prehistoricBox(-3, -6, -3, 6, 6, 6, 0, 48)),
        prehistoricPart("legBR", (-6, 6, 8), prehistoricBox(-3, -6, -3, 6, 6, 6, 0, 48)),
        prehistoricPart("legBL", (6, 6, 8), prehistoricBox(-3, -6, -3, 6, 6, 6, 0, 48)),
    ]
    return MobModel(texW: 128, texH: 128, parts: parts, anim: "quad", scale: recipe.scale,
                    paint: prehistoricPaint(recipe, headDepth: 15, eyeX: 2, eyeY: 2, eyeGap: 5))
}

/// Called from the frozen bestiary registration after its legacy entries.  The
/// additions are data-driven and never change an existing model's key or UVs.
func registerPrehistoricModels() {
    for recipe in prehistoricModelRecipes {
        M2(recipe.id, prehistoricModel(recipe))
    }
}
