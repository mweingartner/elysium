import XCTest
@testable import PebbleCore

/// Property/fuzz tests for the PBT2 binary template codec. The decoder must be total over
/// arbitrary bytes: it may throw on malformed input, but must never trap, over-allocate beyond
/// the documented caps, or return a partially-decoded template. Seeded and reproducible per the
/// playbook's requirement for parser/codec fuzzing (not just happy-path example tests).
final class TemplateDecodeFuzzTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
    }

    private func makeSmallTemplate(name: String = "Fuzz Seed") -> ObjectTemplate {
        registerCoreIfNeeded()
        let chest = makeContainerBE(0, 0, 1, 27)
        chest.items?[0] = stack("diamond", 3)
        return ObjectTemplate(
            name: name,
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: 2, sizeY: 1, sizeZ: 2,
            blocks: [
                TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.stone))),
                TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                TemplateBlock(dx: 0, dy: 0, dz: 1, cell: UInt16(cell(B.chest))),
            ],
            blockEntities: [chest])
    }

    func testDecodeRejectsEveryTruncationLength() throws {
        let blob = try encodeObjectTemplate(makeSmallTemplate())

        for length in 0..<blob.count {
            let prefix = blob.prefix(length)
            XCTAssertThrowsError(try decodeObjectTemplate(Data(prefix)),
                                 "prefix of length \(length) must not decode successfully")
        }
    }

    func testDecodeRejectsCorruptedHeaderFields() throws {
        let blob = try encodeObjectTemplate(makeSmallTemplate())

        func mutated(_ mutate: (inout Data) -> Void) -> Data {
            var copy = blob
            mutate(&copy)
            return copy
        }

        func setU16(_ data: inout Data, at offset: Int, _ value: UInt16) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func setU32(_ data: inout Data, at offset: Int, _ value: UInt32) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
            data[offset + 2] = UInt8((value >> 16) & 0xFF)
            data[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        // header layout (after 4-byte magic): version(u16)=4, flags(u16)=6, nameLength(u16)=8,
        // anchorX/Y/Z(i32)=10/14/18, sizeX/Y/Z(u16)=22/24/26, blockCount(u32)=28,
        // blockEntityCount(u32)=32, blockEntityByteCount(u32)=36
        let wrongVersion = mutated { setU16(&$0, at: 4, 9999) }
        XCTAssertThrowsError(try decodeObjectTemplate(wrongVersion)) { error in
            guard case .unsupportedVersion = error as? TemplateError else {
                XCTFail("expected unsupportedVersion, got \(error)"); return
            }
        }

        let nonzeroFlags = mutated { setU16(&$0, at: 6, 1) }
        XCTAssertThrowsError(try decodeObjectTemplate(nonzeroFlags))

        let hugeNameLength = mutated { setU16(&$0, at: 8, UInt16(OBJECT_TEMPLATE_NAME_MAX + 1)) }
        XCTAssertThrowsError(try decodeObjectTemplate(hugeNameLength))

        let zeroNameLength = mutated { setU16(&$0, at: 8, 0) }
        XCTAssertThrowsError(try decodeObjectTemplate(zeroNameLength))

        let hugeBlockCount = mutated { setU32(&$0, at: 28, UInt32.max) }
        XCTAssertThrowsError(try decodeObjectTemplate(hugeBlockCount)) { error in
            guard case .objectTooLarge = error as? TemplateError else {
                XCTFail("expected objectTooLarge, got \(error)"); return
            }
        }

        let zeroBlockCount = mutated { setU32(&$0, at: 28, 0) }
        XCTAssertThrowsError(try decodeObjectTemplate(zeroBlockCount)) { error in
            guard case .objectTooLarge = error as? TemplateError else {
                XCTFail("expected objectTooLarge, got \(error)"); return
            }
        }

        let hugeBlockEntityCount = mutated { setU32(&$0, at: 32, UInt32.max) }
        XCTAssertThrowsError(try decodeObjectTemplate(hugeBlockEntityCount))

        let lyingBlockEntityByteCountHigh = mutated { setU32(&$0, at: 36, UInt32.max) }
        XCTAssertThrowsError(try decodeObjectTemplate(lyingBlockEntityByteCountHigh))

        let lyingBlockEntityByteCountLow = mutated { setU32(&$0, at: 36, 0) }
        XCTAssertThrowsError(try decodeObjectTemplate(lyingBlockEntityByteCountLow))
    }

    func testDecodeSingleByteFlipsNeverCrash() throws {
        let blob = try encodeObjectTemplate(makeSmallTemplate())
        var rng = RandomX(hashString("pbt2-fuzz"))
        let flipCount = 2000

        for _ in 0..<flipCount {
            var mutant = blob
            let index = rng.nextInt(mutant.count)
            let bit = UInt8(1 << rng.nextInt(8))
            mutant[index] ^= bit

            // total: either throws, or decodes to a template that itself satisfies validateTemplate's
            // invariants (bounds, no duplicate positions, block-entity/block consistency).
            do {
                let decoded = try decodeObjectTemplate(mutant)
                XCTAssertGreaterThan(decoded.blocks.count, 0)
                XCTAssertLessThanOrEqual(decoded.blocks.count, OBJECT_TEMPLATE_MAX_BLOCKS)
                for block in decoded.blocks {
                    XCTAssertGreaterThanOrEqual(block.dx, 0)
                    XCTAssertGreaterThanOrEqual(block.dy, 0)
                    XCTAssertGreaterThanOrEqual(block.dz, 0)
                    XCTAssertLessThan(block.dx, decoded.sizeX)
                    XCTAssertLessThan(block.dy, decoded.sizeY)
                    XCTAssertLessThan(block.dz, decoded.sizeZ)
                }
            } catch {
                // expected outcome for most flips — the invariant is "no crash", not "no throw"
            }
        }
    }

    func testDecodeEncodeRoundTripInvariant() throws {
        registerCoreIfNeeded()
        var rng = RandomX(hashString("pbt2-roundtrip"))

        for trial in 0..<25 {
            let sizeX = 1 + rng.nextInt(4)
            let sizeY = 1 + rng.nextInt(4)
            let sizeZ = 1 + rng.nextInt(4)
            var seen = Set<[Int]>()
            var blocks: [TemplateBlock] = []
            let attempts = sizeX * sizeY * sizeZ
            for _ in 0..<attempts {
                let dx = rng.nextInt(sizeX), dy = rng.nextInt(sizeY), dz = rng.nextInt(sizeZ)
                guard seen.insert([dx, dy, dz]).inserted else { continue }
                blocks.append(TemplateBlock(dx: dx, dy: dy, dz: dz, cell: UInt16(cell(B.stone))))
            }
            guard !blocks.isEmpty else { continue }
            let template = ObjectTemplate(
                name: "Round Trip \(trial)",
                anchorX: 0, anchorY: 0, anchorZ: 0,
                sizeX: sizeX, sizeY: sizeY, sizeZ: sizeZ,
                blocks: blocks)

            let encoded = try encodeObjectTemplate(template)
            let decoded = try decodeObjectTemplate(encoded)
            // validateTemplate (invoked inside encode) sorts blocks by (y, z, x); replicate that
            // ordering here rather than reaching into the private validation helper.
            let expectedBlocks = blocks.sorted {
                if $0.dy != $1.dy { return $0.dy < $1.dy }
                if $0.dz != $1.dz { return $0.dz < $1.dz }
                return $0.dx < $1.dx
            }

            XCTAssertEqual(decoded.name, template.name)
            XCTAssertEqual(decoded.sizeX, sizeX)
            XCTAssertEqual(decoded.sizeY, sizeY)
            XCTAssertEqual(decoded.sizeZ, sizeZ)
            XCTAssertEqual(decoded.blocks.map { [$0.dx, $0.dy, $0.dz, Int($0.cell)] },
                           expectedBlocks.map { [$0.dx, $0.dy, $0.dz, Int($0.cell)] })
        }
    }
}
