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
            authoring: OllamaCodeCompletionAuthoringContext(
                targetReference: "player",
                targetKind: "player",
                scriptMode: "module",
                modeContract: "Module source registers callbacks; ev exists only inside callback functions.",
                selectedEvent: nil,
                compatibleEvents: [
                    OllamaCodeCompletionAuthoringEvent(
                        name: "player.interacted",
                        source: "built_in",
                        payloadFields: ["item:string?"],
                        summary: "A player interacted with an entity."
                    ),
                    OllamaCodeCompletionAuthoringEvent(
                        name: "player.quest_ready",
                        source: "declared_custom",
                        payloadFields: ["quest:string"]
                    ),
                    OllamaCodeCompletionAuthoringEvent(
                        name: "block.changed",
                        source: "built_in",
                        payloadFields: ["oldName:string", "newName:string"],
                        summary: "A non-silent block cell write changed name or metadata."
                    ),
                ],
                targetMembers: ["method self:set(name, value)", "attribute health:number:writable"]
            ),
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
                    ],
                    builtInEvents: ["attribute.changed", "block.used"],
                    customEvents: [
                        OllamaCodeCompletionAuthoringEvent(
                            name: "sensor.threshold",
                            source: "declared_custom",
                            payloadFields: ["value:number", "unit:string?"]
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
        XCTAssertEqual(
            generateBody["keep_alive"] as? String,
            OllamaAgentService.editorModelPreloadKeepAlive
        )
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
        XCTAssertTrue(system.contains("built_in_events"))
        XCTAssertTrue(system.contains("block.used"))
        XCTAssertTrue(system.contains("custom_events"))
        XCTAssertTrue(system.contains("sensor.threshold"))
        XCTAssertTrue(system.contains("value:number"))
        XCTAssertTrue(system.contains("<ELY_AUTHORING_CONTEXT>"))
        XCTAssertTrue(system.contains("player.quest_ready [declared_custom]"))
        XCTAssertTrue(system.contains("block.changed [built_in]"))
        XCTAssertTrue(system.contains("A non-silent block cell write changed name or metadata."))
        XCTAssertTrue(system.contains("method self:set(name, value)"))
        XCTAssertTrue(system.contains("There is no h, block, target, or furnace global"))
        XCTAssertFalse(system.contains("h:emit()"))
        XCTAssertTrue(system.contains("ev exists only inside callback functions"))
        XCTAssertTrue(system.contains("cannot be emitted manually"))
        XCTAssertTrue(system.contains("custom event names only"))
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
            instruction: "Explain this script without changing the world.",
            instructionIntent: .question
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
        XCTAssertTrue((body["system"] as? String)?.contains("This is a question") == true)
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

    func testQuestionResponsePreservesExplanationAroundFencedExample() async throws {
        let raw = "Use this example:\r\n```lua\r\nsay('hello')\r\n```\r\nIt posts one line."
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"]]),
            response(["response": raw]),
        ])
        let request = try makeRequest(
            instruction: "How do I post a line?",
            instructionIntent: .question
        )

        let result = try await OllamaCodeCompletionService(
            baseURL: baseURL,
            transport: transport
        ).complete(request)

        XCTAssertEqual(
            result.text,
            "Use this example:\n```lua\nsay('hello')\n```\nIt posts one line."
        )
    }

    func testCloudTaggedModelIsRejectedBeforeAnyTransportCall() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        for model in ["qwen3-coder:cloud", "qwen3-coder:480b-cloud"] {
            do {
                _ = try await service.complete(makeRequest(model: model))
                XCTFail("cloud-tagged completion model should be rejected")
            } catch {
                XCTAssertEqual(error as? OllamaCodeCompletionError, .cloudModelForbidden)
            }
        }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRemoteBackedAliasIsRejectedBySourceFreeShowBeforeGeneration() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [response([
            "capabilities": ["completion"],
            "remote_model": "qwen3-coder:480b-cloud",
            "remote_host": "https://ollama.com",
        ])])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)

        do {
            _ = try await service.complete(makeRequest(model: "friendly-local-name:latest"))
            XCTFail("a remote-backed alias must never receive editor source")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .cloudModelForbidden)
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/api/show")
        let showBody = try jsonBody(try XCTUnwrap(requests.first))
        XCTAssertEqual(Set(showBody.keys), ["model"])
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
        let editorConfiguration = OllamaAgentService.editorCompletionSessionConfiguration()

        XCTAssertEqual(configuration.connectionProxyDictionary?.isEmpty, true)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertGreaterThanOrEqual(
            editorConfiguration.timeoutIntervalForRequest,
            OllamaCodeCompletionService.generationTimeout
        )
        XCTAssertGreaterThan(
            editorConfiguration.timeoutIntervalForResource,
            OllamaCodeCompletionService.generationTimeout
        )
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

    func testFirstRequestWaitsForOneSharedColdPreparationAcrossEditors() async throws {
        let transport = CoordinatedPreparationTransport(blockFirstWarmup: true)
        let service = OllamaCodeCompletionService(
            baseURL: baseURL,
            transport: transport,
            preparationTransport: transport
        )
        let model = "qwen2.5-coder:7b"
        let firstOwner = UUID()
        let secondOwner = UUID()
        let firstPreparation = Task {
            try await service.prepareEditorModel(model, owner: firstOwner)
        }
        try await waitForWarmupCount(1, transport: transport)

        let secondPreparation = Task {
            try await service.prepareEditorModel(model, owner: secondOwner)
        }
        let completion = Task {
            try await service.complete(makeRequest(model: model))
        }
        for _ in 0..<20 { await Task.yield() }

        var counts = await transport.counts()
        XCTAssertEqual(counts.warmups, 1, "same-model editor/request preparation must coalesce")
        XCTAssertEqual(
            counts.metadata,
            1,
            "one source-free locality check must precede cold preparation"
        )
        XCTAssertEqual(counts.generations, 0, "the first prompt must not race the cold load")

        await transport.releaseFirstWarmup()
        try await firstPreparation.value
        try await secondPreparation.value
        let result = try await completion.value
        XCTAssertEqual(result.insertion, "say('first request works')")

        counts = await transport.counts()
        XCTAssertEqual(counts.warmups, 1)
        XCTAssertEqual(counts.metadata, 1)
        XCTAssertEqual(counts.generations, 1)
        let requests = await transport.recordedRequests()
        let warmup = try XCTUnwrap(requests.first { request in
            guard request.url?.path == "/api/generate",
                  let body = try? jsonBody(request) else { return false }
            return (body["prompt"] as? String) == ""
        })
        let metadata = try XCTUnwrap(requests.first { $0.url?.path == "/api/show" })
        let generation = try XCTUnwrap(requests.last { request in
            guard request.url?.path == "/api/generate",
                  let body = try? jsonBody(request) else { return false }
            return (body["prompt"] as? String)?.isEmpty == false
        })
        XCTAssertEqual(warmup.timeoutInterval, OllamaAgentService.editorModelPreloadTimeout)
        XCTAssertEqual(metadata.timeoutInterval, OllamaCodeCompletionService.metadataTimeout)
        XCTAssertEqual(generation.timeoutInterval, OllamaCodeCompletionService.generationTimeout)

        await service.releaseEditorModel(owner: firstOwner)
        await service.releaseEditorModel(owner: secondOwner)
    }

    func testFailedProactivePreparationRetriesInsideFirstExplicitRequest() async throws {
        let transport = CoordinatedPreparationTransport(failFirstWarmup: true)
        let service = OllamaCodeCompletionService(
            baseURL: baseURL,
            transport: transport,
            preparationTransport: transport
        )
        let model = "qwen2.5-coder:7b"
        let owner = UUID()

        do {
            try await service.prepareEditorModel(model, owner: owner)
            XCTFail("the injected first preparation should fail")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .modelPreparationFailed)
        }

        let result = try await service.complete(makeRequest(model: model))
        XCTAssertEqual(result.insertion, "say('first request works')")
        let counts = await transport.counts()
        XCTAssertEqual(counts.warmups, 2, "the explicit request should retry preparation itself")
        XCTAssertEqual(counts.generations, 1, "one click should produce one source-bearing request")
        await service.releaseEditorModel(owner: owner)
    }

    func testMalformedSuccessfulWarmupNeverMarksModelReady() async throws {
        for malformed in [[:], ["response": ""], ["done": true]] as [[String: Any]] {
            let transport = RecordingCodeCompletionTransport(responses: [
                response(["capabilities": ["completion"]]),
                response(malformed),
            ])
            let service = OllamaCodeCompletionService(
                baseURL: baseURL,
                transport: transport,
                preparationTransport: transport
            )
            do {
                try await service.prepareEditorModel("qwen2.5-coder:7b", owner: UUID())
                XCTFail("a partial 2xx warmup response must fail closed")
            } catch {
                XCTAssertEqual(error as? OllamaCodeCompletionError, .modelPreparationFailed)
            }
        }
    }

    func testFinalGenerationTransportFailureInvalidatesReadinessForRetry() async throws {
        let transport = CoordinatedPreparationTransport(failEveryGeneration: true)
        let service = OllamaCodeCompletionService(
            baseURL: baseURL,
            transport: transport,
            preparationTransport: transport
        )
        let model = "qwen2.5-coder:7b"

        do {
            _ = try await service.complete(makeRequest(model: model))
            XCTFail("both injected generation attempts should fail")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .transport)
        }
        var counts = await transport.counts()
        XCTAssertEqual(counts.warmups, 2)
        XCTAssertEqual(counts.generations, 2)

        let owner = UUID()
        try await service.prepareEditorModel(model, owner: owner)
        counts = await transport.counts()
        XCTAssertEqual(
            counts.warmups,
            3,
            "Retry must perform a real warmup after the final generation transport failure"
        )
        await service.releaseEditorModel(owner: owner)
    }

    func testCancelledLatePreparationCannotLeaveRetiredEditorOwnership() async throws {
        let transport = CancellablePreparationTransport()
        let service = OllamaCodeCompletionService(
            baseURL: baseURL,
            transport: transport,
            preparationTransport: transport
        )
        let model = "qwen2.5-coder:7b"
        let retiredOwner = UUID()
        let gate = TestAsyncGate()
        let retiredPreparation = Task {
            await gate.wait()
            try await service.prepareEditorModel(model, owner: retiredOwner)
        }

        await service.releaseEditorModel(owner: retiredOwner)
        retiredPreparation.cancel()
        await gate.open()
        do {
            try await retiredPreparation.value
            XCTFail("a canceled late preparation must not register its retired owner")
        } catch {
            XCTAssertTrue(
                error is CancellationError ||
                    (error as? OllamaCodeCompletionError) == .cancelled
            )
        }

        let activeOwner = UUID()
        let activePreparation = Task {
            try await service.prepareEditorModel(model, owner: activeOwner)
        }
        let clock = ContinuousClock()
        let startDeadline = clock.now.advanced(by: .seconds(2))
        while clock.now < startDeadline, await transport.startedCount() == 0 {
            try await clock.sleep(for: .milliseconds(10))
        }
        let startedCount = await transport.startedCount()
        XCTAssertEqual(startedCount, 1)

        await service.releaseEditorModel(owner: activeOwner)
        let cancelDeadline = clock.now.advanced(by: .seconds(2))
        while clock.now < cancelDeadline, await transport.cancelledCount() == 0 {
            try await clock.sleep(for: .milliseconds(10))
        }
        let cancellationCount = await transport.cancelledCount()
        XCTAssertEqual(
            cancellationCount,
            1,
            "the active owner's release must cancel the now-unowned preparation"
        )
        await service.releaseEditorModel(owner: retiredOwner)
        await service.releaseEditorModel(owner: activeOwner)
        do {
            try await activePreparation.value
            XCTFail("released preparation should be canceled")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .cancelled)
        }
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
            documentIdentity: 41,
            contextKey: context,
            model: "qwen2.5-coder:7b",
            languageSchema: "self:exists()"
        )
        let result = try await service.complete(request)

        XCTAssertTrue(result.isCurrent(
            documentRevision: 12,
            documentIdentity: 41,
            source: source,
            caretUTF16: 5,
            contextKey: context,
            model: "qwen2.5-coder:7b"
        ))
        XCTAssertFalse(result.isCurrent(
            documentRevision: 12,
            documentIdentity: 42,
            source: source,
            caretUTF16: 5,
            contextKey: context,
            model: "qwen2.5-coder:7b"
        ), "byte-identical scripts in different editor documents must not share AI proposals")
        XCTAssertFalse(result.isCurrent(
            documentRevision: 13,
            documentIdentity: 41,
            source: source + "x",
            caretUTF16: 6,
            contextKey: context,
            model: "qwen2.5-coder:7b"
        ))
    }

    func testCompactAuthoringContextIsIndependentOfLuaCATSTruncation() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"], "template": "ordinary-template"]),
            response(["response": "say(ev.quest)"]),
        ])
        let service = OllamaCodeCompletionService(baseURL: baseURL, transport: transport)
        let request = try makeRequest(
            source: "say(ev.",
            schema: String(repeating: "x", count: 7_000) + "SCHEMA_TAIL_MUST_BE_TRUNCATED",
            authoring: OllamaCodeCompletionAuthoringContext(
                targetReference: "player",
                targetKind: "player",
                scriptMode: "handler",
                modeContract: "Handler source uses implicit ev directly and must not subscribe.",
                selectedEvent: "player.open_signal",
                compatibleEvents: [
                    OllamaCodeCompletionAuthoringEvent(
                        name: "player.quest_ready",
                        source: "declared_custom",
                        payloadFields: ["quest:string"]
                    ),
                    OllamaCodeCompletionAuthoringEvent(
                        name: "player.open_signal",
                        source: "open_custom_selected",
                        payloadFields: [],
                        payloadContract: "open_custom_unknown_envelope_only"
                    ),
                ],
                targetMembers: ["property ref:string", "method self:get(name)"]
            )
        )

        _ = try await service.complete(request)
        let requests = await transport.recordedRequests()
        let generateBody = try jsonBody(requests[1])
        let system = try XCTUnwrap(generateBody["system"] as? String)
        XCTAssertTrue(system.contains("<ELY_AUTHORING_CONTEXT>"))
        XCTAssertTrue(system.contains("selected_event=player.open_signal"))
        XCTAssertTrue(system.contains("player.quest_ready [declared_custom] payload_contract=typed_event_specific fields=quest:string"))
        XCTAssertTrue(system.contains("event_envelope=kind:string,subject:object,tick:integer,source:string"))
        XCTAssertTrue(system.contains("player.open_signal [open_custom_selected]"))
        XCTAssertTrue(system.contains("payload_contract=open_custom_unknown_envelope_only fields=none"))
        XCTAssertTrue(system.contains("event-specific payload is unknown"))
        XCTAssertTrue(system.contains("Handler source uses implicit ev directly"))
        XCTAssertFalse(system.contains("SCHEMA_TAIL_MUST_BE_TRUNCATED"))
    }

    func testSelectedEventKeepsAllDeclaredFieldsAndReportsOmittedWholeContracts() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"]]),
            response(["response": "say(ev.required_31)"]),
        ])
        let selectedFields = (0..<32).map { "required_\($0):string" }
        let fillerFields = (0..<32).map { "filler_\($0):string" }
        var events = (0..<12).map {
            OllamaCodeCompletionAuthoringEvent(
                name: "machine.filler\($0)",
                source: "declared_custom",
                payloadFields: fillerFields
            )
        }
        events.append(OllamaCodeCompletionAuthoringEvent(
            name: "machine.selected",
            source: "declared_custom",
            payloadFields: selectedFields
        ))
        let request = try makeRequest(authoring: OllamaCodeCompletionAuthoringContext(
            targetReference: "block:overworld:1,64,2",
            targetKind: "block",
            scriptMode: "handler",
            modeContract: "Handler source uses implicit ev directly.",
            selectedEvent: "machine.selected",
            compatibleEvents: events,
            targetMembers: []
        ))

        _ = try await OllamaCodeCompletionService(
            baseURL: baseURL, transport: transport
        ).complete(request)

        let requests = await transport.recordedRequests()
        let body = try jsonBody(try XCTUnwrap(requests.last))
        let system = try XCTUnwrap(body["system"] as? String)
        XCTAssertTrue(system.contains("compatible_events_total=13"))
        XCTAssertTrue(system.contains("compatible_events_truncated=true"))
        XCTAssertTrue(system.contains("machine.selected [declared_custom]"))
        XCTAssertTrue(system.contains("required_0:string"))
        XCTAssertTrue(system.contains("required_31:string"))
    }

    func testNearbyContextIncludesOnlyWholeEventContractsAndReportsTruncation() async throws {
        let transport = RecordingCodeCompletionTransport(responses: [
            response(["capabilities": ["completion"]]),
            response(["response": "say('ok')"]),
        ])
        let fields = (0..<32).map { "field_\($0):string" }
        let events = (0..<16).map {
            OllamaCodeCompletionAuthoringEvent(
                name: "machine.signal\($0)",
                source: "declared_custom",
                payloadFields: fields
            )
        }
        let request = try makeRequest(nearby: [
            OllamaCodeCompletionNearbyObject(
                reference: "block:overworld:1,64,2",
                kind: "block",
                customEvents: events
            ),
        ])

        _ = try await OllamaCodeCompletionService(
            baseURL: baseURL, transport: transport
        ).complete(request)

        let requests = await transport.recordedRequests()
        let body = try jsonBody(try XCTUnwrap(requests.last))
        let system = try XCTUnwrap(body["system"] as? String)
        let json = try XCTUnwrap(taggedContent(
            "ELY_AUTHORIZED_NEARBY_OBJECTS_DATA", in: system
        ))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(envelope["objects_total"] as? Int, 1)
        XCTAssertEqual(envelope["objects_included"] as? Int, 1)
        XCTAssertEqual(envelope["objects_truncated"] as? Bool, false)
        let objects = try XCTUnwrap(envelope["objects"] as? [[String: Any]])
        let object = try XCTUnwrap(objects.first)
        XCTAssertEqual(object["custom_events_total"] as? Int, 16)
        let included = try XCTUnwrap(object["custom_events_included"] as? Int)
        XCTAssertGreaterThan(included, 0)
        XCTAssertLessThan(included, 16)
        XCTAssertEqual(object["custom_events_truncated"] as? Bool, true)
        let includedEvents = try XCTUnwrap(object["custom_events"] as? [[String: Any]])
        XCTAssertEqual(includedEvents.count, included)
        for event in includedEvents {
            XCTAssertEqual((event["payload_fields"] as? [String])?.count, 32)
        }
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
        authoring: OllamaCodeCompletionAuthoringContext? = nil,
        diagnostics: [String] = [],
        nearby: [OllamaCodeCompletionNearbyObject] = [],
        fillInMiddlePolicy: OllamaCodeCompletionFillInMiddlePolicy = .disabled,
        instruction: String? = nil,
        instructionIntent: OllamaCodeCompletionInstructionIntent = .codeChange
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
            authoringContext: authoring,
            diagnostics: diagnostics,
            authorizedNearbyObjects: nearby,
            fillInMiddlePolicy: fillInMiddlePolicy,
            instruction: instruction,
            instructionIntent: instructionIntent
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

    private func taggedContent(_ tag: String, in text: String) -> String? {
        let start = "<\(tag)>\n"
        let end = "\n</\(tag)>"
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[startRange.upperBound..<endRange.lowerBound])
    }

    private func waitForWarmupCount(
        _ expected: Int,
        transport: CoordinatedPreparationTransport
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await transport.counts().warmups >= expected { return }
            try await clock.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(expected) model warmup request(s)")
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

private actor TestAsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private actor CancellablePreparationTransport: OllamaCodeCompletionTransport {
    private var started = 0
    private var cancelled = 0

    func send(_ request: URLRequest) async throws -> OllamaCodeCompletionHTTPResponse {
        if request.url?.path == "/api/show" {
            let data = try JSONSerialization.data(withJSONObject: [
                "capabilities": ["completion"],
            ])
            return OllamaCodeCompletionHTTPResponse(statusCode: 200, body: data)
        }
        started += 1
        do {
            try await ContinuousClock().sleep(for: .seconds(30))
            let data = try JSONSerialization.data(withJSONObject: [
                "response": "",
                "done": true,
            ])
            return OllamaCodeCompletionHTTPResponse(statusCode: 200, body: data)
        } catch {
            cancelled += 1
            throw error
        }
    }

    func startedCount() -> Int { started }
    func cancelledCount() -> Int { cancelled }
}

private actor CoordinatedPreparationTransport: OllamaCodeCompletionTransport {
    private let blockFirstWarmup: Bool
    private let failFirstWarmup: Bool
    private let failEveryGeneration: Bool
    private var warmupCount = 0
    private var metadataCount = 0
    private var generationCount = 0
    private var requests: [URLRequest] = []
    private var firstWarmupContinuation: CheckedContinuation<Void, Never>?

    init(
        blockFirstWarmup: Bool = false,
        failFirstWarmup: Bool = false,
        failEveryGeneration: Bool = false
    ) {
        self.blockFirstWarmup = blockFirstWarmup
        self.failFirstWarmup = failFirstWarmup
        self.failEveryGeneration = failEveryGeneration
    }

    func send(_ request: URLRequest) async throws -> OllamaCodeCompletionHTTPResponse {
        requests.append(request)
        if request.url?.path == "/api/show" {
            metadataCount += 1
            return Self.response(["capabilities": ["completion"]])
        }
        let body = try Self.jsonBody(request)
        if (body["prompt"] as? String) == "" {
            warmupCount += 1
            if failFirstWarmup, warmupCount == 1 {
                throw URLError(.cannotConnectToHost)
            }
            if blockFirstWarmup, warmupCount == 1 {
                await withCheckedContinuation { continuation in
                    firstWarmupContinuation = continuation
                }
            }
            return Self.response(["response": "", "done": true])
        }
        generationCount += 1
        if failEveryGeneration {
            throw URLError(.timedOut)
        }
        return Self.response(["response": "say('first request works')"])
    }

    func releaseFirstWarmup() {
        firstWarmupContinuation?.resume()
        firstWarmupContinuation = nil
    }

    func counts() -> (warmups: Int, metadata: Int, generations: Int) {
        (warmupCount, metadataCount, generationCount)
    }

    func recordedRequests() -> [URLRequest] { requests }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecordingTransportError.missingResponse
        }
        return body
    }

    private static func response(_ body: [String: Any]) -> OllamaCodeCompletionHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return OllamaCodeCompletionHTTPResponse(statusCode: 200, body: data)
    }
}
