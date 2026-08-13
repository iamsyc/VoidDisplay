@testable import VoidDisplayFoundation
@testable import VoidDisplaySupport
@testable import VoidDisplayRuntime
import Testing

struct UITestDiagnosticsFixtureTests {
    @Test
    func transactionTimelineProvidesOrderedTerminalEvidence() throws {
        let events = UITestDiagnosticsFixture.events(for: .diagnosticsTransactionTimeline)

        #expect(events.count == 2)
        #expect(events.map {
            $0.metadata[DisplayRuntimeTransactionObservability.phaseMetadataKey]
        } == ["queued", "completed"])
        #expect(events.allSatisfy {
            $0.metadata[DisplayRuntimeTransactionObservability.transactionIDMetadataKey]
                == "00000000-0000-0000-0000-00000000D1A6"
        })
        let first = try #require(events.first)
        let last = try #require(events.last)
        #expect(first.timestamp < last.timestamp)
    }

    @Test
    func recoveredWarningFixtureRemainsIsolated() throws {
        let events = UITestDiagnosticsFixture.events(for: .diagnosticsRecoveredWarning)
        let event = try #require(events.only)

        #expect(
            event.metadata[DisplayRuntimeTransactionObservability.transactionIDMetadataKey] == nil
        )
        #expect(event.severity == .warning)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
