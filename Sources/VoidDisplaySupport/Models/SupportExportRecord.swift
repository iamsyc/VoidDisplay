import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package nonisolated struct SupportExportRecord: Codable, Equatable, Identifiable, Sendable {
    package let id: UUID
    package let exportedAt: Date
    package let issueType: SupportIssueType
    package let bundleFileName: String
    package let sanitizedBundlePath: String
    package let draftPreview: String
    package var summaryCopiedAt: Date?
    package var revealedAt: Date?

    package init(
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

    package var displayInfo: SupportBundleDisplayInfo {
        SupportBundleDisplayInfo(
            displayName: bundleFileName,
            displayTimestamp: exportedAt.formatted(date: .abbreviated, time: .shortened),
            sanitizedFullPath: sanitizedBundlePath
        )
    }

    package var historyCopyText: String {
        let typeLine = String(localized: issueType.presentation.summaryPrefixKey)
        let bundleLine = "\(String(localized: "Support Package")): \(bundleFileName)"
        guard draftPreview.isEmpty == false else {
            return [typeLine, bundleLine].joined(separator: "\n")
        }
        return [typeLine, draftPreview, bundleLine].joined(separator: "\n")
    }

    package var resolvedBundleURL: URL {
        URL(fileURLWithPath: NSString(string: sanitizedBundlePath).expandingTildeInPath)
    }

    package func sanitizingPreview(with sanitizer: ObservabilitySanitizer) -> Self {
        let sanitizedPreview = sanitizer.sanitize(text: draftPreview) ?? ""
        guard sanitizedPreview != draftPreview else { return self }
        return Self(
            id: id,
            exportedAt: exportedAt,
            issueType: issueType,
            bundleFileName: bundleFileName,
            sanitizedBundlePath: sanitizedBundlePath,
            draftPreview: sanitizedPreview,
            summaryCopiedAt: summaryCopiedAt,
            revealedAt: revealedAt
        )
    }
}
