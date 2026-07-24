// Java-format resource pack imports — reads .zip or folder packs from
// ~/Library/Application Support/Elysium/resourcepacks/, maps
// the standard pack texture tree onto the procedural
// tile registry, scales 16×/32× art to one atlas resolution, plays .mcmeta
// frame animations, and falls back to the procedural painter for anything a
// pack doesn't cover. Pure app-layer: ElysiumCore goldens never see any of it.

import AppKit
import Compression
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ElysiumCore

struct ResourcePackPreparationLimits: Sendable {
    var archiveBytes = 512 << 20
    var fileBytes = 64 << 20
    var entries = 100_000
    var pathBytes = 1_024
    var aggregatePathBytes = 16 << 20
    var advertisedBytes = 512 << 20
    var inflatedBytes = 512 << 20
    var decodedRGBABytes = 512 << 20
    var metadataBytes = 64 << 10
    var framesPerTexture = 256
    var framesPerGeneration = 4_096
    var minimumFrameDuration = 1
    var maximumFrameDuration = 1_200

    static let production = ResourcePackPreparationLimits()
}

private let MAX_PACK_ARCHIVE_BYTES = ResourcePackPreparationLimits.production.archiveBytes
private let MAX_PACK_PATH_BYTES = ResourcePackPreparationLimits.production.pathBytes

final class ResourcePackCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

final class ResourcePackPreparationBudget {
    let limits: ResourcePackPreparationLimits
    let cancellation: ResourcePackCancellationToken?
    private(set) var entryCount = 0
    private(set) var pathBytes = 0
    private(set) var advertisedBytes = 0
    private(set) var inflatedBytes = 0
    private(set) var decodedRGBABytes = 0
    private(set) var metadataBytes = 0
    private(set) var animationFrames = 0
    private(set) var isValid = true

    init(limits: ResourcePackPreparationLimits = .production,
         cancellation: ResourcePackCancellationToken? = nil) {
        self.limits = limits
        self.cancellation = cancellation
    }

    var shouldContinue: Bool { isValid && cancellation?.isCancelled != true }

    @discardableResult
    func reject() -> Bool {
        isValid = false
        return false
    }

    private func add(_ amount: Int, to value: inout Int, maximum: Int) -> Bool {
        guard shouldContinue, amount >= 0, amount <= maximum,
              value <= maximum - amount else { return reject() }
        value += amount
        return true
    }

    func chargeEntry(pathByteCount: Int, advertisedByteCount: Int) -> Bool {
        guard pathByteCount > 0, pathByteCount <= limits.pathBytes,
              entryCount < limits.entries,
              add(pathByteCount, to: &pathBytes, maximum: limits.aggregatePathBytes),
              add(advertisedByteCount, to: &advertisedBytes, maximum: limits.advertisedBytes)
        else { return reject() }
        entryCount += 1
        return true
    }

    func chargeInflated(_ amount: Int) -> Bool {
        add(amount, to: &inflatedBytes, maximum: limits.inflatedBytes)
    }

    func chargeDecodedRGBA(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= Int.max / height,
              width * height <= Int.max / 4 else { return reject() }
        return add(width * height * 4, to: &decodedRGBABytes,
                   maximum: limits.decodedRGBABytes)
    }

    func chargeMetadata(_ amount: Int) -> Bool {
        guard amount <= limits.metadataBytes else { return reject() }
        return add(amount, to: &metadataBytes, maximum: limits.metadataBytes)
    }

    func chargeAnimationFrames(_ amount: Int) -> Bool {
        guard amount >= 0, amount <= limits.framesPerTexture else { return reject() }
        return add(amount, to: &animationFrames, maximum: limits.framesPerGeneration)
    }

    func validDuration(_ duration: Int) -> Bool {
        guard duration >= limits.minimumFrameDuration &&
                duration <= limits.maximumFrameDuration else { return reject() }
        return true
    }
}

private func safePackPath(_ path: String, maximumBytes: Int = MAX_PACK_PATH_BYTES) -> Bool {
    if path.isEmpty || path.utf8.count > maximumBytes || path.hasPrefix("/") ||
        path.hasPrefix("\\") || path.contains("\0") || path.contains("\\") { return false }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { return false }
    let contentParts = path.hasSuffix("/") ? parts.dropLast() : parts[...]
    guard !contentParts.isEmpty else { return false }
    return !contentParts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) &&
        !(contentParts.first?.contains(":") ?? false)
}

private func packCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
    }
    return crc ^ 0xffff_ffff
}

private func preferredTextureRoot(from paths: Dictionary<String, String>.Keys) -> String {
    var namespaces: Set<String> = []
    for key in paths {
        let lower = key.lowercased()
        guard let assets = lower.range(of: "assets/") else { continue }
        let parts = lower[assets.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[0].isEmpty, parts[1] == "textures" else { continue }
        namespaces.insert(String(parts[0]))
    }
    guard !namespaces.isEmpty else { return "" }
    let namespace = namespaces.contains("minecraft") ? "minecraft" : namespaces.sorted()[0]
    return "assets/\(namespace)/textures/"
}

// =============================================================================
// minimal read-only zip (central directory + raw deflate via Compression)
// =============================================================================
final class MiniZip {
    struct Entry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let crc32: UInt32
        let compSize: Int
        let uncompSize: Int
        let localOffset: Int
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]
    private var inflatedFiles: [String: Data] = [:]

    init?(data: Data, budget: ResourcePackPreparationBudget = ResourcePackPreparationBudget()) {
        guard data.count <= budget.limits.archiveBytes, budget.shouldContinue else { return nil }
        self.data = data
        guard parseCentralDirectory(budget: budget) else { return nil }
    }

    private func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o + 1]) << 8) }
    private func u32(_ o: Int) -> Int {
        Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
    }

    private func validExtraFields(start: Int, length: Int) -> Bool {
        guard start >= 0, length >= 0, start <= data.count - length else { return false }
        var cursor = start
        let end = start + length
        while cursor < end {
            guard cursor <= end - 4 else { return false }
            let identifier = u16(cursor)
            let size = u16(cursor + 2)
            cursor += 4
            guard cursor <= end - size, identifier != 0x0001 else { return false }
            cursor += size
        }
        return cursor == end
    }

    private func inflated(_ entry: Entry, compressedRange: Range<Int>) -> Data? {
        let raw = data.subdata(in: compressedRange)
        if entry.method == 0 {
            guard entry.uncompSize == entry.compSize else { return nil }
            return packCRC32(raw) == entry.crc32 ? raw : nil
        }
        guard entry.method == 8 else { return nil }
        if entry.uncompSize == 0 { return raw.isEmpty && entry.crc32 == 0 ? Data() : nil }
        guard !raw.isEmpty else { return nil }
        var out = Data(count: entry.uncompSize)
        let written = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstBase, entry.uncompSize,
                    srcBase, raw.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == entry.uncompSize, packCRC32(out) == entry.crc32 else { return nil }
        return out
    }

    private func parseCentralDirectory(budget: ResourcePackPreparationBudget) -> Bool {
        // EOCD signature scan from the tail (comment can pad up to 64KB)
        let n = data.count
        guard n >= 22 else { return false }
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65535)
        while i >= stop {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06,
               i + 22 + u16(i + 20) == n {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0, budget.shouldContinue else { return false }
        guard u16(eocd + 4) == 0, u16(eocd + 6) == 0 else { return false }
        let count = u16(eocd + 10)
        guard u16(eocd + 8) == count, count <= budget.limits.entries,
              u32(eocd + 12) != Int(UInt32.max), u32(eocd + 16) != Int(UInt32.max) else { return false }
        var off = u32(eocd + 16)
        let centralEnd = off + u32(eocd + 12)
        guard off >= 0, centralEnd <= eocd else { return false }
        let centralStart = off
        var pending: [(entry: Entry, pathBytes: Int, compressed: Range<Int>, occupied: Range<Int>)] = []
        var normalizedNames: Set<String> = []
        for _ in 0..<count {
            guard budget.shouldContinue, off <= centralEnd - 46, u32(off) == 0x02014b50 else { return false }
            let creatorSystem = u16(off + 4) >> 8
            let neededVersion = u16(off + 6)
            let flags = UInt16(u16(off + 8))
            let method = UInt16(u16(off + 10))
            let crc = UInt32(u32(off + 16))
            let compSize = u32(off + 20)
            let uncompSize = u32(off + 24)
            let nameLen = u16(off + 28)
            let extraLen = u16(off + 30)
            let commentLen = u16(off + 32)
            let localOffset = u32(off + 42)
            guard neededVersion <= 20,
                  off + 46 + nameLen <= centralEnd,
                  off + 46 + nameLen + extraLen + commentLen <= centralEnd,
                  compSize != Int(UInt32.max), uncompSize != Int(UInt32.max),
                  localOffset != Int(UInt32.max), flags & ~UInt16(0x0808) == 0,
                  method == 0 || method == 8 else { return false }
            let nameData = data.subdata(in: (off + 46)..<(off + 46 + nameLen))
            guard let name = String(data: nameData, encoding: .utf8),
                  safePackPath(name, maximumBytes: budget.limits.pathBytes),
                  validExtraFields(start: off + 46 + nameLen, length: extraLen) else { return false }
            let normalized = name.lowercased()
            guard normalizedNames.insert(normalized).inserted else { return false }
            let external = UInt32(u32(off + 38))
            let mode = (external >> 16) & 0xffff
            let kind = mode & UInt32(S_IFMT)
            let isDirectory = name.hasSuffix("/")
            if creatorSystem == 3 || mode != 0 {
                guard (isDirectory && kind == UInt32(S_IFDIR)) ||
                        (!isDirectory && kind == UInt32(S_IFREG)) else { return false }
            }
            guard !isDirectory || (compSize == 0 && uncompSize == 0),
                  localOffset >= 0, localOffset <= centralStart - 30,
                  u32(localOffset) == 0x04034b50 else { return false }
            let localFlags = UInt16(u16(localOffset + 6))
            let localMethod = UInt16(u16(localOffset + 8))
            let localNameLength = u16(localOffset + 26)
            let localExtraLength = u16(localOffset + 28)
            let localNameStart = localOffset + 30
            let payloadStart = localNameStart + localNameLength + localExtraLength
            guard localNameStart <= centralStart - localNameLength,
                  payloadStart <= centralStart - compSize,
                  data.subdata(in: localNameStart..<(localNameStart + localNameLength)) == nameData,
                  localFlags == flags, localMethod == method,
                  validExtraFields(start: localNameStart + localNameLength, length: localExtraLength)
            else { return false }
            var payloadEnd = payloadStart + compSize
            if flags & 0x0008 == 0 {
                guard u32(localOffset + 14) == Int(crc),
                      u32(localOffset + 18) == compSize,
                      u32(localOffset + 22) == uncompSize else { return false }
            } else {
                guard u32(localOffset + 14) == 0, u32(localOffset + 18) == 0,
                      u32(localOffset + 22) == 0 else { return false }
                let descriptorStart = payloadEnd
                let hasSignature = descriptorStart <= centralStart - 16 &&
                    u32(descriptorStart) == 0x08074b50
                let values = descriptorStart + (hasSignature ? 4 : 0)
                guard values <= centralStart - 12, u32(values) == Int(crc),
                      u32(values + 4) == compSize, u32(values + 8) == uncompSize else { return false }
                payloadEnd = values + 12
            }
            let entry = Entry(name: name, flags: flags, method: method, crc32: crc,
                              compSize: compSize, uncompSize: uncompSize,
                              localOffset: localOffset)
            pending.append((entry, nameData.count, payloadStart..<(payloadStart + compSize),
                            localOffset..<payloadEnd))
            off += 46 + nameLen + extraLen + commentLen
        }
        guard off == centralEnd else { return false }
        let occupied = pending.map(\.occupied).sorted { $0.lowerBound < $1.lowerBound }
        for pair in zip(occupied, occupied.dropFirst()) where pair.0.upperBound > pair.1.lowerBound {
            return false
        }
        for row in pending {
            guard budget.chargeEntry(pathByteCount: row.pathBytes,
                                     advertisedByteCount: row.entry.uncompSize) else { return false }
            if !row.entry.name.hasSuffix("/") {
                guard row.entry.uncompSize <= budget.limits.fileBytes,
                      budget.chargeInflated(row.entry.uncompSize),
                      let bytes = inflated(row.entry, compressedRange: row.compressed) else { return false }
                entries[row.entry.name] = row.entry
                inflatedFiles[row.entry.name] = bytes
            }
        }
        return true
    }

    func file(_ name: String) -> Data? {
        inflatedFiles[name]
    }
}

