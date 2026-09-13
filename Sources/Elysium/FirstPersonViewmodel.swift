// First-person geometry lives in camera space, not in the HUD's sprite transform stack.
// +Y is the handle axis, +Z points back at the player; the origin is the physical grip.
import Foundation
import Metal
import simd
import ElysiumCore

enum ViewmodelAction: String, CaseIterable {
    case mining, chopping, digging, cutting, placing, eating, generic
}

func viewmodelLinearChannel(_ value: Float) -> Float {
    let c = min(1, max(0, value))
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}
func viewmodelLinearColor(_ srgb: SIMD4<Float>) -> SIMD4<Float> {
    SIMD4(viewmodelLinearChannel(srgb.x), viewmodelLinearChannel(srgb.y), viewmodelLinearChannel(srgb.z), srgb.w)
}

struct ViewmodelProfile {
    let action: ViewmodelAction
    let length: Float
    let grip: SIMD2<Float>
    let straighten: Float

    static func item(_ definition: ItemDef) -> Self {
        // Named exceptions precede combat family metadata: a Flying Wand behaves
        // like a sword in simulation, but its authored visual shaft is already +Y.
        // Anchors below come from the bundled Faithful pixels, excluding reels,
        // strings, bristles and lens rims from the physical shaft centerline.
        switch definition.name {
        case "flying_wand":
            return .init(action: .generic, length: 0.78, grip: .init(0.5, 0.8), straighten: 0)
        case "fishing_rod", "carrot_on_a_stick", "warped_fungus_on_a_stick":
            return .init(action: .generic, length: 1.10, grip: .init(0.2421875, 0.8203125), straighten: .pi / 4)
        case "brush":
            return .init(action: .generic, length: 0.62, grip: .init(0.2109375, 0.7890625), straighten: .pi / 4)
        case "trident":
            return .init(action: .generic, length: 1.30, grip: .init(0.2, 0.8), straighten: .pi / 4)
        case "spyglass":
            return .init(action: .generic, length: 0.70, grip: .init(0.234375, 0.78125), straighten: .pi / 4)
        default:
            break
        }
        let family = definition.tool?.type ?? ""
        switch family {
        case "pickaxe": return .init(action: .mining, length: 1.35, grip: .init(0.2, 0.8), straighten: .pi / 4)
        // Faithful haft pixels are centred on x+y=1.0625, not the canvas diagonal.
        // This perpendicular offset puts the actual wood through the socket.
        case "axe": return .init(action: .chopping, length: 1.35, grip: .init(0.24125, 0.82125), straighten: .pi / 4)
        case "shovel": return .init(action: .digging, length: 1.35, grip: .init(0.24125, 0.82125), straighten: .pi / 4)
        case "hoe": return .init(action: .digging, length: 1.35, grip: .init(0.24125, 0.82125), straighten: .pi / 4)
        case "sword": return .init(action: .cutting, length: 1.50, grip: .init(0.23, 0.77), straighten: .pi / 4)
        default:
            if definition.food != nil { return .init(action: .eating, length: 0.90, grip: .init(0.5, 0.78), straighten: 0) }
            if definition.block != nil { return .init(action: .placing, length: 0.38, grip: .init(0.5, 0.8), straighten: 0) }
            let compact = ["shears", "flint_and_steel"].contains(definition.name)
            return .init(action: .generic, length: compact ? 0.48 : 0.55,
                         grip: .init(compact ? 0.3 : 0.5, 0.77), straighten: compact ? .pi / 4 : 0)
        }
    }
}

func vmTranslation(_ v: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4; m.columns.3 = SIMD4(v, 1); return m
}
func vmScale(_ s: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4(s, s, s, 1))
}
func vmRotation(_ angles: SIMD3<Float>) -> simd_float4x4 {
    let x = simd_quatf(angle: angles.x, axis: SIMD3(1, 0, 0))
    let y = simd_quatf(angle: angles.y, axis: SIMD3(0, 1, 0))
    let z = simd_quatf(angle: angles.z, axis: SIMD3(0, 0, 1))
    return simd_float4x4(z * y * x)
}

