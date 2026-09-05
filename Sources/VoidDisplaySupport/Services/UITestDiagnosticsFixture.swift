import Foundation
import VoidDisplayFoundation
import VoidDisplayObservability
import VoidDisplayRuntime

enum UITestDiagnosticsFixture {
    private static let transactionID = "00000000-0000-0000-0000-00000000D1A6"

    static func events(for scenario: UITestScenario) -> [ObservabilityEvent] {
        switch scenario {
        case .diagnosticsRecoveredWarning:
            [recoveredWarningEvent]
        case .diagnosticsTransactionTimeline:
            [recoveredWarningEvent] + transactionTimelineEvents
        case .baseline,
             .displayCatalogLoading,
             .displayCatalogLoadingWithMissingManagedDisplay,
             .permissionDenied,
             .settingsFeedback,
             .previewActive,
             .previewRecovery,
             .previewWindowPayload,
             .menuBarQuickActions:
            []
        }
    }

    private static var recoveredWarningEvent: ObservabilityEvent {
        ObservabilityEvent(
            severity: .warning,
            subsystem: .capture,
            operation: "Screen capture permission check",
            message: "Screen capture permission unavailable."
        )
    }

    private static var transactionTimelineEvents: [ObservabilityEvent] {
        let startedAt = Date(timeIntervalSince1970: 4_000_000_000)
        return [
            transactionEvent(
                id: UUID(),
                timestamp: startedAt,
            phase: .queued
            ),
            transactionEvent(
                id: UUID(),
                timestamp: startedAt.addingTimeInterval(0.25),
            phase: .completed
            )
        ]
    }

    private static func transactionEvent(
        id: UUID,
        timestamp: Date,
        phase: DisplayRuntimeTransactionPhase
    ) -> ObservabilityEvent {
        guard let fixtureTransactionID = UUID(uuidString: transactionID) else {
            preconditionFailure("Invalid diagnostics transaction fixture ID.")
        }
        let runtimeTransactionID = DisplayRuntimeTransactionID(
            rawValue: fixtureTransactionID
        )
        let runtimeEvent = DisplayRuntimeTransactionObservability.event(
            phase: phase,
            transactionID: runtimeTransactionID
        )
        return ObservabilityEvent(
            id: id,
            timestamp: timestamp,
            severity: .info,
            subsystem: .displayRuntime,
            operation: runtimeEvent.operation,
            message: runtimeEvent.message,
            metadata: runtimeEvent.metadata
        )
    }
}
