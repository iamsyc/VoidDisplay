import VoidDisplayFoundation
import Foundation
package nonisolated struct ObservabilityEvent: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package let timestamp: Date
    package let severity: ObservabilitySeverity
    package let subsystem: ObservabilityDomain
    package let operation: String
    package let message: String
    package let metadata: [String: String]
    package let correlationID: String?
    package let deduplicationKey: String?

    package init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: ObservabilitySeverity,
        subsystem: ObservabilityDomain,
        operation: String,
        message: String,
        metadata: [String: String] = [:],
        correlationID: String? = nil,
        deduplicationKey: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.subsystem = subsystem
        self.operation = operation
        self.message = message
        self.metadata = metadata
        self.correlationID = correlationID
        self.deduplicationKey = deduplicationKey
    }
}
