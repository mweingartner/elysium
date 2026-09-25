import Foundation
import Metal
import simd
import ElysiumCore

/// An optional, independent world renderer. Raster remains available during incremental scene
/// preparation or a capability/resource failure; a partly built ray scene is never presented.
final class RayTracedWorldRenderer {
    private final class MemoryLedger {
        private let lock=NSLock()
        private var resident=0,transient=0
        var snapshot: (resident: Int,transient: Int) {
            lock.lock(); defer { lock.unlock() }; return (resident,transient)
        }
        func changeResident(_ delta: Int) { lock.lock(); resident+=delta; lock.unlock() }
        func changeTransient(_ delta: Int) { lock.lock(); transient+=delta; lock.unlock() }
    }
    private final class Geometry {
        let structure: MTLAccelerationStructure
        let triangleCount: Int
        let bytes: Int
        let emitters: [RayTracingLight]
        let ledger: MemoryLedger
        init(structure: MTLAccelerationStructure,triangles: Int,bytes: Int,
             emitters: [RayTracingLight],ledger: MemoryLedger) {
            self.structure=structure; self.triangleCount=triangles; self.bytes=bytes; self.emitters=emitters
            self.ledger=ledger; ledger.changeResident(bytes)
        }
        deinit { ledger.changeResident(-bytes) }
    }
    private final class Section {
        let key: SectionKey
        let minY: Int
        let revision: UInt64
        // Packed source is reconstructible after a distance-based BLAS eviction. The original
        // COW arrays are smaller than retaining duplicate decoded Metal build-input buffers.
        let mesh: MeshOutput
        var geometry: Geometry?
        init(key: SectionKey,minY: Int,mesh: MeshOutput,revision: UInt64) {
            self.key=key; self.minY=minY; self.mesh=mesh; self.revision=revision
        }
    }
    private struct SceneInstance {
        let key: String
        let geometry: Geometry
        let transform: simd_float4x4
        let texture: MTLTexture?
        let tint: SIMD4<Float>
        let overlay: SIMD4<Float>
        let dynamic: Bool
        let primaryVisible: Bool
    }
    /// Retained by the completion closure. Replaced meshes and resized textures remain alive
    /// until their final GPU consumer completes, independent of CPU/render-frame cadence.
    private final class Submission {
        var geometry: [Geometry] = []
        var resources: [MTLResource] = []
        var transientBytes = 0
        let ledger: MemoryLedger
        init(ledger: MemoryLedger) { self.ledger=ledger }
        func retainTransient(_ resource: MTLResource) {
            resources.append(resource)
            transientBytes+=resource.allocatedSize
            ledger.changeTransient(resource.allocatedSize)
        }
        func finish() {
            // A caller may retain its completed command buffer. Release at completion rather
            // than relying on the command buffer/closure's eventual autorelease/deinit.
            let released=transientBytes; transientBytes=0
            resources.removeAll(); geometry.removeAll()
            ledger.changeTransient(-released)
        }
        deinit { finish() }
    }
    let device: MTLDevice
    private let pathPipeline: MTLComputePipelineState
    private let temporalPipeline: MTLComputePipelineState
    private let filterPipeline: MTLComputePipelineState
    private let mediaPipeline: MTLComputePipelineState
    private let textureEncoder: MTLArgumentEncoder
    private let whiteTexture: MTLTexture
    private var sections: [SectionKey: Section] = [:]
    private var requiredSectionKeys: Set<SectionKey> = []
    private var entities: [String: Geometry] = [:]
    private var sectionsRevision: UInt64 = 1
    private var previousParticipatingSections: [SectionKey:UInt64] = [:]
    private var previousSourceRevision: UInt64 = 0
    private var hasPresentedCompleteScene=false
    private static let warmBuildsPerFrame=64
    private static let warmBuildTrianglesPerFrame=1_000_000
    private static let retentionMargin: Double=32
    private var previousWorldIdentity: UInt64 = 0
    private var previousAtlasGeneration: UInt64 = 0
    private var previousCamera = SIMD3<Double>(repeating: 0)
    private var previousViewProjection = matrix_identity_float4x4
    private var previousTransforms: [String: simd_float4x4] = [:]
    private var previousSun = SIMD4<Float>(repeating: 0)
    private var lastDimension: Float = -1
    private var lastClock: Float = 0
    private var sampleIndex: UInt32 = 0
    private var historyFrames = 0
    private var bufferIndex = 0
    private var raw: MTLTexture?
    private var motion: MTLTexture?
    private var diffuseAlbedo: MTLTexture?
    private var specularAlbedo: MTLTexture?
    private var colors: [MTLTexture] = []
    private var depths: [MTLTexture] = []
    private var normals: [MTLTexture] = []
    private var filtered: MTLTexture?
    private var desiredWidth = 1, desiredHeight = 1
    private var allocationFailure: String?
    private var memoryPressureReason: String?
    private let memoryLedger=MemoryLedger()
    private let memoryPolicy: RayTracingMemoryBudget
#if DEBUG
    // Internal fault injection only; no production setting/environment selector can change
    // the memory policy or manufacture device headroom.
    var memoryBudgetOverride: Int?
    var memoryHeadroomOverride: Int?
#endif
    private lazy var denoiser=RayTracingDenoiser(device:device)
    private var previousUsedDenoiser=false
    private var denoiserFailed=false
    private let diagnosticsLock = NSLock()
    private var completedGPUTime = 0.0
    private var completedError: String?
    private(set) var diagnostics = RayTracingDiagnostics()
    /// The last successful frame's normalized Metal depth, not distance from the eye.
    private(set) var depthTexture: MTLTexture?

