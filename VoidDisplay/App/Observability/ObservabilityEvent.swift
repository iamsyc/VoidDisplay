import Foundation

nonisolated struct ObservabilityEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let severity: ObservabilitySeverity
    let subsystem: ObservabilityDomain
    let operation: String
    let message: String
    let metadata: [String: String]
    let correlationID: String?
    let deduplicationKey: String?

    init(
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
