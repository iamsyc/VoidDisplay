import Foundation

nonisolated struct SupportExportRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let exportedAt: Date
    let issueType: SupportIssueType
    let bundleFileName: String
    let sanitizedBundlePath: String
    let draftPreview: String
    var summaryCopiedAt: Date?
    var revealedAt: Date?

    init(
        id: UUID = UUID(),
        exportedAt: Date,
        issueType: SupportIssueType,
        bundleFileName: String,
        sanitizedBundlePath: String,
        draftPreview: String,
        summaryCopiedAt: Date? = nil,
        revealedAt: Date? = nil
    ) {
        self.id = id
        self.exportedAt = exportedAt
        self.issueType = issueType
        self.bundleFileName = bundleFileName
        self.sanitizedBundlePath = sanitizedBundlePath
        self.draftPreview = draftPreview
        self.summaryCopiedAt = summaryCopiedAt
        self.revealedAt = revealedAt
    }

    var displayInfo: SupportBundleDisplayInfo {
        SupportBundleDisplayInfo(
            displayName: bundleFileName,
            displayTimestamp: exportedAt.formatted(date: .abbreviated, time: .shortened),
            sanitizedFullPath: sanitizedBundlePath
        )
    }

    var historyCopyText: String {
        let typeLine = String(localized: issueType.presentation.summaryPrefixKey)
        let bundleLine = "\(String(localized: "Support Package")): \(bundleFileName)"
        guard draftPreview.isEmpty == false else {
            return [typeLine, bundleLine].joined(separator: "\n")
        }
        return [typeLine, draftPreview, bundleLine].joined(separator: "\n")
    }

    var resolvedBundleURL: URL {
        URL(fileURLWithPath: NSString(string: sanitizedBundlePath).expandingTildeInPath)
    }
}
