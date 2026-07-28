import Foundation
import XCTest
@testable import ElysiumDebugProtocol

final class DebugFrameCodecTests: XCTestCase {
    private let key = Data((0..<32).map(UInt8.init))

    func testFragmentedAndCoalescedFramesRoundTrip() throws {
        var encoder = try DebugAuthenticatedFrameEncoder(
            sessionKey: key,
            direction: .clientToServer
        )
        let first = try encoder.encode(kind: .request, payload: Data("one".utf8))
        let second = try encoder.encode(kind: .request, payload: Data("two".utf8))

        var bytewiseDecoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: key,
            direction: .clientToServer
        )
        var bytewiseFrames: [DebugDecodedFrame] = []
        for byte in first + second {
            bytewiseFrames.append(contentsOf: try bytewiseDecoder.append(Data([byte])))
        }
        try bytewiseDecoder.finish()
        XCTAssertEqual(bytewiseFrames.map(\.sequence), [1, 2])
        XCTAssertEqual(bytewiseFrames.map(\.payload), [Data("one".utf8), Data("two".utf8)])

        var coalescedDecoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: key,
            direction: .clientToServer
        )
        XCTAssertEqual(try coalescedDecoder.append(first + second), bytewiseFrames)
        try coalescedDecoder.finish()
    }

    func testPayloadLimitIsEnforcedBeforeAllocation() throws {
        let limits = try DebugFrameLimits(maximumPayloadBytes: 8)
        var encoder = try DebugAuthenticatedFrameEncoder(
            sessionKey: key,
            direction: .clientToServer,
            limits: limits
        )
        XCTAssertThrowsError(try encoder.encode(kind: .request, payload: Data(repeating: 1, count: 9))) {
            XCTAssertEqual($0 as? DebugProtocolError, .payloadTooLarge(actual: 9, maximum: 8))
        }

        var validEncoder = try DebugAuthenticatedFrameEncoder(
            sessionKey: key,
            direction: .clientToServer,
            limits: limits
        )
        var maliciousHeader = Data(try validEncoder.encode(kind: .request, payload: Data()).prefix(20))
        maliciousHeader.replaceSubrange(16..<20, with: [0, 0, 0, 9])
        var decoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: key,
            direction: .clientToServer,
            limits: limits
        )
        XCTAssertThrowsError(try decoder.append(maliciousHeader)) {
            XCTAssertEqual($0 as? DebugProtocolError, .payloadTooLarge(actual: 9, maximum: 8))
        }
        XCTAssertTrue(decoder.isFailed)
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }

    func testTamperingWrongDirectionAndWrongKeyFailAuthentication() throws {
        var encoder = try DebugAuthenticatedFrameEncoder(
            sessionKey: key,
            direction: .clientToServer
        )
        let valid = try encoder.encode(kind: .request, payload: Data("authenticated".utf8))

        var tampered = valid
        tampered[20] ^= 0x01
        var tamperedDecoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: key,
            direction: .clientToServer
        )
        XCTAssertThrowsError(try tamperedDecoder.append(tampered)) {
            XCTAssertEqual($0 as? DebugProtocolError, .authenticationFailed)
        }
        XCTAssertThrowsError(try tamperedDecoder.append(valid)) {
            XCTAssertEqual($0 as? DebugProtocolError, .decoderFailed)
        }

        var reflectedDecoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: key,
            direction: .serverToClient
        )
        XCTAssertThrowsError(try reflectedDecoder.append(valid)) {
            XCTAssertEqual($0 as? DebugProtocolError, .authenticationFailed)
        }

        var wrongKeyDecoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: Data(repeating: 0xff, count: 32),
            direction: .clientToServer
        )
        XCTAssertThrowsError(try wrongKeyDecoder.append(valid)) {
            XCTAssertEqual($0 as? DebugProtocolError, .authenticationFailed)
        }
    }

    func testReplaySkipAndTruncationFailClosed() throws {
        var encoder = try DebugAuthenticatedFrameEncoder(
            sessionKey: key,
            direction: .clientToServer
        )
        let first = try encoder.encode(kind: .request, payload: Data("first".utf8))
        let second = try encoder.encode(kind: .request, payload: Data("second".utf8))

        var replayDecoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: key,
            direction: .clientToServer
        )
        XCTAssertEqual(try replayDecoder.append(first).single?.sequence, 1)
        XCTAssertThrowsError(try replayDecoder.append(first)) {
            XCTAssertEqual($0 as? DebugProtocolError, .unexpectedSequence(expected: 2, actual: 1))
        }

        var skippedDecoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: key,
            direction: .clientToServer
        )
        XCTAssertThrowsError(try skippedDecoder.append(second)) {
            XCTAssertEqual($0 as? DebugProtocolError, .unexpectedSequence(expected: 1, actual: 2))
        }

        var truncatedDecoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: key,
            direction: .clientToServer
        )
        XCTAssertTrue(try truncatedDecoder.append(Data(first.dropLast())).isEmpty)
        XCTAssertThrowsError(try truncatedDecoder.finish()) {
            XCTAssertEqual(
                $0 as? DebugProtocolError,
                .truncatedFrame(pendingBytes: first.count - 1)
            )
        }
    }

    func testInvalidHeaderAndShortKeyAreRejected() throws {
        XCTAssertThrowsError(try DebugAuthenticatedFrameEncoder(
            sessionKey: Data(repeating: 1, count: 31),
            direction: .clientToServer
        )) {
            XCTAssertEqual(
                $0 as? DebugProtocolError,
                .invalidSessionKeyLength(actual: 31, minimum: 32)
            )
        }

        var encoder = try DebugAuthenticatedFrameEncoder(
            sessionKey: key,
            direction: .clientToServer
        )
        var invalidMagic = try encoder.encode(kind: .request, payload: Data())
        invalidMagic[0] ^= 0xff
        var decoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: key,
            direction: .clientToServer
        )
        XCTAssertThrowsError(try decoder.append(invalidMagic))
    }

    func testSequenceValidatorRejectsReplayAndExhaustion() throws {
        var validator = try DebugSequenceValidator(expectedSequence: 7)
        XCTAssertThrowsError(try validator.accept(6)) {
            XCTAssertEqual($0 as? DebugProtocolError, .unexpectedSequence(expected: 7, actual: 6))
        }
        try validator.accept(7)
        XCTAssertEqual(validator.expectedSequence, 8)

        var finalValidator = try DebugSequenceValidator(expectedSequence: UInt64.max - 1)
        try finalValidator.accept(UInt64.max - 1)
        XCTAssertThrowsError(try finalValidator.accept(UInt64.max)) {
            XCTAssertEqual($0 as? DebugProtocolError, .sequenceExhausted)
        }
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}
