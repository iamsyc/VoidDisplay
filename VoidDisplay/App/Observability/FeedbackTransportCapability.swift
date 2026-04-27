import Foundation

nonisolated enum FeedbackTransportCapability: String, Codable, Equatable, Sendable {
    case localExportOnly = "local_export_only"
}
