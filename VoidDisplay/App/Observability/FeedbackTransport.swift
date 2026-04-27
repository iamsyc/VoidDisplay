import Foundation

protocol FeedbackTransport: Sendable {
    var capability: FeedbackTransportCapability { get }
    func submit(bundleURL: URL, manifest: SupportBundleManifest) async throws
}
