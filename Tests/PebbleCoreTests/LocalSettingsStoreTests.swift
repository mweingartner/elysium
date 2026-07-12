import Foundation
import XCTest
@testable import PebbleCore

final class LocalSettingsStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    private func makeStore() throws -> LocalSettingsStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PebbleLocalSettingsTests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return LocalSettingsStore(directoryURL: root)
    }

    private func value<T>(_ result: Result<T, LocalSettingsStoreError>,
                          file: StaticString = #filePath, line: UInt = #line) throws -> T {
        switch result {
        case let .success(value): return value
        case let .failure(error):
            XCTFail("Unexpected failure: \(error)", file: file, line: line)
            throw error
        }
    }

    private func write(_ data: Data, named name: String, to store: LocalSettingsStore) throws {
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try data.write(to: store.directoryURL.appendingPathComponent(name))
    }

    func testMissingDocumentsReturnSanitizedDefaults() throws {
        let store = try makeStore()
        let settings = try value(store.loadSettings())
        XCTAssertEqual(settings.renderDistance, Settings().renderDistance)
        XCTAssertEqual(settings.rpgTutorialVersion, 0)

        let keybinds = try value(store.loadKeybinds())
        XCTAssertEqual(keybinds.count, 25)
        XCTAssertEqual(keybinds, rpgDefaultChordBindings())
    }

    func testEmptyAndNonObjectRootsFailWithoutOverwriting() throws {
        for (name, data) in [
            ("empty", Data()),
            ("array", Data("[]".utf8)),
            ("scalar", Data("true".utf8)),
        ] {
            let store = try makeStore()
            try write(data, named: "settings.json", to: store)
            guard case .failure = store.loadSettings() else { return XCTFail("\(name) should fail") }
            XCTAssertEqual(try Data(contentsOf: store.directoryURL.appendingPathComponent("settings.json")), data)
        }
    }

    func testSettingsExactByteCapAndCapPlusOne() throws {
        let exactStore = try makeStore()
        let exact = Data("{}".utf8) + Data(repeating: 0x20, count: LOCAL_SETTINGS_MAX_BYTES - 2)
        XCTAssertEqual(exact.count, LOCAL_SETTINGS_MAX_BYTES)
        try write(exact, named: "settings.json", to: exactStore)
        _ = try value(exactStore.loadSettings())

        let oversizedStore = try makeStore()
        let oversized = exact + Data([0x20])
        try write(oversized, named: "settings.json", to: oversizedStore)
        guard case .failure(.documentTooLarge(.settings, limit: LOCAL_SETTINGS_MAX_BYTES)) =
            oversizedStore.loadSettings() else { return XCTFail("cap-plus-one settings should fail") }
    }

    func testKeybindExactByteCapAndCapPlusOne() throws {
        let exactStore = try makeStore()
        let exact = Data("{}".utf8) + Data(repeating: 0x20, count: LOCAL_KEYBINDS_MAX_BYTES - 2)
        try write(exact, named: "keybinds.json", to: exactStore)
        XCTAssertEqual(try value(exactStore.loadKeybinds()), rpgDefaultChordBindings())

        let oversizedStore = try makeStore()
        try write(exact + Data([0x20]), named: "keybinds.json", to: oversizedStore)
        XCTAssertEqual(oversizedStore.loadKeybinds(),
                       .failure(.documentTooLarge(.keybinds, limit: LOCAL_KEYBINDS_MAX_BYTES)))
    }

    func testInvalidUTF8AndMalformedJSONFail() throws {
        let utf8Store = try makeStore()
        try write(Data([0x7b, 0x22, 0x78, 0x22, 0x3a, 0xff, 0x7d]), named: "settings.json", to: utf8Store)
        guard case .failure(.invalidUTF8(.settings)) = utf8Store.loadSettings() else {
            return XCTFail("invalid UTF-8 should fail")
        }

        let malformedStore = try makeStore()
        try write(Data("{\"renderDistance\":8".utf8), named: "settings.json", to: malformedStore)
        guard case .failure(.invalidJSON(.settings, _)) = malformedStore.loadSettings() else {
            return XCTFail("malformed JSON should fail")
        }
    }

    func testKnownSettingsFieldsDecodeIndependentlyAndUnknownFieldsAreIgnored() throws {
        let store = try makeStore()
        let json = #"{"renderDistance":12,"fov":"bad","gamma":0.75,"rpgTutorialVersion":1,"future":{"ignored":true}}"#
        try write(Data(json.utf8), named: "settings.json", to: store)
        let settings = try value(store.loadSettings())
        XCTAssertEqual(settings.renderDistance, 12)
        XCTAssertEqual(settings.fov, Settings().fov)
        XCTAssertEqual(settings.gamma, 0.75)
        XCTAssertEqual(settings.rpgTutorialVersion, RPG_TUTORIAL_VERSION)
        XCTAssertEqual(store.lastDiagnostics, [LocalSettingsDiagnostic(field: "fov", reason: "invalid value")])
    }

    func testSettingsSanitizationStillAppliesAfterTolerantDecode() throws {
        let store = try makeStore()
        let json = #"{"renderDistance":100,"fov":1,"gamma":2,"rpgTutorialVersion":-5}"#
        try write(Data(json.utf8), named: "settings.json", to: store)
        let settings = try value(store.loadSettings())
        XCTAssertEqual(settings.renderDistance, 16)
        XCTAssertEqual(settings.fov, 60)
        XCTAssertEqual(settings.gamma, 1)
        XCTAssertEqual(settings.rpgTutorialVersion, 0)
    }

    func testTutorialVersionNormalizesIndependentlyAndPreservesValidPeers() throws {
        let cases = [
            "{}",
            #"{"rpgTutorialVersion":-1,"fov":91}"#,
            #"{"rpgTutorialVersion":"1","fov":91}"#,
            #"{"rpgTutorialVersion":{},"fov":91}"#,
            #"{"rpgTutorialVersion":0.5,"fov":91}"#,
            "{\"rpgTutorialVersion\":\(RPG_TUTORIAL_VERSION + 1),\"fov\":91}",
        ]
        for json in cases {
            let store = try makeStore()
            try write(Data(json.utf8), named: "settings.json", to: store)
            let settings = try value(store.loadSettings())
            XCTAssertEqual(settings.rpgTutorialVersion, 0, json)
            if json != "{}" { XCTAssertEqual(settings.fov, 91, json) }
        }
    }

    func testStructuralScannerDepthWidthStringKeyNumberAndEscapeLimits() throws {
        let cases: [(String, String)] = [
            ("depth", "{\"x\":" + String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32) + "}"),
            ("members", "{" + (0...512).map { "\"k\($0)\":0" }.joined(separator: ",") + "}"),
            ("array", "{\"x\":[" + Array(repeating: "0", count: 257).joined(separator: ",") + "]}"),
            ("key", "{\"" + String(repeating: "k", count: 129) + "\":0}"),
            ("string", "{\"x\":\"" + String(repeating: "s", count: 8193) + "\"}"),
            ("number", "{\"x\":" + String(repeating: "1", count: 129) + "}"),
            ("surrogate", "{\"x\":\"\\uD800\"}"),
        ]
        for (label, json) in cases {
            let store = try makeStore()
            try write(Data(json.utf8), named: "settings.json", to: store)
            guard case .failure = store.loadSettings() else { return XCTFail("\(label) should fail") }
        }
    }

    func testStructuralScannerAcceptsExactMemberAndArrayLimits() throws {
        let store = try makeStore()
        let members = (0..<511).map { "\"k\($0)\":0" } +
            ["\"array\":[" + Array(repeating: "0", count: 256).joined(separator: ",") + "]"]
        let json = "{" + members.joined(separator: ",") + "}"
        try write(Data(json.utf8), named: "settings.json", to: store)
        _ = try value(store.loadSettings())
    }

    func testStructuralScannerAcceptsExactDepthKeyStringAndNumberLimits() throws {
        let values = [
            "{\"x\":" + String(repeating: "[", count: 31) + "0" + String(repeating: "]", count: 31) + "}",
            "{\"" + String(repeating: "k", count: 128) + "\":0}",
            "{\"future\":\"" + String(repeating: "s", count: 8_192) + "\"}",
            "{\"future\":" + String(repeating: "1", count: 128) + "}",
        ]
        for json in values {
            let store = try makeStore()
            try write(Data(json.utf8), named: "settings.json", to: store)
            _ = try value(store.loadSettings())
        }
    }

    func testPrintedFixedSeedStructuredInputCorpus() throws {
        let seed: UInt64 = 0x4c53_5354_4f52_4531
        var random = LocalSettingsCorpusRandom(state: seed)
        let repetitions = 8
        let caseCount = repetitions * 14
        print("LocalSettingsStore structured-input corpus seed=0x\(String(seed, radix: 16)) cases=\(caseCount)")

        var caseIndex = 0
        for _ in 0..<repetitions {
            let whitespace = random.next() & 1 == 0 ? "" : " \n\t"
            let validPeers = "\"renderDistance\":\(4 + random.int(13)),\"future\":"
            let cases: [(label: String, valid: Bool, data: Data)] = [
                ("depth-exact", true, Data(("{" + validPeers + String(repeating: "[", count: 31) + "0" +
                    String(repeating: "]", count: 31) + "}" + whitespace).utf8)),
                ("depth-plus-one", false, Data(("{" + validPeers + String(repeating: "[", count: 32) + "0" +
                    String(repeating: "]", count: 32) + "}").utf8)),
                ("members-exact", true, Data(("{" + (0..<512).map { "\"k\($0)\":\($0)" }
                    .joined(separator: ",") + "}" + whitespace).utf8)),
                ("members-plus-one", false, Data(("{" + (0..<513).map { "\"k\($0)\":\($0)" }
                    .joined(separator: ",") + "}").utf8)),
                ("array-exact", true, Data(("{" + validPeers + "[" + Array(repeating: "0", count: 256)
                    .joined(separator: ",") + "]}" + whitespace).utf8)),
                ("array-plus-one", false, Data(("{" + validPeers + "[" + Array(repeating: "0", count: 257)
                    .joined(separator: ",") + "]}").utf8)),
                ("key-exact", true, Data(("{\"" + String(repeating: "k", count: 128) + "\":0}" + whitespace).utf8)),
                ("key-plus-one", false, Data(("{\"" + String(repeating: "k", count: 129) + "\":0}").utf8)),
                ("string-exact", true, Data(("{" + validPeers + "\"" + String(repeating: "s", count: 8_192) +
                    "\"}" + whitespace).utf8)),
                ("string-plus-one", false, Data(("{" + validPeers + "\"" + String(repeating: "s", count: 8_193) +
                    "\"}").utf8)),
                ("number-exact", true, Data(("{" + validPeers + String(repeating: "1", count: 128) + "}" + whitespace).utf8)),
                ("number-plus-one", false, Data(("{" + validPeers + String(repeating: "1", count: 129) + "}").utf8)),
                ("escaped-valid", true, Data(("{" + validPeers + "\"line\\n\\uD83D\\uDE00\"}" + whitespace).utf8)),
                ("escaped-corrupt", false, Data(("{" + validPeers + "\"line\\uD83D\"}").utf8)),
            ]

            for entry in cases {
                let store = try makeStore()
                try write(entry.data, named: "settings.json", to: store)
                let result = store.loadSettings()
                let context = corpusContext(seed: seed, index: caseIndex, label: entry.label, data: entry.data)
                if entry.valid {
                    guard case .success = result else {
                        return XCTFail("valid corpus case rejected; \(context); result=\(result)")
                    }
                } else {
                    guard case .failure = result else {
                        return XCTFail("corrupt corpus case accepted; \(context)")
                    }
                }
                caseIndex += 1
            }
        }
        XCTAssertEqual(caseIndex, caseCount)
    }

    func testKeybindLoadRepairsOnlyMalformedKnownEntriesAndDropsUnknowns() throws {
        let store = try makeStore()
        let json = #"{"forward":"KeyZ","back":"Command+KeyQ","left":42,"future":"KeyP"}"#
        try write(Data(json.utf8), named: "keybinds.json", to: store)
        let bindings = try value(store.loadKeybinds())
        XCTAssertEqual(bindings.count, 25)
        XCTAssertEqual(bindings["forward"], "KeyZ")
        XCTAssertEqual(bindings["back"], rpgDefaultChordBindings()["back"])
        XCTAssertEqual(bindings["left"], rpgDefaultChordBindings()["left"])
        XCTAssertNil(bindings["future"])
        XCTAssertEqual(Set(store.lastDiagnostics.map(\.field)), ["back", "left"])
    }

    func testKeybindPersistRequiresExactCanonicalUnprotectedCandidate() throws {
        let store = try makeStore()
        let defaults = rpgDefaultChordBindings()
        _ = try value(store.persistKeybinds(defaults))

        var missing = defaults
        missing.removeValue(forKey: "forward")
        guard case .failure(.invalidKeybinds(_)) = store.persistKeybinds(missing) else {
            return XCTFail("missing binding should fail")
        }
        var extra = defaults
        extra["future"] = "KeyP"
        guard case .failure(.invalidKeybinds(_)) = store.persistKeybinds(extra) else {
            return XCTFail("extra binding should fail")
        }
        var protected = defaults
        protected["forward"] = "Command+KeyQ"
        guard case .failure(.invalidKeybinds(_)) = store.persistKeybinds(protected) else {
            return XCTFail("protected binding should fail")
        }
        var noncanonical = defaults
        noncanonical["forward"] = "Shift+Command+KeyW"
        guard case .failure(.invalidKeybinds(_)) = store.persistKeybinds(noncanonical) else {
            return XCTFail("noncanonical binding should fail")
        }
        var overlong = defaults
        overlong["forward"] = String(repeating: "A", count: 65)
        guard case .failure(.invalidKeybinds(_)) = store.persistKeybinds(overlong) else {
            return XCTFail("overlong binding should fail")
        }
    }

    func testReadRejectsSymlinksAndNonRegularFiles() throws {
        let symlinkStore = try makeStore()
        try FileManager.default.createDirectory(at: symlinkStore.directoryURL, withIntermediateDirectories: true)
        let target = symlinkStore.directoryURL.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: symlinkStore.directoryURL.appendingPathComponent("settings.json"),
            withDestinationURL: target
        )
        guard case .failure(.readFailed(.settings, _)) = symlinkStore.loadSettings() else {
            return XCTFail("symlink should fail closed")
        }

        let directoryStore = try makeStore()
        try FileManager.default.createDirectory(
            at: directoryStore.directoryURL.appendingPathComponent("settings.json"),
            withIntermediateDirectories: true
        )
        guard case .failure(.readFailed(.settings, _)) = directoryStore.loadSettings() else {
            return XCTFail("non-regular file should fail closed")
        }
    }

    func testReadAndPersistRejectIntermediateAndParentDirectorySymlinks() throws {
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PebbleLocalSettingsTraversal-\(UUID().uuidString)", isDirectory: true)
        roots.append(base)
        let actual = base.appendingPathComponent("actual", isDirectory: true)
        let actualPebble = actual.appendingPathComponent("Pebble", isDirectory: true)
        try FileManager.default.createDirectory(at: actualPebble, withIntermediateDirectories: true)
        let original = Data("{\"fov\":91}".utf8)
        try original.write(to: actualPebble.appendingPathComponent("settings.json"))

        let intermediateLink = base.appendingPathComponent("intermediate", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: intermediateLink, withDestinationURL: actual)
        let intermediateStore = LocalSettingsStore(
            directoryURL: intermediateLink.appendingPathComponent("Pebble", isDirectory: true)
        )
        guard case .failure(.readFailed(.settings, _)) = intermediateStore.loadSettings() else {
            return XCTFail("intermediate directory symlink read should fail closed")
        }
        guard case .failure(.writeFailed(.settings, .temporaryCreate, _)) =
            intermediateStore.persistSettings(Settings()) else {
            return XCTFail("intermediate directory symlink persist should fail closed")
        }
        XCTAssertEqual(try Data(contentsOf: actualPebble.appendingPathComponent("settings.json")), original)

        let parentLink = base.appendingPathComponent("PebbleLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: actualPebble)
        let parentStore = LocalSettingsStore(directoryURL: parentLink)
        guard case .failure(.readFailed(.settings, _)) = parentStore.loadSettings() else {
            return XCTFail("parent directory symlink read should fail closed")
        }
        guard case .failure(.writeFailed(.settings, .temporaryCreate, _)) =
            parentStore.persistSettings(Settings()) else {
            return XCTFail("parent directory symlink persist should fail closed")
        }
        XCTAssertEqual(try Data(contentsOf: actualPebble.appendingPathComponent("settings.json")), original)
    }

    func testDiagnosticsAreBoundedByUTF8Bytes() {
        let diagnostic = LocalSettingsDiagnostic(
            field: String(repeating: "😀", count: 100),
            reason: String(repeating: "é", count: 100)
        )
        XCTAssertLessThanOrEqual(diagnostic.field.utf8.count, 128)
        XCTAssertLessThanOrEqual(diagnostic.reason.utf8.count, 160)
    }

    func testPersistedDocumentsAreStableCanonicalJSON() throws {
        let store = try makeStore()
        var settings = Settings()
        settings.fov = 93
        settings.rpgTutorialVersion = RPG_TUTORIAL_VERSION
        _ = try value(store.persistSettings(settings))
        let settingsURL = store.directoryURL.appendingPathComponent("settings.json")
        let first = try Data(contentsOf: settingsURL)
        _ = try value(store.persistSettings(settings))
        XCTAssertEqual(try Data(contentsOf: settingsURL), first)

        let defaults = rpgDefaultChordBindings()
        _ = try value(store.persistKeybinds(defaults))
        let keybindData = try Data(contentsOf: store.directoryURL.appendingPathComponent("keybinds.json"))
        XCTAssertEqual(keybindData, try JSONEncoder.sortedEncoding(defaults))
    }

    func testEveryAtomicWriteFailureIsReportedAndRestartIsOldOrNew() throws {
        for stage in LocalSettingsWriteStage.allCases {
            let store = try makeStore()
            var old = Settings()
            old.fov = 71
            _ = try value(store.persistSettings(old))
            var new = old
            new.fov = 109
            store.faultInjector = { current in
                current == stage ? InjectedLocalSettingsFailure(stage: current) : nil
            }
            guard case let .failure(.writeFailed(.settings, reported, _)) = store.persistSettings(new) else {
                return XCTFail("\(stage) should fail")
            }
            XCTAssertEqual(reported, stage)
            store.faultInjector = nil
            let restarted = try value(store.loadSettings())
            XCTAssertTrue(restarted.fov == old.fov || restarted.fov == new.fov)
            let names = try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)
            XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
        }
    }

    func testRealSystemPartialAndCompleteWriteCutsNeverReplaceOldDocument() throws {
        print("LocalSettingsStore real system write-cut cases=2")
        for cut in LocalSettingsSystemWriteCut.allCases {
            let store = try makeStore()
            var old = Settings(); old.fov = 71
            _ = try value(store.persistSettings(old))
            let target = store.directoryURL.appendingPathComponent("settings.json")
            let oldBytes = try Data(contentsOf: target)
            var candidate = old; candidate.fov = 109
            store.systemWriteCut = cut
            guard case .failure(.writeFailed(.settings, .write, _)) =
                store.persistSettings(candidate) else {
                return XCTFail("real system write cut \(cut) must fail at write")
            }
            store.systemWriteCut = nil
            XCTAssertEqual(try Data(contentsOf: target), oldBytes)
            XCTAssertEqual(try value(store.loadSettings()).fov, old.fov)
            let names = try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)
            XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
        }
    }

    func testFailedPersistenceDoesNotMutateCandidateOrExistingDocument() throws {
        let store = try makeStore()
        var old = Settings()
        old.rpgTutorialVersion = nil
        _ = try value(store.persistSettings(old))
        let oldData = try Data(contentsOf: store.directoryURL.appendingPathComponent("settings.json"))

        var candidate = old
        candidate.rpgTutorialVersion = 4
        store.faultInjector = { $0 == .fileSync ? InjectedLocalSettingsFailure(stage: $0) : nil }
        guard case .failure = store.persistSettings(candidate) else { return XCTFail("write should fail") }
        XCTAssertEqual(candidate.rpgTutorialVersion, 4)
        XCTAssertEqual(try Data(contentsOf: store.directoryURL.appendingPathComponent("settings.json")), oldData)
    }

    private func corpusContext(seed: UInt64, index: Int, label: String, data: Data) -> String {
        let head = data.prefix(24).map { String(format: "%02x", $0) }.joined()
        let tail = data.suffix(24).map { String(format: "%02x", $0) }.joined()
        return "seed=0x\(String(seed, radix: 16)) index=\(index) label=\(label) bytes=\(data.count) head=\(head) tail=\(tail)"
    }
}

private struct LocalSettingsCorpusRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func int(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

private extension JSONEncoder {
    static func sortedEncoding<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
