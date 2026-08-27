import Foundation
import XCTest
@testable import Elysium

/// Keeps script-broker requests alive until the service cancels them. This exercises the real
/// `URLSessionDataTask` cancellation/completion path without contacting a listener.
private final class HangingScriptRequestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// Announces an over-limit body before sending any bytes. The broker must reject it from the
/// response metadata instead of letting `URLSession` materialize the body for JSON decoding.
private final class OversizedScriptReplyURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": "\(OllamaAgentService.scriptReplyTransportByteLimit + 1)",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Returns a valid body whose reply crosses the Lua byte cap inside a four-byte scalar. The broker
/// must retain the complete 4,095-byte prefix and omit the scalar rather than count Characters or
/// create replacement text by splitting UTF-8.
private final class MultibyteScriptReplyURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = String(repeating: "a", count: 4_095) + "😀tail"
        let data = try! JSONSerialization.data(withJSONObject: [
            "message": ["role": "assistant", "content": reply],
            "done": true,
        ])
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": "\(data.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class OllamaScriptBrokerTests: XCTestCase {
    func testSessionQualifiedKeysWithSameRuntimeIDCancelIndependently() async {
        let (service, session) = makeService()
        defer {
            service.cancelAllScriptRequests()
            session.invalidateAndCancel()
        }
        let oldKey = OllamaScriptRequestKey(sessionID: UUID(), requestID: 1)
        let newKey = OllamaScriptRequestKey(sessionID: UUID(), requestID: 1)
        let oldCancelled = expectation(description: "old session request cancelled")

        service.generateScriptReply(
            requestKey: oldKey, model: "local-test", prompt: "old", maxChars: 32
        ) { _, error in
            XCTAssertEqual(error, "cancelled")
            oldCancelled.fulfill()
        }
        service.generateScriptReply(
            requestKey: newKey, model: "local-test", prompt: "new", maxChars: 32
        ) { _, _ in }

        XCTAssertEqual(service.scriptBrokerRequestCount, 2)
        XCTAssertTrue(service.hasScriptRequest(oldKey))
        XCTAssertTrue(service.hasScriptRequest(newKey))
        XCTAssertTrue(service.cancelScriptRequest(oldKey))
        XCTAssertFalse(service.hasScriptRequest(oldKey))
        XCTAssertTrue(service.hasScriptRequest(newKey))

        await fulfillment(of: [oldCancelled], timeout: 2)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(
            service.hasScriptRequest(newKey),
            "an old world's deferred cleanup must not erase a new world's equal numeric id"
        )
        XCTAssertEqual(service.scriptBrokerRequestCount, 1)
    }

    func testDisplacedExactKeyLateCleanupCannotEraseReplacement() async {
        let (service, session) = makeService()
        defer {
            service.cancelAllScriptRequests()
            session.invalidateAndCancel()
        }
        let key = OllamaScriptRequestKey(sessionID: UUID(), requestID: 7)
        let displacedCancelled = expectation(description: "displaced request cancelled")

        service.generateScriptReply(
            requestKey: key, model: "local-test", prompt: "first", maxChars: 32
        ) { _, error in
            XCTAssertEqual(error, "cancelled")
            displacedCancelled.fulfill()
        }
        service.generateScriptReply(
            requestKey: key, model: "local-test", prompt: "replacement", maxChars: 32
        ) { _, _ in }

        XCTAssertEqual(service.scriptBrokerRequestCount, 1)
        await fulfillment(of: [displacedCancelled], timeout: 2)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertTrue(
            service.hasScriptRequest(key),
            "cleanup is task-qualified as well as request-qualified"
        )
        XCTAssertTrue(service.cancelScriptRequest(key))
        XCTAssertEqual(service.scriptBrokerRequestCount, 0)
        XCTAssertFalse(service.cancelScriptRequest(key))
    }

    func testScriptReplyRejectsOversizedTransportBodyBeforeDecode() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedScriptReplyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = OllamaAgentService(session: session)
        defer {
            service.cancelAllScriptRequests()
            session.invalidateAndCancel()
        }
        let key = OllamaScriptRequestKey(sessionID: UUID(), requestID: 11)
        let completed = expectation(description: "oversized response refused")

        service.generateScriptReply(
            requestKey: key, model: "local-test", prompt: "bounded", maxChars: 32
        ) { reply, error in
            XCTAssertNil(reply)
            XCTAssertEqual(error, "transport")
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(service.hasScriptRequest(key))
        XCTAssertEqual(service.scriptBrokerRequestCount, 0)
    }

    func testScriptReplyIsUTF8ByteBoundedAtACompleteCharacterBoundary() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MultibyteScriptReplyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = OllamaAgentService(session: session)
        defer {
            service.cancelAllScriptRequests()
            session.invalidateAndCancel()
        }
        let key = OllamaScriptRequestKey(sessionID: UUID(), requestID: 12)
        let completed = expectation(description: "multibyte response clamped")

        service.generateScriptReply(
            requestKey: key, model: "local-test", prompt: "bounded", maxChars: 8_192
        ) { reply, error in
            XCTAssertNil(error)
            XCTAssertEqual(reply?.utf8.count, 4_095)
            XCTAssertEqual(reply, String(repeating: "a", count: 4_095))
            XCTAssertLessThanOrEqual(
                reply?.utf8.count ?? .max, OllamaAgentService.scriptReplyUTF8ByteLimit
            )
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(service.hasScriptRequest(key))
    }

    private func makeService() -> (OllamaAgentService, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingScriptRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (OllamaAgentService(session: session), session)
    }
}
