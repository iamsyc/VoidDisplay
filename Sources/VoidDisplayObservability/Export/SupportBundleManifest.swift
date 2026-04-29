import VoidDisplayFoundation
import Foundation
package nonisolated struct SupportBundleManifest: Codable, Equatable, Sendable {
    package nonisolated struct AppInfo: Codable, Equatable, Sendable {
        let bundleIdentifier: String
        let version: String
        let build: String
    }

    package let reportID: UUID
    package let generatedAt: Date
    package let transportCapability: FeedbackTransportCapability
    package let app: AppInfo
    package let eventCount: Int
    package let issueCount: Int
    package let attachments: [String]
    package let consent: FeedbackConsent
}