// =============================================================================
// PNG decode → straight (un-premultiplied) RGBA8
// =============================================================================
struct RGBAImage {
    var width: Int
    var height: Int
    var pixels: [UInt8]   // straight RGBA, width*height*4
}

func decodePNG(_ data: Data, budget: ResourcePackPreparationBudget? = nil) -> RGBAImage? {
    guard budget?.shouldContinue != false else { return nil }
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    guard w > 0, h > 0, w <= 4096, h <= 8192,
          budget?.chargeDecodedRGBA(width: w, height: h) != false else { return nil }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let ok = px.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return false }
        ctx.interpolationQuality = .none
        // This bitmap context's untransformed CGImage draw writes the authored
        // PNG top scanline to buffer row zero. A translate/negative-scale here
        // would invert it. The literal-scanline fixture locks that contract
        // independently of Core Graphics image encoding.
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    // un-premultiply back to straight alpha (atlas + UI expect straight RGBA)
    var i = 0
    while i < px.count {
        if i & 0x3ffff == 0, budget?.shouldContinue == false { return nil }
        let a = Int(px[i + 3])
        if a > 0 && a < 255 {
            px[i] = UInt8(min(255, Int(px[i]) * 255 / a))
            px[i + 1] = UInt8(min(255, Int(px[i + 1]) * 255 / a))
            px[i + 2] = UInt8(min(255, Int(px[i + 2]) * 255 / a))
        }
        i += 4
    }
    return RGBAImage(width: w, height: h, pixels: px)
}

// ---- pixel helpers ----------------------------------------------------------

/// nearest-neighbor (upscale / same size)
func scaleNearest(_ img: RGBAImage, to res: Int) -> [UInt8] {
    if img.width == res && img.height == res { return img.pixels }
    var out = [UInt8](repeating: 0, count: res * res * 4)
    for y in 0..<res {
        let sy = y * img.height / res
        for x in 0..<res {
            let sx = x * img.width / res
            let s = (sy * img.width + sx) * 4, d = (y * res + x) * 4
            out[d] = img.pixels[s]; out[d + 1] = img.pixels[s + 1]
            out[d + 2] = img.pixels[s + 2]; out[d + 3] = img.pixels[s + 3]
        }
    }
    return out
}

/// alpha-weighted box filter (downscale)
func scaleBox(_ img: RGBAImage, to res: Int) -> [UInt8] {
    if img.width == res && img.height == res { return img.pixels }
    // either axis smaller than the target → box dims would hit zero (div-by-zero
    // on a wide-but-short pack texture); nearest handles upscale fine
    if img.width < res || img.height < res { return scaleNearest(img, to: res) }
    var out = [UInt8](repeating: 0, count: res * res * 4)
    let bx = img.width / res, by = img.height / res
    for y in 0..<res {
        for x in 0..<res {
            var r = 0, g = 0, b = 0, a = 0, n = 0
            for dy in 0..<by {
                for dx in 0..<bx {
                    let s = ((y * by + dy) * img.width + (x * bx + dx)) * 4
                    let pa = Int(img.pixels[s + 3])
                    r += Int(img.pixels[s]) * pa
                    g += Int(img.pixels[s + 1]) * pa
                    b += Int(img.pixels[s + 2]) * pa
                    a += pa
                    n += 1
                }
            }
            let d = (y * res + x) * 4
            if a > 0 {
                out[d] = UInt8(r / a); out[d + 1] = UInt8(g / a); out[d + 2] = UInt8(b / a)
            }
            out[d + 3] = UInt8(a / n)
        }
    }
    return out
}

func scaleTo(_ img: RGBAImage, _ res: Int) -> [UInt8] {
    img.width > res ? scaleBox(img, to: res) : scaleNearest(img, to: res)
}

/// multiply RGB by a fixed color (bake a vanilla tint into the pixels)
func bakeTint(_ px: inout [UInt8], _ rgb: Int) {
    let tr = (rgb >> 16) & 255, tg = (rgb >> 8) & 255, tb = rgb & 255
    var i = 0
    while i < px.count {
        px[i] = UInt8(Int(px[i]) * tr / 255)
        px[i + 1] = UInt8(Int(px[i + 1]) * tg / 255)
        px[i + 2] = UInt8(Int(px[i + 2]) * tb / 255)
        i += 4
    }
}

// =============================================================================
// pack handle (zip or folder) + discovery
// =============================================================================
private struct ResourcePackFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let links: nlink_t
    let size: off_t

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        mode = value.st_mode
        links = value.st_nlink
        size = value.st_size
    }
}

/// A path-free, immutable source image. Resolution and TOCTOU-safe byte capture happen on main;
/// preparation workers receive only these owned values and can never reopen the filesystem.
enum ResourcePackSourcePayload: Sendable {
    case archive(Data)
    case folder([String: Data])
}

struct ResourcePackSourceSnapshot: Sendable {
    let fileName: String
    let displayName: String
    let payload: ResourcePackSourcePayload
}

struct ResourcePackStackSourceSnapshot: Sendable {
    let enabledNames: [String]
    let sources: [ResourcePackSourceSnapshot]
    let bundledAddOns: [BundledResourcePackAddOnID]
}

private func resourcePackDirectoryNames(_ directoryFD: Int32) -> [String]? {
    let fresh = Darwin.openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fresh >= 0, let directory = fdopendir(fresh) else {
        if fresh >= 0 { _ = Darwin.close(fresh) }
        return nil
    }
    defer { closedir(directory) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer -> String? in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(validatingUTF8: $0)
            }
        }
        guard let name else { return nil }
        if name == "." || name == ".." { continue }
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return nil }
        names.append(name)
    }
    guard errno == 0 else { return nil }
    return names.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
}

private func readResourcePackDescriptor(_ fd: Int32, expected: ResourcePackFileIdentity,
                                        maximum: Int) -> Data? {
    guard expected.size >= 0, expected.size <= maximum else { return nil }
    var result = Data()
    result.reserveCapacity(Int(expected.size))
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while offset < expected.size {
        let requested = min(buffer.count, Int(expected.size - offset))
        let count = buffer.withUnsafeMutableBytes {
            Darwin.pread(fd, $0.baseAddress, requested, offset)
        }
        if count > 0 {
            result.append(buffer, count: count)
            offset += off_t(count)
        } else if count < 0 && errno == EINTR {
            continue
        } else {
            return nil
        }
    }
    var after = stat()
    guard fstat(fd, &after) == 0, ResourcePackFileIdentity(after) == expected,
          result.count == Int(expected.size) else { return nil }
    return result
}

