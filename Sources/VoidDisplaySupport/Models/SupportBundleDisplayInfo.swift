import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package nonisolated struct SupportBundleDisplayInfo: Equatable, Sendable {
    package let displayName: String
    package let displayTimestamp: String?
    package let sanitizedFullPath: String

    package var summaryText: String {
        guard let displayTimestamp, !displayTimestamp.isEmpty else {
            return displayName
        }
        return "\(displayName) · \(displayTimestamp)"
    }

    package init?(url: URL, sanitizer: ObservabilitySanitizer = ObservabilitySanitizer()) {
        let displayName = url.lastPathComponent
        guard !displayName.isEmpty else { return nil }

        self.displayName = displayName
        sanitizedFullPath = sanitizer.sanitize(fileURL: url)

        let resourceValues = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .creationDateKey
        ])
        let timestamp = resourceValues?.contentModificationDate ?? resourceValues?.creationDate
        displayTimestamp = timestamp?.formatted(date: .abbreviated, time: .shortened)
    }

    package init(
        displayName: String,
        displayTimestamp: String?,
        sanitizedFullPath: String
    ) {
        self.displayName = displayName
        self.displayTimestamp = displayTimestamp
        self.sanitizedFullPath = sanitizedFullPath
    }
}
