import Foundation

nonisolated struct ObservabilityContext: Codable, Equatable, Sendable {
    var severity: ObservabilitySeverity
    var metadata: [String: String]
    var correlationID: String?
    var deduplicationKey: String?
    var message: String?

    init(
        severity: ObservabilitySeverity = .error,
        metadata: [String: String] = [:],
        correlationID: String? = nil,
        deduplicationKey: String? = nil,
        message: String? = nil
    ) {
        self.severity = severity
        self.metadata = metadata
        self.correlationID = correlationID
        self.deduplicationKey = deduplicationKey
        self.message = message
    }
}