enum ViewmodelPlacement {
    /// Item-only pose measured against the running Minecraft reference. The
    /// shaft enters at the outer lower edge and leans away from screen centre;
    /// no anatomical wrist or elbow constrains the ordinary item silhouette.
    static func item(_ definition: ItemDef, left: Bool, lift: Double = 0,
                     aspect: Float, bob: SIMD3<Float> = .zero) -> simd_float4x4 {
        let sign: Float = left ? -1 : 1
        let block = definition.block != nil
        let food = definition.food != nil
        let depth: Float = block ? 0.72 : (food ? 1.05 : 1.10)
        let halfHeight = depth * tan(35 * Float.pi / 180)
        // Blade, head and food silhouettes need distinct screen placement,
        // not an attempt to keep an invisible fist
        // at one fixed screen coordinate. Intentional right/bottom cropping
        // remains, but the useful head/blade must not disappear past the edge.
        let sword = definition.tool?.type == "sword" && definition.name != "flying_wand"
        let x: Float = block ? 0.88 : (food ? 0.94 : (sword ? 0.88 : 0.85))
        let y: Float = block ? 1.24 : (food ? 0.90 : 1.04)
        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 16.0/9
        let drop = lift.isFinite ? Float(min(1,max(0,lift))) * 1.25 : 0
        // Keep the edge inset in viewport-height units: a fixed normalized X
        // clips more of a long blade when the window becomes narrower.
        let horizontal = halfHeight * max(safeAspect*0.2, safeAspect-2*(1-x)*(16.0/9))
        let position = SIMD3(sign*horizontal,
                             (1-y*2)*halfHeight-drop,-depth) + bob
        // Food has no straightened shaft. Its diagonal source silhouette needs
        // the opposite cant to stand up like the reference instead of flattening.
        let angles = block ? SIMD3<Float>(0.12,sign*0.45,0)
            : SIMD3<Float>(-0.08,-sign*0.55,sign*(food ? 0.35 : -0.43))
        return vmTranslation(position) * vmRotation(angles)
    }

    static func grip(left: Bool, lift: Double = 0, logicalWidth: Double,
                     aspect: Float, bob: SIMD3<Float> = .zero) -> simd_float4x4 {
        let h: Float = 1.35 * tan(35 * .pi/180)
        let hotbar = Float(91 / max(160, logicalWidth))
        let nx = min(0.83, max(0.72, 0.5 + hotbar + 0.04))
        let x = (nx*2-1) * h * aspect * (left ? -1 : 1)
        return vmTranslation(SIMD3(x,-0.56-Float(lift)*1.25,-1.35)+bob)
            * vmRotation(SIMD3(-0.12, left ? 0.26 : -0.26, left ? -0.38 : 0.38))
    }
}

struct ViewmodelVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var color: SIMD4<Float>
    /// xy = face UV, z = atlas slice; negative slice means vertex-colour geometry.
    var surface: SIMD4<Float>
}

struct ViewmodelMesh {
    var vertices: [ViewmodelVertex] = []

    func reflectedX() -> Self {
        var mesh = self
        for i in mesh.vertices.indices {
            mesh.vertices[i].position.x *= -1; mesh.vertices[i].normal.x *= -1
        }
        for i in stride(from: 0, to: mesh.vertices.count, by: 3) { mesh.vertices.swapAt(i+1, i+2) }
        return mesh
    }

