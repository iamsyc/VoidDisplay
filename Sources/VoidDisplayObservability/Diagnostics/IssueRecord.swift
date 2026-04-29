import VoidDisplayFoundation
import Foundation
package nonisolated struct IssueRecord: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package let deduplicationKey: String
    package let subsystem: ObservabilityDomain
    package let operation: String
    package let message: String
    package let firstSeenAt: Date
    package let lastSeenAt: Date
    package let occurrenceCount: Int
    package let latestMetadata: [String: String]
}
