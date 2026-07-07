import XCTest
@testable import PebbleCore

final class RPGAssetManifestTests: XCTestCase {
    func testManifestCoversEveryRPGDefinitionAndAction() {
        let manifest = rpgAssetManifest()
        let ids = manifest.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count, "asset ids must be unique")
        XCTAssertEqual(manifest.filter { $0.kind == .pathIcon }.map(\.ownerID), RPG_PATH_DEFINITIONS.map(\.id))
        XCTAssertEqual(manifest.filter { $0.kind == .branchIcon }.map(\.ownerID), RPG_BRANCH_DEFINITIONS.map(\.id))
        XCTAssertEqual(manifest.filter { $0.kind == .skillIcon }.map(\.ownerID), RPG_SKILL_DEFINITIONS.map(\.id))
        XCTAssertEqual(manifest.filter { $0.kind == .spellIcon }.map(\.ownerID), RPG_SPELL_DEFINITIONS.map(\.id))
        XCTAssertEqual(manifest.filter { $0.kind == .actionIcon }.map(\.ownerID), RPG_ACTION_ASSET_IDS)
    }

    func testEveryManifestEntryProducesNonBlankSixteenBySixteenPixels() {
        for entry in rpgAssetManifest() {
            let pixels = rpgIconPixels(entry)
            XCTAssertEqual(pixels.count, 16 * 16 * 4, entry.id)
            XCTAssertGreaterThan(nonTransparentPixelCount(pixels), 20, entry.id)
            XCTAssertGreaterThan(uniqueOpaqueColorCount(pixels), 1, entry.id)
        }
    }

    func testRegistryRelationshipsAreClosedAndDeterministic() {
        let pathIDs = Set(RPG_PATH_DEFINITIONS.map(\.id))
        let branchIDs = Set(RPG_BRANCH_DEFINITIONS.map(\.id))
        let skillIDs = Set(RPG_SKILL_DEFINITIONS.map(\.id))
        let spellIDs = Set(RPG_SPELL_DEFINITIONS.map(\.id))

        XCTAssertEqual(pathIDs.count, RPG_PATH_DEFINITIONS.count)
        XCTAssertEqual(branchIDs.count, RPG_BRANCH_DEFINITIONS.count)
        XCTAssertEqual(skillIDs.count, RPG_SKILL_DEFINITIONS.count)
        XCTAssertEqual(spellIDs.count, RPG_SPELL_DEFINITIONS.count)

        for path in RPG_PATH_DEFINITIONS {
            for branchID in path.branchIDs {
                XCTAssertTrue(branchIDs.contains(branchID), "\(path.id) references missing branch \(branchID)")
            }
            for skillID in path.starterSkillIDs {
                XCTAssertTrue(skillIDs.contains(skillID), "\(path.id) references missing starter skill \(skillID)")
            }
            for spellID in path.starterSpellIDs {
                XCTAssertTrue(spellIDs.contains(spellID), "\(path.id) references missing starter spell \(spellID)")
            }
        }

        for branch in RPG_BRANCH_DEFINITIONS {
            XCTAssertTrue(pathIDs.contains(branch.pathID), "\(branch.id) references missing path \(branch.pathID)")
            for skillID in branch.skillIDs {
                XCTAssertTrue(skillIDs.contains(skillID), "\(branch.id) references missing skill \(skillID)")
            }
        }

        for skill in RPG_SKILL_DEFINITIONS {
            XCTAssertTrue(pathIDs.contains(skill.pathID), "\(skill.id) references missing path \(skill.pathID)")
            XCTAssertTrue(branchIDs.contains(skill.branchID), "\(skill.id) references missing branch \(skill.branchID)")
            for prereq in skill.prerequisiteSkillIDs {
                XCTAssertTrue(skillIDs.contains(prereq), "\(skill.id) references missing prerequisite \(prereq)")
            }
            for spellID in skill.unlockSpellIDs {
                XCTAssertTrue(spellIDs.contains(spellID), "\(skill.id) references missing spell \(spellID)")
            }
        }

        for spell in RPG_SPELL_DEFINITIONS {
            for prereq in spell.prerequisiteSkillIDs {
                XCTAssertTrue(skillIDs.contains(prereq), "\(spell.id) references missing prerequisite \(prereq)")
            }
        }
    }

    private func nonTransparentPixelCount(_ pixels: [UInt8]) -> Int {
        stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] != 0 }.count
    }

    private func uniqueOpaqueColorCount(_ pixels: [UInt8]) -> Int {
        var colors = Set<Int>()
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] != 0 {
            colors.insert((Int(pixels[i]) << 16) | (Int(pixels[i + 1]) << 8) | Int(pixels[i + 2]))
        }
        return colors.count
    }
}