    init?(device: MTLDevice) {
        guard device.supportsRaytracing else { return nil }
        self.device=device
        memoryPolicy=RayTracingMemoryBudget(recommendedWorkingSet:device.recommendedMaxWorkingSetSize,
            physicalMemory:ProcessInfo.processInfo.physicalMemory)
        do {
            let options=MTLCompileOptions(); options.languageVersion = .version3_1
            let library=try device.makeLibrary(source: ELYSIUM_ENVIRONMENT_MSL + "\n" + RAY_TRACING_MSL,options: options)
            guard let path=library.makeFunction(name:"rt_pathtrace"),
                  let temporal=library.makeFunction(name:"rt_temporal"),
                  let filter=library.makeFunction(name:"rt_filter"),
                  let media=library.makeFunction(name:"rt_media") else { return nil }
            pathPipeline=try device.makeComputePipelineState(function:path)
            temporalPipeline=try device.makeComputePipelineState(function:temporal)
            filterPipeline=try device.makeComputePipelineState(function:filter)
            mediaPipeline=try device.makeComputePipelineState(function:media)
            textureEncoder=path.makeArgumentEncoder(bufferIndex:4)
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false)
            descriptor.usage = .shaderRead
            guard let white=device.makeTexture(descriptor:descriptor) else { return nil }
            var pixel: UInt32=0xffffffff
            white.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&pixel,bytesPerRow:4)
            whiteTexture=white
            diagnostics.available=true; diagnostics.status="Preparing ray scene"
        } catch {
            print("[ray tracing] unavailable: \(error.localizedDescription)")
            return nil
        }
    }

#if DEBUG
    convenience init?(device: MTLDevice,memoryBudgetOverride: Int?) {
        self.init(device:device)
        self.memoryBudgetOverride=memoryBudgetOverride
    }
