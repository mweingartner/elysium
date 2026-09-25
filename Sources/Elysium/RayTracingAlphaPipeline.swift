import Metal

/// Shared by production and native GPU fixtures, so tests cannot accidentally
/// exercise a different alpha-traversal path or use a foreign pipeline handle.
struct RayTracingAlphaPipeline {
    let pipeline: MTLComputePipelineState
    private let alphaHandle: MTLFunctionHandle

    init?(device: MTLDevice, library: MTLLibrary, function: MTLFunction) throws {
        guard let alpha=library.makeFunction(name:"rt_alpha_accept") else { return nil }
        let descriptor=MTLComputePipelineDescriptor();descriptor.computeFunction=function
        let linked=MTLLinkedFunctions();linked.functions=[alpha];descriptor.linkedFunctions=linked
        pipeline=try device.makeComputePipelineState(descriptor:descriptor,options:[],reflection:nil)
        guard let handle=pipeline.functionHandle(function:alpha) else { return nil }
        alphaHandle=handle
    }

    /// Each table belongs to one immutable submission. The caller retains it and
    /// its referenced buffers/textures until that command buffer completes.
    func makeTable(instances: MTLBuffer, textures: MTLBuffer) -> MTLIntersectionFunctionTable? {
        let descriptor=MTLIntersectionFunctionTableDescriptor();descriptor.functionCount=1
        guard let table=pipeline.makeIntersectionFunctionTable(descriptor:descriptor) else { return nil }
        table.setFunction(alphaHandle,index:0)
        table.setBuffer(instances,offset:0,index:0);table.setBuffer(textures,offset:0,index:1)
        return table
    }
}
