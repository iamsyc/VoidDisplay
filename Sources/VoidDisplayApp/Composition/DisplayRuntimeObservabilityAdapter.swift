import Foundation
import VoidDisplayObservability
import VoidDisplayRuntime

@MainActor
package final class DisplayRuntimeObservabilityAdapter: DisplayRuntimeObservabilityRecording {
    private weak var observability: ObservabilityCenter?

    package init(observability: ObservabilityCenter) {
        self.observability = observability
    }

    package func record(_ event: DisplayRuntimeObservabilityEvent) async {
        await observability?.record(
            ObservabilityEvent(
                severity: ObservabilitySeverity(event.severity),
                subsystem: ObservabilityDomain(event.domain),
                operation: event.operation,
                message: event.message,
                metadata: event.metadata,
                deduplicationKey: event.deduplicationKey
            )
        )
    }

    package func refreshSnapshot(reason: DisplayRuntimeObservabilityRefreshReason) async {
        await observability?.refreshSnapshot(reason: SnapshotRefreshReason(reason))
    }
}

private extension ObservabilitySeverity {
    init(_ severity: DisplayRuntimeObservabilitySeverity) {
        switch severity {
        case .info:
            self = .info
        case .warning:
            self = .warning
        }
    }
}

private extension ObservabilityDomain {
    init(_ domain: DisplayRuntimeObservabilityDomain) {
        switch domain {
        case .screenCatalog:
            self = .screenCatalog
        case .displayRuntime:
            self = .displayRuntime
        }
    }
}

private extension SnapshotRefreshReason {
    init(_ reason: DisplayRuntimeObservabilityRefreshReason) {
        switch reason {
        case .screenCatalogStateChanged:
            self = .screenCatalogStateChanged
        case .displayRuntimeTransactionChanged:
            self = .displayRuntimeTransactionChanged
        }
    }
}
