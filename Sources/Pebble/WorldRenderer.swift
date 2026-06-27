// The renderer — plus the entity/sprite/cube/crack/
// selection drawing from the frozen baseline. Owns every pipeline, the offscreen scene
// target, the bloom chain and the composite pass; draws camera-relative.

import AppKit
import Metal
import MetalKit
import simd
import PebbleCore

struct SectionKey: Hashable {
    let cx: Int, sy: Int, cz: Int
}

/// suballocated mesh block: vertices at offset, indices at offset + ibRel
struct MeshBlock {
    let page: Int
    let offset: Int
    let ibRel: Int
    let size: Int
    let indexCount: Int
}

final class SectionGPU {
    let key: SectionKey
    let minY: Int
    var opaque: MeshBlock?
    var cutout: MeshBlock?
    var translucent: MeshBlock?

    init(key: SectionKey, minY: Int) {
        self.key = key
        self.minY = minY
    }
}

/// One big MTLBuffer per ~32MB page with a first-fit free list. Every section
/// draws from the same few buffers (only offsets change between draws), which
/// removes the per-draw buffer-bind/residency work that dominated CPU encode.
/// Frees are deferred 3 frames so in-flight GPU work never reads freed blocks.
final class MeshArena {
    private let device: MTLDevice
    private(set) var pages: [MTLBuffer] = []
    private var free: [[(Int, Int)]] = []
    private var pendingFree: [(MeshBlock, Int)] = []
    private var frame = 0
    static let pageSize = 32 << 20

    init(device: MTLDevice) {
        self.device = device
    }

    func alloc(_ size: Int) -> (page: Int, offset: Int) {
        let sz = (size + 255) & ~255
        for pi in 0..<free.count {
            for bi in 0..<free[pi].count where free[pi][bi].1 >= sz {
                let off = free[pi][bi].0
                if free[pi][bi].1 == sz {
                    free[pi].remove(at: bi)
                } else {
                    free[pi][bi] = (off + sz, free[pi][bi].1 - sz)
                }
                return (pi, off)
            }
        }
        let buf = device.makeBuffer(length: max(Self.pageSize, sz), options: .storageModeShared)!
        pages.append(buf)
        let used = (size + 255) & ~255
        free.append(used < buf.length ? [(used, buf.length - used)] : [])
        return (pages.count - 1, 0)
    }

    func release(_ b: MeshBlock?) {
        if let b { pendingFree.append((b, frame)) }
    }

    /// once per rendered frame: reclaim blocks the GPU can no longer touch
    func tick() {
        frame += 1
        var i = 0
        while i < pendingFree.count {
            if frame - pendingFree[i].1 >= 3 {
                reclaim(pendingFree[i].0)
                pendingFree.remove(at: i)
            } else {
                i += 1
            }
        }
    }

    private func reclaim(_ b: MeshBlock) {
        var blocks = free[b.page]
        let i = blocks.firstIndex { $0.0 > b.offset } ?? blocks.count
        blocks.insert((b.offset, b.size), at: i)
        var j = i
        if j + 1 < blocks.count, blocks[j].0 + blocks[j].1 == blocks[j + 1].0 {
            blocks[j] = (blocks[j].0, blocks[j].1 + blocks[j + 1].1)
            blocks.remove(at: j + 1)
        }
        if j > 0, blocks[j - 1].0 + blocks[j - 1].1 == blocks[j].0 {
            blocks[j - 1] = (blocks[j - 1].0, blocks[j - 1].1 + blocks[j].1)
            blocks.remove(at: j)
            j -= 1
        }
        free[b.page] = blocks
    }
}

struct SkyColors {
    var zenith = SIMD3<Float>(0, 0, 0)
    var horizon = SIMD3<Float>(0, 0, 0)
    var fog = SIMD3<Float>(0, 0, 0)
    var dayLight: Double = 0
    var sunGlow: Double = 0
}

struct ChunkSharedU {
    var viewProj: simd_float4x4
    var shadowMat: simd_float4x4
    var light: SIMD4<Float>
    var fog: SIMD4<Float>
    var fogColor: SIMD4<Float>
    var misc: SIMD4<Float>      // time, packFluidDamp, ultraOn, shadowTexel
}
struct UltraUniforms {
    var invViewProj: simd_float4x4
    var viewProj: simd_float4x4
    var shadowMat: simd_float4x4
    var sunDir: SIMD4<Float>    // xyz + dayLight
    var params: SIMD4<Float>    // time, far, volumetricsOn, underwater
    var fogColor: SIMD4<Float>
    var texel: SIMD4<Float>     // 1/w, 1/h of the ultra target
}
struct SkyUniforms {
    var invViewProj: simd_float4x4
    var zenith: SIMD4<Float>
    var horizon: SIMD4<Float>
    var horizonSun: SIMD4<Float>
    var sunDir: SIMD4<Float>
}
struct CelestialUniforms {
    var viewProj: simd_float4x4
    var center: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
}
struct StarsUniforms {
    var viewProj: simd_float4x4
    var params: SIMD4<Float>
}
struct CloudUniforms {
    var viewProj: simd_float4x4
    var offset: SIMD4<Float>
    var scroll: SIMD4<Float>
}
struct LineUniforms {
    var viewProj: simd_float4x4
    var color: SIMD4<Float>
}
struct SpriteUniforms {
    var viewProj: simd_float4x4
    var center: SIMD4<Float>
    var right: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var light: SIMD4<Float>
    var fogColor: SIMD4<Float>
}
struct CompositeUniforms {
    var params: SIMD4<Float>
    var tint: SIMD4<Float>
    var params2: SIMD4<Float> = .zero   // ultraOn, aoStrength, volStrength
}

