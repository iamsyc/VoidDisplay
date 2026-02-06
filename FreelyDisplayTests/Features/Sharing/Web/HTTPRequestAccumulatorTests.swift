import Foundation
import Testing
@testable import FreelyDisplay

struct HTTPRequestAccumulatorTests {

    @Test func assemblesSplitHeaderAcrossChunks() throws {
        var accumulator = HTTPRequestAccumulator(maxBytes: 1024)

        let part1 = try #require("GET /stream HTTP/1.1\r\nHost: 127.0.0.1".data(using: .utf8))
        let result1 = accumulator.ingest(chunk: part1, isComplete: false)
        if case .waiting = result1 {
            // expected
        } else {
            Issue.record("Expected waiting after first chunk.")
        }

        let part2 = try #require(":8081\r\n\r\n".data(using: .utf8))
        let result2 = accumulator.ingest(chunk: part2, isComplete: false)
        guard case .complete(let data?) = result2 else {
            Issue.record("Expected completed data after second chunk.")
            return
        }

        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text == "GET /stream HTTP/1.1\r\nHost: 127.0.0.1:8081\r\n\r\n")
    }

    @Test func returnsCompleteWhenConnectionEndsWithoutTerminator() throws {
        var accumulator = HTTPRequestAccumulator(maxBytes: 1024)
        let payload = try #require("GET / HTTP/1.1\r\nHost: localhost".data(using: .utf8))

        let result = accumulator.ingest(chunk: payload, isComplete: true)
        guard case .complete(let data?) = result else {
            Issue.record("Expected complete with partial request when socket closes.")
            return
        }
        #expect(data == payload)
    }

    @Test func returnsNilWhenConnectionEndsWithNoData() {
        var accumulator = HTTPRequestAccumulator(maxBytes: 1024)
        let result = accumulator.ingest(chunk: nil, isComplete: true)
        guard case .complete(let data) = result else {
            Issue.record("Expected complete result for closed empty connection.")
            return
        }
        #expect(data == nil)
    }

    @Test func rejectsOversizedHeader() throws {
        var accumulator = HTTPRequestAccumulator(maxBytes: 8)
        let payload = try #require("GET / HTTP/1.1\r\n".data(using: .utf8))
        let result = accumulator.ingest(chunk: payload, isComplete: false)

        guard case .invalidTooLarge = result else {
            Issue.record("Expected invalidTooLarge for oversized request header.")
            return
        }
    }
}
