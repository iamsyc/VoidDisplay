import Foundation
import Testing
@testable import VoidDisplay

struct WebSocketFrameCodecTests {
    @Test func encodesTextFrameHeader() throws {
        let frame = encodeWebSocketTextFrame("hello")
        #expect(frame.count >= 2)
        #expect(frame[0] == 0x81)
        #expect(frame[1] == 0x05)
        let decoded = decodeWebSocketFrames(from: frame)
        #expect(decoded.remainder.isEmpty)
        guard case .text(let payload) = try #require(decoded.frames.first) else {
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

        let decoded = decodeWebSocketFrames(from: frame)
        #expect(decoded.remainder.isEmpty)
        guard case .text(let text) = try #require(decoded.frames.first) else {
            Issue.record("Expected masked text frame.")
            return
        }
        #expect(text == "ping")
    }
}
