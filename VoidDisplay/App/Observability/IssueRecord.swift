import Foundation

nonisolated struct IssueRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let deduplicationKey: String
    let subsystem: ObservabilityDomain
    let operation: String
    let message: String
    let firstSeenAt: Date
    let lastSeenAt: Date
    let occurrenceCount: Int
    let latestMetadata: [String: String]
}
