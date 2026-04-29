import VoidDisplayFoundation
import Foundation
package nonisolated struct ObservabilityHealthSummary: Codable, Equatable, Sendable {
    package nonisolated struct SubsystemIssueCount: Codable, Equatable, Sendable {
        let subsystem: ObservabilityDomain
        let count: Int
    }

    package let generatedAt: Date
    package let recentEventCount: Int
    package let recentIssueCount: Int
    package let highestSeverity: ObservabilitySeverity?
    package let subsystemIssueCounts: [SubsystemIssueCount]
    package let recentIssueMessages: [String]
}
