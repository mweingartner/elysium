import Foundation
import XCTest
@testable import ElysiumCore

final class LANV6FrameCodecTests: XCTestCase {
    private let hostPhase = LANV6ConnectionPhase.authenticated
    private let clientPhase = LANV6ConnectionPhase.connected

    func testKindManifestIsExactContiguousOneThroughTwentyNine() {
        XCTAssertEqual(LANV6MessageKind.allCases.map(\.rawValue),
                       Array(UInt16(1)...UInt16(29)))
        XCTAssertEqual(LANV6MessageKind(rawValue: 1), .clientHello)
        XCTAssertEqual(LANV6MessageKind(rawValue: 5), .playerState)
        XCTAssertEqual(LANV6MessageKind(rawValue: 10), .inputIntent)
        XCTAssertEqual(LANV6MessageKind(rawValue: 26), .rpgIntent)
        XCTAssertEqual(LANV6MessageKind(rawValue: 27), .ownerManifest)
        XCTAssertEqual(LANV6MessageKind(rawValue: 28), .ownerChunk)
        XCTAssertEqual(LANV6MessageKind(rawValue: 29), .clientReady)
        XCTAssertNil(LANV6MessageKind(rawValue: 0))
        XCTAssertNil(LANV6MessageKind(rawValue: 30))
    }