#endif

    /// Refresh without encoding work; completion-bound resource release is observable even
    /// while raster fallback is active. These values describe RT resources, not all GPU memory.
    func refreshMemoryDiagnostics() {
        let snapshot=memoryLedger.snapshot
        let tracked=RayTracingMemoryBudget.saturatingAdd(snapshot.resident,snapshot.transient)
        let allocated=device.currentAllocatedSize
        let available=memoryPolicy.availability(deviceAllocatedBytes:allocated,trackedBytes:tracked)
        var budget=available.effectiveBudgetBytes
#if DEBUG
        if let memoryBudgetOverride { budget=min(budget,max(0,memoryBudgetOverride)) }
        if let memoryHeadroomOverride {
            budget=min(budget,RayTracingMemoryBudget.saturatingAdd(tracked,max(0,memoryHeadroomOverride)))
        }
#endif
        diagnostics.residentGeometryBytes=snapshot.resident
        diagnostics.transientGeometryBytes=snapshot.transient
        diagnostics.geometryBytes=tracked
        diagnostics.memoryBudgetBytes=budget
        diagnostics.deviceAllocatedBytes=allocated
        diagnostics.deviceRecommendedBytes=Int(clamping:device.recommendedMaxWorkingSetSize)
    }

    private func admitsAllocation(_ bytes: Int) -> Bool {
        refreshMemoryDiagnostics()
        var available=max(0,diagnostics.memoryBudgetBytes-diagnostics.geometryBytes)
        if bytes>available {
            // The retention margin is optional performance caching, never a reason to deny a
            // complete selected scene that would otherwise fit. Drop those BLAS references
            // before retrying admission. Submitted frames retain their own references, so
            // their bytes remain charged until real GPU completion and cannot be overspent.
            for section in sections.values where !requiredSectionKeys.contains(section.key) {
                section.geometry=nil
            }
            refreshMemoryDiagnostics()
            available=max(0,diagnostics.memoryBudgetBytes-diagnostics.geometryBytes)
        }
        guard bytes>=0,bytes<=available else {
            memoryPressureReason="Ray memory budget reached; retrying in Ultra"
            return false
        }
        return true
    }

    func uploadSection(key: SectionKey,minY: Int,mesh: MeshOutput) {
        let nonempty = !mesh.opaque.idx.isEmpty || !mesh.cutout.idx.isEmpty || !mesh.translucent.idx.isEmpty
        sectionsRevision &+= 1
        sections[key]=nonempty ? Section(key:key,minY:minY,mesh:mesh,revision:sectionsRevision) : nil
    }
    func removeChunk(cx: Int,cz: Int,sectionCount: Int) {
        for sy in 0..<sectionCount { sections.removeValue(forKey:SectionKey(cx:cx,sy:sy,cz:cz)) }
        sectionsRevision &+= 1
    }
    func clear() {
        sections.removeAll(); entities.removeAll(); previousTransforms.removeAll()
        requiredSectionKeys.removeAll()
        previousParticipatingSections.removeAll(); previousSourceRevision=0; hasPresentedCompleteScene=false
        sectionsRevision &+= 1; historyFrames=0; sampleIndex=0; allocationFailure=nil
        memoryPressureReason=nil
        diagnosticsLock.lock(); completedError=nil; diagnosticsLock.unlock()
    }
    func resize(width: Int,height: Int) {
        let scale=min(1,min(Double(RayTracingLimits.maximumInternalWidth)/Double(max(1,width)),
                            Double(RayTracingLimits.maximumInternalHeight)/Double(max(1,height))))
        let w=max(1,Int(Double(width)*scale)), h=max(1,Int(Double(height)*scale))
        guard w != desiredWidth || h != desiredHeight || raw == nil else { return }
        desiredWidth=w; desiredHeight=h; historyFrames=0
        func texture(_ format: MTLPixelFormat,_ label: String) -> MTLTexture? {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
            d.storageMode = .private; d.usage = [.shaderRead,.shaderWrite]
            let t=device.makeTexture(descriptor:d); t?.label=label; return t
        }
        raw=texture(.rgba16Float,"RT sample"); motion=texture(.rgba16Float,"RT reprojection")
        diffuseAlbedo=texture(.rgba16Float,"RT diffuse albedo and roughness")
        specularAlbedo=texture(.rgba16Float,"RT specular albedo")
        filtered=texture(.rgba16Float,"RT filtered radiance")
        colors=(0..<2).compactMap { texture(.rgba16Float,"RT radiance history \($0)") }
        depths=(0..<2).compactMap { texture(.r32Float,"RT normalized depth \($0)") }
        normals=(0..<2).compactMap { texture(.rgba16Float,"RT normal/distance history \($0)") }
        if raw == nil || motion == nil || diffuseAlbedo == nil || specularAlbedo == nil || filtered == nil || colors.count != 2 || depths.count != 2 || normals.count != 2 {
            allocationFailure="Insufficient GPU memory for ray tracing targets"
        } else { allocationFailure=nil }
    }

    private func fail(_ reason: String) -> MTLTexture? {
        refreshMemoryDiagnostics()
        diagnostics.ready=false; diagnostics.status=reason; historyFrames=0; depthTexture=nil
        return nil
    }
    private func makeBuffer<T>(_ values: [T],label: String,submission: Submission) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        let bytes=values.count*MemoryLayout<T>.stride
        let estimate=max(bytes,device.heapBufferSizeAndAlign(length:bytes,options:.storageModeShared).size)
        guard admitsAllocation(estimate) else { return nil }
        let result=values.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }
        if let result { result.label=label; submission.retainTransient(result) }
        return result
    }
    private func build(_ decoded: RayTracingMeshDecoder.Decoded,command: MTLCommandBuffer,
                       submission: Submission,label: String) -> Geometry? {
        guard admitsAllocation(decoded.byteCount) else { return nil }
        guard !decoded.primitives.isEmpty,
              let vertices=makeBuffer(decoded.positions,label:label+" positions",submission:submission),
              let indices=makeBuffer(decoded.indices,label:label+" indices",submission:submission),
              let primitives=makeBuffer(decoded.primitives,label:label+" materials",submission:submission) else { return nil }
        let triangles=MTLAccelerationStructureTriangleGeometryDescriptor()
        triangles.vertexBuffer=vertices; triangles.vertexStride=MemoryLayout<SIMD3<Float>>.stride
        triangles.vertexFormat = .float3; triangles.indexBuffer=indices; triangles.indexType = .uint32
        triangles.triangleCount=decoded.primitives.count; triangles.opaque=true
        triangles.primitiveDataBuffer=primitives; triangles.primitiveDataStride=MemoryLayout<RayTracingPrimitive>.stride
        triangles.primitiveDataElementSize=MemoryLayout<RayTracingPrimitive>.stride
        let descriptor=MTLPrimitiveAccelerationStructureDescriptor(); descriptor.geometryDescriptors=[triangles]
        let sizes=device.accelerationStructureSizes(descriptor:descriptor)
        let scratchEstimate=max(1,device.heapBufferSizeAndAlign(length:max(1,sizes.buildScratchBufferSize),options:.storageModePrivate).size)
        guard admitsAllocation(RayTracingMemoryBudget.saturatingAdd(sizes.accelerationStructureSize,scratchEstimate)) else { return nil }
        guard let structure=device.makeAccelerationStructure(size:sizes.accelerationStructureSize),
              let scratch=device.makeBuffer(length:max(1,sizes.buildScratchBufferSize),options:.storageModePrivate),
              let encoder=command.makeAccelerationStructureCommandEncoder() else { return nil }
        structure.label=label
        encoder.build(accelerationStructure:structure,descriptor:descriptor,scratchBuffer:scratch,scratchBufferOffset:0)
        encoder.endEncoding()
        submission.retainTransient(scratch)
        // Metal copies both geometry and per-primitive payload into the BLAS. Build-input
        // buffers stay in Submission until completion, not in the persistent Geometry cache.
        let geometry=Geometry(structure:structure,
                              triangles:decoded.primitives.count,bytes:structure.allocatedSize,
                              emitters:decoded.emitters,ledger:memoryLedger)
        submission.geometry.append(geometry)
        return geometry
    }

    private func decodeEntity(_ source: RayTracingEntityGeometry) -> RayTracingMeshDecoder.Decoded? {
        let v=source.vertices
        guard v.count % 27 == 0 else { return nil }
        var out=RayTracingMeshDecoder.Decoded()
        for i in stride(from:0,to:v.count,by:9) {
            let position=SIMD3<Float>(v[i],v[i+1],v[i+2])
            guard position.x.isFinite,position.y.isFinite,position.z.isFinite else { return nil }
            out.positions.append(position); out.indices.append(UInt32(out.indices.count))
        }
        for i in stride(from:0,to:v.count,by:27) {
            let n=SIMD3<Float>(v[i+3],v[i+4],v[i+5])
            guard simd_length_squared(n)>0.00001 else { return nil }
            out.primitives.append(.init(uv01:.init(v[i+6],v[i+7],v[i+15],v[i+16]),
                                        uv2Light:.init(v[i+24],v[i+25],0,0),
                                        normalEmission:.init(simd_normalize(n),source.emission),
                                        material:.init(0xffffff,0,9,0)))
        }
        return out
    }

    func render(command: MTLCommandBuffer,frame: RayTracingFrame,atlas: MTLTexture,
                entities dynamic: [RayTracingEntityInstance],blocks: [RayTracingBlockInstance] = []) -> MTLTexture? {
        diagnosticsLock.lock(); let gpuTime=completedGPUTime, gpuError=completedError; diagnosticsLock.unlock()
        diagnostics.gpuMilliseconds=gpuTime
        memoryPressureReason=nil
        refreshMemoryDiagnostics()
        if let gpuError { return fail("Ray tracing GPU failure: "+gpuError) }
        if let allocationFailure { return fail(allocationFailure) }
        guard let raw,let motion,let diffuseAlbedo,let specularAlbedo,let filtered,colors.count==2,depths.count==2,normals.count==2 else {
            return fail("Preparing ray tracing targets")
        }
        let submission=Submission(ledger:memoryLedger)
        // Completion owns every buffer/AS used by this submission, including replacement/eviction cases.
        command.addCompletedHandler { [weak self,submission] completed in
            submission.finish()
            guard let self else { return }
            self.diagnosticsLock.lock()
            if completed.status == .error { self.completedError=completed.error?.localizedDescription ?? "Unknown GPU error" }
            self.completedGPUTime=max(0,(completed.gpuEndTime-completed.gpuStartTime)*1000)
            self.diagnosticsLock.unlock()
        }
        let range=Double(frame.renderDistance+24)
        let selected=sections.values.filter {
            let dx=Double($0.key.cx*16+8)-frame.camera.x, dz=Double($0.key.cz*16+8)-frame.camera.z
            return dx*dx+dz*dz <= range*range
        }.sorted {
            let ax=Double($0.key.cx*16+8)-frame.camera.x, az=Double($0.key.cz*16+8)-frame.camera.z
            let bx=Double($1.key.cx*16+8)-frame.camera.x, bz=Double($1.key.cz*16+8)-frame.camera.z
            let a=ax*ax+az*az,b=bx*bx+bz*bz
            if a != b { return a<b }
            if $0.key.cx != $1.key.cx { return $0.key.cx<$1.key.cx }
            if $0.key.cz != $1.key.cz { return $0.key.cz<$1.key.cz }
            return $0.key.sy<$1.key.sy
        }
        diagnostics.sections=selected.count
        diagnostics.width=desiredWidth; diagnostics.height=desiredHeight
        requiredSectionKeys=Set(selected.map(\.key))
        // Retain a narrow margin beyond selection: walking back across a chunk/radius boundary
        // should not continually destroy and rebuild the same BLAS. Only selected geometry
        // enters the scene; this cache margin never admits an incomplete ray scene.
        let retainRange=range+Self.retentionMargin
        for section in sections.values where section.geometry != nil {
            let dx=Double(section.key.cx*16+8)-frame.camera.x, dz=Double(section.key.cz*16+8)-frame.camera.z
            if dx*dx+dz*dz>retainRange*retainRange { section.geometry=nil }
        }
        let activeEntityKeys=Set(dynamic.map { $0.geometry.key }+blocks.map { "block:"+$0.geometry.key })
        // Eviction precedes admission. In-flight submissions still own retired BLAS objects,
        // and their bytes remain charged until completion; packed terrain sources can rebuild.
        entities=entities.filter { activeEntityKeys.contains($0.key) }
        refreshMemoryDiagnostics()
        guard selected.count+dynamic.count+blocks.count <= RayTracingLimits.maximumInstances else {
            return fail("Ray scene exceeds the safe instance budget; using raster")
        }
        var built=0,builtTriangles=0
        // Terrain meshing can deliver 26 completions at once. Once a complete RT scene has
        // been shown, a bounded catch-up slice handles that ordinary burst in the same frame
        // instead of flashing Ultra lighting for its second half. Cold startup stays smaller;
        // genuinely larger work still waits for a complete, fresh scene rather than hiding edits.
        let buildLimit=hasPresentedCompleteScene ? Self.warmBuildsPerFrame:RayTracingLimits.buildsPerFrame
        let triangleBuildLimit=hasPresentedCompleteScene ? Self.warmBuildTrianglesPerFrame:RayTracingLimits.buildTrianglesPerFrame
        for section in selected where section.geometry == nil {
            guard built<buildLimit,builtTriangles<triangleBuildLimit else { break }
            guard let decoded=RayTracingMeshDecoder.decode(section.mesh) else {
                return fail("Invalid section geometry; using raster")
            }
            guard let geometry=build(decoded,command:command,submission:submission,label:"RT section \(section.key)") else {
                diagnostics.pendingSections=selected.filter { $0.geometry == nil }.count
                return fail(memoryPressureReason ?? "Unable to allocate ray section geometry; retrying in Ultra")
            }
            section.geometry=geometry; built+=1; builtTriangles+=geometry.triangleCount
        }
        for instance in dynamic where entities[instance.geometry.key] == nil {
            guard built<buildLimit,builtTriangles<triangleBuildLimit else { break }
            guard let decoded=decodeEntity(instance.geometry),!decoded.primitives.isEmpty,
                  let geometry=build(decoded,command:command,submission:submission,label:"RT entity "+instance.geometry.key) else {
                return fail(memoryPressureReason ?? "Invalid or unavailable entity geometry; using raster")
            }
            entities[instance.geometry.key]=geometry; built+=1; builtTriangles+=geometry.triangleCount
        }
        for instance in blocks where entities["block:"+instance.geometry.key] == nil {
            guard built<buildLimit,builtTriangles<triangleBuildLimit else { break }
            guard let decoded=RayTracingMeshDecoder.decodePacked(data:instance.geometry.vertices,indices:instance.geometry.indices),!decoded.primitives.isEmpty,
                  let geometry=build(decoded,command:command,submission:submission,label:"RT block "+instance.geometry.key) else {
                return fail(memoryPressureReason ?? "Invalid or unavailable moving block geometry; using raster")
            }
            entities["block:"+instance.geometry.key]=geometry; built+=1; builtTriangles+=geometry.triangleCount
        }
        let pending=selected.filter { $0.geometry == nil }.count
            + Set(dynamic.filter { entities[$0.geometry.key] == nil }.map { $0.geometry.key }).count
            + Set(blocks.filter { entities["block:"+$0.geometry.key] == nil }.map { $0.geometry.key }).count
        diagnostics.pendingSections=pending
        refreshMemoryDiagnostics()
        if pending>0 { return fail("Preparing ray scene (\(pending) meshes remaining)") }
        var instances: [SceneInstance]=[]
        for section in selected {
            guard let geometry=section.geometry else { continue }
            var transform=matrix_identity_float4x4
            transform.columns.3 = .init(Float(Double(section.key.cx*16)-frame.camera.x),
                                       Float(Double(section.minY+section.key.sy*16)-frame.camera.y),
                                       Float(Double(section.key.cz*16)-frame.camera.z),1)
            instances.append(.init(key:"s\(section.key.cx),\(section.key.sy),\(section.key.cz)",geometry:geometry,
                                   transform:transform,texture:nil,tint:.init(repeating:1),overlay:.zero,dynamic:false,primaryVisible:true))
        }
        for (index,instance) in dynamic.enumerated() {
            guard let geometry=entities[instance.geometry.key] else { continue }
            let stableID=instance.identity.isEmpty ? instance.geometry.key+"#\(index)" : instance.identity
            instances.append(.init(key:stableID,geometry:geometry,transform:instance.transform,
                                   texture:instance.geometry.texture,tint:instance.tint,overlay:instance.overlay,dynamic:true,
                                   primaryVisible:instance.primaryVisible))
        }
        for (index,instance) in blocks.enumerated() {
            guard let geometry=entities["block:"+instance.geometry.key] else { continue }
            let stableID=instance.identity.isEmpty ? "block:"+instance.geometry.key+"#\(index)" : instance.identity
            instances.append(.init(key:stableID,geometry:geometry,transform:instance.transform,
                texture:nil,tint:instance.tint,overlay:instance.overlay,dynamic:true,primaryVisible:instance.primaryVisible))
        }
        diagnostics.instances=instances.count
        diagnostics.triangles=instances.reduce(0) { $0+$1.geometry.triangleCount }
        guard !instances.isEmpty else { return fail("Waiting for loaded world geometry") }
        guard diagnostics.triangles <= RayTracingLimits.maximumTriangles else {
            return fail("Ray scene exceeds the safe triangle budget; using raster")
        }
        var textureSlots: [ObjectIdentifier:Int]=[:],textures:[MTLTexture]=[]
        var descriptors:[MTLAccelerationStructureInstanceDescriptor]=[]
        var instanceUniforms:[RayTracingInstanceUniforms]=[]
        var structures:[MTLAccelerationStructure]=[],structureSlots:[ObjectIdentifier:Int]=[:]
        var lights:[RayTracingLight]=[]
        var transforms:[String:simd_float4x4]=[:]
        for instance in instances {
            let geometry=instance.geometry,identity=ObjectIdentifier(geometry)
            let structureIndex: Int
            if let existing=structureSlots[identity] { structureIndex=existing }
            else { structureIndex=structures.count; structureSlots[identity]=structureIndex; structures.append(geometry.structure) }
            var descriptor=MTLAccelerationStructureInstanceDescriptor()
            let m=instance.transform
            descriptor.transformationMatrix=MTLPackedFloat4x3(columns:(
                MTLPackedFloat3Make(m.columns.0.x,m.columns.0.y,m.columns.0.z),
                MTLPackedFloat3Make(m.columns.1.x,m.columns.1.y,m.columns.1.z),
                MTLPackedFloat3Make(m.columns.2.x,m.columns.2.y,m.columns.2.z),
                MTLPackedFloat3Make(m.columns.3.x,m.columns.3.y,m.columns.3.z)))
            descriptor.mask=instance.primaryVisible ? 0xff:0x02; descriptor.options = .opaque
            descriptor.accelerationStructureIndex=UInt32(structureIndex)
            descriptors.append(descriptor)
            var textureIndex=0
            if let texture=instance.texture {
                let id=ObjectIdentifier(texture)
                if let existing=textureSlots[id] { textureIndex=existing }
                else { textureIndex=textures.count; textureSlots[id]=textureIndex; textures.append(texture) }
            }
            guard textures.count<=RayTracingLimits.maximumTextures else {
                return fail("Ray scene exceeds the safe texture budget; using raster")
            }
            let previous=previousTransforms[instance.key]
            transforms[instance.key]=m
            instanceUniforms.append(.init(transform:m,normalTransform:m.inverse.transpose,
                previousFromCurrent:(previous ?? m)*m.inverse,tint:instance.tint,overlay:instance.overlay,
                info:.init(UInt32(textureIndex),instance.dynamic ? 1:0,(!instance.dynamic || previous != nil) ? 1:0,0)))
            for light in geometry.emitters {
                var positioned=light; positioned.positionRadius = .init((m*SIMD4(light.positionRadius.x,light.positionRadius.y,light.positionRadius.z,1)).xyz,light.positionRadius.w)
                lights.append(positioned)
            }
        }
        // Rotating stratified sampling retains a nonzero probability for every source across
        // frames, not just a camera-frustum list. Power accounts for each stratum's population.
        if lights.count>RayTracingLimits.maximumLights {
            let count=lights.count,stride=Double(count)/Double(RayTracingLimits.maximumLights)
            lights=(0..<RayTracingLimits.maximumLights).map { i in
                let start=Int(Double(i)*stride),end=Int(Double(i+1)*stride)
                var hash=UInt32(truncatingIfNeeded:i) &* 0x9e3779b9 ^ (sampleIndex &* 0x85ebca6b)
                hash ^= hash >> 16; hash &*= 0x7feb352d; hash ^= hash >> 15
                let width=max(1,end-start)
                var light=lights[min(count-1,start+Int(hash % UInt32(width)))]
                light.colorPower.w *= Float(width); return light
            }
        }
        let argumentsEstimate=max(textureEncoder.encodedLength,
            device.heapBufferSizeAndAlign(length:textureEncoder.encodedLength,options:.storageModeShared).size)
        guard let descriptorBuffer=makeBuffer(descriptors,label:"RT instance descriptors",submission:submission),
              let instanceBuffer=makeBuffer(instanceUniforms,label:"RT instance materials",submission:submission),
              let lightBuffer=makeBuffer(lights.isEmpty ? [.init(positionRadius:.zero,colorPower:.zero)] : lights,label:"RT emissive lights",submission:submission),
              admitsAllocation(argumentsEstimate),
              let textureArguments=device.makeBuffer(length:textureEncoder.encodedLength,options:.storageModeShared) else {
            return fail(memoryPressureReason ?? "Unable to allocate ray scene tables; using raster")
        }
        submission.retainTransient(textureArguments)
        textureEncoder.setArgumentBuffer(textureArguments,offset:0)
        for i in 0..<RayTracingLimits.maximumTextures { textureEncoder.setTexture(i<textures.count ? textures[i]:whiteTexture,index:i) }
        let sceneDescriptor=MTLInstanceAccelerationStructureDescriptor()
        sceneDescriptor.instancedAccelerationStructures=structures; sceneDescriptor.instanceCount=descriptors.count
        sceneDescriptor.instanceDescriptorBuffer=descriptorBuffer
        sceneDescriptor.instanceDescriptorStride=MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride
        let size=device.accelerationStructureSizes(descriptor:sceneDescriptor)
        let topScratchEstimate=max(1,device.heapBufferSizeAndAlign(length:max(1,size.buildScratchBufferSize),options:.storageModePrivate).size)
        guard admitsAllocation(RayTracingMemoryBudget.saturatingAdd(size.accelerationStructureSize,topScratchEstimate)),
              let scene=device.makeAccelerationStructure(size:size.accelerationStructureSize),
              let scratch=device.makeBuffer(length:max(1,size.buildScratchBufferSize),options:.storageModePrivate),
              let buildEncoder=command.makeAccelerationStructureCommandEncoder() else {
            return fail(memoryPressureReason ?? "Unable to allocate top-level ray scene; using raster")
        }
        submission.retainTransient(scene); submission.retainTransient(scratch)
        buildEncoder.build(accelerationStructure:scene,descriptor:sceneDescriptor,scratchBuffer:scratch,scratchBufferOffset:0)
        buildEncoder.endEncoding()
        submission.geometry.append(contentsOf:instances.map(\.geometry))
        submission.resources.append(contentsOf:[atlas,whiteTexture])
        submission.resources.append(contentsOf:textures)
        submission.resources.append(contentsOf:[raw,motion,diffuseAlbedo,specularAlbedo,filtered]+colors+depths+normals)
        let dimension=frame.atmosphere.options.x,clock=frame.atmosphere.cameraTime.w
        let participatingSections=Dictionary(uniqueKeysWithValues:selected.map { ($0.key,$0.revision) })
        // Camera-only entry/exit from the selection radius is not a scene edit. Depth/motion
        // reject newly visible pixels locally. Reset globally for actual changes/removals to
        // previously participating geometry, or new uploads entering current coverage.
        let participatingChanged=previousParticipatingSections.contains { key,revision in
            sections[key]?.revision != revision
        } || selected.contains { previousParticipatingSections[$0.key] == nil && $0.revision>previousSourceRevision }
        let discontinuity = frame.worldIdentity != previousWorldIdentity || frame.atlasGeneration != previousAtlasGeneration
            || participatingChanged || simd_length(frame.camera-previousCamera)>8
            || dimension != lastDimension || abs(clock-lastClock)>0.5
            || simd_length(frame.atmosphere.sunDaylight-previousSun)>0.04
        if discontinuity { historyFrames=0 }
        // A supported wrapper may still fail to configure/allocate at this size.
        // After that first failed frame, preserve the fallback's four-ray quality;
        // a later successful encode allows native two-ray denoising again.
        let samplesPerPixel=denoiser != nil && !denoiserFailed ? 2:4
        bufferIndex=1-bufferIndex
        let current=bufferIndex,prior=1-current
        var uniforms=RayTracingUniforms(inverseViewProjection:frame.inverseViewProjection,viewProjection:frame.viewProjection,
            previousViewProjection:previousViewProjection,cameraDelta:.init(SIMD3<Float>(frame.camera-previousCamera),0),
            params:.init(max(256,frame.renderDistance*1.6),frame.gamma,historyFrames>0 ? 1:0,frame.shadows ? 1:0),
            heldLight:frame.heldLight,fogParameters:.init(frame.fogStart,frame.fogEnd,frame.nightVision,0),
            quality:.init(Float(samplesPerPixel),0,0,0),
            counts:.init(sampleIndex,UInt32(lights.count),UInt32(desiredWidth),UInt32(desiredHeight)),
            atmosphere:frame.atmosphere)
        guard let encoder=command.makeComputeCommandEncoder() else { return fail("Unable to encode ray tracing") }
        encoder.label="Path traced world: primary, visibility, indirect and dielectric rays"
        encoder.setComputePipelineState(pathPipeline)
        encoder.setAccelerationStructure(scene,bufferIndex:0)
        encoder.setBuffer(instanceBuffer,offset:0,index:1)
        encoder.setBytes(&uniforms,length:MemoryLayout<RayTracingUniforms>.stride,index:2)
        encoder.setBuffer(lightBuffer,offset:0,index:3); encoder.setBuffer(textureArguments,offset:0,index:4)
        encoder.setTexture(atlas,index:0); encoder.setTexture(raw,index:1); encoder.setTexture(depths[current],index:2)
        encoder.setTexture(normals[current],index:3); encoder.setTexture(motion,index:4)
        encoder.setTexture(diffuseAlbedo,index:5); encoder.setTexture(specularAlbedo,index:6)
        for structure in structures { encoder.useResource(structure,usage:.read) }
        for texture in textures { encoder.useResource(texture,usage:.read) }; encoder.useResource(whiteTexture,usage:.read)
        dispatch(encoder,pipeline:pathPipeline)
        encoder.endEncoding()
        let denoised=denoiser?.encode(command:command,color:raw,depth:depths[current],motion:motion,
            normals:normals[current],diffuseAlbedo:diffuseAlbedo,specularAlbedo:specularAlbedo,
            worldToView:frame.viewMatrix,viewToClip:frame.projectionMatrix,reset:historyFrames==0)
        denoiserFailed=denoiser != nil && denoised == nil
        if denoised == nil {
        guard let filterEncoder=command.makeComputeCommandEncoder() else { return fail("Unable to encode ray reconstruction") }
        if previousUsedDenoiser { uniforms.params.z=0 }
        filterEncoder.setComputePipelineState(temporalPipeline)
        filterEncoder.setBytes(&uniforms,length:MemoryLayout<RayTracingUniforms>.stride,index:0)
        for (index,texture) in [raw,depths[current],normals[current],motion,colors[prior],depths[prior],normals[prior],colors[current]].enumerated() {
            filterEncoder.setTexture(texture,index:index)
        }
        dispatch(filterEncoder,pipeline:temporalPipeline)
        filterEncoder.setComputePipelineState(filterPipeline)
        for (index,texture) in [colors[current],depths[current],normals[current],filtered,diffuseAlbedo].enumerated() { filterEncoder.setTexture(texture,index:index) }
        dispatch(filterEncoder,pipeline:filterPipeline); filterEncoder.endEncoding()
        }
        // Primary camera media does not share the material albedo used by reconstruction.
        // Composite it afterward to avoid colored fog artifacts on dark/saturated surfaces.
        // Earlier serial encoders have finished reading raw, so reuse it as the final target;
        // histories deliberately retain only reconstructed surface/transport radiance.
        guard let mediaEncoder=command.makeComputeCommandEncoder() else { return fail("Unable to encode ray atmosphere") }
        mediaEncoder.label="Primary cloud and camera fog composition"
        mediaEncoder.setComputePipelineState(mediaPipeline)
        mediaEncoder.setBytes(&uniforms,length:MemoryLayout<RayTracingUniforms>.stride,index:0)
        for (index,texture) in [denoised ?? filtered,depths[current],normals[current],raw].enumerated() {
            mediaEncoder.setTexture(texture,index:index)
        }
        dispatch(mediaEncoder,pipeline:mediaPipeline); mediaEncoder.endEncoding()
        previousUsedDenoiser=denoised != nil
        historyFrames=min(24,historyFrames+1); sampleIndex &+= 1
        previousTransforms=transforms; previousCamera=frame.camera; previousViewProjection=frame.viewProjection
        previousWorldIdentity=frame.worldIdentity; previousAtlasGeneration=frame.atlasGeneration
        previousParticipatingSections=participatingSections; previousSourceRevision=sectionsRevision
        hasPresentedCompleteScene=true
        previousSun=frame.atmosphere.sunDaylight; lastClock=clock; lastDimension=dimension
        depthTexture=depths[current]
        diagnostics.ready=true; diagnostics.status="Ray Traced"; diagnostics.historySamples=historyFrames
        diagnostics.denoiser=denoised == nil ? "Albedo-guided temporal/spatial":"MetalFX temporal denoising"
        diagnostics.samplesPerPixel=samplesPerPixel
        refreshMemoryDiagnostics()
        return raw
    }
    private func dispatch(_ encoder: MTLComputeCommandEncoder,pipeline: MTLComputePipelineState) {
        let w=min(8,pipeline.threadExecutionWidth),h=min(8,max(1,pipeline.maxTotalThreadsPerThreadgroup/w))
        encoder.dispatchThreads(.init(width:desiredWidth,height:desiredHeight,depth:1),threadsPerThreadgroup:.init(width:w,height:h,depth:1))
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { .init(x,y,z) }
}
