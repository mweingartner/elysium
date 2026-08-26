import Foundation
import XCTest
@testable import Elysium

@MainActor
final class OllamaCodeCompletionTests: XCTestCase {
    private let baseURL = URL(string: "http://completion.test")!

    func testSafePromptUsesExactModelCarriesBoundedContextAndHasNoToolFields() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"], "template": "ordinary-template"]),
            response(["response": "Here is the completion:\n```lua\nself:exists()\n```"]),
        ])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        let request = try makeRequest(
            source: "local door = self\ndoor:\n",
            caretUTF16: 23,
            schema: "self:exists() -> boolean",
            diagnostics: ["line 2: method expected"],
            nearby: [
                OllamaCodeCompletionNearbyObject(
                    reference: "block:overworld:1,64,2",
                    kind: "block",
                    displayName: "Oak Door",
                    distance: 2.5,
                    capabilities: ["open", "close"],
                    customAttributes: [
                        OllamaCodeCompletionNearbyAttribute(
                            name: "owner_note", type: "string", mutability: "read_only"
                        ),
                    ]
                ),
            ]
        )

        let result = try await service.complete(request)

        XCTAssertEqual(result.insertion, "self:exists()")
        XCTAssertEqual(result.strategy, .safePrompt)
        XCTAssertEqual(result.identity.model, "qwen2.5-coder:7b")
        XCTAssertEqual(result.modelHints?.capabilities, ["completion"])

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/show", "/api/generate"])
        let showBody = try jsonBody(requests[0])
        XCTAssertEqual(showBody["model"] as? String, "qwen2.5-coder:7b")

        let generateBody = try jsonBody(requests[1])
        XCTAssertEqual(generateBody["model"] as? String, "qwen2.5-coder:7b")
        XCTAssertEqual(generateBody["stream"] as? Bool, false)
        XCTAssertNil(generateBody["tools"], "editor completion must never expose AI tools")
        XCTAssertNil(generateBody["messages"], "editor completion must not reuse the tool-loop chat body")
        XCTAssertNil(generateBody["suffix"], "safe-prompt mode must not silently assume FIM support")
        XCTAssertTrue((generateBody["prompt"] as? String)?.contains("<ELY_CURSOR>") == true)
        let system = try XCTUnwrap(generateBody["system"] as? String)
        XCTAssertTrue(system.contains("self:exists() -> boolean"))
        XCTAssertTrue(system.contains("line 2: method expected"))
        XCTAssertTrue(system.contains("block:overworld:1,64,2"))
        XCTAssertTrue(system.contains("owner_note"))
        XCTAssertTrue(system.contains("read_only"))
        XCTAssertTrue(system.contains("untrusted data"))
    }

    func testSelectionIsSeparatedFromPrefixSuffixAndParticipatesInStaleIdentity() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"]]),
            response(["response": "new_value"]),
        ])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        let source = "local x = old\n"
        let caret = ("local x = " as NSString).length
        let request = try makeRequest(source: source, caretUTF16: caret, selectionLengthUTF16: 3)

        XCTAssertEqual(request.prefix, "local x = ")
        XCTAssertEqual(request.selectedText, "old")
        XCTAssertEqual(request.suffix, "\n")

        let result = try await service.complete(request)
        XCTAssertTrue(result.isCurrent(
            documentRevision: 4,
            source: source,
            caretUTF16: caret,
            selectionLengthUTF16: 3,
            contextKey: request.identity.contextKey,
            model: "qwen2.5-coder:7b"
        ))
        XCTAssertFalse(result.isCurrent(
            documentRevision: 4,
            source: source,
            caretUTF16: caret,
            selectionLengthUTF16: 0,
            contextKey: request.identity.contextKey,
            model: "qwen2.5-coder:7b"
        ))
        let requests = await transport.recordedRequests()
        let body = try jsonBody(try XCTUnwrap(requests.last))
        let prompt = try XCTUnwrap(body["prompt"] as? String)
        XCTAssertTrue(prompt.contains("<ELY_SELECTION>\nold\n</ELY_SELECTION>"))
    }

    func testUnfencedInsertionPreservesMeaningfulLeadingAndTrailingWhitespace() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": []]),
            response(["response": "\n  say('hello')\n"]),
        ])
        let result = try await OllamaCodeCompletionService(
            baseURL: baseURL, transport: transport
        ).complete(makeRequest())

        XCTAssertEqual(result.insertion, "\n  say('hello')\n")
    }

    func testExplicitFillInMiddleUsesPrefixAndSuffixWithoutInventingSupport() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"], "template": "{{ .Prompt }}<|fim_prefix|>"]),
            response(["response": "door:exists()"]),
        ])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        let source = "local door = self\n\nreturn door"
        let caret = ("local door = self\n" as NSString).length
        let request = try makeRequest(
            source: source,
            caretUTF16: caret,
            fillInMiddlePolicy: .explicitlyEnabled
        )

        let result = try await service.complete(request)

        XCTAssertEqual(result.strategy, .fillInMiddle)
        XCTAssertEqual(result.modelHints?.templateSuggestsFillInMiddle, true)
        let requests = await transport.recordedRequests()
        let body = try jsonBody(try XCTUnwrap(requests.last))
        XCTAssertEqual(body["prompt"] as? String, "local door = self\n")
        XCTAssertEqual(body["suffix"] as? String, "\nreturn door")
        XCTAssertNil(body["tools"])
    }

    func testEditorInstructionForcesSafeNoToolsPromptAndReturnsPlainText() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"]]),
            response(["response": "This handler checks whether the target still exists."]),
        ])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        let request = try makeRequest(
            fillInMiddlePolicy: .explicitlyEnabled,
            instruction: "Explain this script without changing the world."
        )

        let result = try await service.complete(request)

        XCTAssertEqual(result.strategy, .safePrompt, "instructions are not raw FIM completions")
        XCTAssertEqual(result.insertion, "This handler checks whether the target still exists.")
        let requests = await transport.recordedRequests()
        let body = try jsonBody(try XCTUnwrap(requests.last))
        XCTAssertNil(body["suffix"])
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["messages"])
        XCTAssertTrue((body["prompt"] as? String)?.contains("Explain this script without changing the world.") == true)
        XCTAssertTrue((body["system"] as? String)?.contains("You have no tools") == true)
        XCTAssertTrue(result.isCurrent(
            documentRevision: 4,
            source: "self:",
            caretUTF16: 5,
            contextKey: request.identity.contextKey,
            model: "qwen2.5-coder:7b",
            instruction: "Explain this script without changing the world."
        ))
        XCTAssertFalse(result.isCurrent(
            documentRevision: 4,
            source: "self:",
            caretUTF16: 5,
            contextKey: request.identity.contextKey,
            model: "qwen2.5-coder:7b",
            instruction: "Rewrite it instead."
        ))
    }

    func testCloudTaggedModelIsRejectedBeforeAnyTransportCall() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        let request = try makeRequest(model: "qwen3-coder:cloud")

        do {
            _ = try await service.complete(request)
            XCTFail("cloud-tagged completion model should be rejected")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .cloudModelForbidden)
        }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testProductionOllamaSessionRejectsRedirectBeforeForwardingRequestBody() throws {
        let delegate = OllamaLoopbackSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var original = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        original.httpMethod = "POST"
        original.httpBody = Data("private-source".utf8)
        let task = session.dataTask(with: original)
        let redirect = URLRequest(url: URL(string: "https://outside.example/collect")!)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: original.url!, statusCode: 307,
            httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.url!.absoluteString]
        ))
        var proposed: URLRequest? = redirect
        var completionCalled = false

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirect
        ) { request in
            proposed = request
            completionCalled = true
        }

        XCTAssertTrue(completionCalled)
        XCTAssertNil(proposed, "redirect must be rejected so no source-bearing POST reaches another origin")
    }

    func testProductionOllamaConfigurationDisablesAmbientTransportStateAndProxies() {
        let configuration = OllamaAgentService.loopbackSessionConfiguration()

        XCTAssertEqual(configuration.connectionProxyDictionary?.isEmpty, true)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testBoundedResponseBufferRejectsDeclaredAndStreamingOverflow() throws {
        XCTAssertThrowsError(try OllamaBoundedResponseBuffer(
            maximumBytes: 4,
            expectedContentLength: 5
        )) { error in
            XCTAssertEqual(error as? OllamaBoundedResponseError, .responseTooLarge)
        }

        var buffer = try OllamaBoundedResponseBuffer(maximumBytes: 4)
        for byte in Data("four".utf8) { try buffer.append(byte) }
        XCTAssertEqual(buffer.data, Data("four".utf8))
        XCTAssertThrowsError(try buffer.append(UInt8(ascii: "!"))) { error in
            XCTAssertEqual(error as? OllamaBoundedResponseError, .responseTooLarge)
        }
    }

    func testModelMustAlreadyBeTheExactSanitizedSelectedName() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        let request = try makeRequest(model: " qwen2.5-coder:7b ")

        do {
            _ = try await service.complete(request)
            XCTFail("service must not silently substitute a sanitized model name")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .invalidModel)
        }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testMalformedGenerateResponseFailsClosed() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"]]),
            OllamaCodeCompletionHTTPResponse(statusCode: 200, body: Data("not-json".utf8)),
        ])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)

        do {
            _ = try await service.complete(makeRequest())
            XCTFail("malformed output should not become an editor insertion")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .malformedResponse)
        }
    }

    func testCompletionOutputIsCharacterLineAndControlBounded() async throws {
        let oversized = (0..<100)
            .map { "line\($0)-" + String(repeating: "x", count: 90) }
            .joined(separator: "\n") + "\u{0}"
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": []]),
            response(["response": oversized]),
        ])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)

        let result = try await service.complete(makeRequest())

        XCTAssertLessThanOrEqual(result.insertion.count, 4_096)
        XCTAssertLessThanOrEqual(
            result.insertion.split(separator: "\n", omittingEmptySubsequences: false).count,
            80
        )
        XCTAssertFalse(result.insertion.contains("\u{0}"))
    }

    func testCancellationStopsGenerateAndReturnsCancelled() async throws {
        let transport = BlockingGenerateCodeCompletionTransport()
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        let request = try makeRequest()
        let task = Task { try await service.complete(request) }

        for _ in 0..<2_000 {
            if await transport.generateHasStarted() { break }
            await Task.yield()
        }
        let started = await transport.generateHasStarted()
        XCTAssertTrue(started, "test must reach the cancellable generate call")
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled request should not publish a proposal")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .cancelled)
        }
        let cancelled = await transport.generateWasCancelled()
        XCTAssertTrue(cancelled)
    }

    func testCurrentnessHookRejectsReplyThatBecameStaleDuringTransport() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"]]),
            response(["response": "say('late')"]),
        ])
        let gate = CurrentnessGate(staleAtCheck: 3)
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)

        do {
            _ = try await service.complete(makeRequest()) { identity in
                await gate.isCurrent(identity)
            }
            XCTFail("a proposal from stale source/context must be discarded")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .stale)
        }
        let checkCount = await gate.checkCount()
        XCTAssertEqual(checkCount, 3)
    }

    func testResponseIdentityDetectsDocumentCaretContextAndModelChanges() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": []]),
            response(["response": "exists()"]),
        ])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        let source = "self:"
        let context = OllamaCodeCompletionContextKey(
            revision: 7,
            targetReference: "player",
            scriptMode: "module"
        )
        let request = try OllamaCodeCompletionRequest(
            source: source,
            caretUTF16: (source as NSString).length,
            documentRevision: 12,
            contextKey: context,
            model: "qwen2.5-coder:7b",
            languageSchema: "self:exists()"
        )
        let result = try await service.complete(request)

        XCTAssertTrue(result.isCurrent(
            documentRevision: 12,
            source: source,
            caretUTF16: 5,
            contextKey: context,
            model: "qwen2.5-coder:7b"
        ))
        XCTAssertFalse(result.isCurrent(
            documentRevision: 13,
            source: source + "x",
            caretUTF16: 6,
            contextKey: context,
            model: "qwen2.5-coder:7b"
        ))
    }

    func testCaretSplittingASurrogatePairIsRejected() throws {
        XCTAssertThrowsError(try OllamaCodeCompletionRequest(
            source: "a😀b",
            caretUTF16: 2,
            documentRevision: 1,
            contextKey: OllamaCodeCompletionContextKey(
                revision: 1,
                targetReference: "player",
                scriptMode: "module"
            ),
            model: "qwen2.5-coder:7b",
            languageSchema: ""
        )) { error in
            XCTAssertEqual(error as? OllamaCodeCompletionError, .invalidCaret)
        }
    }

    private func makeRequest(
        source: String = "self:",
        caretUTF16: Int? = nil,
        selectionLengthUTF16: Int = 0,
        model: String = "qwen2.5-coder:7b",
        schema: String = "self:exists() -> boolean",
        diagnostics: [String] = [],
        nearby: [OllamaCodeCompletionNearbyObject] = [],
        fillInMiddlePolicy: OllamaCodeCompletionFillInMiddlePolicy = .disabled,
        instruction: String? = nil
    ) throws -> OllamaCodeCompletionRequest {
        try OllamaCodeCompletionRequest(
            source: source,
            caretUTF16: caretUTF16 ?? (source as NSString).length,
            selectionLengthUTF16: selectionLengthUTF16,
            documentRevision: 4,
            contextKey: OllamaCodeCompletionContextKey(
                revision: 9,
                targetReference: "player",
                scriptMode: "module",
                eventName: "player.interacted"
            ),
            model: model,
            languageSchema: schema,
            diagnostics: diagnostics,
            authorizedNearbyObjects: nearby,
            fillInMiddlePolicy: fillInMiddlePolicy,
            instruction: instruction
        )
    }

    private func response(_ object: [String: Any], statusCode: Int = 200) -> OllamaCodeCompletionHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return OllamaCodeCompletionHTTPResponse(statusCode: statusCode, body: data)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private enum RecordingTransportError: Error {
    case missingResponse
}

