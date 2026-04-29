import VoidDisplayFoundation
import Foundation
package nonisolated struct ObservabilityContext: Codable, Equatable, Sendable {
    package var severity: ObservabilitySeverity
    package var metadata: [String: String]
    package var correlationID: String?
    package var deduplicationKey: String?
    package var message: String?

    package init(
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
