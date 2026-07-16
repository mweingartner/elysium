import Foundation
import XCTest

final class BrandAttributionSourceTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testReadmeAndInGameCreditsPreservePebbleOriginAttribution() throws {
        let upstreamURL = "https://github.com/thebriangao/pebble"
        let readme = try source("README.md")
        let credits = try source("Sources/Elysium/MenusM.swift")

        XCTAssertGreaterThanOrEqual(readme.components(separatedBy: upstreamURL).count - 1, 2)
        XCTAssertTrue(readme.contains("Elysium began"))
        XCTAssertTrue(credits.contains("Elysium began with the open-source"))
        XCTAssertTrue(credits.contains("Pebble project by Brian Gao"))
        XCTAssertTrue(credits.contains("github.com/thebriangao/pebble"))
        XCTAssertFalse(credits.contains("built from scratch"))
        XCTAssertFalse(credits.contains("original fan re-creation"))
    }

    func testReadmeAndTitleRuntimeUseOneCanonicalElysiumHero() throws {
        let readme = try source("README.md")
        let renderer = try source("Sources/Elysium/WorldRenderer.swift")
        let menus = try source("Sources/Elysium/MenusM.swift")
        let packaging = try source("scripts/package-app.sh")

        XCTAssertTrue(readme.contains("packaging/title-bg.png"))
        XCTAssertFalse(readme.contains("packaging/homepage.png"))
        XCTAssertFalse(readme.contains("packaging/logo.png"))
        XCTAssertFalse(readme.contains("packaging/elysium-readme-hero.png"))

        XCTAssertTrue(renderer.contains("bundleResourcePath(\"title-bg.png\")"))
        XCTAssertTrue(renderer.contains("if titleBgTex == nil, let logo = titleLogoTex"))
        XCTAssertTrue(menus.contains("if !ui.titlePhoto"))
        XCTAssertTrue(packaging.contains("packaging/title-bg.png"))

        let hero = repository.appendingPathComponent("packaging/title-bg.png")
        let attributes = try FileManager.default.attributesOfItem(atPath: hero.path)
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 0)
    }
}
