import VoidDisplayFoundation
import Foundation
package struct LocalExportTransport: FeedbackTransport {
    package let capability: FeedbackTransportCapability = .localExportOnly

    package init() {}

    package func submit(bundleURL: URL, manifest: SupportBundleManifest) async throws {
        _ = bundleURL
        _ = manifest
    }
}
