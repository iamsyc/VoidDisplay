import Foundation

nonisolated struct ObservabilityStateSnapshot: Codable, Equatable, Sendable {
    nonisolated struct AppInfo: Codable, Equatable, Sendable {
        let bundleIdentifier: String
        let version: String
        let build: String
        let executablePath: String
    }

    let generatedAt: Date
    let refreshReason: SnapshotRefreshReason
    let app: AppInfo
    let sections: [String: JSONValue]
}
