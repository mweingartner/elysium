import XCTest
@testable import Elysium
@testable import ElysiumCore

final class PrehistoricAudioTests: XCTestCase {
    func testEveryPrehistoricCueHasAnExplicitUniqueSynthesizedRecipe() {
        let roster = PrehistoricCreatureDefinition.all
        let expectedNames = Set(roster.flatMap(\.soundNames))
        let recipes = prehistoricSynthesizedSoundRecipes()

        XCTAssertEqual(recipes.count, roster.count * PrehistoricSoundCue.allCases.count)
        XCTAssertEqual(Set(recipes.map(\.name)), expectedNames,
                       "the audio bank must include every direct Core cue, not a fallback")
        XCTAssertEqual(Set(recipes.map(\.acousticSignature)).count, recipes.count,
                       "each creature/action pair must retain its own synthesis motif")

        for definition in roster {
            let prefix = "entity.\(definition.id)."
            let speciesRecipes = recipes.filter { $0.name.hasPrefix(prefix) }
            XCTAssertEqual(speciesRecipes.count, PrehistoricSoundCue.allCases.count)
            XCTAssertTrue(speciesRecipes.allSatisfy {
                $0.subtitle?.contains(definition.displayName) == true
            })
            XCTAssertEqual(
                Set(speciesRecipes.compactMap(\.subtitle)).count,
                PrehistoricSoundCue.allCases.count,
                "each action must have a separately described species cue"
            )
            let expectedCategory = (definition.isPredatory || definition.canCharge) ? "hostile" : "friendly"
            XCTAssertTrue(speciesRecipes.allSatisfy { $0.category == expectedCategory })
        }
    }
}