    init(_ packed: [Float] = []) {
        guard packed.count % 30 == 0 else { return }
        vertices.reserveCapacity(packed.count / 10)
        for i in stride(from: 0, to: packed.count, by: 10) {
            vertices.append(.init(position: SIMD4(packed[i], packed[i+1], packed[i+2], 1),
                                  normal: SIMD4(packed[i+3], packed[i+4], packed[i+5], 0),
                                  color: SIMD4(packed[i+6], packed[i+7], packed[i+8], packed[i+9]),
                                  surface: SIMD4(0, 0, -1, 0)))
        }
    }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                       normal: SIMD3<Float>, color: SIMD4<Float>, slice: Float = -1) {
        let points = [a, b, c, d]
        let uvs: [SIMD2<Float>] = [.init(0,1), .init(1,1), .init(1,0), .init(0,0)]
        for i in [0,1,2,0,2,3] {
            vertices.append(.init(position: SIMD4(points[i], 1), normal: SIMD4(normal, 0),
                                  color: color, surface: SIMD4(uvs[i].x, uvs[i].y, slice, 0)))
        }
    }

    mutating func box(min a: SIMD3<Float>, max b: SIMD3<Float>, color: SIMD4<Float>, slices: [Float] = []) {
        let faces: [(SIMD3<Float>, [SIMD3<Float>])] = [
            (.init(0,0,1), [.init(a.x,a.y,b.z),.init(b.x,a.y,b.z),.init(b.x,b.y,b.z),.init(a.x,b.y,b.z)]),
            (.init(0,0,-1), [.init(b.x,a.y,a.z),.init(a.x,a.y,a.z),.init(a.x,b.y,a.z),.init(b.x,b.y,a.z)]),
            (.init(1,0,0), [.init(b.x,a.y,b.z),.init(b.x,a.y,a.z),.init(b.x,b.y,a.z),.init(b.x,b.y,b.z)]),
            (.init(-1,0,0), [.init(a.x,a.y,a.z),.init(a.x,a.y,b.z),.init(a.x,b.y,b.z),.init(a.x,b.y,a.z)]),
            (.init(0,1,0), [.init(a.x,b.y,b.z),.init(b.x,b.y,b.z),.init(b.x,b.y,a.z),.init(a.x,b.y,a.z)]),
            (.init(0,-1,0), [.init(a.x,a.y,a.z),.init(b.x,a.y,a.z),.init(b.x,a.y,b.z),.init(a.x,a.y,b.z)]),
        ]
        for (i, face) in faces.enumerated() {
            quad(face.1[0], face.1[1], face.1[2], face.1[3], normal: face.0,
                 color: color, slice: i < slices.count ? slices[i] : -1)
        }
    }

    /// Native-resolution texels become solid coloured surfaces. Only silhouette sidewalls
    /// are emitted; transparent and detached speck pixels cannot become fragments on a fist.
    static func extruded(_ image: RGBAImage, profile: ViewmodelProfile) -> Self {
        guard image.width > 0, image.height > 0, image.width <= 64, image.height <= 64,
              image.pixels.count == image.width * image.height * 4 else { return .init() }
        let w = image.width, h = image.height
        var occupied = [Bool](repeating: false, count: w*h)
        for i in occupied.indices { occupied[i] = image.pixels[i*4+3] >= 128 }
        // Keep meaningful detached parts (e.g. fishing line) but discard single-pixel export noise.
        let original = occupied
        for y in 0..<h { for x in 0..<w where original[y*w+x] {
            var neighbours = 0
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                if x+dx >= 0, x+dx < w, y+dy >= 0, y+dy < h, original[(y+dy)*w+x+dx] { neighbours += 1 }
            } }
            if neighbours == 0 { occupied[y*w+x] = false }
        } }
        var mesh = Self()
        let cs = cos(profile.straighten), sn = sin(profile.straighten)
        let width = profile.length / (profile.straighten == 0 ? 1 : 1.25)
        let depth: Float = profile.action == .eating ? 0.065 : 0.045
        func point(_ x: Int, _ y: Int, _ z: Float) -> SIMD3<Float> {
            let px = (Float(x)/Float(w) - profile.grip.x) * width
            let py = (profile.grip.y - Float(y)/Float(h)) * width
            return .init(px*cs-py*sn, px*sn+py*cs, z)
        }
        func solid(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && occupied[y*w+x] }
        for y in 0..<h { for x in 0..<w where occupied[y*w+x] {
            let i = (y*w+x)*4
            let c = viewmodelLinearColor(SIMD4<Float>(Float(image.pixels[i])/255,Float(image.pixels[i+1])/255,Float(image.pixels[i+2])/255,1))
            let a = point(x,y+1,depth/2), b = point(x+1,y+1,depth/2)
            let d = point(x,y,depth/2), e = point(x+1,y,depth/2)
            let aa = point(x,y+1,-depth/2), bb = point(x+1,y+1,-depth/2)
            let dd = point(x,y,-depth/2), ee = point(x+1,y,-depth/2)
            mesh.quad(a,b,e,d,normal:.init(0,0,1),color:c)
            mesh.quad(bb,aa,dd,ee,normal:.init(0,0,-1),color:c)
            if !solid(x-1,y) { mesh.quad(aa,a,d,dd,normal:.init(-cs,-sn,0),color:c) }
            if !solid(x+1,y) { mesh.quad(b,bb,ee,e,normal:.init(cs,sn,0),color:c) }
            if !solid(x,y-1) { mesh.quad(d,e,ee,dd,normal:.init(-sn,cs,0),color:c) }
            if !solid(x,y+1) { mesh.quad(aa,bb,b,a,normal:.init(sn,-cs,0),color:c) }
        } }
        return mesh
    }

    /// Canonical inventory state, rendered by the same atlas-aware mesher as a
    /// placed block. Reusing that boundary keeps partial-box UVs, biome tint
    /// gates and packed chest/door/bed regions in sync with the live world.
    /// Callers cache by block id, context generation, and biome.
    static func block(_ id: Int, context: MeshRenderContext = .procedural,
                      biome: Int = Biome.plains.rawValue) -> Self {
        guard id > 0, id < blockDefs.count else { return .init() }
        var boxes: [AABB] = []
        let canonical = cell(UInt16(id))
        shapeBoxes(Int(canonical), { _,_,_ in 0 }, &boxes, false)
        guard !boxes.isEmpty, boxes.count <= 256,
              boxes.allSatisfy({ box in
                  [box.x0,box.y0,box.z0,box.x1,box.y1,box.z1].allSatisfy(\.isFinite)
                      && box.x1 > box.x0 && box.y1 > box.y0 && box.z1 > box.z0
              }) else { return .init() }

        // One isolated block in the mesher's 18³ padded snapshot. There is no
        // World, entity, RNG, save, or gameplay mutation on this render path.
        let edge = 18, volume = edge * edge * edge
        var blocks = [UInt16](repeating: 0, count: volume)
        blocks[(edge + 1) * edge + 1] = canonical // section-local (0,0,0)
        let input = MeshInput(blocks: blocks,
                              skyLight: [UInt8](repeating: 15, count: volume),
                              blockLight: [UInt8](repeating: 0, count: volume),
                              biomes: [UInt8](repeating: UInt8(exactly: biome) ?? UInt8(Biome.plains.rawValue),
                                              count: edge * edge),
                              noMerge: true, renderContext: context)
        let output = buildSectionMesh(input)
        let layers = [output.opaque, output.cutout, output.translucent]
        let vertexCount = layers.reduce(0) { $0 + $1.idx.count }
        // At most 1 MiB of 64-byte ViewmodelVertex data per cached block mesh,
        // including unusual registered fixtures; excessive output fails closed.
        guard vertexCount <= 16_384 else { return .init() }
        let normals: [SIMD3<Float>] = [.init(0,-1,0),.init(0,1,0),.init(0,0,-1),
                                       .init(0,0,1),.init(-1,0,0),.init(1,0,0)]
        var mesh = Self()
        mesh.vertices.reserveCapacity(vertexCount)
        for layer in layers {
            guard layer.idx.count % 3 == 0, layer.data.count == layer.count * 7,
                  layer.idx.allSatisfy({ Int($0) < layer.count }) else { return .init() }
            for triangle in stride(from: 0, to: layer.idx.count, by: 3) {
                var vertices: [ViewmodelVertex] = []
                for index in layer.idx[triangle..<triangle + 3] {
                    let i = Int(index) * 7, material = layer.data[i + 5], tint = layer.data[i + 6]
                    let normal = Int((material >> 12) & 7)
                    guard normal < normals.count else { return .init() }
                    let p = SIMD3(Float(bitPattern: layer.data[i]), Float(bitPattern: layer.data[i + 1]),
                                  Float(bitPattern: layer.data[i + 2]))
                    let color = viewmodelLinearColor(SIMD4(Float((tint >> 16) & 255) / 255,
                                                           Float((tint >> 8) & 255) / 255,
                                                           Float(tint & 255) / 255, 1))
                    vertices.append(.init(position: SIMD4((p - SIMD3(0.5,0,0.5))*0.38 + SIMD3(0,0.02,-0.08), 1),
                                          normal: SIMD4(normals[normal], 0), color: color,
                                          surface: SIMD4(Float(bitPattern: layer.data[i + 3]),
                                                         Float(bitPattern: layer.data[i + 4]),
                                                         Float(material & 4095), 0)))
                }
                // World meshes use their own front-face convention. Normalize
                // winding for this renderer without mirroring texture UVs.
                let a = vertices[0].position, b = vertices[1].position, c = vertices[2].position
                let cross = simd_cross(SIMD3(b.x-a.x,b.y-a.y,b.z-a.z), SIMD3(c.x-a.x,c.y-a.y,c.z-a.z))
                let n = vertices[0].normal
                if simd_dot(cross, SIMD3(n.x,n.y,n.z)) < 0 { vertices.swapAt(1, 2) }
                mesh.vertices.append(contentsOf: vertices)
            }
        }
        return mesh
    }
}
