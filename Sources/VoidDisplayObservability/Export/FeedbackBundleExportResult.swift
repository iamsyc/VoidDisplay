import VoidDisplayFoundation
import Foundation
package nonisolated struct FeedbackBundleExportResult: Sendable {
    package let bundleURL: URL
    package let manifest: SupportBundleManifest
}
