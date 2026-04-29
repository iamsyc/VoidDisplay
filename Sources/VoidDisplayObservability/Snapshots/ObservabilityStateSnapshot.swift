import VoidDisplayFoundation
import Foundation
package nonisolated struct ObservabilityStateSnapshot: Codable, Equatable, Sendable {
    package nonisolated struct AppInfo: Codable, Equatable, Sendable {
        let bundleIdentifier: String
        let version: String
        let build: String
        let executablePath: String
    }

    package let generatedAt: Date
    package let refreshReason: SnapshotRefreshReason
    package let app: AppInfo
    package let sections: [String: JSONValue]
}
