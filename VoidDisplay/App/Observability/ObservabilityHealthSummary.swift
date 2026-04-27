import Foundation

nonisolated struct ObservabilityHealthSummary: Codable, Equatable, Sendable {
    nonisolated struct SubsystemIssueCount: Codable, Equatable, Sendable {
        let subsystem: ObservabilityDomain
        let count: Int
    }

    let generatedAt: Date
    let recentEventCount: Int
    let recentIssueCount: Int
    let highestSeverity: ObservabilitySeverity?
    let subsystemIssueCounts: [SubsystemIssueCount]
    let recentIssueMessages: [String]
}
