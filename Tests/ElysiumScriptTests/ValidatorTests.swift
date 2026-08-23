// ValidatorTests.swift — task 6.1/6.4. design.md Decision 12 (validator stages 0-3)
// and spec "Validator stages 0-3", plus Condition 28's format-grammar amendment.

import ElysiumCore
import ElysiumScript
import XCTest

final class ValidatorTests: XCTestCase {
    // MARK: - Stage 0: text hygiene (bidi, C1, \r, size)

    func testStage0RejectsBidiControl() throws {
        let state = try ScriptTestSupport.makeState()
        let source = "return 1 -- \u{202E}reversed"
        let result = ScriptValidator.validate(source: source, chunkName: "bidi", using: state)
        guard case .refused(let stage, let message, _, let line) = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(stage, 0)
        XCTAssertEqual(line, 1)
        XCTAssertTrue(message.contains("invalid character"), message)
    }

    func testStage0RejectsC1Control() throws {
        let state = try ScriptTestSupport.makeState()
        let source = "return 1 -- \u{0085}"
        let result = ScriptValidator.validate(source: source, chunkName: "c1", using: state)
        guard case .refused(let stage, _, _, _) = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertEqual(stage, 0)
    }

    func testStage0RejectsCarriageReturn() throws {
        let state = try ScriptTestSupport.makeState()
        let source = "return 1\r\nreturn 2"
        let result = ScriptValidator.validate(source: source, chunkName: "cr", using: state)
        guard case .refused(let stage, let message, _, let line) = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(stage, 0)
        XCTAssertEqual(line, 1, "the validator never rewrites CRLF; \\r is rejected exactly where it appears")
        XCTAssertTrue(message.contains("invalid character"), message)
    }

    func testStage0AcceptsNewlineAndTab() throws {
        let state = try ScriptTestSupport.makeState()
        let source = "return 1\n\t-- tab and newline are fine"
        let result = ScriptValidator.validate(source: source, chunkName: "nltab", using: state)
        guard case .accepted = result else { return XCTFail("expected acceptance, got \(result)") }
    }

    func testStage0RejectsOversizeSource() throws {
        let state = try ScriptTestSupport.makeState()
        let source = "-- " + String(repeating: "x", count: 20_000)
        let result = ScriptValidator.validate(source: source, chunkName: "big", using: state)
        guard case .refused(let stage, let message, _, _) = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertEqual(stage, 0)
        XCTAssertTrue(message.contains("16384") || message.contains("bytes"), message)
    }

    // MARK: - Stage 1: syntax errors are sanitized

    func testStage1SyntaxErrorIsSanitized() throws {
        let state = try ScriptTestSupport.makeState()
        let result = ScriptValidator.validate(source: "local x = (1 +", chunkName: "syntaxbad", using: state)
        guard case .refused(let stage, let message, let hint, _) = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(stage, 1)
        XCTAssertFalse(message.contains("0x"), message)
        XCTAssertLessThanOrEqual(message.utf8.count, 512)
        XCTAssertEqual(hint, "fix the syntax error")
    }

    // MARK: - Stage 2: accepts declared locals, denies bare globals

    func testStage2AcceptsDeclaredLocalShadowingABannedName() throws {
        let state = try ScriptTestSupport.makeState()
        let result = ScriptValidator.validate(source: "local debug = 1\nreturn debug + 1", chunkName: "shadow", using: state)
        guard case .accepted = result else { return XCTFail("expected acceptance, got \(result)") }
    }

    func testStage2AcceptsFieldPositionUseOfABannedRootName() throws {
        let state = try ScriptTestSupport.makeState()
        let result = ScriptValidator.validate(source: "local self = {os = {x = 1}}\nreturn self.os.x", chunkName: "fieldpos", using: state)
        guard case .accepted = result else { return XCTFail("expected acceptance, got \(result)") }
    }

    func testStage2RejectsBareRequireAtTopLevel() throws {
        let state = try ScriptTestSupport.makeState()
        let result = ScriptValidator.validate(source: "require('x')", chunkName: "requirebad", using: state)
        guard case .refused(let stage, let message, let hint, _) = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(stage, 2)
        XCTAssertTrue(message.contains("require"), message)
        XCTAssertTrue(hint.contains("require"), hint)
    }

