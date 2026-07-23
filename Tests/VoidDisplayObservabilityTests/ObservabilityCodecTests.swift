@testable import VoidDisplayObservability
import Foundation
import Testing

@Suite
struct ObservabilityCodecTests {
    @Test func preservesLegacySecondPrecisionEncoding() throws {
        let event = ObservabilityEvent(
            timestamp: Date(timeIntervalSince1970: 1_000.123),
            severity: .info,
            subsystem: .displayRuntime,
            operation: "Virtual display transaction",
            message: "Virtual display transaction phase changed."
        )

        let encoded = try ObservabilityCodec.encode(event)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        let roundTripped = try ObservabilityCodec.decode(
            ObservabilityEvent.self,
            from: encoded
        )

        #expect(encodedText.contains("1970-01-01T00:16:40Z"))
        #expect(encodedText.contains("1970-01-01T00:16:40.123Z") == false)
        #expect(roundTripped.timestamp == Date(timeIntervalSince1970: 1_000))
    }
}