private actor RecordingCodeCompletionTransport: OllamaCodeCompletionTransport {
    private var requests: [URLRequest] = []
    private var responses: [OllamaCodeCompletionHTTPResponse]

    init(responses: [OllamaCodeCompletionHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> OllamaCodeCompletionHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw RecordingTransportError.missingResponse }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private actor BlockingGenerateCodeCompletionTransport: OllamaCodeCompletionTransport {
    private var started = false
    private var cancelled = false

    func send(_ request: URLRequest) async throws -> OllamaCodeCompletionHTTPResponse {
        if request.url?.path == "/api/show" {
            let data = try JSONSerialization.data(withJSONObject: ["capabilities": ["completion"]])
            return OllamaCodeCompletionHTTPResponse(statusCode: 200, body: data)
        }
        started = true
        do {
            try await ContinuousClock().sleep(for: .seconds(30))
            let data = try JSONSerialization.data(withJSONObject: ["response": "too late"])
            return OllamaCodeCompletionHTTPResponse(statusCode: 200, body: data)
        } catch {
            cancelled = true
            throw error
        }
    }

    func generateHasStarted() -> Bool { started }
    func generateWasCancelled() -> Bool { cancelled }
}

private actor CurrentnessGate {
    private let staleAtCheck: Int
    private var count = 0

    init(staleAtCheck: Int) {
        self.staleAtCheck = staleAtCheck
    }

    func isCurrent(_ identity: OllamaCodeCompletionIdentity) -> Bool {
        _ = identity
        count += 1
        return count < staleAtCheck
    }

    func checkCount() -> Int { count }
}
