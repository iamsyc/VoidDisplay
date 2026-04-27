import Foundation

nonisolated struct SupportBundleDisplayInfo: Equatable, Sendable {
    let displayName: String
    let displayTimestamp: String?
    let sanitizedFullPath: String

    var summaryText: String {
        guard let displayTimestamp, !displayTimestamp.isEmpty else {
            return displayName
        }
        return "\(displayName) · \(displayTimestamp)"
    }

    init?(url: URL, sanitizer: ObservabilitySanitizer = ObservabilitySanitizer()) {
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

    init(
        displayName: String,
        displayTimestamp: String?,
        sanitizedFullPath: String
    ) {
        self.displayName = displayName
        self.displayTimestamp = displayTimestamp
        self.sanitizedFullPath = sanitizedFullPath
    }
}
