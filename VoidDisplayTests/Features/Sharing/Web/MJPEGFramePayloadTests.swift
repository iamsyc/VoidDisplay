import Foundation
import Testing
@testable import VoidDisplay

struct MJPEGFramePayloadTests {
    @Test func wrapsPacketWithBinaryHeader() {
        let packet = EncodedVideoPacket(
            ptsUs: 42,
            isKeyframe: true,
            width: 1920,
            height: 1080,
            payload: Data([0x10, 0x20, 0x30, 0x40])
        )
        let payload = makeLiveVideoPacket(packet: packet, configRefresh: true)

        #expect(payload.count == 22)
        #expect(payload[0] == 1)
        #expect(payload[1] == 0x3)
        #expect(payload.suffix(4) == Data([0x10, 0x20, 0x30, 0x40]))
    }

    @Test func wrapsTextFramesAsWebSocketFrames() throws {
        let frame = makeWebSocketTextFrame(#"{"type":"config"}"#)
        #expect(frame[0] == 0x81)
        let text = try #require(String(data: frame.dropFirst(2), encoding: .utf8))
        #expect(text.contains(#""type":"config""#))
    }
}
