import Foundation
import Testing
@testable import VoidDisplay

struct MJPEGFramePayloadTests {
    @Test func wrapsFrameWithBoundaryAndHeaders() throws {
        let frame = Data([0x10, 0x20, 0x30, 0x40])
        let boundary = "unit-test-boundary"
        let payload = makeMJPEGFramePayload(frame: frame, boundary: boundary)

        let expectedPrefix = "--unit-test-boundary\r\n"
            + "Content-Type: image/jpeg\r\n"
            + "Content-Length: 4\r\n\r\n"
        let prefixData = try #require(expectedPrefix.data(using: .utf8))
        let trailerData = Data("\r\n".utf8)

        #expect(payload.starts(with: prefixData))
        #expect(payload.suffix(trailerData.count) == trailerData)

        let frameStart = prefixData.count
        let frameEnd = payload.count - trailerData.count
        let extractedFrame = payload.subdata(in: frameStart..<frameEnd)
        #expect(extractedFrame == frame)
    }

    @Test func writesZeroLengthForEmptyFrame() throws {
        let payload = makeMJPEGFramePayload(frame: Data(), boundary: "empty")
        let text = try #require(String(data: payload, encoding: .utf8))

        #expect(text.contains("Content-Length: 0\r\n\r\n"))
        #expect(text.hasSuffix("\r\n"))
    }
}
