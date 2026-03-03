import Foundation
import Testing
@testable import VoidDisplay

struct WebSocketFrameCodecTests {
    @Test func encodesTextFrameHeader() throws {
        let frame = encodeWebSocketTextFrame("hello")
        #expect(frame.count >= 2)
        #expect(frame[0] == 0x81)
        #expect(frame[1] == 0x05)
        let decoder = WebSocketFrameDecoder(
            maxFramePayloadBytes: Int.max,
            maxContinuationPayloadBytes: Int.max
        )
        let output = decoder.ingest(frame)
        #expect(output.errors.isEmpty)
        #expect(decoder.remainder.isEmpty)
        guard case .text(let payload) = try #require(output.frames.first) else {
            Issue.record("Expected text frame.")
            return
        }
        #expect(payload == "hello")
    }

    @Test func decodesMaskedTextFrameFromClient() throws {
        let payload = Array("ping".utf8)
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        var frame = Data([0x81, 0x80 | UInt8(payload.count)])
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }

        let decoder = WebSocketFrameDecoder(
            maxFramePayloadBytes: Int.max,
            maxContinuationPayloadBytes: Int.max
        )
        let output = decoder.ingest(frame)
        #expect(output.errors.isEmpty)
        #expect(decoder.remainder.isEmpty)
        guard case .text(let text) = try #require(output.frames.first) else {
            Issue.record("Expected masked text frame.")
            return
        }
        #expect(text == "ping")
    }

    @Test func incrementallyReassemblesContinuationTextFrames() throws {
        let decoder = WebSocketFrameDecoder(requiresMaskedFrames: true)
        let part1 = makeMaskedFrame(fin: false, opcode: 0x1, payload: Array("hel".utf8))
        let part2 = makeMaskedFrame(fin: true, opcode: 0x0, payload: Array("lo".utf8))

        let first = decoder.ingest(part1)
        #expect(first.frames.isEmpty)
        #expect(first.errors.isEmpty)

        let second = decoder.ingest(part2)
        #expect(second.errors.isEmpty)
        guard case .text(let text) = try #require(second.frames.first) else {
            Issue.record("Expected reassembled text continuation frame.")
            return
        }
        #expect(text == "hello")
    }

    @Test func supportsControlFramesDuringContinuation() throws {
        let decoder = WebSocketFrameDecoder(requiresMaskedFrames: true)
        let initial = makeMaskedFrame(fin: false, opcode: 0x1, payload: Array("a".utf8))
        let ping = makeMaskedFrame(fin: true, opcode: 0x9, payload: [0x01, 0x02])
        let final = makeMaskedFrame(fin: true, opcode: 0x0, payload: Array("b".utf8))

        let first = decoder.ingest(initial)
        #expect(first.errors.isEmpty)
        #expect(first.frames.isEmpty)

        let second = decoder.ingest(ping)
        #expect(second.errors.isEmpty)
        guard case .ping(let payload) = try #require(second.frames.first) else {
            Issue.record("Expected ping frame.")
            return
        }
        #expect(payload == Data([0x01, 0x02]))

        let third = decoder.ingest(final)
        #expect(third.errors.isEmpty)
        guard case .text(let text) = try #require(third.frames.first) else {
            Issue.record("Expected completed text frame.")
            return
        }
        #expect(text == "ab")
    }

    @Test func rejectsUnexpectedContinuationSequence() {
        let decoder = WebSocketFrameDecoder(requiresMaskedFrames: true)
        let continuation = makeMaskedFrame(fin: true, opcode: 0x0, payload: Array("oops".utf8))

        let output = decoder.ingest(continuation)

        #expect(output.frames.isEmpty)
        #expect(output.errors == [.unexpectedContinuation])
    }

    @Test func rejectsUnmaskedFrameWhenMaskingRequired() {
        let decoder = WebSocketFrameDecoder(requiresMaskedFrames: true)
        let output = decoder.ingest(encodeWebSocketTextFrame("unmasked"))

        #expect(output.frames.isEmpty)
        #expect(output.errors == [.invalidMasking])
        #expect(decoder.remainder.isEmpty)
    }

    @Test func rejectsFragmentedControlFrame() {
        let decoder = WebSocketFrameDecoder(requiresMaskedFrames: true)
        let fragmentedPing = makeMaskedFrame(fin: false, opcode: 0x9, payload: [0x01])

        let output = decoder.ingest(fragmentedPing)

        #expect(output.frames.isEmpty)
        #expect(output.errors == [.fragmentedControlFrame])
        #expect(decoder.remainder.isEmpty)
    }

    @Test func rejectsOversizedControlFramePayload() {
        let decoder = WebSocketFrameDecoder(requiresMaskedFrames: true)
        let oversizedPing = makeMaskedFrame(fin: true, opcode: 0x9, payload: Array(repeating: 0x01, count: 126))

        let output = decoder.ingest(oversizedPing)

        #expect(output.frames.isEmpty)
        #expect(output.errors == [.oversizedControlFramePayload])
        #expect(decoder.remainder.isEmpty)
    }

    @Test func rejectsInvalidUTF8TextPayload() {
        let decoder = WebSocketFrameDecoder(requiresMaskedFrames: true)
        let invalidUTF8Text = makeMaskedFrame(fin: true, opcode: 0x1, payload: [0xC3, 0x28])

        let output = decoder.ingest(invalidUTF8Text)

        #expect(output.frames.isEmpty)
        #expect(output.errors == [.invalidUTF8Text])
        #expect(decoder.remainder.isEmpty)
    }

    private func makeMaskedFrame(fin: Bool, opcode: UInt8, payload: [UInt8]) -> Data {
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        var frame = Data([fin ? (0x80 | opcode) : opcode])
        if payload.count <= 125 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            var length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        } else {
            frame.append(0x80 | 127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        }
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }
        return frame
    }
}
