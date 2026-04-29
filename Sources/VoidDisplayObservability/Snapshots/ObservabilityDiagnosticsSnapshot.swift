import VoidDisplayFoundation
import Foundation
package nonisolated struct ObservabilityDiagnosticsSnapshot: Sendable {
    package let state: ObservabilityStateSnapshot
    package let health: ObservabilityHealthSummary
    package let issues: [IssueRecord]
    package let events: [ObservabilityEvent]
    package let lastExportedBundleDisplayPath: String?
}
