import Foundation
import Metal

/// One mip level's place inside a staged animation upload.
struct AtlasMipUpload: Equatable {
    let level: Int, size: Int, offset: Int, rowBytes: Int
}

/// Prepares animated atlas tiles (water, lava, fire, ...) away from the main thread.
///
/// Twenty times a second every animated tile needs its next image: for an interpolating tile a
/// blend of two frames, then a full mip chain, then a row-padded staging buffer. Done inside the
/// draw call that cost about three milliseconds of the frame it landed on, a visible hitch at high
/// frame rates. The renderer now only says what each tile should show (`request`); one batch at a
/// time is built on a private queue, and the finished immutable buffers are collected at the start
/// of a later frame and blitted in GPU order, as before. The pixels are the same; they reach the
/// atlas one frame later.
final class AtlasAnimationStager {
    /// What one animated tile should show after an animation tick.
    struct Request {
        let slice: Int
        let current: [UInt8]
        /// The frame being blended toward and how far along (0..<1), or nil to show `current`.
        let blend: (next: [UInt8], fraction: Double)?
    }

    /// An immutable staging buffer holding every mip level of one tile.
    struct Staged {
        let buffer: MTLBuffer
        let slice: Int
        let levels: [AtlasMipUpload]
    }

    private let device: MTLDevice
    private let queue = DispatchQueue(label: "elysium.atlas-animation", qos: .userInteractive)

    // Main thread only.
    private var pending: [Int: Request] = [:]

    // Shared with the queue.
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var busy = false
    private var finished: [Staged] = []

    init(device: MTLDevice) { self.device = device }

    /// Records the newest wanted image for a tile. A newer request replaces an unbuilt older one,
    /// so a slow build can never queue more than one image per tile.
    func request(_ request: Request) { pending[request.slice] = request }

    /// Forgets everything asked for or built for the previous atlas.
    func reset() {
        pending.removeAll()
        lock.lock()
        generation &+= 1
        finished.removeAll()
        lock.unlock()
    }

    /// Starts building the pending images unless a batch is still being built.
    func pump(tileSize: Int) {
        guard !pending.isEmpty else { return }
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        let batchGeneration = generation
        lock.unlock()
        let batch = pending.values.sorted { $0.slice < $1.slice }
        pending.removeAll(keepingCapacity: true)
        queue.async { [device, weak self] in
            let staged = batch.compactMap { Self.stage($0, tileSize: tileSize, device: device) }
            guard let self else { return }
            self.lock.lock()
            // An atlas installed meanwhile has other tiles; its predecessor's images are dropped.
            if batchGeneration == self.generation { self.finished.append(contentsOf: staged) }
            self.busy = false
            self.lock.unlock()
        }
    }

    /// The images finished since the last call, oldest first.
    func takeFinished() -> [Staged] {
        lock.lock(); defer { lock.unlock() }
        let result = finished
        finished.removeAll(keepingCapacity: true)
        return result
    }

    /// Blocks until the batch being built, if any, has finished. For tests and captures that need
    /// a tick's images in the very next frame.
    func waitUntilIdle() { queue.sync {} }

    /// The image a request asks for. The blend is the per-channel truncating interpolation the
    /// renderer has always used, so animated tiles keep their exact colours.
    static func pixels(for request: Request) -> [UInt8] {
        guard let blend = request.blend, blend.next.count == request.current.count else { return request.current }
        let current = request.current, next = blend.next, fraction = blend.fraction
        return [UInt8](unsafeUninitializedCapacity: current.count) { buffer, count in
            for i in 0..<current.count {
                buffer[i] = UInt8(Double(current[i]) + (Double(next[i]) - Double(current[i])) * fraction)
            }
            count = current.count
        }
    }

    /// Every mip level of a tile, each row padded to the 256-byte blit alignment.
    static func layout(_ levels: [WorldAtlasMipChain.Level]) -> (bytes: [UInt8], levels: [AtlasMipUpload]) {
        var bytes: [UInt8] = [], uploads: [AtlasMipUpload] = []
        for (level, image) in levels.enumerated() {
            let rowBytes = ((image.size * 4 + 255) / 256) * 256
            let offset = bytes.count
            uploads.append(AtlasMipUpload(level: level, size: image.size, offset: offset, rowBytes: rowBytes))
            bytes.append(contentsOf: repeatElement(0, count: rowBytes * image.size))
            for row in 0..<image.size {
                bytes.replaceSubrange((offset + row * rowBytes)..<(offset + row * rowBytes + image.size * 4),
                                      with: image.pixels[(row * image.size * 4)..<((row + 1) * image.size * 4)])
            }
        }
        return (bytes, uploads)
    }

    private static func stage(_ request: Request, tileSize: Int, device: MTLDevice) -> Staged? {
        guard let chain = WorldAtlasMipChain.make(pixels: pixels(for: request), size: tileSize) else { return nil }
        let (bytes, levels) = layout(chain)
        let buffer = bytes.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
        return buffer.map { Staged(buffer: $0, slice: request.slice, levels: levels) }
    }
}
