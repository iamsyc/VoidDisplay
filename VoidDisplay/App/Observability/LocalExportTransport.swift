import Foundation

struct LocalExportTransport: FeedbackTransport {
    let capability: FeedbackTransportCapability = .localExportOnly

    func submit(bundleURL: URL, manifest: SupportBundleManifest) async throws {
        _ = bundleURL
        _ = manifest
    }
}
