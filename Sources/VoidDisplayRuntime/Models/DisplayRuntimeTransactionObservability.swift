import Foundation

package nonisolated enum DisplayRuntimeTransactionObservability {
    package static let operation = "Virtual display transaction"
    package static let message = "Virtual display transaction phase changed."
    package static let transactionIDMetadataKey = "transactionID"
    package static let phaseMetadataKey = "phase"

    package static func event(
        phase: DisplayRuntimeTransactionPhase,
        transactionID: DisplayRuntimeTransactionID
    ) -> DisplayRuntimeObservabilityEvent {
        DisplayRuntimeObservabilityEvent(
            domain: .displayRuntime,
            severity: severity(for: phase),
            operation: operation,
            message: message,
            metadata: [
                transactionIDMetadataKey: transactionID.rawValue.uuidString,
                phaseMetadataKey: phase.rawValue
            ],
            deduplicationKey: nil
        )
    }

    private static func severity(
        for phase: DisplayRuntimeTransactionPhase
    ) -> DisplayRuntimeObservabilitySeverity {
        switch phase {
        case .failed, .cancelled:
            .warning
        case .queued,
             .preparing,
             .persistingConfig,
             .compensatingPersistence,
             .quiescingSessions,
             .executingVirtualDisplayCommand,
             .waitingForTopology,
             .restoringSessions,
             .completed:
            .info
        }
    }
}