    func testStage2RejectsBareLibraryFieldChain() throws {
        let state = try ScriptTestSupport.makeState()
        let result = ScriptValidator.validate(source: "return os.time()", chunkName: "osfield", using: state)
        guard case .refused(let stage, let message, _, _) = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertEqual(stage, 2)
        XCTAssertTrue(message.contains("os.time"), message)
    }

    func testStage2RejectsStringDump() throws {
        let state = try ScriptTestSupport.makeState()
        let result = ScriptValidator.validate(source: "return string.dump(print)", chunkName: "dumpbad", using: state)
        guard case .refused(let stage, let message, _, _) = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertEqual(stage, 2)
        XCTAssertTrue(message.contains("string.dump"), message)
    }

    // MARK: - %p format grammar (Condition 28)

    func testFormatPRejectionGrammar() throws {
        let state = try ScriptTestSupport.makeState()
        for rejected in ["string.format('%p', x)", "string.format('%5p', x)", "string.format('%-10p', x)", "string.format('%-+ 0 5.2p', x)"] {
            let result = ScriptValidator.validate(source: "local x = {}\nreturn \(rejected)", chunkName: "pbad", using: state)
            guard case .refused(let stage, let message, _, _) = result else {
                XCTFail("expected \(rejected) to be refused, got \(result)")
                continue
            }
            XCTAssertEqual(stage, 2)
            XCTAssertTrue(message.contains("%p") || message.contains("format"), "\(rejected) -> \(message)")
        }
        // %% is not a conversion at all, so a literal '%%p' must be accepted.
        let accepted = ScriptValidator.validate(source: "return string.format('%%p')", chunkName: "pescaped", using: state)
        guard case .accepted = accepted else { return XCTFail("expected '%%p' to be accepted, got \(accepted)") }
        // An ordinary conversion (not p) must also be accepted.
        let ordinary = ScriptValidator.validate(source: "return string.format('%5d', 1)", chunkName: "pordinary", using: state)
        guard case .accepted = ordinary else { return XCTFail("expected '%5d' to be accepted, got \(ordinary)") }
    }

    // MARK: - Stage 3: fence / chat-template tokens

    func testStage3RejectsFenceAndChatTemplateTokens() throws {
        let state = try ScriptTestSupport.makeState()
        let markers = ["```", "<|im_start|>", "<|im_end|>", "<|eot_id|>", "<<SYS>>", "[INST]"]
        for marker in markers {
            let source = "return 1 -- \(marker) trailing comment"
            let result = ScriptValidator.validate(source: source, chunkName: "fence", using: state)
            guard case .refused(let stage, let message, let hint, _) = result else {
                XCTFail("expected '\(marker)' to be refused, got \(result)")
                continue
            }
            XCTAssertEqual(stage, 3)
            XCTAssertTrue(message.contains("fence") || message.contains("template"), message)
            XCTAssertTrue(hint.contains(marker), hint)
        }
    }

    func testStage3AcceptsCleanSource() throws {
        let state = try ScriptTestSupport.makeState()
        let result = ScriptValidator.validate(source: "local t = {1, 2, 3}\nreturn #t", chunkName: "clean", using: state)
        guard case .accepted = result else { return XCTFail("expected acceptance, got \(result)") }
    }

    // MARK: - sourceSHA256 is stable

    func testSourceSHA256Stable() throws {
        let state = try ScriptTestSupport.makeState()
        let source = "local function greet() return 'hello' end\nreturn greet()"
        guard case .accepted(let hash1) = ScriptValidator.validate(source: source, chunkName: "hashA", using: state) else {
            return XCTFail("expected acceptance")
        }
        guard case .accepted(let hash2) = ScriptValidator.validate(source: source, chunkName: "hashB", using: state) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertEqual(hash1, hash2, "the same source must hash identically regardless of chunk name")
        XCTAssertEqual(hash1.count, 64, "expected a 64-hex-character SHA-256 digest")

        guard case .accepted(let hash3) = ScriptValidator.validate(source: source + "\n", chunkName: "hashA", using: state) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertNotEqual(hash1, hash3, "a single trailing byte must change the hash")
    }
}
