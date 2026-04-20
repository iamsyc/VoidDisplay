import Foundation

nonisolated struct SupportBundleManifest: Codable, Equatable, Sendable {
    nonisolated struct AppInfo: Codable, Equatable, Sendable {
        let bundleIdentifier: String
        let version: String
        let build: String
    }

    let reportID: UUID
    let generatedAt: Date
    let transportCapability: FeedbackTransportCapability
    let app: AppInfo
    let eventCount: Int
    let issueCount: Int
    let attachments: [String]
    let consent: FeedbackConsent
}