private func snapshotResourcePackFolder(
    directoryFD: Int32, prefix: String = "", budget: ResourcePackPreparationBudget,
    into files: inout [String: Data], normalizedNames: inout Set<String>
) -> Bool {
    guard budget.shouldContinue, let names = resourcePackDirectoryNames(directoryFD) else { return false }
    for name in names {
        guard budget.shouldContinue else { return false }
        let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
        guard safePackPath(relative, maximumBytes: budget.limits.pathBytes) else { return false }
        var linkStatus = stat()
        guard fstatat(directoryFD, name, &linkStatus, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        let linkIdentity = ResourcePackFileIdentity(linkStatus)
        let kind = linkStatus.st_mode & S_IFMT
        if kind == S_IFDIR {
            guard budget.chargeEntry(pathByteCount: relative.utf8.count + 1,
                                     advertisedByteCount: 0) else { return false }
            let child = Darwin.openat(directoryFD, name,
                                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard child >= 0 else { return false }
            var opened = stat()
            let valid = fstat(child, &opened) == 0 &&
                ResourcePackFileIdentity(opened) == linkIdentity &&
                snapshotResourcePackFolder(directoryFD: child, prefix: relative,
                                           budget: budget, into: &files,
                                           normalizedNames: &normalizedNames)
            _ = Darwin.close(child)
            guard valid else { return false }
        } else if kind == S_IFREG {
            let normalized = relative.lowercased()
            guard normalizedNames.insert(normalized).inserted,
                  linkStatus.st_nlink == 1, linkStatus.st_size >= 0,
                  linkStatus.st_size <= budget.limits.fileBytes,
                  budget.chargeEntry(pathByteCount: relative.utf8.count,
                                     advertisedByteCount: Int(linkStatus.st_size)),
                  budget.chargeInflated(Int(linkStatus.st_size)) else { return false }
            let fileFD = Darwin.openat(directoryFD, name,
                                       O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard fileFD >= 0 else { return false }
            var opened = stat()
            let bytes = fstat(fileFD, &opened) == 0 && ResourcePackFileIdentity(opened) == linkIdentity
                ? readResourcePackDescriptor(fileFD, expected: linkIdentity,
                                             maximum: budget.limits.fileBytes) : nil
            _ = Darwin.close(fileFD)
            guard let bytes else { return false }
            files[relative] = bytes
        } else {
            return false
        }
    }
    return true
}

final class ResourcePack {
    let fileName: String          // exact user or managed archive filename
    let displayName: String
    private(set) var description = ""
    private(set) var packFormat = 0
    private let files: [String: Data]
    /// lowercased path → exact path (zips from Windows tools vary in case)
    private var pathIndex: [String: String] = [:]
    /// the pack's texture root, detected from its own folder layout
    /// ("assets/<namespace>/textures/") — Java packs declare the namespace
    private(set) var texRoot = ""

    convenience init?(url: URL, budget: ResourcePackPreparationBudget = ResourcePackPreparationBudget()) {
        let parent = Darwin.open(url.deletingLastPathComponent().path,
                                 O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { return nil }
        defer { _ = Darwin.close(parent) }
        self.init(directoryFD: parent, fileName: url.lastPathComponent, budget: budget)
    }

    convenience init?(snapshot: ResourcePackSourceSnapshot,
                      budget: ResourcePackPreparationBudget = ResourcePackPreparationBudget()) {
        let files: [String: Data]
        switch snapshot.payload {
        case .archive(let data):
            guard let archive = MiniZip(data: data, budget: budget) else { return nil }
            var values: [String: Data] = [:]
            for key in archive.entries.keys { values[key] = archive.file(key) }
            files = values
        case .folder(let values):
            files = values
        }
        self.init(fileName: snapshot.fileName, displayName: snapshot.displayName,
                  snapshottedFiles: files, budget: budget)
    }

    private init?(fileName: String, displayName: String, snapshottedFiles: [String: Data],
                  budget: ResourcePackPreparationBudget) {
        guard !fileName.isEmpty, fileName.count <= 255, !fileName.contains("/"),
              !fileName.contains("\0"), budget.shouldContinue else { return nil }
        self.fileName = fileName
        self.displayName = displayName
        files = snapshottedFiles
        for key in files.keys {
            let normalized = key.lowercased()
            guard pathIndex[normalized] == nil else { return nil }
            pathIndex[normalized] = key
        }
        guard pathIndex.keys.contains(where: { $0.hasSuffix("pack.mcmeta") }) else { return nil }
        texRoot = preferredTextureRoot(from: pathIndex.keys)
        parseMeta(budget: budget)
        guard budget.isValid else { return nil }
    }

    init?(directoryFD parent: Int32, fileName: String,
          budget: ResourcePackPreparationBudget = ResourcePackPreparationBudget()) {
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("\0") else { return nil }
        self.fileName = fileName
        var linkStatus = stat()
        guard fstatat(parent, fileName, &linkStatus, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        let identity = ResourcePackFileIdentity(linkStatus)
        let kind = linkStatus.st_mode & S_IFMT
        var snapshot: [String: Data] = [:]
        if kind == S_IFDIR {
            displayName = fileName
            let directoryFD = Darwin.openat(parent, fileName,
                                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard directoryFD >= 0 else { return nil }
            defer { _ = Darwin.close(directoryFD) }
            var opened = stat()
            var normalized: Set<String> = []
            guard fstat(directoryFD, &opened) == 0, ResourcePackFileIdentity(opened) == identity,
                  snapshotResourcePackFolder(directoryFD: directoryFD, budget: budget,
                                             into: &snapshot, normalizedNames: &normalized)
            else { return nil }
        } else if kind == S_IFREG, (fileName as NSString).pathExtension.lowercased() == "zip" {
            displayName = String(fileName.dropLast(4))
            guard linkStatus.st_nlink == 1, linkStatus.st_size <= budget.limits.archiveBytes else { return nil }
            let fileFD = Darwin.openat(parent, fileName,
                                       O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard fileFD >= 0 else { return nil }
            defer { _ = Darwin.close(fileFD) }
            var opened = stat()
            guard fstat(fileFD, &opened) == 0, ResourcePackFileIdentity(opened) == identity,
                  let bytes = readResourcePackDescriptor(fileFD, expected: identity,
                                                         maximum: budget.limits.archiveBytes),
                  let archive = MiniZip(data: bytes, budget: budget) else { return nil }
            for key in archive.entries.keys { snapshot[key] = archive.file(key) }
        } else {
            return nil
        }
        files = snapshot
        for key in files.keys {
            let normalized = key.lowercased()
            guard pathIndex[normalized] == nil else { return nil }
            pathIndex[normalized] = key
        }
        guard pathIndex.keys.contains(where: { $0.hasSuffix("pack.mcmeta") }) else { return nil }
        // Texture packs often include helper namespaces (forge/fabric/realms).
        // Block/item/UI art is vanilla-compatible only under minecraft; using
        // dictionary iteration here made launches randomly fall back to the
        // procedural atlas. Prefer minecraft and keep fallback deterministic.
        texRoot = preferredTextureRoot(from: pathIndex.keys)
        parseMeta(budget: budget)
        guard budget.isValid else { return nil }
    }

    init?(data: Data, fileName: String,
          budget: ResourcePackPreparationBudget = ResourcePackPreparationBudget()) {
        guard fileName.count <= 255, let archive = MiniZip(data: data, budget: budget) else { return nil }
        self.fileName = fileName
        displayName = fileName.hasSuffix(".zip") ? String(fileName.dropLast(4)) : fileName
        var snapshot: [String: Data] = [:]
        for key in archive.entries.keys {
            let normalized = key.lowercased()
            guard pathIndex[normalized] == nil else { return nil }
            pathIndex[normalized] = key
            snapshot[key] = archive.file(key)
        }
        files = snapshot
        guard pathIndex.keys.contains(where: { $0.hasSuffix("pack.mcmeta") }) else { return nil }
        texRoot = preferredTextureRoot(from: pathIndex.keys)
        parseMeta(budget: budget)
        guard budget.isValid else { return nil }
    }

    /// raw bytes for an in-pack path ("assets/<ns>/textures/block/stone.png")
    func file(_ path: String) -> Data? {
        // some packs nest everything one folder deep inside the zip
        for candidate in [path, prefixedPath(path)] {
            guard let c = candidate, let exact = pathIndex[c.lowercased()] else { continue }
            if let bytes = files[exact] { return bytes }
        }
        return nil
    }

    private var nestedPrefix: String?
    private var nestedResolved = false
    private func prefixedPath(_ path: String) -> String? {
        if !nestedResolved {
            nestedResolved = true
            if pathIndex["pack.mcmeta"] == nil,
               let meta = pathIndex.keys.first(where: { $0.hasSuffix("/pack.mcmeta") && $0.components(separatedBy: "/").count == 2 }) {
                nestedPrefix = String(meta.dropLast("pack.mcmeta".count))
            }
        }
        guard let p = nestedPrefix else { return nil }
        return p + path
    }

    func has(_ path: String) -> Bool {
        pathIndex[path.lowercased()] != nil || (prefixedPath(path).map { pathIndex[$0.lowercased()] != nil } ?? false)
    }

    /// all in-pack paths under a directory prefix (normalized, nested prefix stripped)
    func list(prefix: String) -> [String] {
        let p = prefix.lowercased()
        var out: [String] = []
        for k in pathIndex.keys {
            if k.hasPrefix(p) { out.append(pathIndex[k]!) }
            else if let np = nestedPrefixLowercased(), k.hasPrefix(np + p) {
                out.append(String(pathIndex[k]!.dropFirst(np.count)))
            }
        }
        return out
    }
    private func nestedPrefixLowercased() -> String? {
        _ = prefixedPath("x")   // force resolution
        return nestedPrefix?.lowercased()
    }

    private func parseMeta(budget: ResourcePackPreparationBudget) {
        guard let d = file("pack.mcmeta"), d.count <= budget.limits.metadataBytes,
              budget.chargeMetadata(d.count),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pack = json["pack"] as? [String: Any] else {
            _ = budget.reject()
            return
        }
        packFormat = pack["pack_format"] as? Int ?? 0
        if let s = pack["description"] as? String {
            description = s
        } else if let arr = pack["description"] as? [Any] {
            description = arr.compactMap { ($0 as? [String: Any])?["text"] as? String ?? $0 as? String }.joined()
        } else if let obj = pack["description"] as? [String: Any] {
            description = obj["text"] as? String ?? ""
        }
        // strip § formatting codes for our 5×7 UI font
        while let r = description.range(of: "§") {
            let next = description.index(after: r.lowerBound)
            description.removeSubrange(r.lowerBound..<(next < description.endIndex ? description.index(after: next) : description.endIndex))
        }
    }
}

func resourcePacksDir() -> URL {
    let dir = vcSupportDir().appendingPathComponent("resourcepacks", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// =============================================================================
// Reviewed managed Faithful assets. These exact hashes are the runtime and
// packaging authority; managed files are never selected by ambient discovery.
// =============================================================================
enum BundledResourcePackAssetRole { case base, addOn(BundledResourcePackAddOnID) }
struct BundledResourcePackAsset {
    let role: BundledResourcePackAssetRole
    let fileName: String
    let displayName: String
    let sha256: String
    let requiredPaths: [String]
}

let BUNDLED_RESOURCE_PACK_ASSETS: [BundledResourcePackAsset] = [
    .init(role: .base, fileName: "Faithful 64x - December 2025 Release.zip",
          displayName: "Faithful 64x",
          sha256: "a136d9101a4748558587980dace3cd7447b758fb72c4684d15fb805d0a812dac",
          requiredPaths: ["pack.mcmeta", "LICENSE.txt",
            "assets/minecraft/textures/block/stone.png",
            "assets/minecraft/textures/item/diamond.png",
            "assets/minecraft/textures/gui/container/inventory.png",
            "assets/minecraft/textures/font/ascii.png"]),
    .init(role: .addOn(.oreBorders64x), fileName: "Faithful 64x - Ore Borders 64x.zip",
          displayName: "Ore Borders 64x",
          sha256: "232b8a64d745dc08b958c3c4c07167bd3f38eebdc4cd682da9d1016b2ed190f8",
          requiredPaths: ["pack.mcmeta", "LICENSE.txt", "CREDITS.txt",
            "assets/minecraft/textures/block/ancient_debris_side.png",
            "assets/minecraft/textures/block/ancient_debris_top.png",
            "assets/minecraft/textures/block/coal_ore.png",
            "assets/minecraft/textures/block/copper_ore.png",
            "assets/minecraft/textures/block/deepslate_coal_ore.png",
            "assets/minecraft/textures/block/deepslate_copper_ore.png",
            "assets/minecraft/textures/block/deepslate_diamond_ore.png",
            "assets/minecraft/textures/block/deepslate_emerald_ore.png",
            "assets/minecraft/textures/block/deepslate_gold_ore.png",
            "assets/minecraft/textures/block/deepslate_iron_ore.png",
            "assets/minecraft/textures/block/deepslate_lapis_ore.png",
            "assets/minecraft/textures/block/deepslate_redstone_ore.png",
            "assets/minecraft/textures/block/diamond_ore.png",
            "assets/minecraft/textures/block/emerald_ore.png",
            "assets/minecraft/textures/block/gilded_blackstone.png",
            "assets/minecraft/textures/block/gold_ore.png",
            "assets/minecraft/textures/block/iron_ore.png",
            "assets/minecraft/textures/block/lapis_ore.png",
            "assets/minecraft/textures/block/nether_gold_ore.png",
            "assets/minecraft/textures/block/nether_quartz_ore.png",
            "assets/minecraft/textures/block/redstone_ore.png"]),
    .init(role: .addOn(.staticLanterns), fileName: "Faithful 64x - Static Lanterns.zip",
          displayName: "Static Lanterns",
          sha256: "d0165130d505da8996354c21090a47fd6def87f4c2a96442f1a4282b1bf2cbc8",
          requiredPaths: ["pack.mcmeta", "LICENSE.txt",
            "assets/minecraft/textures/block/sea_lantern.png"]),
]

let DEFAULT_PACK_FILE = BUNDLED_RESOURCE_PACK_ASSETS[0].fileName
let DEFAULT_PACK_LABEL = "Default (Faithful 64x)"
let LEGACY_DEFAULT_PACK_FILES: Set<String> = ["Faithful 32x - 1.20.1.zip"]

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func readRegularFileNoFollow(directoryFD: Int32, name: String,
                                     maximum: Int = MAX_PACK_ARCHIVE_BYTES) -> Data? {
    guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return nil }
    let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { _ = Darwin.close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
          before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximum
    else { return nil }
    return readResourcePackDescriptor(fd, expected: ResourcePackFileIdentity(before),
                                      maximum: maximum)
}

private func verifiedBundledBytes(_ asset: BundledResourcePackAsset) -> Data? {
    guard let path = bundleResourcePath(asset.fileName) else { return nil }
    let url = URL(fileURLWithPath: path)
    let parentFD = Darwin.open(url.deletingLastPathComponent().path,
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parentFD >= 0 else { return nil }
    defer { _ = Darwin.close(parentFD) }
    let budget = ResourcePackPreparationBudget()
    guard let bytes = readRegularFileNoFollow(directoryFD: parentFD, name: url.lastPathComponent),
          sha256Hex(bytes) == asset.sha256, let zip = MiniZip(data: bytes, budget: budget),
          asset.requiredPaths.allSatisfy({ zip.file($0) != nil }) else { return nil }
    return bytes
}

private func atomicInstallManagedBytes(_ bytes: Data, asset: BundledResourcePackAsset,
                                       directoryFD: Int32) -> Bool {
    let temporary = ".\(asset.fileName).\(UUID().uuidString).tmp"
    let fd = Darwin.openat(directoryFD, temporary,
                           O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return false }
    var fileOpen = true
    var renamed = false
    defer {
        if fileOpen { _ = Darwin.close(fd) }
        if !renamed { _ = Darwin.unlinkat(directoryFD, temporary, 0) }
    }
    let wrote = bytes.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return bytes.isEmpty }
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { return false }
        }
        return true
    }
    guard wrote else { return false }
    while fsync(fd) != 0 { if errno != EINTR { return false } }
    guard Darwin.close(fd) == 0 else { fileOpen = false; return false }
    fileOpen = false
    guard renameat(directoryFD, temporary, directoryFD, asset.fileName) == 0 else { return false }
    renamed = true
    while fsync(directoryFD) != 0 { if errno != EINTR { return false } }
    return readRegularFileNoFollow(directoryFD: directoryFD, name: asset.fileName)
        .map(sha256Hex) == asset.sha256
}

/// restore the bundled default pack if the app-support copy is missing or stale
@discardableResult
func ensureBundledResourcePackAssets() -> [String: Data] {
    let directory = resourcePacksDir()
    let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directoryFD >= 0 else { return [:] }
    defer { _ = Darwin.close(directoryFD) }
    var result: [String: Data] = [:]
    for asset in BUNDLED_RESOURCE_PACK_ASSETS {
        guard let source = verifiedBundledBytes(asset) else {
            print("[packs] bundled \(asset.displayName) failed verification")
            continue
        }
        if readRegularFileNoFollow(directoryFD: directoryFD, name: asset.fileName).map(sha256Hex) != asset.sha256,
           !atomicInstallManagedBytes(source, asset: asset, directoryFD: directoryFD) {
            print("[packs] could not restore \(asset.displayName)")
            continue
        }
        guard let installed = readRegularFileNoFollow(directoryFD: directoryFD, name: asset.fileName),
              sha256Hex(installed) == asset.sha256 else { continue }
        // Hash, parse, copy, and generation preparation all retain the exact
        // immutable bundle snapshot. The post-copy descriptor read above is
        // only a destination attestation, never a second source of truth.
        result[asset.fileName] = source
    }
    return result
}

func ensureDefaultPack() {
    _ = ensureBundledResourcePackAssets()
}

/// user pack list → applied list: default pack force-appended at the END
/// (lowest priority — user packs override it, like vanilla's layering)
func withDefaultPack(_ userPacks: [String], addOns: [BundledResourcePackAddOnID] = []) -> [String] {
    let managed = Set(BUNDLED_RESOURCE_PACK_ASSETS.map(\.fileName)).union(LEGACY_DEFAULT_PACK_FILES)
    var list = userPacks.filter { !managed.contains($0) }
    for id in BUNDLED_RESOURCE_PACK_ADD_ONS.map(\.id) where addOns.contains(id) {
        if let asset = BUNDLED_RESOURCE_PACK_ASSETS.first(where: {
            if case .addOn(let candidate) = $0.role { return candidate == id }
            return false
        }) { list.append(asset.fileName) }
    }
    let dest = resourcePacksDir().appendingPathComponent(DEFAULT_PACK_FILE)
    if FileManager.default.fileExists(atPath: dest.path) { list.append(DEFAULT_PACK_FILE) }
    return list
}

func discoverResourcePacks() -> [ResourcePack] {
    let dir = resourcePacksDir()
    guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
    return items
        .filter { !$0.lastPathComponent.hasPrefix(".") }
        .compactMap { ResourcePack(url: $0) }
        .sorted { $0.fileName.lowercased() < $1.fileName.lowercased() }
}

// =============================================================================
// tile name → pack texture path mapping
// =============================================================================

// plain renames: tile name → ordered candidate paths under the texture root
private let NAME_MAP: [String: [String]] = [
    "grass_top": ["block/grass_block_top"],
    "grass_side": ["block/grass_block_side"],
    "farmland_dry": ["block/farmland"],
    "farmland_wet": ["block/farmland_moist"],
    "sandstone_side": ["block/sandstone"],
    "red_sandstone_side": ["block/red_sandstone"],
    "snow_block": ["block/snow"],
    "frosted_ice": ["block/frosted_ice_0"],
    "dried_kelp_block": ["block/dried_kelp_side"],
    "magma_block": ["block/magma"],
    "water": ["block/water_still"],
    "lava": ["block/lava_still"],
    "fire": ["block/fire_0"],
    "soul_fire": ["block/soul_fire_0"],
    "short_grass": ["block/short_grass", "block/grass"],
    "mangrove_roots": ["block/mangrove_roots_side", "block/mangrove_roots"],
    "suspicious_sand": ["block/suspicious_sand_0"],
    "suspicious_gravel": ["block/suspicious_gravel_0"],
    "bamboo": ["block/bamboo_stalk"],
    "bamboo_sapling": ["block/bamboo_stage0"],
    "big_dripleaf": ["block/big_dripleaf_top"],
    "small_dripleaf": ["block/small_dripleaf_top"],
    "azalea": ["block/azalea_top"],
    "flowering_azalea": ["block/flowering_azalea_top"],
    "pitcher_plant_top": ["block/pitcher_plant_top", "block/pitcher_crop_top"],
    "pitcher_plant_bottom": ["block/pitcher_plant_bottom", "block/pitcher_crop_bottom"],
    "pitcher_crop": ["block/pitcher_crop_top", "block/pitcher_crop_bottom"],
    "furnace_front_lit": ["block/furnace_front_on"],
    "blast_furnace_front_lit": ["block/blast_furnace_front_on"],
    "smoker_front_lit": ["block/smoker_front_on"],
    "observer_back_lit": ["block/observer_back_on"],
    "anvil_side": ["block/anvil"],
    "cartography_table_side": ["block/cartography_table_side3"],
    "lectern_side": ["block/lectern_sides"],
    "soul_campfire_log": ["block/soul_campfire_log_lit"],
    "respawn_anchor_side": ["block/respawn_anchor_side0"],
    "honey_block": ["block/honey_block_side"],
    "calibrated_sculk_sensor_side": ["block/calibrated_sculk_sensor_input_side"],
    "pointed_dripstone": ["block/pointed_dripstone_down_tip"],
    "sniffer_egg": ["block/sniffer_egg_not_cracked_north", "block/sniffer_egg_not_cracked"],
    "cocoa_stage3": ["block/cocoa_stage2"],
    "redstone_dust_line": ["block/redstone_dust_line0"],
    "stem_stage7": ["block/pumpkin_stem", "block/melon_stem"],
    "attached_stem": ["block/attached_pumpkin_stem", "block/attached_melon_stem"],
    // particle sprites (best-effort; procedural fallback is fine)
    "smoke_particle": ["particle/big_smoke_2", "particle/generic_3"],
    "flame_particle": ["particle/flame"],
    "heart_particle": ["particle/heart"],
    "angry_particle": ["particle/angry"],
    "crit_particle": ["particle/critical_hit"],
    "splash_particle": ["particle/splash_0"],
    "bubble_particle": ["particle/bubble"],
    "note_particle": ["particle/note"],
    "soul_particle": ["particle/soul_1", "particle/soul_0"],
    "sweep_particle": ["particle/sweep_2", "particle/sweep_0"],
    "slime_particle": ["item/slime_ball"],
    "snow_particle": ["particle/snowflake"],
    "petal_particle": ["particle/cherry_0", "particle/glow"],
    "portal_particle": ["particle/glow"],
    "redstone_particle": ["particle/glitter_0"],
    "enchant_particle": ["particle/sga_a"],
    // entity-textured / shader-effect blocks: stay procedural
    "air": [], "cave_air": [], "void_air": [],
    "end_portal": [], "chest_side": [], "ender_chest_side": [],
    "decorated_pot_side": [], "bell_body": [],
]

/// fixed vanilla tints to bake (engine renders these tiles untinted, MC art is grayscale)
private let BAKE_TINT: [String: Int] = [
    "birch_leaves": 0x80A755,
    "spruce_leaves": 0x619961,
    "redstone_dust_dot": 0xFF3030,
    "redstone_dust_line": 0xFF3030,
]

/// tiles whose MC art is grayscale-by-design and must KEEP the engine's biome
/// tint when a pack overrides them; every other overridden tile renders untinted
private let TINT_EXPECTED: Set<String> = [
    "grass_top", "water", "short_grass", "fern", "tall_grass", "large_fern",
    "sugar_cane", "vine", "lily_pad", "big_dripleaf", "small_dripleaf",
    "oak_leaves", "jungle_leaves", "acacia_leaves", "dark_oak_leaves", "mangrove_leaves",
]

private func candidates(_ tile: String) -> [String] {
    if let m = NAME_MAP[tile] { return m }
    if tile.hasPrefix("destroy_"), let n = Int(tile.dropFirst("destroy_".count)) {
        return ["block/destroy_stage_\(n)"]
    }
    if tile.hasPrefix("stem_stage"), Int(tile.dropFirst("stem_stage".count)) != nil {
        return ["block/pumpkin_stem", "block/melon_stem"]
    }
    return ["block/\(tile)"]
}

/// tiles built by stacking MC top/bottom halves into one square (door + 2-tall plants)
private func compositeHalves(_ tile: String) -> (top: String, bottom: String)? {
    if tile.hasSuffix("_door") {
        return ("block/\(tile)_top", "block/\(tile)_bottom")
    }
    if tile == "tall_grass" || tile == "large_fern" {
        return ("block/\(tile)_top", "block/\(tile)_bottom")
    }
    return nil
}

// vanilla stem age tint: r = age*32, g = 255-age*8, b = age*4
private func stemTint(_ age: Int) -> Int {
    (min(255, age * 32) << 16) | ((255 - age * 8) << 8) | (age * 4)
}

// =============================================================================
// atlas build
// =============================================================================
struct TileAnimation {
    let slice: Int
    let frames: [[UInt8]]           // each res*res*4
    let order: [(Int, Int)]         // (frame index, ticks)
    let interpolate: Bool
}

struct PackAtlasResult {
    var res: Int
    var slices: [[UInt8]]
    var icon16: BuiltAtlas
    var animations: [TileAnimation]
    var itemIcons: [String: [UInt8]]
    var tintGate: [UInt8]
    var textureGate: [UInt8]
    var fluidAnimated: Bool
    var appliedTiles: Int
    var appliedItems: Int
}

private struct LoadedTexture {
    var image: RGBAImage
    /// (frame index, ticks) play order + interpolate flag
    var animation: (frames: [(Int, Int)], interpolate: Bool)?
}

/// load a texture + its optional .mcmeta animation from the pack stack (first hit wins)
// =============================================================================
// entity-texture crops — beds, chests, the bell and the decorated pot are
// rendered by vanilla as block ENTITIES, so no Java pack has flat block/
// textures for them; the art lives in entity/ unwraps. These crops lift the
// pack's own art from there so every visible surface comes from the pack.
// (the end portal stays an engine effect — vanilla renders it as a shader,
// and packs have no texture for it either)
// =============================================================================
private struct EntityTileCrop {
    let path: String                                           // relative to texRoot, no .png
    let rects: [(x: Double, y: Double, w: Double, h: Double)]  // fractional; stacked vertically
    let rotate: Bool                                           // long bed strips lie sideways
}

private func entityTileCrop(_ tile: String) -> EntityTileCrop? {
    if tile.hasSuffix("_bed_top") {
        let c = String(tile.dropLast("_bed_top".count))
        // head (pillow) half over foot half, like the painter's layout
        return EntityTileCrop(path: "entity/bed/\(c)",
                              rects: [(6 / 64, 6 / 64, 16 / 64, 16 / 64),
                                      (6 / 64, 28 / 64, 16 / 64, 16 / 64)], rotate: false)
    }
    if tile.hasSuffix("_bed_side") {
        let c = String(tile.dropLast("_bed_side".count))
        // Head and foot side strips are independently rotated then stacked so
        // the mesher can select the semantic half without stretching either.
        return EntityTileCrop(path: "entity/bed/\(c)",
                              rects: [(22 / 64, 6 / 64, 6 / 64, 16 / 64),
                                      (22 / 64, 28 / 64, 6 / 64, 16 / 64)], rotate: true)
    }
    switch tile {
    case "chest_side":
        // lid front (5 rows) stacked on base front (10 rows)
        return EntityTileCrop(path: "entity/chest/normal",
                              rects: [(14 / 64, 14 / 64, 14 / 64, 5 / 64),
                                      (14 / 64, 33 / 64, 14 / 64, 10 / 64)], rotate: false)
    case "ender_chest_side":
        return EntityTileCrop(path: "entity/chest/ender",
                              rects: [(14 / 64, 14 / 64, 14 / 64, 5 / 64),
                                      (14 / 64, 33 / 64, 14 / 64, 10 / 64)], rotate: false)
    case "bell_body":
        return EntityTileCrop(path: "entity/bell/bell_body",
                              rects: [(6 / 32, 6 / 32, 6 / 32, 7 / 32)], rotate: false)
    case "decorated_pot_side":
        return EntityTileCrop(path: "entity/decorated_pot/decorated_pot_side",
                              rects: [(0, 0, 1, 1)], rotate: false)
    default:
        return nil
    }
}

private func cropEntityTile(_ packs: [ResourcePack], _ crop: EntityTileCrop,
                            budget: ResourcePackPreparationBudget) -> RGBAImage? {
    guard let tex = loadTexture(packs, crop.path, budget: budget) else { return nil }
    let img = tex.image
    var pieces: [RGBAImage] = []
    for r in crop.rects {
        guard budget.shouldContinue else { return nil }
        let x0 = Int(r.x * Double(img.width)), y0 = Int(r.y * Double(img.height))
        let w = max(1, Int(r.w * Double(img.width))), h = max(1, Int(r.h * Double(img.height)))
        guard x0 + w <= img.width, y0 + h <= img.height else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = ((y0 + y) * img.width + (x0 + x)) * 4, d = (y * w + x) * 4
                px[d] = img.pixels[s]; px[d + 1] = img.pixels[s + 1]
                px[d + 2] = img.pixels[s + 2]; px[d + 3] = img.pixels[s + 3]
            }
        }
        var piece = RGBAImage(width: w, height: h, pixels: px)
        if crop.rotate {
            // Rotate each strip before stacking; rotating the combined image
            // would turn semantic head/foot rows into left/right columns.
            var rotated = [UInt8](repeating: 0, count: piece.width * piece.height * 4)
            for r in 0..<piece.width {
                for c in 0..<piece.height {
                    let s = (c * piece.width + r) * 4, d = (r * piece.height + c) * 4
                    rotated[d] = piece.pixels[s]; rotated[d + 1] = piece.pixels[s + 1]
                    rotated[d + 2] = piece.pixels[s + 2]; rotated[d + 3] = piece.pixels[s + 3]
                }
            }
            piece = RGBAImage(width: piece.height, height: piece.width, pixels: rotated)
        }
        pieces.append(piece)
    }
    var out: RGBAImage
    if pieces.count == 1 {
        out = pieces[0]
    } else {
        // stack vertically (all crops share a width by construction)
        let w = pieces[0].width
        let h = pieces.reduce(0) { $0 + $1.height }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var yOff = 0
        for p in pieces {
            for y in 0..<p.height {
                let s = y * p.width * 4, d = ((yOff + y) * w) * 4
                px.replaceSubrange(d..<(d + p.width * 4), with: p.pixels[s..<(s + p.width * 4)])
            }
            yOff += p.height
        }
        out = RGBAImage(width: w, height: h, pixels: px)
    }
    return out
}

/// A packed chest slice has a full single chest followed by its two double
/// chest parts.  Missing pack parts use the single image, keeping malformed or
/// older packs valid while still giving a deterministic semantic layout.
private func cropSemanticChestTile(_ packs: [ResourcePack],
                                   budget: ResourcePackPreparationBudget) -> RGBAImage? {
    let rects: [(x: Double, y: Double, w: Double, h: Double)] = [
        (14.0 / 64, 14.0 / 64, 14.0 / 64, 5.0 / 64),
        (14.0 / 64, 33.0 / 64, 14.0 / 64, 10.0 / 64),
    ]
    let normal = EntityTileCrop(path: "entity/chest/normal", rects: rects, rotate: false)
    guard let single = cropEntityTile(packs, normal, budget: budget) else { return nil }
    let left = cropEntityTile(packs, EntityTileCrop(path: "entity/chest/normal_left", rects: rects, rotate: false), budget: budget) ?? single
    let right = cropEntityTile(packs, EntityTileCrop(path: "entity/chest/normal_right", rects: rects, rotate: false), budget: budget) ?? single
    guard single.width == left.width, single.width == right.width,
          single.height == left.height, single.height == right.height else { return single }
    let height = single.height + left.height + right.height
    var pixels = [UInt8](repeating: 0, count: single.width * height * 4)
    var offset = 0
    for image in [single, left, right] {
        guard image.width == single.width else { return single }
        for y in 0..<image.height {
            let source = y * image.width * 4
            let destination = (offset + y) * single.width * 4
            pixels.replaceSubrange(destination..<(destination + image.width * 4),
                                   with: image.pixels[source..<(source + image.width * 4)])
        }
        offset += image.height
    }
    return RGBAImage(width: single.width, height: height, pixels: pixels)
}

private func loadTexture(_ packs: [ResourcePack], _ relPath: String,
                         budget: ResourcePackPreparationBudget) -> LoadedTexture? {
    for p in packs {
        guard budget.shouldContinue else { return nil }
        let full = "\(p.texRoot)\(relPath).png"
        guard let d = p.file(full) else { continue }
        guard let img = decodePNG(d, budget: budget) else {
            _ = budget.reject()
            return nil
        }
        var anim: (frames: [(Int, Int)], interpolate: Bool)?
        if img.height > img.width, img.height % img.width == 0 {
            // animated strip; .mcmeta refines timing/order
            var frametime = 1
            var interpolate = false
            var frames: [(Int, Int)] = []
            if let md = p.file(full + ".mcmeta") {
                guard md.count <= budget.limits.metadataBytes, budget.chargeMetadata(md.count),
                      let json = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
                      let a = json["animation"] as? [String: Any] else {
                    _ = budget.reject()
                    return nil
                }
                frametime = a["frametime"] as? Int ?? 1
                guard budget.validDuration(frametime) else { return nil }
                interpolate = a["interpolate"] as? Bool ?? false
                if let list = a["frames"] as? [Any] {
                    guard list.count <= budget.limits.framesPerTexture else {
                        _ = budget.reject()
                        return nil
                    }
                    for f in list {
                        if let i = f as? Int { frames.append((i, frametime)) }
                        else if let o = f as? [String: Any], let i = o["index"] as? Int {
                            let duration = o["time"] as? Int ?? frametime
                            guard budget.validDuration(duration) else { return nil }
                            frames.append((i, duration))
                        } else { _ = budget.reject(); return nil }
                    }
                }
            }
            let count = img.height / img.width
            guard count <= budget.limits.framesPerTexture else { _ = budget.reject(); return nil }
            if frames.isEmpty { frames = (0..<count).map { ($0, frametime) } }
            guard frames.allSatisfy({ $0.0 >= 0 && $0.0 < count }),
                  budget.chargeAnimationFrames(frames.count) else { _ = budget.reject(); return nil }
            if frames.count > 1 { anim = (frames, interpolate) }
        }
        return LoadedTexture(image: img, animation: anim)
    }
    return nil
}

/// cut frame i out of a vertical strip
private func stripFrame(_ img: RGBAImage, _ i: Int) -> RGBAImage {
    let w = img.width
    let start = i * w * w * 4
    return RGBAImage(width: w, height: w, pixels: Array(img.pixels[start..<(start + w * w * 4)]))
}

func buildPackAtlas(enabledFileNames: [String]) -> PackAtlasResult? {
    let budget = ResourcePackPreparationBudget()
    let all = discoverResourcePacks()
    let packs = enabledFileNames.compactMap { name in all.first { $0.fileName == name } }
    return buildPackAtlas(packs: packs, budget: budget)
}

func buildPackAtlas(packs: [ResourcePack],
                    budget: ResourcePackPreparationBudget = ResourcePackPreparationBudget()) -> PackAtlasResult? {
    guard !packs.isEmpty, budget.shouldContinue else { return nil }

    let base = ElysiumCore.buildAtlas()
    let names = allTileNames()

    // resolve every tile to (image, animation) or nil
    var resolved: [Int: LoadedTexture] = [:]
    var compositeSrcs: [Int: (RGBAImage, RGBAImage)] = [:]
    var entityTiles: [Int: RGBAImage] = [:]
    for (i, name) in names.enumerated() {
        guard budget.shouldContinue else { return nil }
        if let halves = compositeHalves(name) {
            if var t = loadTexture(packs, halves.top, budget: budget)?.image,
               var b = loadTexture(packs, halves.bottom, budget: budget)?.image {
                if t.height > t.width { t = stripFrame(t, 0) }
                if b.height > b.width { b = stripFrame(b, 0) }
                compositeSrcs[i] = (t, b)
            }
            continue
        }
        for c in candidates(name) {
            if let t = loadTexture(packs, c, budget: budget) { resolved[i] = t; break }
        }
        if resolved[i] == nil {
            if name == "chest_side", let img = cropSemanticChestTile(packs, budget: budget) {
                entityTiles[i] = img
            } else if let ec = entityTileCrop(name), let img = cropEntityTile(packs, ec, budget: budget) {
                entityTiles[i] = img
            }
        }
    }

    // pick one atlas resolution: the largest native size found, clamped sanely
    var res = 16
    for t in resolved.values { res = max(res, min(128, t.image.width)) }
    for (a, b) in compositeSrcs.values { res = max(res, min(128, max(a.width, b.width))) }

    var slices: [[UInt8]] = []
    slices.reserveCapacity(names.count)
    var icon16: [[UInt8]] = []
    icon16.reserveCapacity(names.count)
    var animations: [TileAnimation] = []
    var tintGate = [UInt8](repeating: 1, count: names.count)
    var textureGate = [UInt8](repeating: 0, count: names.count)
    var fluidAnimated = false
    var applied = 0

    for (i, name) in names.enumerated() {
        guard budget.shouldContinue else { return nil }
        var px: [UInt8]
        if let t = resolved[i] {
            applied += 1
            textureGate[i] = 1
            if !TINT_EXPECTED.contains(name) { tintGate[i] = 0 }
            if let anim = t.animation {
                // frame 0 of the play order into the slice; full set to the animator
                var frames: [[UInt8]] = []
                let count = t.image.height / t.image.width
                for f in 0..<count {
                    var fp = scaleTo(stripFrame(t.image, f), res)
                    if let bake = BAKE_TINT[name] { bakeTint(&fp, bake) }
                    frames.append(fp)
                }
                px = frames[anim.frames[0].0]
                animations.append(TileAnimation(slice: i, frames: frames,
                                                order: anim.frames, interpolate: anim.interpolate))
                if name == "water" || name == "lava" || name == "fire" || name == "soul_fire" {
                    fluidAnimated = true
                }
            } else {
                var img = t.image
                if img.height > img.width { img = stripFrame(img, 0) }   // strip without anim meta
                px = scaleTo(img, res)
                if let bake = BAKE_TINT[name] { bakeTint(&px, bake) }
                if name.hasPrefix("stem_stage"), let age = Int(name.dropFirst("stem_stage".count)) {
                    // vanilla stem models crop from the bottom: keep 2*(age+1)/16 rows
                    let keep = res * 2 * (age + 1) / 16
                    for y in 0..<(res - keep) {
                        for x in 0..<res { px[(y * res + x) * 4 + 3] = 0 }
                    }
                    bakeTint(&px, stemTint(age))
                } else if name == "attached_stem" {
                    bakeTint(&px, stemTint(7))
                }
            }
        } else if let img = entityTiles[i] {
            applied += 1
            textureGate[i] = 1
            tintGate[i] = 0
            px = scaleTo(img, res)
        } else if let (top, bottom) = compositeSrcs[i] {
            applied += 1
            textureGate[i] = 1
            tintGate[i] = TINT_EXPECTED.contains(name) ? 1 : 0
            // squash both halves into one square (each block half repeats the tile)
            px = [UInt8](repeating: 0, count: res * res * 4)
            let half = res / 2
            let t = scaleTo(top, res), b = scaleTo(bottom, res)
            for y in 0..<half {
                for x in 0..<res {
                    let sT = ((y * 2) * res + x) * 4, dT = (y * res + x) * 4
                    px[dT] = t[sT]; px[dT + 1] = t[sT + 1]; px[dT + 2] = t[sT + 2]; px[dT + 3] = t[sT + 3]
                    let sB = ((y * 2) * res + x) * 4, dB = ((y + half) * res + x) * 4
                    px[dB] = b[sB]; px[dB + 1] = b[sB + 1]; px[dB + 2] = b[sB + 2]; px[dB + 3] = b[sB + 3]
                }
            }
        } else {
            // substrate fallback, upscaled to the pack resolution
            if ProcessInfo.processInfo.environment["ELYSIUM_PACKDEBUG"] != nil {
                print("[packs] no pack art for tile \(i): \(name)")
            }
            px = scaleNearest(RGBAImage(width: 16, height: 16, pixels: base.pixels[i]), to: res)
        }
        slices.append(px)
        icon16.append(scaleBox(RGBAImage(width: res, height: res, pixels: px), to: 16))
    }

    // item icons: every textures/item/*.png in the stack, 16× for the icon cache
    var itemIcons: [String: [UInt8]] = [:]
    let registeredItemImages = Set(itemDefs.flatMap { [$0.name, $0.icon] })
    for p in packs.reversed() {   // walk lowest→highest so highest priority wins
        for path in p.list(prefix: p.texRoot + "item/") where path.hasSuffix(".png") {
            guard budget.shouldContinue else { return nil }
            let base = String(path.components(separatedBy: "/").last!.dropLast(4))
            guard registeredItemImages.contains(base) else { continue }
            guard let d = p.file(path), var img = decodePNG(d, budget: budget) else { continue }
            if img.height > img.width, img.height % img.width == 0 {
                img = stripFrame(img, 0)
            }
            guard img.width == img.height else { continue }
            itemIcons[base] = scaleBox(img, to: 16)
        }
    }

    return PackAtlasResult(
        res: res, slices: slices,
        icon16: BuiltAtlas(count: names.count, pixels: icon16, missing: []),
        animations: animations, itemIcons: itemIcons, tintGate: tintGate, textureGate: textureGate,
        fluidAnimated: fluidAnimated, appliedTiles: applied, appliedItems: itemIcons.count)
}

// =============================================================================
// apply / revert — the single entry point used at boot and from the packs screen
// =============================================================================
/// the enabled pack stack, highest priority first — entity skins resolve here
var ACTIVE_PACKS: [ResourcePack] = []
private let RESOURCE_PACK_FALLBACK_NOTICE =
    "Faithful 64x is unavailable; built-in fallback active."

func resourcePackPresentationAfterActivePublication(
    _ current: ResourcePackPresentationSnapshot,
    activeAddOns: [BundledResourcePackAddOnID]
) -> ResourcePackPresentationSnapshot {
    ResourcePackPresentationSnapshot(
        generation: .faithful64x(activeAddOns: activeAddOns),
        noticeSerial: current.noticeSerial)
}

func resourcePackPresentationAfterFallbackPublication(
    _ current: ResourcePackPresentationSnapshot
) -> ResourcePackPresentationSnapshot {
    ResourcePackPresentationSnapshot(
        generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
        noticeSerial: current.noticeSerial == UInt64.max ? 1 : current.noticeSerial + 1,
        pendingNotice: RESOURCE_PACK_FALLBACK_NOTICE)
}

var RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
    generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
    pendingNotice: RESOURCE_PACK_FALLBACK_NOTICE)
@MainActor private var consumedResourcePackPresentationNoticeSerial: UInt64 = 0

@MainActor
func consumeResourcePackPresentationNotice() -> String? {
    let snapshot = RESOURCE_PACK_PRESENTATION
    guard case .proceduralFallback(let failedPackDisplayName) = snapshot.generation,
          failedPackDisplayName == "Faithful 64x",
          snapshot.noticeSerial != 0,
          snapshot.noticeSerial != consumedResourcePackPresentationNoticeSerial,
          let notice = snapshot.pendingNotice,
          notice == RESOURCE_PACK_FALLBACK_NOTICE else { return nil }
    consumedResourcePackPresentationNoticeSerial = snapshot.noticeSerial
    return notice
}

/// load + composite a vanilla entity texture from the active packs
/// (base + overlays alpha-blended in order, or stacked vertically); nil when absent
func packEntityImage(_ rels: [String], stack: Bool = false, tints: [Int] = []) -> RGBAImage? {
    packEntityImage(rels, packs: ACTIVE_PACKS, stack: stack, tints: tints, budget: nil)
}

private func packEntityImage(_ rels: [String], packs: [ResourcePack], stack: Bool = false,
                             tints: [Int] = [], budget: ResourcePackPreparationBudget?) -> RGBAImage? {
    guard !rels.isEmpty, !packs.isEmpty, budget?.shouldContinue != false else { return nil }
    func load(_ rel: String) -> RGBAImage? {
        for p in packs {
            if let d = p.file(p.texRoot + rel), var img = decodePNG(d, budget: budget) {
                // vanilla ships some entity art grayscale for render-time
                // tinting (tropical fish, sheep wool) — bake the tint here
                if let i = rels.firstIndex(of: rel), i < tints.count, tints[i] != 0xFFFFFF {
                    bakeTint(&img.pixels, tints[i])
                }
                return img
            }
        }
        return nil
    }
    guard var base = load(rels[0]) else { return nil }
    if stack {
        // vertical sheet: each entry appended below the previous (sheep + fur)
        for rel in rels.dropFirst() {
            guard let next = load(rel), next.width == base.width else { return nil }
            base = RGBAImage(width: base.width, height: base.height + next.height,
                             pixels: base.pixels + next.pixels)
        }
        return base
    }
    for rel in rels.dropFirst() {
        guard budget?.shouldContinue != false else { return nil }
        guard let over = load(rel), over.width == base.width, over.height == base.height else { continue }
        for i in stride(from: 0, to: base.pixels.count, by: 4) {
            let a = Int(over.pixels[i + 3])
            if a == 0 { continue }
            for c in 0..<3 {
                let o = Int(over.pixels[i + c]), b = Int(base.pixels[i + c])
                base.pixels[i + c] = UInt8((o * a + b * (255 - a)) / 255)
            }
            base.pixels[i + 3] = 255
        }
    }
    return base
}

private var iconPackPublicationActive = false // main-thread confined
enum IconPackPublicationBoundary { case staged, retired, uiWorldInstalled, coreCommitted }
var iconPackPublicationHook: ((IconPackPublicationBoundary) -> Void)?
var failNextIconPackPublicationBeforeMutation = false

private func resolvedResourcePackStack(
    _ userPacks: [String], bundledAddOns: [BundledResourcePackAddOnID],
    budget: ResourcePackPreparationBudget
) -> (names: [String], packs: [ResourcePack])? {
    let managedBytes = ensureBundledResourcePackAssets()
    let enabled = withDefaultPack(userPacks, addOns: bundledAddOns)
    guard budget.shouldContinue, Set(enabled).count == enabled.count else { return nil }
    let managedNames = Set(BUNDLED_RESOURCE_PACK_ASSETS.map(\.fileName))
    let directory = resourcePacksDir()
    let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directoryFD >= 0 else { return nil }
    defer { _ = Darwin.close(directoryFD) }
    let packs = enabled.compactMap { name -> ResourcePack? in
        guard budget.shouldContinue else { return nil }
        if managedNames.contains(name), let bytes = managedBytes[name] {
            return ResourcePack(data: bytes, fileName: name, budget: budget)
        }
        guard !managedNames.contains(name) else { return nil }
        return ResourcePack(directoryFD: directoryFD, fileName: name, budget: budget)
    }
    guard packs.count == enabled.count, budget.isValid else { return nil }
    return (enabled, packs)
}

/// Resolve names and capture every byte exactly once on main. The returned value has no URL,
/// descriptor, file descriptor, or resolver closure that a worker could use to touch live state.
func snapshotResourcePackStack(
    _ userPacks: [String], bundledAddOns: [BundledResourcePackAddOnID]
) -> ResourcePackStackSourceSnapshot? {
    guard Thread.isMainThread else { return nil }
    let managedBytes = ensureBundledResourcePackAssets()
    let enabled = withDefaultPack(userPacks, addOns: bundledAddOns)
    guard Set(enabled).count == enabled.count else { return nil }
    let managedNames = Set(BUNDLED_RESOURCE_PACK_ASSETS.map(\.fileName))
    let directory = resourcePacksDir()
    let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directoryFD >= 0 else { return nil }
    defer { _ = Darwin.close(directoryFD) }
    let budget = ResourcePackPreparationBudget()
    var sources: [ResourcePackSourceSnapshot] = []
    sources.reserveCapacity(enabled.count)
    for name in enabled {
        guard budget.shouldContinue else { return nil }
        if managedNames.contains(name) {
            guard let data = managedBytes[name] else { return nil }
            sources.append(ResourcePackSourceSnapshot(
                fileName: name, displayName: String(name.dropLast(4)), payload: .archive(data)))
            continue
        }
        var linkStatus = stat()
        guard fstatat(directoryFD, name, &linkStatus, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        let identity = ResourcePackFileIdentity(linkStatus)
        switch linkStatus.st_mode & S_IFMT {
        case S_IFREG:
            guard (name as NSString).pathExtension.lowercased() == "zip",
                  linkStatus.st_nlink == 1, linkStatus.st_size >= 0,
                  linkStatus.st_size <= budget.limits.archiveBytes,
                  budget.chargeEntry(pathByteCount: name.utf8.count,
                                     advertisedByteCount: Int(linkStatus.st_size)),
                  budget.chargeInflated(Int(linkStatus.st_size)) else { return nil }
            let fd = Darwin.openat(directoryFD, name,
                                   O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            var opened = stat()
            let data = fstat(fd, &opened) == 0 && ResourcePackFileIdentity(opened) == identity
                ? readResourcePackDescriptor(fd, expected: identity,
                                             maximum: budget.limits.archiveBytes) : nil
            _ = Darwin.close(fd)
            guard let data else { return nil }
            sources.append(ResourcePackSourceSnapshot(
                fileName: name, displayName: String(name.dropLast(4)), payload: .archive(data)))
        case S_IFDIR:
            let fd = Darwin.openat(directoryFD, name,
                                   O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            var opened = stat()
            var files: [String: Data] = [:]
            var normalized: Set<String> = []
            let captured = fstat(fd, &opened) == 0 && ResourcePackFileIdentity(opened) == identity &&
                snapshotResourcePackFolder(directoryFD: fd, budget: budget, into: &files,
                                           normalizedNames: &normalized)
            _ = Darwin.close(fd)
            guard captured else { return nil }
            sources.append(ResourcePackSourceSnapshot(
                fileName: name, displayName: name, payload: .folder(files)))
        default:
            return nil
        }
    }
    return ResourcePackStackSourceSnapshot(
        enabledNames: enabled, sources: sources, bundledAddOns: bundledAddOns)
}

/// Owned CPU result. Its input snapshot contains no path API, and `stage` claims this value once.
final class PreparedResourcePackTransaction: @unchecked Sendable {
    fileprivate let enabledNames: [String]
    fileprivate let bundledAddOns: [BundledResourcePackAddOnID]
    fileprivate let packs: [ResourcePack]
    fileprivate let atlas: PackAtlasResult
    fileprivate let packUI: PreparedPackUI
    fileprivate let sunImage: RGBAImage?
    fileprivate let moonImage: RGBAImage?
    private var stagingClaimed = false

    fileprivate init(enabledNames: [String], bundledAddOns: [BundledResourcePackAddOnID],
                     packs: [ResourcePack], atlas: PackAtlasResult, packUI: PreparedPackUI,
                     sunImage: RGBAImage?, moonImage: RGBAImage?) {
        self.enabledNames = enabledNames
        self.bundledAddOns = bundledAddOns
        self.packs = packs
        self.atlas = atlas
        self.packUI = packUI
        self.sunImage = sunImage
        self.moonImage = moonImage
    }

    /// Main-only and fallible. Claiming occurs before any GPU allocation, preventing retries that
    /// could accidentally stage a different A/B mix from the same logical transaction.
    func stage(renderer: WorldRenderer, game: GameCore) -> StagedResourcePackPublication? {
        precondition(Thread.isMainThread)
        guard !stagingClaimed else { return nil }
        stagingClaimed = true
        guard let candidate = IconSourceCandidate(atlas: atlas.icon16,
                                                   itemOverrides: atlas.itemIcons),
              let stagedWorld = renderer.stagePackAtlas(atlas),
              let stagedPackUI = PackUI(prepared: packUI, device: renderer.device) else { return nil }
        let stagedSun = sunImage.flatMap(renderer.makeImageTexture)
        let stagedMoon = moonImage.flatMap(renderer.makeImageTexture)
        guard (sunImage == nil || stagedSun != nil), (moonImage == nil || stagedMoon != nil) else {
            return nil
        }
        iconPackPublicationHook?(.staged)
        if failNextIconPackPublicationBeforeMutation {
            failNextIconPackPublicationBeforeMutation = false
            return nil
        }
        guard let meshContext = game.prepareNextMeshRenderContext(
            tintGate: atlas.tintGate, textureGate: atlas.textureGate) else { return nil }
        return StagedResourcePackPublication(
            enabledNames: enabledNames, bundledAddOns: bundledAddOns, packs: packs,
            atlas: atlas, candidate: candidate, world: stagedWorld, packUI: stagedPackUI,
            sun: stagedSun, moon: stagedMoon, meshContext: meshContext)
    }
}

/// Parse/decode/compose exclusively from owned snapshots. Cancellation is checked by the shared
/// budget throughout archive inflation, image decode, atlas generation, and GUI composition.
func prepareResourcePackTransaction(
    snapshot: ResourcePackStackSourceSnapshot, cancellation: ResourcePackCancellationToken
) -> PreparedResourcePackTransaction? {
    let budget = ResourcePackPreparationBudget(cancellation: cancellation)
    let packs = snapshot.sources.compactMap { ResourcePack(snapshot: $0, budget: budget) }
    guard packs.count == snapshot.sources.count, budget.shouldContinue,
          let atlas = buildPackAtlas(packs: packs, budget: budget),
          let preparedUI = PackUI.prepare(packs: packs, budget: budget) else { return nil }
    let sun = packEntityImage(["environment/sun.png"], packs: packs, budget: budget)
    let moon = packEntityImage(["environment/moon_phases.png"], packs: packs, budget: budget)
    guard budget.shouldContinue else { return nil }
    return PreparedResourcePackTransaction(
        enabledNames: snapshot.enabledNames, bundledAddOns: snapshot.bundledAddOns,
        packs: packs, atlas: atlas, packUI: preparedUI, sunImage: sun, moonImage: moon)
}

/// Fully staged publication. After successful staging and persistence, this operation has no
/// recoverable failure branch: it consumes exactly once and commits every A/B generation together.
final class StagedResourcePackPublication {
    private let enabledNames: [String]
    private let bundledAddOns: [BundledResourcePackAddOnID]
    private let packs: [ResourcePack]
    private let atlas: PackAtlasResult
    private let candidate: IconSourceCandidate
    private let world: WorldRenderer.StagedWorldAtlas
    private let packUI: PackUI
    private let sun: MTLTexture?
    private let moon: MTLTexture?
    private let meshContext: MeshRenderContext
    private var consumed = false

    fileprivate init(enabledNames: [String], bundledAddOns: [BundledResourcePackAddOnID],
                     packs: [ResourcePack], atlas: PackAtlasResult,
                     candidate: IconSourceCandidate, world: WorldRenderer.StagedWorldAtlas,
                     packUI: PackUI, sun: MTLTexture?, moon: MTLTexture?,
                     meshContext: MeshRenderContext) {
        self.enabledNames = enabledNames
        self.bundledAddOns = bundledAddOns
        self.packs = packs
        self.atlas = atlas
        self.candidate = candidate
        self.world = world
        self.packUI = packUI
        self.sun = sun
        self.moon = moon
        self.meshContext = meshContext
    }

    func publish(game: GameCore, renderer: WorldRenderer, ui: UIManager) {
        precondition(Thread.isMainThread && !consumed && !iconPackPublicationActive)
        consumed = true
        iconPackPublicationActive = true
        defer { iconPackPublicationActive = false }
        ui.cv.resetIconSlots()
        renderer.resetSpriteSlots()
        iconPackPublicationHook?(.retired)
        installUIAtlas(atlas.icon16)
        renderer.installStagedWorldAtlas(world)
        iconPackPublicationHook?(.uiWorldInstalled)
        // Install every main-confined B component while background Core icon readers remain on A.
        // The atomic Core icon swap below is the final source commit for the complete generation.
        ACTIVE_PACKS = packs
        RESOURCE_PACK_PRESENTATION = resourcePackPresentationAfterActivePublication(
            RESOURCE_PACK_PRESENTATION, activeAddOns: bundledAddOns)
        renderer.sunTex = sun
        renderer.moonTex = moon
        ui.packUI = packUI
        ui.cv.guiTexture = packUI.texture
        packFontWidths = packUI.fontWidths
        renderer.entityRenderer.resetSkins()
        let generation = publishIconSourceSnapshot(candidate)
        recordUIIconGeneration(generation)
        renderer.recordWorldIconGeneration(generation)
        precondition(currentIconSourceGeneration() == generation &&
                     currentUIIconGeneration() == generation &&
                     renderer.currentWorldIconGeneration() == generation)
        game.installMeshRenderContext(meshContext)
        iconPackPublicationHook?(.coreCommitted)
        game.remeshAllLoaded()
        print("[packs] \(enabledNames.joined(separator: " + ")) published as one generation")
        fflush(stdout)
    }
}

func validateResourcePackStack(_ userPacks: [String],
                               bundledAddOns: [BundledResourcePackAddOnID],
                               cancellation: ResourcePackCancellationToken? = nil) -> Bool {
    let budget = ResourcePackPreparationBudget(cancellation: cancellation)
    guard let stack = resolvedResourcePackStack(userPacks, bundledAddOns: bundledAddOns,
                                                budget: budget) else {
        return false
    }
    return buildPackAtlas(packs: stack.packs, budget: budget) != nil && budget.isValid
}

@discardableResult
func applyResourcePacks(_ userPacks: [String],
                        bundledAddOns: [BundledResourcePackAddOnID] = [],
                        game: GameCore, renderer: WorldRenderer, ui: UIManager) -> Bool {
    guard Thread.isMainThread, !iconPackPublicationActive else {
        print("[packs] rejected off-main or re-entrant pack publication")
        return false
    }
    iconPackPublicationActive = true
    defer { iconPackPublicationActive = false }
    let t0 = CFAbsoluteTimeGetCurrent()
    let budget = ResourcePackPreparationBudget()
    let resolved = resolvedResourcePackStack(userPacks, bundledAddOns: bundledAddOns,
                                             budget: budget)
    if resolved == nil {
        print("[packs] requested resource-pack layer unavailable; retaining prior pack")
    }
    let enabled = resolved?.names ?? []
    let packs = resolved?.packs ?? []
    if let result = buildPackAtlas(packs: packs, budget: budget) {
        let items = result.itemIcons
        guard let candidate = IconSourceCandidate(
            atlas: result.icon16,
            itemOverrides: items
        ), let stagedWorld = renderer.stagePackAtlas(result),
              let stagedPackUI = PackUI(packs: packs, device: renderer.device, budget: budget),
              budget.shouldContinue else {
            print("[packs] rejected invalid icon generation; retaining prior pack")
            return false
        }
        // Every fallible CPU/AppKit/Metal candidate is complete before the
        // first live-generation mutation.
        let stagedSunImage = packEntityImage(["environment/sun.png"], packs: packs,
                                             budget: budget)
        let stagedMoonImage = packEntityImage(["environment/moon_phases.png"], packs: packs,
                                              budget: budget)
        guard budget.shouldContinue else { return false }
        let stagedSun = stagedSunImage.flatMap { renderer.makeImageTexture($0) }
        let stagedMoon = stagedMoonImage.flatMap { renderer.makeImageTexture($0) }
        iconPackPublicationHook?(.staged)
        if failNextIconPackPublicationBeforeMutation {
            failNextIconPackPublicationBeforeMutation = false
            print("[packs] injected pre-commit failure; retaining prior pack")
            return false
        }
        guard let meshContext = game.prepareNextMeshRenderContext(
            tintGate: result.tintGate, textureGate: result.textureGate) else {
            print("[packs] mesh generation exhausted; retaining prior pack")
            return false
        }
        ui.cv.resetIconSlots()
        renderer.resetSpriteSlots()
        iconPackPublicationHook?(.retired)
        installUIAtlas(result.icon16)
        renderer.installStagedWorldAtlas(stagedWorld)
        iconPackPublicationHook?(.uiWorldInstalled)
        // Core is the final source commit. Until this line, background icon readers remain on A.
        let generation = publishIconSourceSnapshot(candidate)
        recordUIIconGeneration(generation)
        renderer.recordWorldIconGeneration(generation)
        precondition(currentIconSourceGeneration() == generation &&
                     currentUIIconGeneration() == generation &&
                     renderer.currentWorldIconGeneration() == generation)
        game.installMeshRenderContext(meshContext)
        iconPackPublicationHook?(.coreCommitted)
        ACTIVE_PACKS = packs
        RESOURCE_PACK_PRESENTATION = resourcePackPresentationAfterActivePublication(
            RESOURCE_PACK_PRESENTATION, activeAddOns: bundledAddOns)
        renderer.sunTex = stagedSun
        renderer.moonTex = stagedMoon
        ui.packUI = stagedPackUI
        ui.cv.guiTexture = stagedPackUI.texture
        packFontWidths = stagedPackUI.fontWidths
        print(String(format: "[packs] %@ → %d/%d tiles, %d item icons, %d animated, %d× atlas, %d GUI sheets (%.0fms)",
                     enabled.joined(separator: " + "), result.appliedTiles, result.slices.count,
                     result.appliedItems, result.animations.count, result.res, stagedPackUI.sheets.count,
                     (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    } else {
        let atlas = ElysiumCore.buildAtlas()
        guard let candidate = IconSourceCandidate(atlas: atlas),
              let stagedWorld = renderer.stageProceduralAtlas(atlas) else {
            print("[packs] procedural icon generation failed; retaining prior pack")
            return false
        }
        iconPackPublicationHook?(.staged)
        if failNextIconPackPublicationBeforeMutation {
            failNextIconPackPublicationBeforeMutation = false
            print("[packs] injected procedural pre-commit failure; retaining prior pack")
            return false
        }
        guard let meshContext = game.prepareNextMeshRenderContext(
            tintGate: nil, textureGate: nil) else {
            print("[packs] mesh generation exhausted; retaining prior pack")
            return false
        }
        ui.cv.resetIconSlots()
        renderer.resetSpriteSlots()
        iconPackPublicationHook?(.retired)
        installUIAtlas(atlas)
        renderer.installStagedWorldAtlas(stagedWorld)
        iconPackPublicationHook?(.uiWorldInstalled)
        let generation = publishIconSourceSnapshot(candidate)
        recordUIIconGeneration(generation)
        renderer.recordWorldIconGeneration(generation)
        precondition(currentIconSourceGeneration() == generation &&
                     currentUIIconGeneration() == generation &&
                     renderer.currentWorldIconGeneration() == generation)
        game.installMeshRenderContext(meshContext)
        iconPackPublicationHook?(.coreCommitted)
        ACTIVE_PACKS = []
        RESOURCE_PACK_PRESENTATION = resourcePackPresentationAfterFallbackPublication(
            RESOURCE_PACK_PRESENTATION)
        renderer.sunTex = nil
        renderer.moonTex = nil
        ui.packUI = nil
        ui.cv.guiTexture = nil
        packFontWidths = nil
        print("[packs] procedural atlas restored")
    }
    fflush(stdout)
    renderer.entityRenderer.resetSkins()   // entity textures re-resolve vs the new stack
    game.remeshAllLoaded()   // vertex tints depend on the gate — rebuild meshes
    return true
}

// =============================================================================
// PACK GUI — imports the pack's interface art (HUD icons, widgets, container
// backgrounds, bitmap font, dirt background) into one composited texture.
// Sheets live in fixed 512×512 cells at exactly 2× base-GUI scale (16px-per-
// 8px-glyph); packs at other resolutions are rescaled on load.
// =============================================================================
struct PreparedPackUI: Sendable {
    let pixels: [UInt8]
    let sheets: Set<String>
    let fontWidths: [Double]?
}

final class PackUI {
    let texture: MTLTexture
    private(set) var sheets: Set<String> = []
    /// per-character advance in base px (8px grid), from ascii.png; nil = no pack font
    private(set) var fontWidths: [Double]?

    /// cell origins in the composite texture (each 512×512; content = base×2)
    static let CELLS: [String: (Int, Int)] = [
        "icons": (0, 0), "widgets": (512, 0), "ascii": (1024, 0), "bg": (1536, 0),
        "inventory": (0, 512), "generic_54": (512, 512), "crafting_table": (1024, 512), "furnace": (1536, 512),
        "brewing_stand": (0, 1024), "enchanting_table": (512, 1024), "anvil": (1024, 1024), "hopper": (1536, 1024),
        "dispenser": (0, 1536), "shulker_box": (512, 1536), "grindstone": (1024, 1536), "stonecutter": (1536, 1536),
        "smithing": (0, 2048), "cartography_table": (512, 2048), "beacon": (1024, 2048), "horse": (1536, 2048),
    ]

    static func prepare(packs: [ResourcePack],
                        budget: ResourcePackPreparationBudget? = nil) -> PreparedPackUI? {
        let W = 2048, H = 2560
        var pixels = [UInt8](repeating: 0, count: W * H * 4)
        var sheets: Set<String> = []
        var fontWidths: [Double]?

        func load(_ rel: String) -> RGBAImage? {
            for p in packs {
                if let d = p.file(p.texRoot + "\(rel).png"),
                   let img = decodePNG(d, budget: budget) {
                    return img
                }
            }
            return nil
        }
        func blit(_ img: RGBAImage, _ cellX: Int, _ cellY: Int, baseSize: Int) {
            // rescale so content occupies baseSize*2 px in the cell
            let target = baseSize * 2
            let scaled = img.width == target ? img.pixels : scaleTo(img, target)
            for y in 0..<min(target, 512) {
                let dst = ((cellY + y) * W + cellX) * 4
                let src = y * target * 4
                pixels.replaceSubrange(dst..<(dst + min(target, 512) * 4),
                                       with: scaled[src..<(src + min(target, 512) * 4)])
            }
        }

        let sources: [(String, String, Int)] = [
            ("icons", "gui/icons", 256), ("widgets", "gui/widgets", 256),
            ("bg", "gui/options_background", 16),
            ("inventory", "gui/container/inventory", 256),
            ("generic_54", "gui/container/generic_54", 256),
            ("crafting_table", "gui/container/crafting_table", 256),
            ("furnace", "gui/container/furnace", 256),
            ("brewing_stand", "gui/container/brewing_stand", 256),
            ("enchanting_table", "gui/container/enchanting_table", 256),
            ("anvil", "gui/container/anvil", 256),
            ("hopper", "gui/container/hopper", 256),
            ("dispenser", "gui/container/dispenser", 256),
            ("shulker_box", "gui/container/shulker_box", 256),
            ("grindstone", "gui/container/grindstone", 256),
            ("stonecutter", "gui/container/stonecutter", 256),
            ("smithing", "gui/container/smithing", 256),
            ("cartography_table", "gui/container/cartography_table", 256),
            ("beacon", "gui/container/beacon", 256),
            ("horse", "gui/container/horse", 256),
        ]
        for (key, rel, base) in sources {
            guard budget?.shouldContinue != false else { return nil }
            if let img = load(rel) {
                let cell = PackUI.CELLS[key]!
                blit(img, cell.0, cell.1, baseSize: base)
                sheets.insert(key)
            }
        }
        // bitmap font: 16×16 grid of 8×8 glyphs; advance = trailing edge + 1
        if let ascii = load("font/ascii") {
            let cell = PackUI.CELLS["ascii"]!
            blit(ascii, cell.0, cell.1, baseSize: 128)
            sheets.insert("ascii")
            let g = ascii.width / 16    // native glyph cell size
            var widths = [Double](repeating: 6, count: 256)
            for c in 0..<256 {
                let gx = (c % 16) * g, gy = (c / 16) * g
                var maxX = -1
                for y in 0..<g {
                    for x in 0..<g {
                        if ascii.pixels[((gy + y) * ascii.width + gx + x) * 4 + 3] > 32 {
                            if x > maxX { maxX = x }
                        }
                    }
                }
                let base = 8.0 / Double(g)
                widths[c] = maxX < 0 ? 4 : (Double(maxX + 1) * base + 1)
            }
            widths[32] = 4   // space
            fontWidths = widths
        }
        guard !sheets.isEmpty, budget?.shouldContinue != false else { return nil }
        return PreparedPackUI(pixels: pixels, sheets: sheets, fontWidths: fontWidths)
    }

    init?(prepared: PreparedPackUI, device: MTLDevice) {
        let W = 2048, H = 2560
        guard prepared.pixels.count == W * H * 4 else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        prepared.pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: W * 4)
        }
        texture = tex
        sheets = prepared.sheets
        fontWidths = prepared.fontWidths
    }

    convenience init?(packs: [ResourcePack], device: MTLDevice,
                      budget: ResourcePackPreparationBudget? = nil) {
        guard let prepared = Self.prepare(packs: packs, budget: budget) else { return nil }
        self.init(prepared: prepared, device: device)
    }
}