    func testAdmissionPolicyCartesianLookupIsExactAndPublicPolicyDeniesAll() {
        var admitted = Set<LANV6FrameAdmissionKey>()
        for role in LANV6LocalRole.allCases {
            for phase in LANV6ConnectionPhase.allCases {
                for flow in LANV6FrameFlow.allCases {
                    for kind in LANV6MessageKind.allCases {
                        let selected = (role == .host) == (kind.rawValue.isMultiple(of: 2))
                            && (flow == .inbound) == (phase.rawValue.count.isMultiple(of: 2))
                        if selected {
                            admitted.insert(LANV6FrameAdmissionKey(
                                localRole: role, phase: phase, flow: flow, kind: kind
                            ))
                        }
                    }
                }
            }
        }
        let fixture = LANV6FrameAdmissionPolicy(admitted)
        var checked = 0
        for role in LANV6LocalRole.allCases {
            for phase in LANV6ConnectionPhase.allCases {
                for flow in LANV6FrameFlow.allCases {
                    for kind in LANV6MessageKind.allCases {
                        let key = LANV6FrameAdmissionKey(localRole: role, phase: phase,
                                                        flow: flow, kind: kind)
                        XCTAssertEqual(fixture.admits(localRole: role, phase: phase,
                                                      flow: flow, kind: kind),
                                       admitted.contains(key), "\(key)")
                        XCTAssertFalse(LANV6FrameAdmissionPolicy.denyAll.admits(
                            localRole: role, phase: phase, flow: flow, kind: kind
                        ))
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2 * 10 * 2 * 29)
    }

    func testPerKindPayloadCapsAreClosedAndRejectWithoutConsumingSequence() throws {
        for kind in LANV6MessageKind.allCases {
            let expected = kind == .replicationBatch
                ? LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT
                : kind == .ownerChunk
                    ? LAN_V6_OWNER_CHUNK_PAYLOAD_LIMIT
                    : LAN_V6_NON_REPLICATION_PAYLOAD_LIMIT
            XCTAssertEqual(kind.payloadLimit, expected, "\(kind)")
        }

        for kind in [LANV6MessageKind.chat, .replicationBatch, .ownerChunk] {
            let policy = outboundPolicy(role: .host, phase: hostPhase, kinds: [kind])
            var sequences = LANV6FrameSequenceState()
            let accepted = try LANV6FrameCodec.frame(
                kind: kind, rawPayload: Data(repeating: 0xa5, count: kind.payloadLimit),
                localRole: .host, phase: hostPhase, policy: policy, sequences: &sequences
            )
            XCTAssertEqual(accepted.count, LANV6FrameCodec.headerByteCount + kind.payloadLimit)
            XCTAssertEqual(sequences.nextOutbound, 2)

            let before = sequences
            XCTAssertThrowsError(try LANV6FrameCodec.frame(
                kind: kind, rawPayload: Data(repeating: 0, count: kind.payloadLimit + 1),
                localRole: .host, phase: hostPhase, policy: policy, sequences: &sequences
            )) { error in
                XCTAssertEqual(error as? LANV6FrameCodecError,
                               .payloadTooLarge(kind: kind, count: kind.payloadLimit + 1,
                                                limit: kind.payloadLimit))
            }
            XCTAssertEqual(sequences, before)

            let inbound = inboundPolicy(role: .host, phase: hostPhase, kinds: [kind])
            var oversizedHeader = rawFrame(kind: kind, sequence: 1, payload: Data()).prefix(16)
            let declared = UInt32(kind.payloadLimit + 1)
            oversizedHeader[12] = UInt8((declared >> 24) & 0xff)
            oversizedHeader[13] = UInt8((declared >> 16) & 0xff)
            oversizedHeader[14] = UInt8((declared >> 8) & 0xff)
            oversizedHeader[15] = UInt8(declared & 0xff)
            var inboundSequences = LANV6FrameSequenceState()
            var buffer = Data(oversizedHeader)
            XCTAssertThrowsError(try LANV6FrameCodec.decodeFrames(
                from: &buffer, localRole: .host, phase: hostPhase,
                policy: inbound, sequences: &inboundSequences
            )) { error in
                XCTAssertEqual(error as? LANV6FrameCodecError,
                               .payloadTooLarge(kind: kind, count: kind.payloadLimit + 1,
                                                limit: kind.payloadLimit))
            }
            XCTAssertEqual(inboundSequences, LANV6FrameSequenceState(),
                           "declared oversize must reject from the header before payload buffering")
        }
    }

    func testFixedHeaderVectorAndRawPayloadRoundTrip() throws {
        let payload = Data([0xde, 0xad])
        let outbound = outboundPolicy(role: .client, phase: clientPhase, kinds: [.rpgIntent])
        var clientSequences = LANV6FrameSequenceState()
        let encoded = try LANV6FrameCodec.frame(
            kind: .rpgIntent, rawPayload: payload, localRole: .client,
            phase: clientPhase, policy: outbound, sequences: &clientSequences
        )
        XCTAssertEqual(Array(encoded), [
            0x50, 0x42, 0x4c, 0x4e, 0x00, 0x06, 0x00, 0x1a,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02,
            0xde, 0xad,
        ])

        let inbound = inboundPolicy(role: .host, phase: hostPhase, kinds: [.rpgIntent])
        var hostSequences = LANV6FrameSequenceState()
        XCTAssertEqual(try LANV6FrameCodec.decode(
            encoded, localRole: .host, phase: hostPhase,
            policy: inbound, sequences: &hostSequences
        ), LANV6Frame(sequence: 1, kind: .rpgIntent, rawPayload: payload))
        XCTAssertEqual(clientSequences.nextOutbound, 2)
        XCTAssertEqual(clientSequences.nextInbound, 1)
        XCTAssertEqual(hostSequences.nextInbound, 2)
        XCTAssertEqual(hostSequences.nextOutbound, 1)
    }

    func testDirectDecodeRejectsHeaderLengthAndTrailingViolationsExactly() throws {
        let policy = inboundPolicy(role: .host, phase: hostPhase, kinds: [.ping])
        let valid = rawFrame(kind: .ping, sequence: 1, payload: Data([1, 2, 3]))

        for count in 0..<LANV6FrameCodec.headerByteCount {
            var sequences = LANV6FrameSequenceState()
            XCTAssertThrowsError(try LANV6FrameCodec.decode(
                Data(valid.prefix(count)), localRole: .host, phase: hostPhase,
                policy: policy, sequences: &sequences
            )) { XCTAssertEqual($0 as? LANV6FrameCodecError, .truncated) }
            XCTAssertEqual(sequences, LANV6FrameSequenceState())
        }

        var badMagic = valid
        badMagic[0] ^= 0xff
        assertDecodeError(badMagic, policy: policy, .invalidMagic)
        var badVersion = valid
        badVersion[5] = 5
        assertDecodeError(badVersion, policy: policy, .unsupportedVersion(5))
        var badKind = valid
        badKind[6] = 0
        badKind[7] = 30
        assertDecodeError(badKind, policy: policy, .unknownMessageKind(30))

        assertDecodeError(Data(valid.dropLast()), policy: policy, .truncated)
        var trailing = valid
        trailing.append(0xff)
        assertDecodeError(trailing, policy: policy, .trailingBytes(1))
    }

    func testAdmissionIsCallerSuppliedFailClosedAndRunsOnHeaderOnly() throws {
        let denied = LANV6FrameAdmissionPolicy([])
        var inbound = LANV6FrameSequenceState()
        let headerOnly = Data(rawFrame(kind: .clientHello, sequence: 1,
                                       payload: Data([0xff])).prefix(16))
        var deniedBuffer = headerOnly
        XCTAssertThrowsError(try LANV6FrameCodec.decodeFrames(
            from: &deniedBuffer, localRole: .host, phase: .awaitingHello,
            policy: denied, sequences: &inbound
        )) { error in
            XCTAssertEqual(error as? LANV6FrameCodecError, .admissionDenied(
                localRole: .host, phase: .awaitingHello, flow: .inbound,
                kind: .clientHello
            ))
        }
        XCTAssertEqual(inbound, LANV6FrameSequenceState())

        let onlyHello = inboundPolicy(role: .host, phase: .awaitingHello,
                                      kinds: [.clientHello])
        var wrongPhaseBuffer = headerOnly
        XCTAssertThrowsError(try LANV6FrameCodec.decodeFrames(
            from: &wrongPhaseBuffer, localRole: .host, phase: .authenticated,
            policy: onlyHello, sequences: &inbound
        )) { error in
            XCTAssertEqual(error as? LANV6FrameCodecError, .admissionDenied(
                localRole: .host, phase: .authenticated, flow: .inbound,
                kind: .clientHello
            ))
        }

        var outboundSequences = LANV6FrameSequenceState()
        XCTAssertThrowsError(try LANV6FrameCodec.frame(
            kind: .clientHello, rawPayload: Data(), localRole: .host,
            phase: .awaitingHello, policy: onlyHello, sequences: &outboundSequences
        )) { error in
            XCTAssertEqual(error as? LANV6FrameCodecError, .admissionDenied(
                localRole: .host, phase: .awaitingHello, flow: .outbound,
                kind: .clientHello
            ))
        }
        XCTAssertEqual(outboundSequences, LANV6FrameSequenceState())
    }

    func testInboundAndOutboundSequencesAreIndependentStrictAndTerminal() throws {
        let outbound = outboundPolicy(role: .host, phase: hostPhase, kinds: [.ping])
        var state = LANV6FrameSequenceState()
        _ = try LANV6FrameCodec.frame(kind: .ping, rawPayload: Data(), localRole: .host,
                                      phase: hostPhase, policy: outbound, sequences: &state)
        XCTAssertEqual(state.nextOutbound, 2)
        XCTAssertEqual(state.nextInbound, 1)

        let inbound = inboundPolicy(role: .host, phase: hostPhase, kinds: [.ping])
        assertDecodeError(rawFrame(kind: .ping, sequence: 0, payload: Data()),
                          policy: inbound,
                          .invalidSequence(direction: .inbound, expected: 1, actual: 0),
                          sequences: &state)
        assertDecodeError(rawFrame(kind: .ping, sequence: 2, payload: Data()),
                          policy: inbound,
                          .invalidSequence(direction: .inbound, expected: 1, actual: 2),
                          sequences: &state)
        _ = try LANV6FrameCodec.decode(rawFrame(kind: .ping, sequence: 1, payload: Data()),
                                       localRole: .host, phase: hostPhase,
                                       policy: inbound, sequences: &state)
        XCTAssertEqual(state.nextInbound, 2)
        assertDecodeError(rawFrame(kind: .ping, sequence: 1, payload: Data()),
                          policy: inbound,
                          .invalidSequence(direction: .inbound, expected: 2, actual: 1),
                          sequences: &state)

        var terminal = LANV6FrameSequenceState(nextInbound: .max, nextOutbound: .max)
        _ = try LANV6FrameCodec.frame(kind: .ping, rawPayload: Data(), localRole: .host,
                                      phase: hostPhase, policy: outbound, sequences: &terminal)
        XCTAssertTrue(terminal.outboundExhausted)
        XCTAssertThrowsError(try LANV6FrameCodec.frame(
            kind: .ping, rawPayload: Data(), localRole: .host,
            phase: hostPhase, policy: outbound, sequences: &terminal
        )) { XCTAssertEqual($0 as? LANV6FrameCodecError, .sequenceExhausted(.outbound)) }
        _ = try LANV6FrameCodec.decode(rawFrame(kind: .ping, sequence: .max,
                                                payload: Data()),
                                       localRole: .host, phase: hostPhase,
                                       policy: inbound, sequences: &terminal)
        XCTAssertTrue(terminal.inboundExhausted)
        assertDecodeError(rawFrame(kind: .ping, sequence: .max, payload: Data()),
                          policy: inbound, .sequenceExhausted(.inbound),
                          sequences: &terminal)
    }

    func testStreamingDecoderDrainsCompleteFramesAndRetainsOneBoundedPartial() throws {
        let policy = inboundPolicy(role: .client, phase: clientPhase,
                                   kinds: [.ping, .pong, .keepalive])
        let first = rawFrame(kind: .ping, sequence: 1, payload: Data([1]))
        let second = rawFrame(kind: .pong, sequence: 2, payload: Data([2, 3]))
        let third = rawFrame(kind: .keepalive, sequence: 3, payload: Data([4, 5, 6]))
        let cut = third.count - 1
        var buffer = first + second + third.prefix(cut)
        var sequences = LANV6FrameSequenceState()

        XCTAssertEqual(try LANV6FrameCodec.decodeFrames(
            from: &buffer, localRole: .client, phase: clientPhase,
            policy: policy, sequences: &sequences
        ), [
            LANV6Frame(sequence: 1, kind: .ping, rawPayload: Data([1])),
            LANV6Frame(sequence: 2, kind: .pong, rawPayload: Data([2, 3])),
        ])
        XCTAssertEqual(buffer, third.prefix(cut))
        XCTAssertEqual(sequences.nextInbound, 3)
        buffer.append(third.suffix(1))
        XCTAssertEqual(try LANV6FrameCodec.decodeFrames(
            from: &buffer, localRole: .client, phase: clientPhase,
            policy: policy, sequences: &sequences
        ), [LANV6Frame(sequence: 3, kind: .keepalive,
                       rawPayload: Data([4, 5, 6]))])
        XCTAssertTrue(buffer.isEmpty)

        var oversizedBuffer = Data(repeating: 0,
                                   count: LANV6FrameCodec.maximumBufferedBytes + 1)
        let oversizedOriginal = oversizedBuffer
        let sequencesBeforeMalformed = sequences
        XCTAssertThrowsError(try LANV6FrameCodec.decodeFrames(
            from: &oversizedBuffer, localRole: .client, phase: clientPhase,
            policy: policy, sequences: &sequences
        )) { error in
            XCTAssertEqual(error as? LANV6FrameCodecError,
                           .streamBufferTooLarge(LANV6FrameCodec.maximumBufferedBytes + 1))
        }
        XCTAssertEqual(oversizedBuffer, oversizedOriginal)
        XCTAssertEqual(sequences, sequencesBeforeMalformed)
    }

    func testIncrementalFeedDrainsBeforeAdmittingMoreAndSupportsOneByteFeeds() throws {
        let policy = inboundPolicy(role: .host, phase: hostPhase,
                                   kinds: [.replicationBatch, .ping])
        let maximum = rawFrame(
            kind: .replicationBatch, sequence: 1,
            payload: Data(repeating: 0x5a, count: LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT)
        )
        var buffer = Data()
        var sequences = LANV6FrameSequenceState()
        var coalesced = maximum
        coalesced.append(0x50)
        let result = try LANV6FrameCodec.feed(
            coalesced, into: &buffer, localRole: .host, phase: hostPhase,
            policy: policy, sequences: &sequences
        )
        XCTAssertEqual(result.frames, [LANV6Frame(
            sequence: 1, kind: .replicationBatch,
            rawPayload: Data(repeating: 0x5a, count: LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT)
        )])
        XCTAssertEqual(result.consumedInputByteCount, coalesced.count)
        XCTAssertEqual(result.unconsumedInputByteCount, 0)
        XCTAssertEqual(result.framedByteCount, maximum.count)
        XCTAssertEqual(result.payloadByteCount, LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT)
        XCTAssertEqual(buffer, Data([0x50]),
                       "the maximum frame must drain before one next-header byte is retained")
        XCTAssertEqual(sequences.nextInbound, 2)

        let rest = rawFrame(kind: .ping, sequence: 2,
                            payload: Data((0..<64).map(UInt8.init)))
        var oneByteOutput: [LANV6Frame] = []
        for (index, byte) in rest.dropFirst().enumerated() {
            let emitted = try LANV6FrameCodec.feed(
                Data([byte]), into: &buffer, localRole: .host, phase: hostPhase,
                policy: policy, sequences: &sequences
            )
            if index < rest.count - 2 { XCTAssertTrue(emitted.frames.isEmpty) }
            oneByteOutput.append(contentsOf: emitted.frames)
        }
        XCTAssertEqual(oneByteOutput, [LANV6Frame(
            sequence: 2, kind: .ping,
            rawPayload: Data((0..<64).map(UInt8.init))
        )])
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(sequences.nextInbound, 3)
    }

    func testCoalescedFeedCommitsAllValidFramesAtomically() throws {
        let policy = inboundPolicy(role: .host, phase: hostPhase, kinds: [.ping, .pong])
        let first = rawFrame(kind: .ping, sequence: 1, payload: Data([1]))
        let second = rawFrame(kind: .pong, sequence: 2, payload: Data([2]))
        var buffer = Data()
        var sequences = LANV6FrameSequenceState()

        XCTAssertEqual(try LANV6FrameCodec.feed(
            first + second, into: &buffer, localRole: .host, phase: hostPhase,
            policy: policy, sequences: &sequences
        ).frames, [
            LANV6Frame(sequence: 1, kind: .ping, rawPayload: Data([1])),
            LANV6Frame(sequence: 2, kind: .pong, rawPayload: Data([2])),
        ])
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(sequences.nextInbound, 3)
    }

    func testFeedFrameCapLeavesThirtyThirdFrameAsUntouchedCallerSuffix() throws {
        let policy = inboundPolicy(role: .host, phase: hostPhase, kinds: [.keepalive])
        var input = Data()
        for sequence in 1...33 {
            input.append(rawFrame(kind: .keepalive, sequence: UInt32(sequence),
                                  payload: Data()))
        }
        var buffer = Data()
        var sequences = LANV6FrameSequenceState()
        let first = try LANV6FrameCodec.feed(
            input, into: &buffer, localRole: .host, phase: hostPhase,
            policy: policy, sequences: &sequences
        )
        XCTAssertEqual(first.frames.count, LAN_V6_MAX_FEED_FRAMES)
        XCTAssertEqual(first.frames.map(\.sequence), (1...32).map(UInt32.init))
        XCTAssertEqual(first.consumedInputByteCount, 32 * LANV6FrameCodec.headerByteCount)
        XCTAssertEqual(first.unconsumedInputByteCount, LANV6FrameCodec.headerByteCount)
        XCTAssertEqual(first.framedByteCount, 32 * LANV6FrameCodec.headerByteCount)
        XCTAssertEqual(first.payloadByteCount, 0)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(sequences.nextInbound, 33)

        let suffix = Data(input.dropFirst(first.consumedInputByteCount))
        let second = try LANV6FrameCodec.feed(
            suffix, into: &buffer, localRole: .host, phase: hostPhase,
            policy: policy, sequences: &sequences
        )
        XCTAssertEqual(second.frames.map(\.sequence), [33])
        XCTAssertEqual(second.consumedInputByteCount, suffix.count)
        XCTAssertEqual(second.unconsumedInputByteCount, 0)
        XCTAssertEqual(sequences.nextInbound, 34)
    }

    func testFeedFramedByteCapLeavesCapPlusOneByteUntouched() throws {
        let policy = inboundPolicy(role: .host, phase: hostPhase,
                                   kinds: [.replicationBatch, .ping])
        let payload = Data(repeating: 0xc3, count: LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT)
        let firstFrame = rawFrame(kind: .replicationBatch, sequence: 1, payload: payload)
        let secondFrame = rawFrame(kind: .replicationBatch, sequence: 2, payload: payload)
        var input = firstFrame + secondFrame
        input.append(0x50)
        var buffer = Data()
        var sequences = LANV6FrameSequenceState()

        let result = try LANV6FrameCodec.feed(
            input, into: &buffer, localRole: .host, phase: hostPhase,
            policy: policy, sequences: &sequences
        )
        XCTAssertEqual(result.frames.map(\.sequence), [1, 2])
        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.framedByteCount, LAN_V6_MAX_FEED_FRAMED_BYTES)
        XCTAssertEqual(result.payloadByteCount, 2 * LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT)
        XCTAssertEqual(result.consumedInputByteCount, LAN_V6_MAX_FEED_FRAMED_BYTES)
        XCTAssertEqual(result.unconsumedInputByteCount, 1)
        XCTAssertEqual(Data(input.dropFirst(result.consumedInputByteCount)), Data([0x50]))
        XCTAssertTrue(buffer.isEmpty,
                      "bytes beyond the bounded prefix remain caller-owned, not retained")
        XCTAssertEqual(sequences.nextInbound, 3)
    }

    func testFeedLeavesEntireNextHeaderUntouchedWhenBudgetHasOneThroughFifteenBytes() throws {
        let policy = inboundPolicy(role: .host, phase: hostPhase,
                                   kinds: [.replicationBatch, .ping])
        let maximumPayload = Data(repeating: 0x81,
                                  count: LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT)
        let firstFrame = rawFrame(kind: .replicationBatch, sequence: 1,
                                  payload: maximumPayload)

        for remainingBudget in 1..<LANV6FrameCodec.headerByteCount {
            let secondPayloadCount = LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT - remainingBudget
            let secondFrame = rawFrame(
                kind: .replicationBatch, sequence: 2,
                payload: Data(repeating: 0x42, count: secondPayloadCount)
            )
            let prefix = firstFrame + secondFrame
            XCTAssertEqual(prefix.count,
                           LAN_V6_MAX_FEED_FRAMED_BYTES - remainingBudget)

            var malformed = rawFrame(kind: .ping, sequence: 3, payload: Data())
            malformed[0] = 0
            let fixtures: [(String, Data, LANV6FrameCodecError)] = [
                ("malformed", malformed, .invalidMagic),
                ("denied", rawFrame(kind: .chat, sequence: 3, payload: Data()),
                 .admissionDenied(localRole: .host, phase: hostPhase,
                                  flow: .inbound, kind: .chat)),
                ("duplicate", rawFrame(kind: .ping, sequence: 2, payload: Data()),
                 .invalidSequence(direction: .inbound, expected: 3, actual: 2)),
                ("future", rawFrame(kind: .ping, sequence: 4, payload: Data()),
                 .invalidSequence(direction: .inbound, expected: 3, actual: 4)),
            ]

            for fixture in fixtures {
                let input = prefix + fixture.1
                var buffer = Data()
                var sequences = LANV6FrameSequenceState()
                let accepted = try LANV6FrameCodec.feed(
                    input, into: &buffer, localRole: .host, phase: hostPhase,
                    policy: policy, sequences: &sequences
                )
                XCTAssertEqual(accepted.frames.map(\.sequence), [1, 2], fixture.0)
                XCTAssertEqual(accepted.framedByteCount, prefix.count, fixture.0)
                XCTAssertEqual(accepted.payloadByteCount,
                               LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT + secondPayloadCount,
                               fixture.0)
                XCTAssertEqual(accepted.consumedInputByteCount, prefix.count,
                               "budget \(remainingBudget), \(fixture.0)")
                XCTAssertEqual(accepted.unconsumedInputByteCount, fixture.1.count,
                               "budget \(remainingBudget), \(fixture.0)")
                XCTAssertEqual(Data(input.dropFirst(accepted.consumedInputByteCount)),
                               fixture.1, fixture.0)
                XCTAssertTrue(buffer.isEmpty, fixture.0)
                XCTAssertEqual(sequences.nextInbound, 3, fixture.0)

                let committedState = sequences
                XCTAssertThrowsError(try LANV6FrameCodec.feed(
                    fixture.1, into: &buffer, localRole: .host, phase: hostPhase,
                    policy: policy, sequences: &sequences
                )) { error in
                    XCTAssertEqual(error as? LANV6FrameCodecError, fixture.2,
                                   "budget \(remainingBudget), \(fixture.0)")
                }
                XCTAssertTrue(buffer.isEmpty, fixture.0)
                XCTAssertEqual(sequences, committedState,
                               "suffix failure cannot roll back the committed prefix")
            }
        }
    }

    func testHugeZeroPayloadCoalescingResumesDeterministicallyInBoundedPrefixes() throws {
        let policy = inboundPolicy(role: .host, phase: hostPhase, kinds: [.keepalive])
        var input = Data()
        for sequence in 1...10_000 {
            input.append(rawFrame(kind: .keepalive, sequence: UInt32(sequence),
                                  payload: Data()))
        }

        func drain() throws -> ([UInt32], Int, LANV6FrameSequenceState) {
            var offset = 0
            var decoded: [UInt32] = []
            var calls = 0
            var buffer = Data()
            var sequences = LANV6FrameSequenceState()
            while offset < input.count {
                let suffix = Data(input.dropFirst(offset))
                let result = try LANV6FrameCodec.feed(
                    suffix, into: &buffer, localRole: .host, phase: hostPhase,
                    policy: policy, sequences: &sequences
                )
                XCTAssertGreaterThan(result.consumedInputByteCount, 0)
                XCTAssertLessThanOrEqual(result.frames.count, LAN_V6_MAX_FEED_FRAMES)
                XCTAssertLessThanOrEqual(result.framedByteCount,
                                         LAN_V6_MAX_FEED_FRAMED_BYTES)
                XCTAssertEqual(result.payloadByteCount, 0)
                XCTAssertEqual(result.consumedInputByteCount
                               + result.unconsumedInputByteCount, suffix.count)
                decoded.append(contentsOf: result.frames.map(\.sequence))
                offset += result.consumedInputByteCount
                calls += 1
            }
            XCTAssertTrue(buffer.isEmpty)
            return (decoded, calls, sequences)
        }

        let first = try drain()
        let second = try drain()
        XCTAssertEqual(first.0, (1...10_000).map(UInt32.init))
        XCTAssertEqual(second.0, first.0)
        XCTAssertEqual(first.1, 313)
        XCTAssertEqual(second.1, first.1)
        XCTAssertEqual(first.2.nextInbound, 10_001)
        XCTAssertEqual(second.2, first.2)
    }

    func testOversizedRetainedBufferRejectsBeforeParsingOrConsumingInput() {
        let policy = inboundPolicy(role: .host, phase: hostPhase, kinds: [.ping])
        var buffer = Data(repeating: 0, count: LANV6FrameCodec.maximumBufferedBytes + 1)
        let original = buffer
        let input = rawFrame(kind: .ping, sequence: 1, payload: Data([1]))
        var sequences = LANV6FrameSequenceState()
        XCTAssertThrowsError(try LANV6FrameCodec.feed(
            input, into: &buffer, localRole: .host, phase: hostPhase,
            policy: policy, sequences: &sequences
        )) { error in
            XCTAssertEqual(error as? LANV6FrameCodecError,
                           .streamBufferTooLarge(LANV6FrameCodec.maximumBufferedBytes + 1))
        }
        XCTAssertEqual(buffer, original)
        XCTAssertEqual(sequences, LANV6FrameSequenceState())
    }

    func testCoalescedFeedRollsBackBufferSequenceAndOutputForEveryLaterError() {
        let first = rawFrame(kind: .ping, sequence: 1, payload: Data([1]))
        let allowed = inboundPolicy(role: .host, phase: hostPhase,
                                    kinds: [.ping, .pong, .ownerChunk])
        let pingOnly = inboundPolicy(role: .host, phase: hostPhase, kinds: [.ping])

        var malformed = rawFrame(kind: .pong, sequence: 2, payload: Data([2]))
        malformed[0] = 0
        var oversized = Data(rawFrame(kind: .ownerChunk, sequence: 2,
                                      payload: Data()).prefix(16))
        writeUInt32(UInt32(LAN_V6_OWNER_CHUNK_PAYLOAD_LIMIT + 1), at: 12,
                    in: &oversized)
        let fixtures: [(String, Data, LANV6FrameAdmissionPolicy, LANV6FrameCodecError)] = [
            ("malformed", malformed, allowed, .invalidMagic),
            ("denied", rawFrame(kind: .pong, sequence: 2, payload: Data([2])),
             pingOnly, .admissionDenied(localRole: .host, phase: hostPhase,
                                        flow: .inbound, kind: .pong)),
            ("duplicate", rawFrame(kind: .pong, sequence: 1, payload: Data([2])),
             allowed, .invalidSequence(direction: .inbound, expected: 2, actual: 1)),
            ("future", rawFrame(kind: .pong, sequence: 3, payload: Data([2])),
             allowed, .invalidSequence(direction: .inbound, expected: 2, actual: 3)),
            ("oversize", oversized, allowed,
             .payloadTooLarge(kind: .ownerChunk,
                              count: LAN_V6_OWNER_CHUNK_PAYLOAD_LIMIT + 1,
                              limit: LAN_V6_OWNER_CHUNK_PAYLOAD_LIMIT)),
        ]

        let sentinel = [LANV6Frame(sequence: 99, kind: .keepalive,
                                   rawPayload: Data([99]))]
        for fixture in fixtures {
            var buffer = Data()
            var sequences = LANV6FrameSequenceState()
            var output = sentinel
            do {
                output = try LANV6FrameCodec.feed(
                    first + fixture.1, into: &buffer, localRole: .host,
                    phase: hostPhase, policy: fixture.2, sequences: &sequences
                ).frames
                XCTFail("\(fixture.0) unexpectedly succeeded")
            } catch {
                XCTAssertEqual(error as? LANV6FrameCodecError, fixture.3, fixture.0)
            }
            XCTAssertEqual(output, sentinel, "\(fixture.0) cannot publish prefix output")
            XCTAssertTrue(buffer.isEmpty, "\(fixture.0) must restore the caller buffer")
            XCTAssertEqual(sequences, LANV6FrameSequenceState(),
                           "\(fixture.0) must restore both sequence directions")
        }
    }

    func testCoalescedDecodeFromExistingBufferIsTransactionalOnLaterError() {
        let policy = inboundPolicy(role: .host, phase: hostPhase, kinds: [.ping, .pong])
        let first = rawFrame(kind: .ping, sequence: 1, payload: Data([1]))
        let invalid = rawFrame(kind: .pong, sequence: 3, payload: Data([2]))
        var buffer = first + invalid
        let original = buffer
        var sequences = LANV6FrameSequenceState()

        XCTAssertThrowsError(try LANV6FrameCodec.decodeFrames(
            from: &buffer, localRole: .host, phase: hostPhase,
            policy: policy, sequences: &sequences
        )) { error in
            XCTAssertEqual(error as? LANV6FrameCodecError,
                           .invalidSequence(direction: .inbound, expected: 2, actual: 3))
        }
        XCTAssertEqual(buffer, original)
        XCTAssertEqual(sequences, LANV6FrameSequenceState())

    }

    func testSeededTenThousandRawPayloadRoundTrips() throws {
        let kinds = LANV6MessageKind.allCases
        let outbound = outboundPolicy(role: .client, phase: clientPhase, kinds: kinds)
        let inbound = inboundPolicy(role: .host, phase: hostPhase, kinds: kinds)
        var sender = LANV6FrameSequenceState()
        var receiver = LANV6FrameSequenceState()
        var rng = LCG(state: 0x6c61_6e76_365f_7769)

        for index in 0..<10_000 {
            let kind = kinds[Int(rng.next() % UInt64(kinds.count))]
            let count = Int(rng.next() % 257)
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            for _ in 0..<count { bytes.append(UInt8(truncatingIfNeeded: rng.next())) }
            let payload = Data(bytes)
            let encoded = try LANV6FrameCodec.frame(
                kind: kind, rawPayload: payload, localRole: .client,
                phase: clientPhase, policy: outbound, sequences: &sender
            )
            let decoded = try LANV6FrameCodec.decode(
                encoded, localRole: .host, phase: hostPhase,
                policy: inbound, sequences: &receiver
            )
            XCTAssertEqual(decoded.sequence, UInt32(index + 1))
            XCTAssertEqual(decoded.kind, kind)
            XCTAssertEqual(decoded.rawPayload, payload)
        }
        XCTAssertEqual(sender.nextOutbound, 10_001)
        XCTAssertEqual(receiver.nextInbound, 10_001)
    }

    func testSeededTenThousandMalformedInputsNeverTrapOrClamp() {
        let policy = inboundPolicy(role: .host, phase: hostPhase,
                                   kinds: LANV6MessageKind.allCases)
        var rng = LCG(state: 0x6675_7a7a_5f76_365f)
        var accepted = 0
        for _ in 0..<10_000 {
            let count = Int(rng.next() % 129)
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            for _ in 0..<count { bytes.append(UInt8(truncatingIfNeeded: rng.next())) }
            var sequences = LANV6FrameSequenceState()
            do {
                let frame = try LANV6FrameCodec.decode(
                    Data(bytes), localRole: .host, phase: hostPhase,
                    policy: policy, sequences: &sequences
                )
                accepted += 1
                XCTAssertEqual(frame.sequence, 1)
                XCTAssertLessThanOrEqual(frame.rawPayload.count, frame.kind.payloadLimit)
            } catch {
                XCTAssertEqual(sequences, LANV6FrameSequenceState(),
                               "rejected bytes cannot advance or normalize sequence state")
            }
        }
        XCTAssertEqual(accepted, 0,
                       "seeded arbitrary bytes must not accidentally form a canonical frame")
    }

    private func inboundPolicy(role: LANV6LocalRole, phase: LANV6ConnectionPhase,
                               kinds: [LANV6MessageKind]) -> LANV6FrameAdmissionPolicy {
        LANV6FrameAdmissionPolicy(kinds.map {
            LANV6FrameAdmissionKey(localRole: role, phase: phase,
                                   flow: .inbound, kind: $0)
        })
    }

    private func outboundPolicy(role: LANV6LocalRole, phase: LANV6ConnectionPhase,
                                kinds: [LANV6MessageKind]) -> LANV6FrameAdmissionPolicy {
        LANV6FrameAdmissionPolicy(kinds.map {
            LANV6FrameAdmissionKey(localRole: role, phase: phase,
                                   flow: .outbound, kind: $0)
        })
    }

    private func rawFrame(kind: LANV6MessageKind, sequence: UInt32,
                          payload: Data) -> Data {
        var data = Data([0x50, 0x42, 0x4c, 0x4e, 0x00, 0x06,
                         UInt8((kind.rawValue >> 8) & 0xff), UInt8(kind.rawValue & 0xff),
                         UInt8((sequence >> 24) & 0xff), UInt8((sequence >> 16) & 0xff),
                         UInt8((sequence >> 8) & 0xff), UInt8(sequence & 0xff),
                         UInt8((UInt32(payload.count) >> 24) & 0xff),
                         UInt8((UInt32(payload.count) >> 16) & 0xff),
                         UInt8((UInt32(payload.count) >> 8) & 0xff),
                         UInt8(UInt32(payload.count) & 0xff)])
        data.append(payload)
        return data
    }

    private func writeUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }

    private func assertDecodeError(_ data: Data, policy: LANV6FrameAdmissionPolicy,
                                   _ expected: LANV6FrameCodecError,
                                   file: StaticString = #filePath, line: UInt = #line) {
        var sequences = LANV6FrameSequenceState()
        assertDecodeError(data, policy: policy, expected, sequences: &sequences,
                          file: file, line: line)
        XCTAssertEqual(sequences, LANV6FrameSequenceState(), file: file, line: line)
    }

    private func assertDecodeError(_ data: Data, policy: LANV6FrameAdmissionPolicy,
                                   _ expected: LANV6FrameCodecError,
                                   sequences: inout LANV6FrameSequenceState,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let before = sequences
        XCTAssertThrowsError(try LANV6FrameCodec.decode(
            data, localRole: .host, phase: hostPhase,
            policy: policy, sequences: &sequences
        ), file: file, line: line) { error in
            XCTAssertEqual(error as? LANV6FrameCodecError, expected,
                           file: file, line: line)
        }
        XCTAssertEqual(sequences, before, file: file, line: line)
    }
}

private struct LCG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
