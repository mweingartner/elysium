import XCTest
@testable import ElysiumCore

final class SettingsTests: XCTestCase {
    func testSettingsAreSanitizedToRuntimeRanges() {
        var s = Settings()
        s.renderDistance = 10_000
        s.fov = 1
        s.particles = 99
        s.gamma = .infinity
        s.guiScale = -10
        s.maxFps = 1
        s.entityDistance = .nan
        s.sensitivity = -5
        s.darknessPulse = 9
        s.volumes = ["master": -2, "music": 4, "blocks": .nan]
        s.resourcePacks = ["", "../bad.zip", "ok.zip", String(repeating: "x", count: 300)]
        s.bundledResourcePackAddOns = ["static-lanterns", "unknown", "ore-borders-64x",
                                         "static-lanterns"]
        s.aiOllamaModel = " llama3.1:8b\nbad chars <> "

        let out = sanitizedSettings(s)

        XCTAssertEqual(out.renderDistance, 16)
        XCTAssertEqual(out.fov, 60)
        XCTAssertEqual(out.particles, 2)
        XCTAssertEqual(out.gamma, Settings().gamma)
        XCTAssertEqual(out.guiScale, 0)
        XCTAssertEqual(out.maxFps, 30)
        XCTAssertEqual(out.entityDistance, Settings().entityDistance)
        XCTAssertEqual(out.sensitivity, 0)
        XCTAssertEqual(out.darknessPulse, 1)
        XCTAssertEqual(out.volumes["master"], 0)
        XCTAssertEqual(out.volumes["music"], 1)
        XCTAssertEqual(out.volumes["blocks"], Settings().volumes["blocks"])
        XCTAssertEqual(out.resourcePacks, ["ok.zip"])
        XCTAssertEqual(out.bundledResourcePackAddOns, ["ore-borders-64x", "static-lanterns"])
        XCTAssertEqual(out.aiOllamaModel, "llama3.1:8bbadchars")
    }

    func testKeybindSanitizationDropsUnknownAndInvalidValues() {
        let out = sanitizedKeybinds([
            "forward": "KeyI",
            "jump": "",
            "inventory": String(repeating: "A", count: 100),
            "unknown": "KeyZ",
        ])

        XCTAssertEqual(out["forward"], "KeyI")
        XCTAssertEqual(out["jump"], DEFAULT_KEYBINDS["jump"])
        XCTAssertEqual(out["inventory"], DEFAULT_KEYBINDS["inventory"])
        XCTAssertNil(out["unknown"])
        XCTAssertEqual(Set(out.keys), Set(DEFAULT_KEYBINDS.keys))
    }

    func testOllamaModelPolicyAllowsLocalModelsAndRejectsCloudModels() {
        XCTAssertTrue(isAllowedLocalOllamaModelName("qwen3:latest"))
        XCTAssertTrue(isAllowedLocalOllamaModelName("namespace/model:tag"))
        XCTAssertFalse(isAllowedLocalOllamaModelName(""))
        XCTAssertFalse(isAllowedLocalOllamaModelName("minimax-m3:cloud"))
        XCTAssertFalse(isAllowedLocalOllamaModelName(" kimi-k2.5:cloud "))
    }
}