final class WorldRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue

    // pipelines
    var opaquePipeline: MTLRenderPipelineState!
    var cutoutPipeline: MTLRenderPipelineState!
    var translucentPipeline: MTLRenderPipelineState!
    var shadowPipeline: MTLRenderPipelineState!
    var skyPipeline: MTLRenderPipelineState!
    var celestialPipeline: MTLRenderPipelineState!
    var celestialAddPipeline: MTLRenderPipelineState!   // additive — pack sun/moon art ships on black
    var starsPipeline: MTLRenderPipelineState!
    var cloudPipeline: MTLRenderPipelineState!
    var entityPipeline: MTLRenderPipelineState!
    var entityPipelineHDR: MTLRenderPipelineState!
    var particlePipelineHDR: MTLRenderPipelineState!
    var spritePipelineHDR: MTLRenderPipelineState!
    /// pack mode: entity/sprite passes target rgba16F colortex instead of the drawable formats
    var packTargets = false
    var particlePipeline: MTLRenderPipelineState!
    var linePipeline: MTLRenderPipelineState!
    var spritePipeline: MTLRenderPipelineState!
    var bloomExtractPipeline: MTLRenderPipelineState!
    var blurPipeline: MTLRenderPipelineState!
    var compositePipeline: MTLRenderPipelineState!
    var titlePipeline: MTLRenderPipelineState!
    var logoPipeline: MTLRenderPipelineState!
    var titleBgTex: MTLTexture?
    var titleLogoTex: MTLTexture?
    var sunTex: MTLTexture?         // pack environment/sun.png
    var moonTex: MTLTexture?        // pack environment/moon_phases.png (4×2 grid)

    func makeImageTexture(_ img: RGBAImage) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: img.width, height: img.height, mipmapped: false)
        td.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: td) else { return nil }
        img.pixels.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: img.width * 4)
        }
        return t
    }
    var ultraPipeline: MTLRenderPipelineState!
    var ultraBlurPipeline: MTLRenderPipelineState!
    var uiPipeline: MTLRenderPipelineState!

    var depthWrite: MTLDepthStencilState!
    var depthRead: MTLDepthStencilState!
    var depthNone: MTLDepthStencilState!

    var atlasTexture: MTLTexture!
    var atlasSampler: MTLSamplerState!
    var linearSampler: MTLSamplerState!

    // resource-pack atlas state (procedural default: 16×, no animations)
    var atlasRes = 16
    var tileAnimations: [TileAnimation] = []
    private var animState: [(Int, Int)] = []   // (order position, ticks into frame)
    private var animAccumMs = 0.0
    private var animScratch: [UInt8] = []
    var packFluidDamp: Float = 0               // 1 = pack animates fluids, damp UV scroll
    private var shaderPackFailed: Set<String> = []
    private var frameCounter: Int32 = 0
    private var prevViewM = matrix_identity_float4x4
    private var prevProj = matrix_identity_float4x4
    private var prevCamPos = SIMD3<Float>(0, 0, 0)
    var shadowTexture: MTLTexture!
    var shadowSampler: MTLSamplerState!
    var cloudTexture: MTLTexture!
    var starsBuffer: MTLBuffer!
    var starCount = 0

    // offscreen targets
    var sceneColor: MTLTexture!
    var sceneDepth: MTLTexture!
    var bloomA: MTLTexture!
    var bloomB: MTLTexture!
    var ultraA: MTLTexture!         // half-res rgba16f: rgb=volumetric, a=AO
    var ultraB: MTLTexture!
    var ultraDummy: MTLTexture!     // 1×1 neutral bound when ultra is off
    var fbWidth = 0, fbHeight = 0
    private var shadowSizeNow = 0   // rebuilt when the ultra preset changes it

    var sections: [SectionKey: SectionGPU] = [:]
    var arena: MeshArena!
    var drawCalls = 0

    let entityRenderer: EntityRendererM
    let particles: ParticleSystemM

    // item sprite atlas (dropped items / thrown projectiles)
    var spriteTex: MTLTexture!
    var spriteSlots: [String: Int] = [:]

    // scratch GPU meshes for cubes/crack
    private var cubeMesh: (vb: MTLBuffer, ib: MTLBuffer, count: Int)?
    private var overlayMesh: (vb: MTLBuffer, ib: MTLBuffer, count: Int)?
    private var overlayStage = -1

    init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()!
        arena = MeshArena(device: device)
        entityRenderer = EntityRendererM(device: device)
        particles = ParticleSystemM(device: device)
        buildPipelines()
        buildAtlas()
        buildShadow()
        buildClouds()
        buildStars()
        buildSpriteAtlas()
    }

    // ---- setup ----------------------------------------------------------------
    private func buildPipelines() {
        let lib = try! device.makeLibrary(source: GAME_MSL, options: nil)

        let chunkVD = MTLVertexDescriptor()
        chunkVD.attributes[0].format = .float3
        chunkVD.attributes[0].offset = 0
        chunkVD.attributes[0].bufferIndex = 0
        chunkVD.attributes[1].format = .float2
        chunkVD.attributes[1].offset = 12
        chunkVD.attributes[1].bufferIndex = 0
        chunkVD.attributes[2].format = .uint
        chunkVD.attributes[2].offset = 20
        chunkVD.attributes[2].bufferIndex = 0
        chunkVD.attributes[3].format = .uint
        chunkVD.attributes[3].offset = 24
        chunkVD.attributes[3].bufferIndex = 0
        chunkVD.layouts[0].stride = 28

        func pipe(_ vs: String, _ fs: String?, vd: MTLVertexDescriptor?, blend: Bool = false,
                  additive: Bool = false, color: MTLPixelFormat = .bgra8Unorm, depth: MTLPixelFormat = .depth32Float) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            if let fs { d.fragmentFunction = lib.makeFunction(name: fs) }
            d.vertexDescriptor = vd
            if color != .invalid {
                d.colorAttachments[0].pixelFormat = color
                if blend {
                    d.colorAttachments[0].isBlendingEnabled = true
                    d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                    d.colorAttachments[0].destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                    d.colorAttachments[0].sourceAlphaBlendFactor = .one
                    d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            if depth != .invalid { d.depthAttachmentPixelFormat = depth }
            return try! device.makeRenderPipelineState(descriptor: d)
        }

        opaquePipeline = pipe("chunk_vs", "chunk_fs", vd: chunkVD)
        cutoutPipeline = pipe("chunk_vs", "chunk_fs", vd: chunkVD)
        translucentPipeline = pipe("chunk_vs", "chunk_fs", vd: chunkVD, blend: true)
        shadowPipeline = pipe("shadow_vs", nil, vd: chunkVD, color: .invalid)
        skyPipeline = pipe("sky_vs", "sky_fs", vd: nil)
        celestialPipeline = pipe("celestial_vs", "celestial_fs", vd: nil, blend: true)
        celestialAddPipeline = pipe("celestial_vs", "celestial_fs", vd: nil, blend: true, additive: true)
        cloudPipeline = pipe("cloud_vs", "cloud_fs", vd: nil, blend: true)

        let starsVD = MTLVertexDescriptor()
        starsVD.attributes[0].format = .float3
        starsVD.attributes[0].offset = 0
        starsVD.attributes[0].bufferIndex = 0
        starsVD.attributes[1].format = .float
        starsVD.attributes[1].offset = 12
        starsVD.attributes[1].bufferIndex = 0
        starsVD.layouts[0].stride = 16
        starsPipeline = pipe("stars_vs", "stars_fs", vd: starsVD, blend: true, additive: true)

        let entityVD = MTLVertexDescriptor()
        entityVD.attributes[0].format = .float3
        entityVD.attributes[0].offset = 0
        entityVD.attributes[0].bufferIndex = 0
        entityVD.attributes[1].format = .float3
        entityVD.attributes[1].offset = 12
        entityVD.attributes[1].bufferIndex = 0
        entityVD.attributes[2].format = .float2
        entityVD.attributes[2].offset = 24
        entityVD.attributes[2].bufferIndex = 0
        entityVD.attributes[3].format = .float
        entityVD.attributes[3].offset = 32
        entityVD.attributes[3].bufferIndex = 0
        entityVD.layouts[0].stride = 36
        entityPipeline = pipe("entity_vs", "entity_fs", vd: entityVD, blend: true)
        entityPipelineHDR = pipe("entity_vs", "entity_fs", vd: entityVD, blend: true, color: .rgba16Float)

        let particleVD = MTLVertexDescriptor()
        particleVD.attributes[0].format = .float2
        particleVD.attributes[0].offset = 0
        particleVD.attributes[0].bufferIndex = 0
        particleVD.attributes[1].format = .float3
        particleVD.attributes[1].offset = 0
        particleVD.attributes[1].bufferIndex = 1
        particleVD.attributes[2].format = .float4
        particleVD.attributes[2].offset = 12
        particleVD.attributes[2].bufferIndex = 1
        particleVD.attributes[3].format = .float
        particleVD.attributes[3].offset = 28
        particleVD.attributes[3].bufferIndex = 1
        particleVD.attributes[4].format = .float4
        particleVD.attributes[4].offset = 32
        particleVD.attributes[4].bufferIndex = 1
        particleVD.layouts[0].stride = 8
        particleVD.layouts[1].stride = 48
        particleVD.layouts[1].stepFunction = .perInstance
        particlePipeline = pipe("particle_vs", "particle_fs", vd: particleVD, blend: true)
        particlePipelineHDR = pipe("particle_vs", "particle_fs", vd: particleVD, blend: true, color: .rgba16Float)

        linePipeline = pipe("line_vs", "line_fs", vd: nil, blend: true)
        spritePipeline = pipe("sprite_vs", "sprite_fs", vd: nil, blend: true)
        spritePipelineHDR = pipe("sprite_vs", "sprite_fs", vd: nil, blend: true, color: .rgba16Float)
        bloomExtractPipeline = pipe("fs_vs", "bloom_extract_fs", vd: nil, depth: .invalid)
        blurPipeline = pipe("fs_vs", "blur_fs", vd: nil, depth: .invalid)
        compositePipeline = pipe("fs_vs", "composite_fs", vd: nil, depth: .invalid)
        titlePipeline = pipe("fs_vs", "title_fs", vd: nil, depth: .invalid)
        logoPipeline = pipe("logo_vs", "logo_fs", vd: nil, blend: true, depth: .invalid)
        if let path = bundleResourcePath("logo.png"),
           let d = FileManager.default.contents(atPath: path),
           let img = decodePNG(d) {
            titleLogoTex = makeImageTexture(img)
        }
        if let path = bundleResourcePath("title-bg.png"),
           let d = FileManager.default.contents(atPath: path),
           let img = decodePNG(d) {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                              width: img.width, height: img.height, mipmapped: false)
            td.usage = .shaderRead
            if let t = device.makeTexture(descriptor: td) {
                img.pixels.withUnsafeBytes { raw in
                    t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0,
                              withBytes: raw.baseAddress!, bytesPerRow: img.width * 4)
                }
                titleBgTex = t
            }
        }
        ultraPipeline = pipe("fs_vs", "ultra_fs", vd: nil, color: .rgba16Float, depth: .invalid)
        ultraBlurPipeline = pipe("fs_vs", "ultra_blur_fs", vd: nil, color: .rgba16Float, depth: .invalid)

        let uiVD = MTLVertexDescriptor()
        uiVD.attributes[0].format = .float2
        uiVD.attributes[0].offset = 0
        uiVD.attributes[0].bufferIndex = 0
        uiVD.attributes[1].format = .float2
        uiVD.attributes[1].offset = 8
        uiVD.attributes[1].bufferIndex = 0
        uiVD.attributes[2].format = .float4
        uiVD.attributes[2].offset = 16
        uiVD.attributes[2].bufferIndex = 0
        uiVD.layouts[0].stride = 32
        uiPipeline = pipe("ui_vs", "ui_fs", vd: uiVD, blend: true, depth: .invalid)

        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .lessEqual
        dw.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: dw)
        let dr = MTLDepthStencilDescriptor()
        dr.depthCompareFunction = .lessEqual
        dr.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: dr)
        let dn = MTLDepthStencilDescriptor()
        dn.depthCompareFunction = .always
        dn.isDepthWriteEnabled = false
        depthNone = device.makeDepthStencilState(descriptor: dn)
    }

    private func buildAtlas() {
        installProceduralAtlas()

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .nearest
        sd.magFilter = .nearest
        sd.sAddressMode = .repeat
        sd.tAddressMode = .repeat
        atlasSampler = device.makeSamplerState(descriptor: sd)
        let ld = MTLSamplerDescriptor()
        ld.minFilter = .linear
        ld.magFilter = .linear
        ld.sAddressMode = .clampToEdge
        ld.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: ld)
    }

    // ---- atlas install (procedural / resource pack) ------------------------------
    private func makeAtlasTexture(_ slices: [[UInt8]], res: Int) {
        let td = MTLTextureDescriptor()
        td.textureType = .type2DArray
        td.pixelFormat = .rgba8Unorm
        td.width = res
        td.height = res
        td.arrayLength = slices.count
        td.usage = .shaderRead
        let tex = device.makeTexture(descriptor: td)!
        for (i, px) in slices.enumerated() {
            px.withUnsafeBytes { raw in
                tex.replace(region: MTLRegionMake2D(0, 0, res, res), mipmapLevel: 0, slice: i,
                            withBytes: raw.baseAddress!, bytesPerRow: res * 4, bytesPerImage: res * res * 4)
            }
        }
        atlasTexture = tex
        atlasRes = res
    }

    func installProceduralAtlas() {
        let atlas = PebbleCore.buildAtlas()
        initIcons(atlas)      // item icons sample atlas tiles
        setUIAtlas(atlas)     // UI dirt-background blits reuse the same build
        makeAtlasTexture(atlas.pixels, res: TILE)
        tileAnimations = []
        animState = []
        packFluidDamp = 0
    }

    func installPackAtlas(_ result: PackAtlasResult) {
        makeAtlasTexture(result.slices, res: result.res)
        tileAnimations = result.animations
        animState = Array(repeating: (0, 0), count: result.animations.count)
        animAccumMs = 0
        packFluidDamp = result.fluidAnimated ? 1 : 0
    }

    func resetSpriteSlots() {
        spriteSlots.removeAll()
    }

    // ---- frame capture (photo booth) ---------------------------------------------
    private var pendingCapture: String?
    func requestCapture(path: String) {
        pendingCapture = path
    }

    /// encode a texture→buffer blit + async PNG write; call with the final
    /// composited image so captures include the full post stack
    private func encodeCapture(_ cmd: MTLCommandBuffer, from tex: MTLTexture) {
        guard let path = pendingCapture else { return }
        pendingCapture = nil
        let w = tex.width, h = tex.height
        let bpr = w * 4
        guard let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
              let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        cmd.addCompletedHandler { _ in
            let data = Data(bytes: buf.contents(), count: bpr * h)
            guard let provider = CGDataProvider(data: data as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                        | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                             "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// advance .mcmeta frame animations at 20Hz, blitting changed slices
    func tickTileAnimations(dtMs: Double) {
        guard !tileAnimations.isEmpty, atlasTexture != nil else { return }
        animAccumMs += dtMs
        var steps = 0
        while animAccumMs >= 50, steps < 4 {
            animAccumMs -= 50
            steps += 1
            advanceAnimationTick()
        }
        if animAccumMs >= 50 { animAccumMs = 0 }   // stalled frame: drop the backlog
    }

    private func advanceAnimationTick() {
        for k in 0..<tileAnimations.count {
            let anim = tileAnimations[k]
            var (pos, t) = animState[k]
            t += 1
            var frameChanged = false
            if t >= anim.order[pos].1 {
                t = 0
                pos = (pos + 1) % anim.order.count
                frameChanged = true
            }
            animState[k] = (pos, t)
            if anim.interpolate {
                // vanilla-style blend toward the next frame, every tick
                let cur = anim.frames[anim.order[pos].0]
                let nxt = anim.frames[anim.order[(pos + 1) % anim.order.count].0]
                let f = Double(t) / Double(anim.order[pos].1)
                if animScratch.count != cur.count { animScratch = [UInt8](repeating: 0, count: cur.count) }
                for i in 0..<cur.count {
                    animScratch[i] = UInt8(Double(cur[i]) + (Double(nxt[i]) - Double(cur[i])) * f)
                }
                uploadAtlasSlice(animScratch, anim.slice)
            } else if frameChanged {
                uploadAtlasSlice(anim.frames[anim.order[pos].0], anim.slice)
            }
        }
    }

    // animated-tile uploads are staged and blitted at frame start —
    // texture.replace() writes CPU-side while 1-2 in-flight frames may still
    // sample the slice (frame tearing on animated water/lava)
    private var pendingAtlasUploads: [(buf: MTLBuffer, slice: Int)] = []

    private func uploadAtlasSlice(_ px: [UInt8], _ slice: Int) {
        let buf = px.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
        if let buf { pendingAtlasUploads.append((buf, slice)) }
    }

    /// encode the staged slice updates as a blit BEFORE the frame's render
    /// passes — GPU-ordered, so in-flight frames finish sampling first
    func flushAtlasUploads(_ cmd: MTLCommandBuffer) {
        guard !pendingAtlasUploads.isEmpty, let blit = cmd.makeBlitCommandEncoder() else { return }
        for (buf, slice) in pendingAtlasUploads {
            blit.copy(from: buf, sourceOffset: 0, sourceBytesPerRow: atlasRes * 4,
                      sourceBytesPerImage: atlasRes * atlasRes * 4,
                      sourceSize: MTLSize(width: atlasRes, height: atlasRes, depth: 1),
                      to: atlasTexture, destinationSlice: slice, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        pendingAtlasUploads.removeAll()
    }

    private func buildShadow(size: Int = 2048) {
        shadowSizeNow = size
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                          width: size, height: size, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        shadowTexture = device.makeTexture(descriptor: td)!
        if shadowSampler == nil {
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear
            sd.magFilter = .linear
            sd.compareFunction = .lessEqual
            sd.sAddressMode = .clampToEdge
            sd.tAddressMode = .clampToEdge
            shadowSampler = device.makeSamplerState(descriptor: sd)!
        }
    }

    private func buildClouds() {
        // blobby cellular clouds, wrapping — pattern pinned by the baselines
        let size = 128
        var px = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                var v = 0.0
                for (s, w) in [(8, 0.55), (16, 0.3), (32, 0.15)] {
                    let cellW = size / s
                    let gx = x / cellW, gy = y / cellW
                    let fx = Double(x % cellW) / Double(cellW), fy = Double(y % cellW) / Double(cellW)
                    func h(_ a: Int, _ b: Int) -> Double {
                        Double(hash2(31337, ((a % s) + s) % s, ((b % s) + s) % s, UInt32(s))) / 4294967296.0
                    }
                    let v00 = h(gx, gy), v10 = h(gx + 1, gy), v01 = h(gx, gy + 1), v11 = h(gx + 1, gy + 1)
                    let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
                    v += ((v00 * (1 - sx) + v10 * sx) * (1 - sy) + (v01 * (1 - sx) + v11 * sx) * sy) * w
                }
                let on: UInt8 = v > 0.56 ? 255 : 0
                let i = (y * size + x) * 4
                px[i] = on; px[i + 1] = on; px[i + 2] = on; px[i + 3] = 255
            }
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        td.usage = .shaderRead
        cloudTexture = device.makeTexture(descriptor: td)!
        px.withUnsafeBytes { raw in
            cloudTexture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                                 withBytes: raw.baseAddress!, bytesPerRow: size * 4)
        }
    }

    private func buildClouds_sampler() {}

    private func buildStars() {
        let N = 1300
        var data = [Float](repeating: 0, count: N * 4)
        for i in 0..<N {
            let u = Double(hash2(777, i, 0)) / 4294967296.0
            let v = Double(hash2(777, i, 1)) / 4294967296.0
            let theta = u * .pi * 2
            let phi = Foundation.acos(2 * v - 1)
            data[i * 4] = Float(Foundation.sin(phi) * Foundation.cos(theta))
            data[i * 4 + 1] = Float(Foundation.cos(phi))
            data[i * 4 + 2] = Float(Foundation.sin(phi) * Foundation.sin(theta))
            data[i * 4 + 3] = Float(Double(hash2(777, i, 2)) / 4294967296.0)
        }
        starCount = N
        starsBuffer = data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
    }

    private func buildSpriteAtlas() {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2048, height: 512, mipmapped: false)
        td.usage = .shaderRead
        spriteTex = device.makeTexture(descriptor: td)!
    }

    func resize(_ w: Int, _ h: Int) {
        if w == fbWidth && h == fbHeight { return }
        fbWidth = max(1, w)
        fbHeight = max(1, h)
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: fbWidth, height: fbHeight, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]
        cd.storageMode = .private
        sceneColor = device.makeTexture(descriptor: cd)!
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: fbWidth, height: fbHeight, mipmapped: false)
        dd.usage = [.renderTarget, .shaderRead]   // ultra pass reads scene depth
        dd.storageMode = .private
        sceneDepth = device.makeTexture(descriptor: dd)!
        let bw = max(1, fbWidth >> 2), bh = max(1, fbHeight >> 2)
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: bw, height: bh, mipmapped: false)
        bd.usage = [.renderTarget, .shaderRead]
        bd.storageMode = .private
        bloomA = device.makeTexture(descriptor: bd)!
        bloomB = device.makeTexture(descriptor: bd)!
        let uw = max(1, fbWidth >> 1), uh = max(1, fbHeight >> 1)
        let ud = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: uw, height: uh, mipmapped: false)
        ud.usage = [.renderTarget, .shaderRead]
        ud.storageMode = .private
        ultraA = device.makeTexture(descriptor: ud)!
        ultraB = device.makeTexture(descriptor: ud)!
        if ultraDummy == nil {
            let dd1 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
            dd1.usage = .shaderRead
            ultraDummy = device.makeTexture(descriptor: dd1)!
            let px: [UInt16] = [0, 0, 0, 0x3c00]   // (0,0,0,1) half-floats
            px.withUnsafeBytes { raw in
                ultraDummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                                   withBytes: raw.baseAddress!, bytesPerRow: 8)
            }
        }
    }

    // ---- section meshes (GameHost) ----------------------------------------------
    private func releaseSection(_ gpu: SectionGPU) {
        arena.release(gpu.opaque)
        arena.release(gpu.cutout)
        arena.release(gpu.translucent)
    }

    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {
        let key = SectionKey(cx: cx, sy: sy, cz: cz)
        if let old = sections.removeValue(forKey: key) { releaseSection(old) }
        let gpu = SectionGPU(key: key, minY: minY)
        func make(_ layer: MeshLayer) -> MeshBlock? {
            guard layer.count > 0, !layer.idx.isEmpty else { return nil }
            let vbBytes = layer.data.count * 4
            let ibBytes = layer.idx.count * 4
            let (page, offset) = arena.alloc(vbBytes + ibBytes)
            let base = arena.pages[page].contents().advanced(by: offset)
            layer.data.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: vbBytes) }
            layer.idx.withUnsafeBytes { base.advanced(by: vbBytes).copyMemory(from: $0.baseAddress!, byteCount: ibBytes) }
            return MeshBlock(page: page, offset: offset, ibRel: vbBytes,
                             size: (vbBytes + ibBytes + 255) & ~255, indexCount: layer.idx.count)
        }
        gpu.opaque = make(mesh.opaque)
        gpu.cutout = make(mesh.cutout)
        gpu.translucent = make(mesh.translucent)
        if gpu.opaque == nil && gpu.cutout == nil && gpu.translucent == nil { return }
        sections[key] = gpu
    }
    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sectionCount: Int) {
        for sy in 0..<sectionCount {
            if let old = sections.removeValue(forKey: SectionKey(cx: cx, sy: sy, cz: cz)) {
                releaseSection(old)
            }
        }
    }
    func clearAllSections() {
        for gpu in sections.values { releaseSection(gpu) }
        sections.removeAll()
    }

    // ---- sky colors -------------------------------------------------------------
    func skyColors(_ world: World, _ cam: CamState) -> SkyColors {
        var out = SkyColors()
        let info = world.info
        if world.dim == .nether {
            let f = info.fogColor
            out.zenith = SIMD3<Float>(Float(f.0 * 0.55), Float(f.1 * 0.5), Float(f.2 * 0.5))
            out.horizon = SIMD3<Float>(Float(f.0), Float(f.1), Float(f.2))
            out.fog = out.horizon
            return out
        }
        if world.dim == .end {
            out.zenith = SIMD3<Float>(0.03, 0.025, 0.05)
            out.horizon = SIMD3<Float>(0.1, 0.08, 0.13)
            out.fog = SIMD3<Float>(0.07, 0.06, 0.1)
            return out
        }
        let angle = world.sunAngle()
        let sunH = Foundation.cos(angle * .pi * 2)
        let day = min(1.0, max(0.0, sunH * 2 + 0.5))
        let dusk = min(1.0, max(0.0, 1 - abs(sunH) * 3.2))
        let rain = Float(world.rainLevel)
        let dayZen = SIMD3<Float>(0.45, 0.65, 1.0)
        let nightZen = SIMD3<Float>(0.012, 0.015, 0.04)
        let dayHor = SIMD3<Float>(0.74, 0.84, 1.0)
        let nightHor = SIMD3<Float>(0.04, 0.05, 0.1)
        var zenith = nightZen + (dayZen - nightZen) * Float(day)
        var horizon = nightHor + (dayHor - nightHor) * Float(day)
        let grayZ = (zenith.x + zenith.y + zenith.z) / 3
        let grayH = (horizon.x + horizon.y + horizon.z) / 3
        zenith = zenith + (SIMD3<Float>(grayZ * 0.7, grayZ * 0.7, grayZ * 0.75) - zenith) * rain
        horizon = horizon + (SIMD3<Float>(grayH * 0.75, grayH * 0.75, grayH * 0.8) - horizon) * rain
        out.zenith = zenith
        out.horizon = horizon
        out.fog = horizon
        out.dayLight = min(1, max(0.06, day + cam.nightVision))
        out.sunGlow = dusk * (1 - Double(rain))
        return out
    }

    // ---- frame --------------------------------------------------------------------
    /// renders the world into the offscreen scene target, then composites into
    /// `rpd` (the drawable's pass). Returns the open encoder for the UI pass.
    func render(cmd: MTLCommandBuffer, rpd: MTLRenderPassDescriptor,
                game: GameCore, cam: CamState, partial: Double, timeSec: Double) -> MTLRenderCommandEncoder {
        drawCalls = 0
        arena.tick()
        let world = game.world
        let settings = game.settings
        let ultraOn = settings.shader == "ultra"
        let wantShadowSize = ultraOn ? 4096 : 2048
        if shadowSizeNow != wantShadowSize { buildShadow(size: wantShadowSize) }

        let aspect = Float(fbWidth) / Float(max(1, fbHeight))
        let far = max(256, Float(settings.renderDistance) * 16 * 1.6)
        let proj = mat4Perspective(fovYRad: Float(cam.fov * .pi / 180), aspect: aspect, near: 0.05, far: far)
        let dir = SIMD3<Float>(
            Float(Foundation.cos(cam.pitch) * -Foundation.sin(cam.yaw)),
            Float(Foundation.sin(-cam.pitch)),
            Float(Foundation.cos(cam.pitch) * Foundation.cos(cam.yaw)))
        let viewM = mat4LookDir(eye: SIMD3<Float>(0, 0, 0), dir: dir, up: SIMD3<Float>(0, 1, 0))
        let viewProj = proj * viewM
        var frustum = Frustum()
        frustum.setFromMatrix(viewProj)

        let sky = skyColors(world, cam)
        var fogColor = sky.fog
        var fogStart = Float(settings.renderDistance) * 16 * 0.55
        var fogEnd = Float(settings.renderDistance) * 16 * 0.95
        if cam.underwater {
            let wc = BIOMES[world.biomeAt(ifloorD(cam.x), ifloorD(cam.y), ifloorD(cam.z))]?.waterColor ?? 0x3f76e4
            fogColor = SIMD3<Float>(Float((wc >> 16) & 255) / 255 * 0.4, Float((wc >> 8) & 255) / 255 * 0.45, Float(wc & 255) / 255 * 0.6)
            fogStart = 4
            fogEnd = 28 + Float(cam.nightVision) * 40
        } else if cam.underLava {
            fogColor = SIMD3<Float>(0.6, 0.18, 0.04)
            fogStart = 0.2
            fogEnd = 2.2
        } else if cam.powderSnow {
            fogColor = SIMD3<Float>(0.9, 0.95, 0.98)
            fogStart = 0.1
            fogEnd = 2.5
        } else if world.dim == .nether {
            fogStart = min(fogStart, 60)
            fogEnd = min(fogEnd, 128)
        }
        if cam.blindness > 0 {
            let b = Float(cam.blindness)
            fogStart = fogStart + (1 - fogStart) * b
            fogEnd = fogEnd + (6 - fogEnd) * b
            fogColor = SIMD3<Float>(0, 0, 0)
        }

        let angle = world.sunAngle()
        let sunDir = SIMD3<Float>(Float(-Foundation.sin(angle * .pi * 2 + .pi)), Float(Foundation.cos(angle * .pi * 2)), 0.18)
        let shadowOK = settings.shadows && world.dim == .overworld && sky.dayLight > 0.1 && sunDir.y > 0.05

        var shadowMat = matrix_identity_float4x4
        // --- shadow pass ---
        if shadowOK {
            let r: Float = 72
            let lightView = mat4LookDir(eye: sunDir * 120, dir: -sunDir, up: SIMD3<Float>(0, 1, 0))
            let lightProj = mat4Ortho(l: -r, r: r, b: -r, t: r, n: 1, f: 320)
            shadowMat = lightProj * lightView
            // texel snap: pin the shadow grid to the world, not the camera —
            // continuous sub-texel drift while moving reads as edge shimmer
            let worldAnchor = SIMD4<Float>(Float(-cam.x), Float(-cam.y), Float(-cam.z), 1)
            let anchorClip = shadowMat * worldAnchor
            let texel = 2 / Float(shadowSizeNow)
            var snap = matrix_identity_float4x4
            snap.columns.3.x = -anchorClip.x.truncatingRemainder(dividingBy: texel)
            snap.columns.3.y = -anchorClip.y.truncatingRemainder(dividingBy: texel)
            shadowMat = snap * shadowMat
            let spd = MTLRenderPassDescriptor()
            spd.depthAttachment.texture = shadowTexture
            spd.depthAttachment.loadAction = .clear
            spd.depthAttachment.storeAction = .store
            spd.depthAttachment.clearDepth = 1
            let senc = cmd.makeRenderCommandEncoder(descriptor: spd)!
            senc.setRenderPipelineState(shadowPipeline)
            senc.setDepthStencilState(depthWrite)
            senc.setDepthBias(6, slopeScale: 8, clamp: 0.02)
            var su = ChunkSharedU(viewProj: shadowMat, shadowMat: shadowMat,
                                  light: .zero, fog: .zero, fogColor: .zero, misc: .zero)
            senc.setVertexBytes(&su, length: MemoryLayout<ChunkSharedU>.stride, index: 1)
            var boundPage = -1
            for gpu in sections.values {
                guard let buf = gpu.opaque else { continue }
                let ox = Float(Double(gpu.key.cx * 16) - cam.x)
                let oy = Float(Double(gpu.minY + gpu.key.sy * 16) - cam.y)
                let oz = Float(Double(gpu.key.cz * 16) - cam.z)
                if abs(ox + 8) > r + 24 || abs(oz + 8) > r + 24 { continue }
                var origin = SIMD4<Float>(ox, oy, oz, 0)
                senc.setVertexBytes(&origin, length: 16, index: 2)
                if buf.page != boundPage {
                    boundPage = buf.page
                    senc.setVertexBuffer(arena.pages[buf.page], offset: buf.offset, index: 0)
                } else {
                    senc.setVertexBufferOffset(buf.offset, index: 0)
                }
                senc.drawIndexedPrimitives(type: .triangle, indexCount: buf.indexCount, indexType: .uint32,
                                           indexBuffer: arena.pages[buf.page], indexBufferOffset: buf.offset + buf.ibRel)
                drawCalls += 1
            }
            senc.endEncoding()
        }

        // --- main scene pass (offscreen) ---
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneColor
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: Double(fogColor.x), green: Double(fogColor.y), blue: Double(fogColor.z), alpha: 1)
        scenePass.depthAttachment.texture = sceneDepth
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = ultraOn ? .store : .dontCare
        scenePass.depthAttachment.clearDepth = 1
        let enc = cmd.makeRenderCommandEncoder(descriptor: scenePass)!

        // sky dome + celestials + stars
        enc.setDepthStencilState(depthNone)
        if !cam.underwater && !cam.underLava && cam.blindness < 0.5 {
            var skyU = SkyUniforms(
                invViewProj: viewProj.inverse,
                zenith: SIMD4<Float>(sky.zenith, 0),
                horizon: SIMD4<Float>(sky.horizon, 0),
                horizonSun: SIMD4<Float>(1.0, 0.45, 0.18, Float(sky.sunGlow)),
                sunDir: SIMD4<Float>(sunDir, world.dim == .end ? 1 : 0))
            enc.setRenderPipelineState(skyPipeline)
            enc.setVertexBytes(&skyU, length: MemoryLayout<SkyUniforms>.stride, index: 1)
            enc.setFragmentBytes(&skyU, length: MemoryLayout<SkyUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            if world.dim == .overworld {
                let starAlpha = min(1.0, max(0.0, 1 - sky.dayLight * 1.6)) * (1 - world.rainLevel)
                if starAlpha > 0.01 {
                    var stU = StarsUniforms(viewProj: viewProj, params: SIMD4<Float>(Float(timeSec), Float(starAlpha), 0, 0))
                    enc.setRenderPipelineState(starsPipeline)
                    enc.setVertexBuffer(starsBuffer, offset: 0, index: 0)
                    enc.setVertexBytes(&stU, length: MemoryLayout<StarsUniforms>.stride, index: 1)
                    enc.setFragmentBytes(&stU, length: MemoryLayout<StarsUniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)
                }
                if world.rainLevel < 0.95 {
                    enc.setFragmentSamplerState(linearSampler, index: 0)
                    func drawCelestial(_ cdir: SIMD3<Float>, _ size: Float, _ moonPhase: Float, _ tex: MTLTexture?, _ texMode: Float) {
                        enc.setRenderPipelineState(tex != nil ? celestialAddPipeline : celestialPipeline)
                        let up0 = SIMD3<Float>(0, 0, 1)
                        var right = simd_cross(cdir, up0)
                        let rl = simd_length(right)
                        right = rl < 1e-6 ? SIMD3<Float>(1, 0, 0) : right / rl
                        let up2 = simd_cross(right, cdir)
                        var cu = CelestialUniforms(
                            viewProj: viewProj,
                            center: SIMD4<Float>(cdir * 500, size),
                            right: SIMD4<Float>(right, tex != nil ? texMode : 0),
                            up: SIMD4<Float>(up2, moonPhase))
                        enc.setFragmentTexture(tex ?? ultraDummy, index: 0)
                        enc.setVertexBytes(&cu, length: MemoryLayout<CelestialUniforms>.stride, index: 1)
                        enc.setFragmentBytes(&cu, length: MemoryLayout<CelestialUniforms>.stride, index: 1)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    }
                    // vanilla quads are ±30/±20 at distance 100 — the art carries
                    // its own padding+glow, so textured quads are much larger
                    drawCelestial(sunDir, sunTex != nil ? 150 : 55, -1, sunTex, 1)
                    let dayPhase = world.time / 24000 % 8
                    let phase = Float(((Double(dayPhase) / 8) + 0.5).truncatingRemainder(dividingBy: 1))
                    drawCelestial(-sunDir, moonTex != nil ? 100 : 38, phase, moonTex, Float(1 + dayPhase))
                }
            }
        }
        enc.setDepthStencilState(depthWrite)

        // --- chunk passes ---
        var uni = ChunkSharedU(
            viewProj: viewProj,
            shadowMat: shadowMat,
            light: SIMD4<Float>(Float(sky.dayLight), Float(settings.gamma + cam.nightVision * 1.6),
                                Float(Double(world.info.ambientLight) / 15), shadowOK ? 1 : 0),
            fog: SIMD4<Float>(fogStart, fogEnd, 0, 1),
            fogColor: SIMD4<Float>(fogColor, 1),
            misc: SIMD4<Float>(Float(timeSec), packFluidDamp, ultraOn ? 1 : 0, 1 / Float(shadowSizeNow)))
        enc.setFragmentTexture(atlasTexture, index: 0)
        enc.setFragmentTexture(shadowTexture, index: 1)
        enc.setFragmentSamplerState(atlasSampler, index: 0)
        enc.setFragmentSamplerState(shadowSampler, index: 1)

        let rd = Float(settings.renderDistance) * 16
        var visible: [(gpu: SectionGPU, rel: SIMD3<Float>, dist: Float)] = []
        visible.reserveCapacity(sections.count)
        for gpu in sections.values {
            let ox = Float(Double(gpu.key.cx * 16) - cam.x)
            let oy = Float(Double(gpu.minY + gpu.key.sy * 16) - cam.y)
            let oz = Float(Double(gpu.key.cz * 16) - cam.z)
            let dx = ox + 8, dz = oz + 8, dy = oy + 8
            let distSq = dx * dx + dz * dz
            if distSq > (rd + 16) * (rd + 16) { continue }
            if !frustum.intersectsBox(ox, oy, oz, ox + 16, oy + 16, oz + 16) { continue }
            visible.append((gpu, SIMD3<Float>(ox, oy, oz), distSq + dy * dy * 0.25))
        }
        visible.sort { $0.dist < $1.dist }

        func drawLayer(_ pipeline: MTLRenderPipelineState,
                       _ pick: (SectionGPU) -> MeshBlock?,
                       _ list: [(gpu: SectionGPU, rel: SIMD3<Float>, dist: Float)],
                       cull: Bool) {
            enc.setRenderPipelineState(pipeline)
            enc.setCullMode(cull ? .back : .none)
            enc.setVertexBytes(&uni, length: MemoryLayout<ChunkSharedU>.stride, index: 1)
            enc.setFragmentBytes(&uni, length: MemoryLayout<ChunkSharedU>.stride, index: 1)
            var boundPage = -1
            for v in list {
                guard let buf = pick(v.gpu) else { continue }
                var origin = SIMD4<Float>(v.rel, 0)
                enc.setVertexBytes(&origin, length: 16, index: 2)
                if buf.page != boundPage {
                    boundPage = buf.page
                    enc.setVertexBuffer(arena.pages[buf.page], offset: buf.offset, index: 0)
                } else {
                    enc.setVertexBufferOffset(buf.offset, index: 0)
                }
                enc.drawIndexedPrimitives(type: .triangle, indexCount: buf.indexCount, indexType: .uint32,
                                          indexBuffer: arena.pages[buf.page], indexBufferOffset: buf.offset + buf.ibRel)
                drawCalls += 1
            }
        }

        // opaque front-to-back
        uni.fog.z = 0
        uni.fog.w = 1
        drawLayer(opaquePipeline, { $0.opaque }, visible, cull: true)
        // cutout: alpha test, back-cull — the mesher emits explicit two-sided
        // pairs for crosses/vines, and culling kills the coincident interior
        // leaf faces that z-fight (sway-displaced) when both rasterize
        uni.fog.z = 0.35
        drawLayer(cutoutPipeline, { $0.cutout }, visible, cull: true)
        enc.setCullMode(.back)

        // entities + sprites + cubes + crack + selection + particles
        let camPos = SIMD3<Double>(cam.x, cam.y, cam.z)
        drawEntities(enc, game: game, viewProj: viewProj, camPos: camPos, dayLight: sky.dayLight,
                     fog: (fogColor, fogStart, fogEnd), partial: partial, timeSec: timeSec)
        drawSprites(enc, game: game, viewProj: viewProj, camPos: camPos, cam: cam,
                    dayLight: sky.dayLight, fog: (fogColor, fogStart, fogEnd), partial: partial)
        drawCubes(enc, game: game, viewProj: viewProj, camPos: camPos, uni: &uni, partial: partial)
        drawCrack(enc, game: game, camPos: camPos, uni: &uni)
        drawSelection(enc, game: game, viewProj: viewProj, camPos: camPos)
        let pr = SIMD3<Float>(Float(detCos(cam.yaw)), 0, Float(detSin(cam.yaw)))
        let pu = SIMD3<Float>(Float(detSin(cam.yaw) * detSin(cam.pitch)), Float(detCos(cam.pitch)), Float(-detCos(cam.yaw) * detSin(cam.pitch)))
        enc.setDepthStencilState(depthRead)
        particles.render(enc, pipeline: particlePipeline, atlasTex: atlasTexture, sampler: atlasSampler,
                         viewProj: viewProj, camPos: camPos, right: pr, up: pu, dayLight: sky.dayLight)
        enc.setDepthStencilState(depthWrite)

        // translucent back-to-front
        enc.setDepthStencilState(depthRead)
        uni.fog.z = 0
        uni.fog.w = 0.82
        enc.setFragmentTexture(atlasTexture, index: 0)
        enc.setFragmentSamplerState(atlasSampler, index: 0)
        drawLayer(translucentPipeline, { $0.translucent }, visible.reversed(), cull: true)
        uni.fog.w = 1

        // clouds
        if settings.clouds && world.dim == .overworld && !cam.underwater {
            let cy = Float(192.33 - cam.y)
            let scroll = timeSec * 0.0006
            var cu = CloudUniforms(
                viewProj: viewProj,
                offset: SIMD4<Float>(0, cy, 0, 2048),
                scroll: SIMD4<Float>(Float((cam.x / 4096 + scroll).truncatingRemainder(dividingBy: 1)),
                                     Float((cam.z / 4096).truncatingRemainder(dividingBy: 1)),
                                     Float(0.75 + sky.dayLight * 0.25),
                                     fogEnd * 2.5))
            enc.setRenderPipelineState(cloudPipeline)
            enc.setCullMode(.none)
            enc.setVertexBytes(&cu, length: MemoryLayout<CloudUniforms>.stride, index: 1)
            enc.setFragmentBytes(&cu, length: MemoryLayout<CloudUniforms>.stride, index: 1)
            enc.setFragmentTexture(cloudTexture, index: 0)
            enc.setFragmentSamplerState(linearSampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.setCullMode(.back)
        }
        enc.endEncoding()

        func blit(_ target: MTLTexture, _ pipeline: MTLRenderPipelineState, _ src: MTLTexture, dir: SIMD2<Float>?) {
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = target
            pd.colorAttachments[0].loadAction = .dontCare
            pd.colorAttachments[0].storeAction = .store
            let e = cmd.makeRenderCommandEncoder(descriptor: pd)!
            e.setRenderPipelineState(pipeline)
            var u = CompositeUniforms(params: .zero, tint: SIMD4<Float>(dir?.x ?? 0, dir?.y ?? 0, 0, 0))
            e.setFragmentBytes(&u, length: MemoryLayout<CompositeUniforms>.stride, index: 1)
            e.setFragmentTexture(src, index: 0)
            e.setFragmentSamplerState(linearSampler, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        // --- ultra pass: SSAO + volumetric light at half res, then one blur ---
        if ultraOn {
            let upd = MTLRenderPassDescriptor()
            upd.colorAttachments[0].texture = ultraA
            upd.colorAttachments[0].loadAction = .dontCare
            upd.colorAttachments[0].storeAction = .store
            let ue = cmd.makeRenderCommandEncoder(descriptor: upd)!
            ue.setRenderPipelineState(ultraPipeline)
            var uu = UltraUniforms(
                invViewProj: viewProj.inverse,
                viewProj: viewProj,
                shadowMat: shadowMat,
                sunDir: SIMD4<Float>(sunDir, Float(sky.dayLight)),
                params: SIMD4<Float>(Float(timeSec), far,
                                     (shadowOK && !cam.underwater) ? 1 : 0,
                                     cam.underwater ? 1 : 0),
                fogColor: SIMD4<Float>(fogColor, Float(settings.renderDistance * 16)),
                texel: SIMD4<Float>(1 / Float(ultraA.width), 1 / Float(ultraA.height), 0, 0))
            ue.setFragmentBytes(&uu, length: MemoryLayout<UltraUniforms>.stride, index: 1)
            ue.setFragmentTexture(sceneDepth, index: 0)
            ue.setFragmentTexture(shadowTexture, index: 1)
            ue.setFragmentSamplerState(linearSampler, index: 0)
            ue.setFragmentSamplerState(shadowSampler, index: 1)
            ue.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            ue.endEncoding()
            blit(ultraB, ultraBlurPipeline, ultraA, dir: SIMD2<Float>(1 / Float(ultraA.width), 0))
            blit(ultraA, ultraBlurPipeline, ultraB, dir: SIMD2<Float>(0, 1 / Float(ultraA.height)))
        }

        // --- bloom chain ---
        if settings.bloom {
            blit(bloomA, bloomExtractPipeline, sceneColor, dir: nil)
            for _ in 0..<2 {
                blit(bloomB, blurPipeline, bloomA, dir: SIMD2<Float>(1 / Float(bloomA.width), 0))
                blit(bloomA, blurPipeline, bloomB, dir: SIMD2<Float>(0, 1 / Float(bloomA.height)))
            }
        }

        // --- composite into the drawable ---
        let fenc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        fenc.setRenderPipelineState(compositePipeline)
        var tint = SIMD4<Float>(0, 0, 0, 0)
        if cam.underwater { tint = SIMD4<Float>(0.1, 0.2, 0.45, 0.12) }
        if cam.underLava { tint = SIMD4<Float>(0.9, 0.3, 0.05, 0.55) }
        if cam.powderSnow { tint = SIMD4<Float>(0.95, 0.97, 1.0, 0.5) }
        var compU = CompositeUniforms(
            params: SIMD4<Float>(settings.bloom ? 0.55 : 0,
                                 settings.reduceMotion ? 0 : Float(cam.portalWarp),
                                 Float(timeSec), Float(cam.darkness)),
            tint: tint,
            params2: SIMD4<Float>(ultraOn ? 1 : 0, 0.85, 1.0, 0))
        fenc.setFragmentBytes(&compU, length: MemoryLayout<CompositeUniforms>.stride, index: 1)
        fenc.setFragmentTexture(sceneColor, index: 0)
        fenc.setFragmentTexture(settings.bloom ? bloomA : sceneColor, index: 1)
        fenc.setFragmentTexture(ultraOn ? ultraA : ultraDummy, index: 2)
        fenc.setFragmentSamplerState(linearSampler, index: 0)
        fenc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        // pending capture: grab the composited drawable (ultra/bloom/ACES applied,
        // no UI), then reopen the pass for the UI overlay
        if pendingCapture != nil, let drawableTex = rpd.colorAttachments[0].texture,
           !drawableTex.isFramebufferOnly {
            fenc.endEncoding()
            encodeCapture(cmd, from: drawableTex)
            rpd.colorAttachments[0].loadAction = .load
            return cmd.makeRenderCommandEncoder(descriptor: rpd)!
        }
        return fenc
    }

    /// title-screen frame: in-game photo background (aspect-fill), or a clear
    func renderTitle(cmd: MTLCommandBuffer, rpd: MTLRenderPassDescriptor) -> MTLRenderCommandEncoder {
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)
        rpd.colorAttachments[0].loadAction = .clear
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        if let tex = titleBgTex, let target = rpd.colorAttachments[0].texture {
            let sA = Double(target.width) / Double(target.height)
            let tA = Double(tex.width) / Double(tex.height)
            var tu: SIMD4<Float>
            if tA > sA {   // photo wider than screen: crop sides
                let f = Float(sA / tA)
                tu = SIMD4<Float>(f, 1, (1 - f) / 2, 0)
            } else {       // crop top/bottom
                let f = Float(tA / sA)
                tu = SIMD4<Float>(1, f, 0, (1 - f) / 2)
            }
            enc.setRenderPipelineState(titlePipeline)
            enc.setFragmentBytes(&tu, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(linearSampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if let logo = titleLogoTex, let target = rpd.colorAttachments[0].texture {
            // mirror the UI auto scale so the wordmark sits where the text logo did
            let pw = Double(target.width), ph = Double(target.height)
            let scale = max(1.0, min((pw / 380).rounded(.down), (ph / 240).rounded(.down)))
            let gw = pw / scale, gh = ph / scale
            let logoH = 52.0
            let logoW = logoH * Double(logo.width) / Double(logo.height)
            let cx = gw / 2, top = gh / 4 - 34
            // GUI units → NDC (y flipped)
            func ndcX(_ x: Double) -> Float { Float(x / gw * 2 - 1) }
            func ndcY(_ y: Double) -> Float { Float(1 - y / gh * 2) }
            var lu = SIMD4<Float>(ndcX(cx - logoW / 2), ndcY(top + logoH), ndcX(cx + logoW / 2), ndcY(top))
            enc.setRenderPipelineState(logoPipeline)
            enc.setVertexBytes(&lu, length: 16, index: 1)
            enc.setFragmentTexture(logo, index: 0)
            enc.setFragmentSamplerState(linearSampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        return enc
    }

    // ---- entity drawing  -----------------------------------
    private func modelNameFor(_ ent: Entity) -> String? {
        let type = ent.type
        // data-driven skin variants (dyed sheep wool, villager professions)
        if type == "sheep", let c = ent.data.color, c > 0, !(ent.data.sheared ?? false),
           hasModel("sheep_\(c)") {
            return "sheep_\(c)"
        }
        if type == "villager", let prof = (ent as? Villager)?.profession, prof != "none",
           hasModel("villager_\(prof)") {
            return "villager_\(prof)"
        }
        if hasModel(type) { return type }
        if type == "arrow" || type == "trident" { return "arrow_model" }
        if type == "end_crystal" { return "end_crystal_model" }
        if type == "boat" { return "boat_model" }
        if type == "minecart" { return "minecart_model" }
        return nil
    }

    private func drawEntities(_ enc: MTLRenderCommandEncoder, game: GameCore, viewProj: simd_float4x4,
                              camPos: SIMD3<Double>, dayLight: Double,
                              fog: (SIMD3<Float>, Float, Float), partial: Double, timeSec: Double) {
        let w = game.world
        let maxD = game.settings.entityDistance * game.settings.entityDistance
        for e in w.entities {
            if e.dead { continue }
            guard let ent = e as? Entity else { continue }
            if ent.type == "player" && game.perspective == 0 { continue }
            let dx = ent.x - camPos.x, dz = ent.z - camPos.z
            if dx * dx + dz * dz > maxD { continue }
            guard let name = modelNameFor(ent) else { continue }
            let liv = ent as? LivingEntity
            let ix = ent.prevX + (ent.x - ent.prevX) * partial
            let iy = ent.prevY + (ent.y - ent.prevY) * partial
            let iz = ent.prevZ + (ent.z - ent.prevZ) * partial
            let yaw = ent.prevYaw + wrapAngleD(ent.yaw - ent.prevYaw) * partial
            let bx = ifloorD(ent.x), by = ifloorD(ent.y + ent.height * 0.5), bz = ifloorD(ent.z)
            let deathFlip = (liv?.deathTime ?? 0) > 0 ? min(1.0, Double(liv!.deathTime) / 20) : 0
            var pose = EntityPose()
            pose.x = ix; pose.y = iy; pose.z = iz
            pose.yaw = yaw
            pose.headYaw = liv != nil ? wrapAngleD(liv!.headYaw - yaw) : 0
            pose.pitch = ent.pitch
            pose.limbSwing = liv?.limbSwing ?? 0
            pose.limbAmp = liv?.limbAmp ?? 0
            pose.attackSwing = liv?.attackAnim ?? 0
            pose.hurtFlash = (liv?.hurtTime ?? 0) > 0 ? Double(liv!.hurtTime) / 10 : deathFlip * 0.6
            pose.scale = 1
            pose.baby = ent.data.baby ?? false
            pose.sky = w.getSkyLight(bx, by, bz)
            pose.block = w.getBlockLight(bx, by, bz)
            pose.ageTicks = ent.age
            pose.airborne = !ent.onGround
            pose.aiming = (ent as? Mob)?.target != nil
            pose.crossed = pose.aiming
            pose.grazing = ent.data.grazing ?? false
            pose.sitting = (ent as? Mob)?.sitting ?? false
            pose.open = (ent as? Shulker)?.peekAmount ?? 0
            pose.hanging = ent.type == "bat" && ent.onGround
            pose.alpha = deathFlip > 0 ? 1 - deathFlip * 0.6 : 1
            enc.setDepthStencilState(depthWrite)
            entityRenderer.draw(enc, pipeline: packTargets ? entityPipelineHDR : entityPipeline, sampler: atlasSampler,
                                viewProj: viewProj, camPos: camPos, name: name, p: pose,
                                time: timeSec, dayLight: dayLight,
                                fog: (fog.0, fog.1, fog.2),
                                gamma: game.settings.gamma, ambient: Double(w.info.ambientLight) / 15)
            // end crystal beams + lightning via line overlay
            if let c = ent as? EndCrystal, let bt = c.beamTarget {
                drawBoxOutline(enc, viewProj, [(
                    ix - camPos.x, iy + 1 - camPos.y, iz - camPos.z,
                    Double(bt.0) - camPos.x, Double(bt.1) - camPos.y, Double(bt.2) - camPos.z)],
                    asLines: true, color: SIMD4<Float>(1, 0.4, 0.9, 0.8))
            }
            if ent.type == "lightning" {
                let h = 40.0
                for seg in 0..<3 {
                    let ox = Double(hash2(UInt32(bitPattern: Int32(truncatingIfNeeded: ent.id)), seg, ent.age >> 1) % 100) / 100 - 0.5
                    drawBoxOutline(enc, viewProj, [(
                        ix + ox - 0.1 - camPos.x, iy - camPos.y, iz + ox - 0.1 - camPos.z,
                        ix + ox + 0.1 - camPos.x, iy + h - camPos.y, iz + ox + 0.1 - camPos.z)],
                        asLines: false, color: SIMD4<Float>(1, 1, 1, 0.9))
                }
            }
        }
    }

    // ---- item / projectile billboards ------------------------------------------
    private func spriteSlot(_ stack: ItemStack) -> Int {
        let key = "\(stack.id)|\(stack.data.potion ?? "")"
        if let slot = spriteSlots[key] { return slot }
        let slot = spriteSlots.count
        if slot >= 128 * 32 { return 0 }
        spriteSlots[key] = slot
        let px = itemIconPixels(stack.id, stack.data)
        let sx = (slot % 128) * 16, sy = (slot / 128) * 16
        px.withUnsafeBytes { raw in
            spriteTex.replace(region: MTLRegionMake2D(sx, sy, 16, 16), mipmapLevel: 0,
                              withBytes: raw.baseAddress!, bytesPerRow: 16 * 4)
        }
        return slot
    }

    private func drawSprites(_ enc: MTLRenderCommandEncoder, game: GameCore, viewProj: simd_float4x4,
                             camPos: SIMD3<Double>, cam: CamState, dayLight: Double,
                             fog: (SIMD3<Float>, Float, Float), partial: Double) {
        let w = game.world
        let spriteMap: [String: String] = [
            "snowball": "snowball", "egg": "egg", "ender_pearl": "ender_pearl", "xp_bottle": "experience_bottle",
            "thrown_potion": "splash_potion", "firework": "firework_rocket", "eye_of_ender": "ender_eye",
            "fishing_bobber": "string", "wither_skull": "wither_skeleton_skull_item", "dragon_fireball": "fire_charge",
            "fireball": "fire_charge", "shulker_bullet": "shulker_shell", "llama_spit": "snowball",
        ]
        var items: [(x: Double, y: Double, z: Double, slot: Int, size: Double, bob: Double, light: Double, emissive: Double)] = []
        for e in w.entities {
            if e.dead { continue }
            guard let ent = e as? Entity else { continue }
            var stack: ItemStack? = nil
            var size = 0.45
            var emissive = 0.0
            if ent.type == "item" {
                stack = (ent as? ItemEntity)?.stack
            } else if ent.type == "xp_orb" {
                stack = ItemStack(iid("experience_bottle"), 1)
                size = 0.3
                emissive = 1
            } else if SPRITE_TYPES.contains(ent.type) {
                let id = iidOpt(spriteMap[ent.type] ?? "snowball") ?? iid("snowball")
                stack = ItemStack(id, 1)
                size = 0.35
                if ent.type == "fireball" || ent.type == "dragon_fireball" || ent.type == "wither_skull" { emissive = 1 }
            }
            guard let stack else { continue }
            let dx = ent.x - camPos.x, dz = ent.z - camPos.z
            if dx * dx + dz * dz > 64 * 64 { continue }
            let ix = ent.prevX + (ent.x - ent.prevX) * partial
            let iy = ent.prevY + (ent.y - ent.prevY) * partial
            let iz = ent.prevZ + (ent.z - ent.prevZ) * partial
            let bx = ifloorD(ent.x), by = ifloorD(ent.y + 0.3), bz = ifloorD(ent.z)
            let sky = max(0, Double(w.getSkyLight(bx, by, bz)) - w.skyDarken())
            let light = max(Double(w.info.ambientLight),
                            max(sky * dayLight * 15 / max(1, 15 - w.skyDarken()), Double(w.getBlockLight(bx, by, bz))))
            items.append((ix, iy, iz, spriteSlot(stack), size,
                          ent.type == "item" ? detSin((Double(ent.age) + partial) * 0.08) * 0.08 + 0.12 : 0,
                          min(1, max(0.12, light / 15)), emissive))
        }
        if items.isEmpty { return }
        enc.setRenderPipelineState(packTargets ? spritePipelineHDR : spritePipeline)
        enc.setDepthStencilState(depthWrite)
        enc.setFragmentTexture(spriteTex, index: 0)
        enc.setFragmentSamplerState(atlasSampler, index: 0)
        let rx = Float(detCos(cam.yaw)), rz = Float(detSin(cam.yaw))
        for it in items {
            let u0 = Float((it.slot % 128) * 16) / 2048
            let v0 = Float((it.slot / 128) * 16) / 512
            var u = SpriteUniforms(
                viewProj: viewProj,
                center: SIMD4<Float>(Float(it.x - camPos.x), Float(it.y + it.bob - camPos.y), Float(it.z - camPos.z), Float(it.size)),
                right: SIMD4<Float>(rx, 0, rz, 0),
                uvRect: SIMD4<Float>(u0, v0, u0 + 16 / 2048, v0 + 16 / 512),
                light: SIMD4<Float>(Float(it.emissive > 0 ? 1 : it.light * (0.35 + dayLight * 0.65) + 0.08), fog.1, fog.2, 0),
                fogColor: SIMD4<Float>(fog.0, 1))
            enc.setVertexBytes(&u, length: MemoryLayout<SpriteUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<SpriteUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    // ---- textured cubes (falling blocks, TNT, crystal base) ----------------------
    private func packCube(_ out: inout [Float], _ outIdx: inout [UInt32],
                          _ x0: Float, _ y0: Float, _ z0: Float, _ x1: Float, _ y1: Float, _ z1: Float,
                          _ blockCell: Int, _ sky: Int, _ blk: Int, _ flash: Bool) {
        let id = blockCell >> 4
        let meta = blockCell & 15
        let def = blockDefs[id]
        func tileOf(_ face: Int) -> Int {
            def.texFn?(meta, face) ?? (def.tex.isEmpty ? 0 : Int(def.tex[face]))
        }
        func u32(_ layer: Int, _ normal: Int) -> UInt32 {
            UInt32((layer & 4095) | (normal << 12) | (3 << 15) | ((sky & 15) << 17) | ((blk & 15) << 21) | ((flash ? 1 : 0) << 25))
        }
        let Bv: UInt32 = 0xffffff
        let faces: [(Int, [[Float]])] = [
            (0, [[x0, y0, z1], [x1, y0, z1], [x1, y0, z0], [x0, y0, z0]]),
            (1, [[x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1]]),
            (2, [[x1, y0, z0], [x1, y1, z0], [x0, y1, z0], [x0, y0, z0]]),
            (3, [[x0, y0, z1], [x0, y1, z1], [x1, y1, z1], [x1, y0, z1]]),
            (4, [[x0, y0, z0], [x0, y1, z0], [x0, y1, z1], [x0, y0, z1]]),
            (5, [[x1, y0, z1], [x1, y1, z1], [x1, y1, z0], [x1, y0, z0]]),
        ]
        let uvs: [[Float]] = [[0, 1], [1, 1], [1, 0], [0, 0]]
        for (face, corners) in faces {
            let layer = tileOf(face)
            let base = UInt32(out.count / 7)
            for i in 0..<4 {
                let c = corners[i]
                out.append(contentsOf: [c[0], c[1], c[2], uvs[i][0], uvs[i][1],
                                        Float(bitPattern: u32(layer, face)), Float(bitPattern: Bv)])
            }
            outIdx.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
        }
    }

    private func drawCubes(_ enc: MTLRenderCommandEncoder, game: GameCore, viewProj: simd_float4x4,
                           camPos: SIMD3<Double>, uni: inout ChunkSharedU, partial: Double) {
        let w = game.world
        var verts: [Float] = []
        var idx: [UInt32] = []
        for e in w.entities {
            if e.dead { continue }
            guard let ent = e as? Entity else { continue }
            var blockCell = 0
            var flash = false
            if let fb = ent as? FallingBlockEntity {
                blockCell = fb.blockCell
            } else if let tnt = ent as? TNTEntity {
                blockCell = Int(cell(B.tnt))
                flash = (Double(tnt.fuse) / 5).truncatingRemainder(dividingBy: 2) < 1
            } else {
                continue
            }
            let dx = ent.x - camPos.x, dz = ent.z - camPos.z
            if dx * dx + dz * dz > 96 * 96 { continue }
            let ix = Float(ent.prevX + (ent.x - ent.prevX) * partial - camPos.x)
            let iy = Float(ent.prevY + (ent.y - ent.prevY) * partial - camPos.y)
            let iz = Float(ent.prevZ + (ent.z - ent.prevZ) * partial - camPos.z)
            let bx = ifloorD(ent.x), by = ifloorD(ent.y + 0.5), bz = ifloorD(ent.z)
            let half: Float = 0.49
            let fuse = (ent as? TNTEntity)?.fuse ?? 0
            packCube(&verts, &idx, ix - half, iy, iz - half, ix + half, iy + half * 2, iz + half,
                     blockCell, w.getSkyLight(bx, by, bz),
                     max(w.getBlockLight(bx, by, bz), flash ? 15 : 0),
                     flash && fuse % 10 < 5)
        }
        guard !idx.isEmpty else { return }
        let vb = verts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        let ib = idx.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        cubeMesh = (vb, ib, idx.count)
        uni.fog.z = 0.1
        var origin = SIMD4<Float>(0, 0, 0, 0)
        enc.setRenderPipelineState(opaquePipeline)
        enc.setDepthStencilState(depthWrite)
        enc.setVertexBytes(&uni, length: MemoryLayout<ChunkSharedU>.stride, index: 1)
        enc.setFragmentBytes(&uni, length: MemoryLayout<ChunkSharedU>.stride, index: 1)
        enc.setVertexBytes(&origin, length: 16, index: 2)
        enc.setFragmentTexture(atlasTexture, index: 0)
        enc.setFragmentTexture(shadowTexture, index: 1)
        enc.setFragmentSamplerState(atlasSampler, index: 0)
        enc.setFragmentSamplerState(shadowSampler, index: 1)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: idx.count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
        uni.fog.z = 0
    }

    // ---- breaking crack overlay ----------------------------------------------------
    private func drawCrack(_ enc: MTLRenderCommandEncoder, game: GameCore, camPos: SIMD3<Double>, uni: inout ChunkSharedU) {
        guard let p = game.player else { return }
        if p.breakingProgress < 0 || p.gameMode == GameMode.creative {
            overlayMesh = nil
            overlayStage = -1
            return
        }
        let stage = min(9, max(0, Int(p.breakingProgress * 10)))
        // crack follows the block's actual outline shape (slab/stairs/torch…)
        let w = game.world
        let cell = w.getBlock(p.breakingX, p.breakingY, p.breakingZ)
        let key = stage &+ (cell &* 16) &+ (p.breakingX &* 1_000_003) &+ (p.breakingY &* 7919) &+ (p.breakingZ &* 31)
        if key != overlayStage || overlayMesh == nil {
            overlayStage = key
            var scratch: [AABB] = []
            shapeBoxes(cell, { dx, dy, dz in w.getBlock(p.breakingX + dx, p.breakingY + dy, p.breakingZ + dz) }, &scratch, false)
            if scratch.isEmpty { scratch = [AABB(0, 0, 0, 1, 1, 1)] }
            var verts: [Float] = []
            var idx: [UInt32] = []
            let layer = tileId("destroy_\(stage)")
            let g: Float = 0.004
            let A = UInt32((layer & 4095) | (3 << 15) | (15 << 17) | (15 << 21))
            let uvs: [[Float]] = [[0, 1], [1, 1], [1, 0], [0, 0]]
            for b in scratch {
                let x0 = Float(b.x0) - g, y0 = Float(b.y0) - g, z0 = Float(b.z0) - g
                let x1 = Float(b.x1) + g, y1 = Float(b.y1) + g, z1 = Float(b.z1) + g
                let faces: [[[Float]]] = [
                    [[x0, y0, z1], [x1, y0, z1], [x1, y0, z0], [x0, y0, z0]],
                    [[x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1]],
                    [[x1, y0, z0], [x1, y1, z0], [x0, y1, z0], [x0, y0, z0]],
                    [[x0, y0, z1], [x0, y1, z1], [x1, y1, z1], [x1, y0, z1]],
                    [[x0, y0, z0], [x0, y1, z0], [x0, y1, z1], [x0, y0, z1]],
                    [[x1, y0, z1], [x1, y1, z1], [x1, y1, z0], [x1, y0, z0]],
                ]
                for fi in 0..<6 {
                    let base = UInt32(verts.count / 7)
                    for i in 0..<4 {
                        let c = faces[fi][i]
                        verts.append(contentsOf: [c[0], c[1], c[2], uvs[i][0], uvs[i][1],
                                                  Float(bitPattern: A | UInt32(fi << 12)), Float(bitPattern: 0xffffff)])
                    }
                    idx.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
                }
            }
            let vb = verts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
            let ib = idx.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
            overlayMesh = (vb, ib, idx.count)
        }
        guard let mesh = overlayMesh else { return }
        uni.fog.z = 0.05
        var origin = SIMD4<Float>(Float(Double(p.breakingX) - camPos.x), Float(Double(p.breakingY) - camPos.y),
                                  Float(Double(p.breakingZ) - camPos.z), 0)
        enc.setRenderPipelineState(translucentPipeline)
        enc.setDepthStencilState(depthRead)
        enc.setVertexBytes(&uni, length: MemoryLayout<ChunkSharedU>.stride, index: 1)
        enc.setFragmentBytes(&uni, length: MemoryLayout<ChunkSharedU>.stride, index: 1)
        enc.setVertexBytes(&origin, length: 16, index: 2)
        enc.setFragmentTexture(atlasTexture, index: 0)
        enc.setFragmentSamplerState(atlasSampler, index: 0)
        enc.setVertexBuffer(mesh.vb, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.ib, indexBufferOffset: 0)
        enc.setDepthStencilState(depthWrite)
        uni.fog.z = 0
    }

    // ---- selection / template-placement outlines ----------------------------------
    private struct TemplatePreviewBlockKey: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    private func drawTemplatePlacementPreview(_ enc: MTLRenderCommandEncoder,
                                              session: TemplatePlacementSession,
                                              target: TemplatePlacementTarget,
                                              viewProj: simd_float4x4,
                                              camPos: SIMD3<Double>) {
        let template = session.rotatedTemplate
        var occupied = Set<TemplatePreviewBlockKey>()
        occupied.reserveCapacity(template.blocks.count)
        for block in template.blocks {
            occupied.insert(TemplatePreviewBlockKey(x: block.dx, y: block.dy, z: block.dz))
        }
        let neighbors = [
            TemplatePreviewBlockKey(x: 1, y: 0, z: 0), TemplatePreviewBlockKey(x: -1, y: 0, z: 0),
            TemplatePreviewBlockKey(x: 0, y: 1, z: 0), TemplatePreviewBlockKey(x: 0, y: -1, z: 0),
            TemplatePreviewBlockKey(x: 0, y: 0, z: 1), TemplatePreviewBlockKey(x: 0, y: 0, z: -1),
        ]
        var boxes: [(Double, Double, Double, Double, Double, Double)] = []
        boxes.reserveCapacity(min(template.blocks.count, OBJECT_TEMPLATE_PREVIEW_MAX_BLOCKS))
        for block in template.blocks {
            let key = TemplatePreviewBlockKey(x: block.dx, y: block.dy, z: block.dz)
            let isSurface = neighbors.contains { delta in
                !occupied.contains(TemplatePreviewBlockKey(x: key.x + delta.x, y: key.y + delta.y, z: key.z + delta.z))
            }
            if !isSurface && template.blocks.count > OBJECT_TEMPLATE_PREVIEW_MAX_BLOCKS {
                continue
            }
            let x = Double(target.originX + block.dx) - camPos.x
            let y = Double(target.originY + block.dy) - camPos.y
            let z = Double(target.originZ + block.dz) - camPos.z
            boxes.append((x - 0.01, y - 0.01, z - 0.01, x + 1.01, y + 1.01, z + 1.01))
            if boxes.count >= OBJECT_TEMPLATE_PREVIEW_MAX_BLOCKS { break }
        }
        if boxes.isEmpty, let block = template.blocks.first {
            let x = Double(target.originX + block.dx) - camPos.x
            let y = Double(target.originY + block.dy) - camPos.y
            let z = Double(target.originZ + block.dz) - camPos.z
            boxes.append((x - 0.01, y - 0.01, z - 0.01, x + 1.01, y + 1.01, z + 1.01))
        }
        if !boxes.isEmpty {
            drawBoxOutline(enc, viewProj, boxes, asLines: false, color: SIMD4<Float>(0.08, 0.88, 1.0, 0.78))
        }
        let x0 = Double(target.originX) - camPos.x - 0.03
        let y0 = Double(target.originY) - camPos.y - 0.03
        let z0 = Double(target.originZ) - camPos.z - 0.03
        let x1 = Double(target.originX + template.sizeX) - camPos.x + 0.03
        let y1 = Double(target.originY + template.sizeY) - camPos.y + 0.03
        let z1 = Double(target.originZ + template.sizeZ) - camPos.z + 0.03
        drawBoxOutline(enc, viewProj, [(x0, y0, z0, x1, y1, z1)],
                       asLines: false, color: SIMD4<Float>(1.0, 0.82, 0.18, 0.95))
    }

    private func drawSelection(_ enc: MTLRenderCommandEncoder, game: GameCore, viewProj: simd_float4x4, camPos: SIMD3<Double>) {
        guard let p = game.player else { return }
        if (game.host?.hasScreen() ?? false) || p.deathTime > 0 {
            game.targetedBlock = nil
            return
        }
        if let session = game.templatePlacement, let target = game.templatePlacementTarget() {
            game.targetedBlock = nil
            game.lastCursorHit = nil
            drawTemplatePlacementPreview(enc, session: session, target: target, viewProj: viewProj, camPos: camPos)
            return
        }
        guard let hit = game.crosshairBlock() else {
            game.targetedBlock = nil
            game.lastCursorHit = nil
            return
        }
        game.targetedBlock = (hit.x, hit.y, hit.z, hit.cell)
        game.lastCursorHit = hit
        let w = game.world
        var scratch: [AABB] = []
        shapeBoxes(hit.cell, { dx, dy, dz in w.getBlock(hit.x + dx, hit.y + dy, hit.z + dz) }, &scratch, false)
        var boxes: [(Double, Double, Double, Double, Double, Double)] = []
        for b in scratch {
            boxes.append((
                b.x0 + Double(hit.x) - camPos.x - 0.002, b.y0 + Double(hit.y) - camPos.y - 0.002, b.z0 + Double(hit.z) - camPos.z - 0.002,
                b.x1 + Double(hit.x) - camPos.x + 0.002, b.y1 + Double(hit.y) - camPos.y + 0.002, b.z1 + Double(hit.z) - camPos.z + 0.002))
        }
        if !boxes.isEmpty {
            drawBoxOutline(enc, viewProj, boxes, asLines: false, color: SIMD4<Float>(0.05, 0.05, 0.05, 0.55))
        }
    }

    /// wireframe boxes (12 edges) or a single straight segment (asLines)
    func drawBoxOutline(_ enc: MTLRenderCommandEncoder, _ viewProj: simd_float4x4,
                        _ boxes: [(Double, Double, Double, Double, Double, Double)],
                        asLines: Bool, color: SIMD4<Float>) {
        var verts: [Float] = []
        for (x0, y0, z0, x1, y1, z1) in boxes {
            if asLines {
                verts.append(contentsOf: [Float(x0), Float(y0), Float(z0), Float(x1), Float(y1), Float(z1)])
                continue
            }
            let X0 = Float(x0), Y0 = Float(y0), Z0 = Float(z0), X1 = Float(x1), Y1 = Float(y1), Z1 = Float(z1)
            let edges: [[Float]] = [
                [X0, Y0, Z0, X1, Y0, Z0], [X1, Y0, Z0, X1, Y0, Z1], [X1, Y0, Z1, X0, Y0, Z1], [X0, Y0, Z1, X0, Y0, Z0],
                [X0, Y1, Z0, X1, Y1, Z0], [X1, Y1, Z0, X1, Y1, Z1], [X1, Y1, Z1, X0, Y1, Z1], [X0, Y1, Z1, X0, Y1, Z0],
                [X0, Y0, Z0, X0, Y1, Z0], [X1, Y0, Z0, X1, Y1, Z0], [X1, Y0, Z1, X1, Y1, Z1], [X0, Y0, Z1, X0, Y1, Z1],
            ]
            for e in edges { verts.append(contentsOf: e) }
        }
        guard !verts.isEmpty else { return }
        var u = LineUniforms(viewProj: viewProj, color: color)
        enc.setRenderPipelineState(linePipeline)
        enc.setDepthStencilState(depthRead)
        verts.withUnsafeBytes { raw in
            enc.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        enc.setVertexBytes(&u, length: MemoryLayout<LineUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<LineUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: verts.count / 3)
        enc.setDepthStencilState(depthWrite)
    }
}

@inline(__always) func wrapAngleD(_ a: Double) -> Double {
    var a = a
    while a > .pi { a -= .pi * 2 }
    while a < -.pi { a += .pi * 2 }
    return a
}
