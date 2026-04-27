import Foundation

nonisolated struct FeedbackBundleExportResult: Sendable {
    let bundleURL: URL
    let manifest: SupportBundleManifest
}
