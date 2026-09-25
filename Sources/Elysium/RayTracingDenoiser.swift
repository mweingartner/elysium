// Native neural denoising is optional: the world path tracer keeps its
// albedo-aware temporal/spatial fallback on macOS 14/15 or unsupported GPUs.
import Metal
import MetalFX
import simd

final class RayTracingDenoiser {
    private let implementation: RayTracingDenoisingBackend
    var status: String { implementation.status }

    init?(device: MTLDevice) {
        guard #available(macOS 26.0, *),
              MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device),
              let native = NativeRayTracingDenoiser(device: device) else { return nil }
        implementation = native
    }

    /// Guides are noise-free primary material values. Color is linear HDR;
    /// depth is ordinary Metal 0...1; normals are signed world-space XYZ;
    /// motion.xy is the existing absolute previous-frame UV, motion.w validity;
    /// diffuseAlbedo.a carries linear material roughness. No primary-ray jitter
    /// is used, so both jitter offsets are zero.
    func encode(command: MTLCommandBuffer, color: MTLTexture, depth: MTLTexture,
                motion: MTLTexture, normals: MTLTexture, diffuseAlbedo: MTLTexture,
                specularAlbedo: MTLTexture, worldToView: simd_float4x4,
                viewToClip: simd_float4x4, reset: Bool) -> MTLTexture? {
        implementation.encode(command: command, color: color, depth: depth, motion: motion,
            normals: normals, diffuseAlbedo: diffuseAlbedo, specularAlbedo: specularAlbedo,
            worldToView: worldToView, viewToClip: viewToClip, reset: reset)
    }

    func reset() { implementation.reset() }
}

private protocol RayTracingDenoisingBackend: AnyObject {
    var status: String { get }
    func reset()
    func encode(command: MTLCommandBuffer, color: MTLTexture, depth: MTLTexture,
                motion: MTLTexture, normals: MTLTexture, diffuseAlbedo: MTLTexture,
                specularAlbedo: MTLTexture, worldToView: simd_float4x4,
                viewToClip: simd_float4x4, reset: Bool) -> MTLTexture?
}

@available(macOS 26.0, *)
private final class NativeRayTracingDenoiser: RayTracingDenoisingBackend {
    private let device: MTLDevice
    private let guidePipeline: MTLComputePipelineState
    private let exposure: MTLTexture
    private var state: State?
    private var failedSize: SIMD2<Int>?
    private var needsReset = true
    private(set) var status = "MetalFX neural denoising"

    private final class State {
        let scaler: MTLFXTemporalDenoisedScaler
        let motion: MTLTexture
        let roughness: MTLTexture
        let reactive: MTLTexture
        let output: MTLTexture
        init(scaler: MTLFXTemporalDenoisedScaler, motion: MTLTexture,
             roughness: MTLTexture, reactive: MTLTexture, output: MTLTexture) {
            self.scaler = scaler
            self.motion = motion
            self.roughness = roughness
            self.reactive = reactive
            self.output = output
        }
    }

    init?(device: MTLDevice) {
        self.device = device
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        guard let library = try? device.makeLibrary(source: Self.guideSource, options: options),
              let function = library.makeFunction(name: "ely_rt_denoising_guides"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        guidePipeline = pipeline
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
            width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let exposure = device.makeTexture(descriptor: descriptor) else { return nil }
        var one = Float16(1)
        exposure.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                         withBytes: &one, bytesPerRow: MemoryLayout<Float16>.stride)
        exposure.label = "RT denoiser fixed exposure hint"
        self.exposure = exposure
    }

    func reset() { needsReset = true }

