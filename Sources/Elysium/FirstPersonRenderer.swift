// A separate camera-space depth pass. The HUD is rendered afterward, so the minimap
// always occludes held equipment without changing its placement as map size changes.
import Foundation
import Metal
import simd
import ElysiumCore

private struct ViewmodelUniforms {
    var projection: simd_float4x4
    var model: simd_float4x4
    var light: SIMD4<Float>
}

private final class ViewmodelGPU {
    let buffer: MTLBuffer
    let count: Int
    init?(_ mesh: ViewmodelMesh, device: MTLDevice) {
        guard !mesh.vertices.isEmpty,
              let buffer = mesh.vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }) else { return nil }
        self.buffer = buffer; count = mesh.vertices.count
    }
}

final class FirstPersonRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private var depth: MTLTexture?
    private var meshes: [String: ViewmodelGPU] = [:]
    private var workingPoints: [String: SIMD3<Float>] = [:]
    private var meshOrder: [String] = []
    private var generation: UInt64 = .max
    private var mainDisplay = HeldHandDisplay()
    private var offDisplay = HeldHandDisplay()
    private var swing = HeldSwingAnimationState()
    private var flourish = HeldEquipmentAnimationState()
    private var shieldRelax = HeldRelaxState()
    private var bowRelax = HeldRelaxState()
    private var projectileDepth = FirstPersonAimDepth()
    private var identity: ObjectIdentifier?

    init(device: MTLDevice) {
        self.device = device
        let library = try! device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "viewmodelVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "viewmodelFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = .less; d.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: d)!
        let s = MTLSamplerDescriptor(); s.minFilter = .nearest; s.magFilter = .nearest
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)!
    }

    private func mesh(_ key: String, build: () -> ViewmodelMesh) -> ViewmodelGPU? {
        if let cached = meshes[key] { return cached }
        guard let value = ViewmodelGPU(build(), device: device) else { return nil }
        // Tool scrolling cannot accumulate an unbounded second inventory in GPU memory.
        while meshOrder.count >= 24 {
            let expired = meshOrder.removeFirst()
            meshes.removeValue(forKey: expired); workingPoints.removeValue(forKey: expired)
        }
        meshOrder.append(key); meshes[key] = value; return value
    }

    private func reset() {
        mainDisplay = HeldHandDisplay(); offDisplay = HeldHandDisplay()
        swing = HeldSwingAnimationState(); flourish = HeldEquipmentAnimationState()
        shieldRelax = HeldRelaxState(); bowRelax = HeldRelaxState()
        projectileDepth = FirstPersonAimDepth()
    }

    func render(command: MTLCommandBuffer, target: MTLTexture, game: GameCore, cam: CamState,
                canvas: UICanvas, atlas: MTLTexture, partial: Double, time: Double,
                visible: Bool, logicalWidth: Double, logicalHeight: Double) {
        guard let player = game.player else { identity = nil; reset(); return }
        if identity != ObjectIdentifier(player) { identity = ObjectIdentifier(player); reset() }
        let currentGeneration = currentIconSourceGeneration()
        if currentGeneration != generation {
            meshes.removeAll(); workingPoints.removeAll(); meshOrder.removeAll(); generation = currentGeneration
        }
        let eligible = visible && game.perspective == 0
        let main = mainDisplay.observe(stack: player.inventory[player.selectedSlot],
                                       key: player.inventory[player.selectedSlot].map { $0.id &* 16 &+ player.selectedSlot },
                                       at: time, eligible: eligible)
        let off = offDisplay.observe(stack: player.offHand, key: player.offHand?.id, at: time, eligible: eligible)
        let progress = swing.observe(primaryHeld: game.primaryActionHeld, engineAttack: player.attackAnim,
                                     at: time, eligible: eligible)
        let mainDefinition = main.stack.map { itemDef($0.id) }
        let mainName = mainDefinition?.name
        let offName = off.stack.map { itemDef($0.id).name }
        let isBow = mainName == "bow"
        let isShield = mainName == "shield"
        let isUsing = player.usingItem && main.stack != nil && main.key == mainDisplay.swap.itemKey
            && main.stack?.id == player.usingMainHandStack()?.id
        let flourishKey = mainDefinition?.tool == nil ? nil : main.key
        let selectedFlourishKey = player.inventory[player.selectedSlot].flatMap { stack -> Int? in
            itemDef(stack.id).tool == nil ? nil : stack.id &* 16 &+ player.selectedSlot
        }
        if game.settings.reduceMotion { flourish.reset(to: flourishKey) }
        let flip = flourish.observe(itemID: flourishKey, at: time, eligible: eligible,
                                    working: progress != nil || isUsing || player.shieldRaised,
                                    selectedItemID: selectedFlourishKey)
        let guardAmount = shieldRelax.observe(target: player.shieldRaised
            ? min(1, (Double(player.shieldRaiseTicks)+partial)/5) : 0,
            at: time, fallDuration: HELD_SHIELD_LOWER_DURATION)
        let drawAmount = min(1, max(0, (Double(player.useItemTicks)+partial)/20))
        let bowRelease = bowRelax.observe(target: isBow && isUsing ? drawAmount : 0,
                                         at: time, fallDuration: HELD_BOW_RELAX_DURATION)
        guard eligible, logicalWidth >= 160, logicalHeight >= 120,
              main.stack != nil || off.stack != nil else { return }
        if depth?.width != target.width || depth?.height != target.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                width: target.width, height: target.height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = .renderTarget
            depth = device.makeTexture(descriptor: descriptor)
        }
        guard let depth else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth; pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "First-person voxel viewmodel"
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back); encoder.setFrontFacing(.counterClockwise)
        encoder.setFragmentTexture(atlas, index: 0); encoder.setFragmentSamplerState(sampler, index: 0)
        let aspect = Float(target.width)/Float(target.height)
        // Fixed viewmodel lens keeps held-item presentation stable across world FOV changes.
        let projection = mat4Perspective(fovYRad: 70 * .pi/180, aspect: aspect, near: 0.035, far: 12)
        let ranged = isBow || mainName == "crossbow" || (mainName == "trident" && isUsing)
        let aimedTarget = ranged
            ? FirstPersonTarget.resolve(game: game, cam: cam, partial: partial, aspect: aspect, ranged: true)
            : nil
        let rangedDepth = projectileDepth.observe(min(64,max(2,aimedTarget?.worldDepth ?? 32)),at:time)
        let walk = game.heldItemBob(partial: partial)
        let motion = game.settings.reduceMotion ? 0 : min(0.4, walk.amplitude)
        let bob = SIMD3<Float>(Float(sin(walk.phase * .pi)*motion)*0.035,
                               -Float(abs(cos(walk.phase * .pi))*motion)*0.035, 0)
        let sky = Float(game.world.sunAngle())
        let ambient: Float = game.world.dim == .overworld ? max(0.68, min(1, 0.8 + cos(sky * .pi * 2)*0.2)) : 0.78

        func draw(_ key: String, _ transform: simd_float4x4, build: () -> ViewmodelMesh) {
            guard let gpu = mesh(key, build: build) else { return }
            var uniforms = ViewmodelUniforms(projection: projection, model: transform, light: SIMD4(ambient,0,0,0))
            encoder.setVertexBuffer(gpu.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewmodelUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewmodelUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gpu.count)
        }

        func arm(_ transform: simd_float4x4, left: Bool, handGrip: FirstPersonHandGrip = .standard) {
            // Reflection is confined to authored arm geometry; correct winding and normals
            // at mesh construction. Items always retain positive-determinant transforms.
            func reflected(_ data: [Float]) -> ViewmodelMesh {
                let mesh = ViewmodelMesh(data)
                return left ? mesh.reflectedX() : mesh
            }
            let pose = FirstPersonArmPose.solve(hand: transform, left: left)
            draw("forearm:\(left)", pose.forearm) { reflected(FirstPersonModelAssets.forearm) }
            draw("upper-arm:\(left)", pose.upperArm) { reflected(FirstPersonModelAssets.upperArm) }
            draw("wrist-joint:\(left)", vmTranslation(pose.wrist)) { reflected(FirstPersonModelAssets.wristJoint) }
            draw("hand:\(left):\(handGrip.rawValue)", handGrip.meshTransform(in: transform)) {
                switch handGrip {
                case .standard: return reflected(FirstPersonModelAssets.handNarrow)
                case .pickaxe: return reflected(FirstPersonModelAssets.hand)
                case .round: return reflected(FirstPersonModelAssets.handRound)
                case .shield: return reflected(FirstPersonModelAssets.handShield)
                case .draw: return reflected(FirstPersonModelAssets.handDraw)
                }
            }
        }

        func grip(left: Bool, lift: Double = 0) -> simd_float4x4 {
            // Item placement is independent of minimap size.
            ViewmodelPlacement.grip(left: left, lift: lift, logicalWidth: logicalWidth, aspect: aspect, bob: bob)
        }

        func itemKey(_ stack: ItemStack) -> String {
            let definition = itemDef(stack.id)
            let biome = game.world.biomeAt(ifloorD(player.x), ifloorD(player.y), ifloorD(player.z))
            return "item:\(stack.id):\(stack.data.potion ?? ""):\(game.liveMeshRenderContext.generation):\(definition.block == nil ? 0 : biome)"
        }

        func itemMesh(_ stack: ItemStack) -> ViewmodelMesh {
            let definition = itemDef(stack.id)
            let profile = ViewmodelProfile.item(definition)
            let biome = game.world.biomeAt(ifloorD(player.x), ifloorD(player.y), ifloorD(player.z))
            let context = game.liveMeshRenderContext
            if definition.name == "crossbow" { return .crossbow() }
            if definition.name == "flying_wand" { return .flyingWand() }
            if let block = definition.block, blockItemIconUsesThreeDimensionalPreview(Int(block)) {
                return .block(Int(block), context: context, biome: biome)
            }
            return .extruded(canvas.viewmodelItemImage(definition, data: stack.data), profile: profile)
        }

        func item(_ stack: ItemStack, transform: simd_float4x4) {
            draw(itemKey(stack), transform) { itemMesh(stack) }
        }

        func workingPoint(_ stack: ItemStack) -> SIMD3<Float> {
            let key = itemKey(stack)
            if let point = workingPoints[key] { return point }
            let geometry = itemMesh(stack)
            _ = mesh(key) { geometry }
            let point = FirstPersonStrike.workingPoint(itemDef(stack.id), mesh: geometry)
            workingPoints[key] = point
            return point
        }

        func beam(_ key: String, from a: SIMD3<Float>, to b: SIMD3<Float>, width: Float,
                  color: SIMD4<Float>, parent: simd_float4x4) {
            let delta = b-a, length = simd_length(delta)
            guard length > 0.0001 else { return }
            let orientation = simd_float4x4(simd_quatf(from: SIMD3<Float>(0,1,0), to: delta/length))
            let scaling = simd_float4x4(diagonal: SIMD4(width,length,width,1))
            draw(key, parent * vmTranslation(a) * orientation * scaling) {
                var m = ViewmodelMesh()
                if key == "bow-wood" {
                    // Grain is part of the solid limb surfaces, not a floating overlay.
                    for row in 0..<12 {
                        let shade: Float = [0.86,1.0,0.93,1.10,0.96,1.04][row % 6]
                        let c = viewmodelLinearColor(SIMD4(color.x*shade,color.y*shade,color.z*shade,1))
                        m.box(min: SIMD3(-0.5,Float(row)/12,-0.5),
                              max: SIMD3(0.5,Float(row+1)/12,0.5), color: c)
                    }
                } else { m.box(min: SIMD3(-0.5,0,-0.5), max: SIMD3(0.5,1,0.5), color: viewmodelLinearColor(color)) }
                return m
            }
        }

        if isBow {
            let t = Float(bowRelease)
            let idle = grip(left: true, lift: main.lift)
            let idlePosition = SIMD3(idle.columns.3.x,idle.columns.3.y,idle.columns.3.z)
            let aimedPosition = SIMD3<Float>(-0.39,-0.24-Float(main.lift)*1.25,-1.52) + bob
            let bow = vmTranslation(idlePosition + (aimedPosition-idlePosition)*t)
                * simd_float4x4(simd_slerp(simd_quatf(idle),simd_quatf(angle:0,axis:SIMD3(0,1,0)),t))
            arm(bow, left: true, handGrip: .round)
            let wood = SIMD4<Float>(0.48,0.27,0.11,1)
            let string = SIMD4<Float>(0.88,0.86,0.73,1)
            let nock = SIMD3<Float>(0.095 + 0.25*t,0.03,0.10 + 0.36*t)
            for sign: Float in [-1,1] {
                let points = [SIMD3<Float>(0,0,0), SIMD3(-0.07,sign*0.17,-0.04),
                              SIMD3(-0.03,sign*0.34,0.015+0.08*t), SIMD3(0.095,sign*0.46,0.10+0.12*t)]
                for i in 0..<3 { beam("bow-wood", from: points[i], to: points[i+1], width: 0.052-Float(i)*0.010, color: wood, parent: bow) }
                beam("bow-string", from: points[3], to: nock, width: 0.007, color: string, parent: bow)
            }
            if t > 0.001 {
                // String contact is shared, but the right forearm returns to the right
                // shoulder. It never inherits the left arm's origin or elbow orientation.
                let p = bow * SIMD4(nock,1)
                let stringPoint = SIMD3(p.x,p.y,p.z)
                let up = simd_normalize(SIMD3(bow.columns.1.x,bow.columns.1.y,bow.columns.1.z))
                let toward = SIMD3(bow.columns.3.x,bow.columns.3.y,bow.columns.3.z)-stringPoint
                let fingers = simd_normalize(toward-up*simd_dot(toward,up))
                let orientation = simd_float3x3(columns:(up,fingers,simd_normalize(simd_cross(up,fingers))))
                let position = stringPoint-orientation*FirstPersonModelAssets.handDrawStringContact
                arm(vmTranslation(position) * simd_float4x4(simd_quatf(orientation)), left:false, handGrip:.draw)
            }
            if isUsing {
                // Aim at the same forward axis as the crosshair, not along the left-hand
                // idle yaw. Cosmetic geometry never emits a gameplay projectile.
                let aim = aimedTarget?.viewmodelPoint(depthRange: rangedDepth...rangedDepth, aspect: aspect)
                    ?? SIMD3<Float>(0,0,-32)
                let target = bow.inverse * SIMD4<Float>(aim,1)
                let direction = simd_normalize(SIMD3(target.x,target.y,target.z)-nock)
                beam("arrow-shaft", from: nock, to: nock + direction*0.90, width: 0.013, color: wood, parent: bow)
                beam("arrow-tip", from: nock + direction*0.90, to: nock + direction*0.96, width: 0.028, color: SIMD4(0.65,0.69,0.70,1), parent: bow)
                beam("arrow-feather", from: nock + SIMD3(-0.025,0,0) + direction*0.035,
                     to: nock + SIMD3(0.025,0,0) + direction*0.12, width: 0.025, color: SIMD4(0.86,0.87,0.84,1), parent: bow)
            }
        } else {
            if let mainStack = main.stack, !isShield {
                let definition = itemDef(mainStack.id)
                let profile = ViewmodelProfile.item(definition)
                var assembly = FirstPersonSwing.pose(rest: ViewmodelPlacement.item(definition,
                    left: false, aspect: aspect, bob: bob),
                    progress: progress, action: profile.action, left: false,
                    reducedMotion: game.settings.reduceMotion)
                if isUsing && (definition.food != nil || mainName == "potion" || mainName == "milk_bucket") {
                    let t = Float(min(1,(Double(player.useItemTicks)+partial)/6))
                    let nibble = game.settings.reduceMotion ? 0 : Float(sin((Double(player.useItemTicks)+partial)*1.1))*0.018
                    assembly = assembly * vmTranslation(SIMD3(-0.30*t,0.28*t+nibble,0.22*t)) * vmRotation(SIMD3(0.10,0,0.50*t))
                }
                if mainName == "crossbow" || (mainName == "trident" && isUsing) {
                    // A long trident needs a proxy ahead of its tip. Preserve
                    // screen alignment while keeping that presentation ray reachable.
                    let aimDepth = mainName == "trident" ? max(3,rangedDepth) : rangedDepth
                    let aim = aimedTarget?.viewmodelPoint(depthRange:aimDepth...aimDepth,aspect:aspect)
                        ?? SIMD3<Float>(0,0,-32)
                    // Ranged use aligns from rest instead of inheriting the
                    // ordinary item swing, which can carry the muzzle past its target.
                    let aimRest = mainName == "trident"
                        ? ViewmodelPlacement.item(definition,left:false,aspect:aspect,bob:bob)
                        : grip(left:false)
                    assembly = FirstPersonStrike.aimedProp(rest:aimRest,
                        muzzle:mainName == "crossbow" ? SIMD3(0,0.15,-0.55) : workingPoint(mainStack),
                        forward:mainName == "crossbow" ? SIMD3(0,0,-1) : SIMD3(0,1,0),target:aim)
                }
                // Equipment swapping owns its screen-space drop even at impact;
                // a held attack cannot raise the outgoing item back to the target.
                assembly = FirstPersonStrike.equipmentPose(assembly,lift:main.lift)
                // The live Minecraft reference renders ordinary held items alone;
                // visible arms remain confined to the dedicated bow/shield paths.
                // The timeline eases an interrupted twirl to its nearest full-turn
                // rest even during work; zeroing it here would reintroduce a snap.
                let turn: Float = game.settings.reduceMotion ? 0 : Float(flip < 1 ? flip : 0) * .pi * 2
                item(mainStack, transform: assembly * vmRotation(SIMD3(0,turn,0)))
            }
            if isShield || offName == "shield" {
                let t = Float(guardAmount)
                let base = grip(left: true, lift: isShield ? main.lift : off.lift)
                    * vmTranslation(SIMD3(0.24*t,0.24*t,-0.12*t)) * vmRotation(SIMD3(0,-0.30*t,0.10*t))
                arm(base, left: true, handGrip: .shield)
                draw("shield", base) { ViewmodelMesh(FirstPersonModelAssets.shield) }
            } else if let offStack = off.stack {
                let base = ViewmodelPlacement.item(itemDef(offStack.id),
                    left:true,lift:off.lift,aspect:aspect,bob:bob)
                item(offStack, transform: base)
            }
        }
        encoder.endEncoding()
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position; float4 normal; float4 color; float4 surface; };
    struct U { float4x4 projection; float4x4 model; float4 light; };
    struct Out { float4 position [[position]]; float3 normal; float4 color; float3 surface; };
    float3 fromSRGB(float3 c) { return select(c/12.92, pow((c+0.055)/1.055,float3(2.4)), c>0.04045); }
    float3 toSRGB(float3 c) { return select(c*12.92, 1.055*pow(max(c,float3(0)),float3(1.0/2.4))-0.055, c>0.0031308); }
    vertex Out viewmodelVertex(uint id [[vertex_id]], const device V *vertices [[buffer(0)]], constant U &u [[buffer(1)]]) {
        V v = vertices[id]; Out o;
        o.position = u.projection * u.model * v.position;
        o.normal = normalize((u.model * v.normal).xyz); o.color = v.color; o.surface = v.surface.xyz; return o;
    }
    fragment float4 viewmodelFragment(Out in [[stage_in]], constant U &u [[buffer(1)]],
                                      texture2d_array<float> atlas [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = in.color;
        if (in.surface.z >= 0) {
            float4 texel = atlas.sample(s, in.surface.xy, uint(in.surface.z + 0.5));
            c *= float4(fromSRGB(texel.rgb), texel.a);
        }
        if (c.a < 0.5) discard_fragment();
        float key = max(0.0, dot(normalize(in.normal), normalize(float3(-0.5,0.75,0.8))));
        float fill = max(0.0, dot(normalize(in.normal), normalize(float3(0.6,0.2,-0.5))));
        return float4(toSRGB(c.rgb * (0.58 + key*0.35 + fill*0.12) * u.light.x), 1);
    }
    """
}
