import Foundation

nonisolated struct ObservabilityDiagnosticsSnapshot: Sendable {
    let state: ObservabilityStateSnapshot
    let health: ObservabilityHealthSummary
    let issues: [IssueRecord]
    let events: [ObservabilityEvent]
    let lastExportedBundleDisplayPath: String?
}