    private func configure(width: Int, height: Int) -> State? {
        if let state, state.output.width == width, state.output.height == height { return state }
        let size = SIMD2(width, height)
        guard failedSize != size, width > 0, height > 0,
              width <= 4096, height <= 4096, width * height <= 4_194_304 else { return nil }
        // Never upscale pixel art here. MetalFX also supports the 1:1 case,
        // which removes ray noise without changing authored texture resolution.
        let descriptor = MTLFXTemporalDenoisedScalerDescriptor()
        descriptor.inputWidth = width
        descriptor.inputHeight = height
        descriptor.outputWidth = width
        descriptor.outputHeight = height
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.depthTextureFormat = .r32Float
        descriptor.motionTextureFormat = .rg16Float
        descriptor.diffuseAlbedoTextureFormat = .rgba16Float
        descriptor.specularAlbedoTextureFormat = .rgba16Float
        descriptor.normalTextureFormat = .rgba16Float
        descriptor.roughnessTextureFormat = .r16Float
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.isAutoExposureEnabled = false
        descriptor.isReactiveMaskTextureEnabled = true
        descriptor.reactiveMaskTextureFormat = .r8Unorm
        descriptor.requiresSynchronousInitialization = true
        guard let scaler = descriptor.makeTemporalDenoisedScaler(device: device) else {
            failedSize = size
            status = "MetalFX unavailable at this render size; using native filter"
            return nil
        }
        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage, _ name: String) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = usage.union([.shaderRead, .shaderWrite])
            let texture = device.makeTexture(descriptor: descriptor)
            texture?.label = name
            return texture
        }
        // Reactive-mask input is shader-read on macOS 26 as well as 27; do not
        // reference the renamed macOS 27 property and break older deployment.
        guard let motion = texture(.rg16Float, scaler.motionTextureUsage, "RT denoiser motion offsets"),
              let roughness = texture(.r16Float, scaler.roughnessTextureUsage, "RT denoiser roughness"),
              let reactive = texture(.r8Unorm, .shaderRead, "RT denoiser disocclusion mask"),
              let output = texture(.rgba16Float, scaler.outputTextureUsage, "RT neural denoised HDR") else {
            failedSize = size
            status = "MetalFX allocation unavailable; using native filter"
            return nil
        }
        let replacement = State(scaler: scaler, motion: motion, roughness: roughness,
                                reactive: reactive, output: output)
        state = replacement
        failedSize = nil
        needsReset = true
        return replacement
    }

    func encode(command: MTLCommandBuffer, color: MTLTexture, depth: MTLTexture,
                motion: MTLTexture, normals: MTLTexture, diffuseAlbedo: MTLTexture,
                specularAlbedo: MTLTexture, worldToView: simd_float4x4,
                viewToClip: simd_float4x4, reset: Bool) -> MTLTexture? {
        let inputs: [(MTLTexture, MTLPixelFormat)] = [
            (color, .rgba16Float), (depth, .r32Float), (motion, .rgba16Float),
            (normals, .rgba16Float), (diffuseAlbedo, .rgba16Float), (specularAlbedo, .rgba16Float),
        ]
        guard inputs.allSatisfy({ texture, format in
            texture.width == color.width && texture.height == color.height
                && texture.pixelFormat == format && texture.textureType == .type2D
                && texture.usage.contains(.shaderRead)
        }), (0..<4).allSatisfy({ column in
            let a = worldToView[column], b = viewToClip[column]
            return [a.x, a.y, a.z, a.w, b.x, b.y, b.z, b.w].allSatisfy(\.isFinite)
        }), let state = configure(width: color.width, height: color.height),
            let encoder = command.makeComputeCommandEncoder() else {
            needsReset = true
            return nil
        }
        encoder.label = "Convert native ray-tracing guides for MetalFX"
        encoder.setComputePipelineState(guidePipeline)
        for (index, texture) in [motion, diffuseAlbedo, state.motion, state.roughness, state.reactive].enumerated() {
            encoder.setTexture(texture, index: index)
        }
        let width = min(8, guidePipeline.threadExecutionWidth)
        let height = min(8, max(1, guidePipeline.maxTotalThreadsPerThreadgroup / width))
        encoder.dispatchThreads(MTLSize(width: color.width, height: color.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        let scaler = state.scaler
        scaler.colorTexture = color
        scaler.depthTexture = depth
        scaler.motionTexture = state.motion
        scaler.normalTexture = normals
        scaler.diffuseAlbedoTexture = diffuseAlbedo
        scaler.specularAlbedoTexture = specularAlbedo
        scaler.roughnessTexture = state.roughness
        scaler.reactiveMaskTexture = state.reactive
        scaler.outputTexture = state.output
        scaler.exposureTexture = exposure
        scaler.preExposure = 1
        scaler.isDepthReversed = false
        scaler.motionVectorScaleX = Float(color.width)
        scaler.motionVectorScaleY = Float(color.height)
        scaler.jitterOffsetX = 0
        scaler.jitterOffsetY = 0
        scaler.worldToViewMatrix = worldToView
        scaler.viewToClipMatrix = viewToClip
        scaler.shouldResetHistory = reset || needsReset
        scaler.encode(commandBuffer: command)
        needsReset = false
        status = "MetalFX neural denoising"
        // Replacement on resize is safe while earlier command buffers execute.
        // GPU-only rewriting uses one serial command queue; CPU never rewrites
        // a submitted texture or guide buffer.
        let resources = inputs.map(\.0) + [exposure]
        command.addCompletedHandler { [state, resources] _ in
            _ = state.output.width
            _ = resources.count
        }
        return state.output
    }

    private static let guideSource = #"""
    #include <metal_stdlib>
    using namespace metal;
    kernel void ely_rt_denoising_guides(
        texture2d<float, access::read> previousUV [[texture(0)]],
        texture2d<float, access::read> diffuse [[texture(1)]],
        texture2d<float, access::write> offsets [[texture(2)]],
        texture2d<float, access::write> roughness [[texture(3)]],
        texture2d<float, access::write> reactive [[texture(4)]],
        uint2 pixel [[thread_position_in_grid]]) {
        if (pixel.x >= offsets.get_width() || pixel.y >= offsets.get_height()) return;
        float2 uv = (float2(pixel) + 0.5) / float2(offsets.get_width(), offsets.get_height());
        float4 prior = previousUV.read(pixel);
        bool valid = prior.w > 0.5 && all(isfinite(prior.xy));
        float2 movement = valid ? prior.xy - uv : float2(0);
        offsets.write(float4(movement, 0, 0), pixel);
        float materialRoughness = diffuse.read(pixel).a;
        roughness.write(float4(isfinite(materialRoughness) ? clamp(materialRoughness, 0.0, 1.0) : 1.0), pixel);
        reactive.write(float4(valid ? 0.0 : 1.0), pixel);
    }
    """#
}
