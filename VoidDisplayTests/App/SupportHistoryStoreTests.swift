import Foundation
import Testing
@testable import VoidDisplay

@Suite(.serialized)
struct SupportHistoryStoreTests {
    @Test func appendTrimsToTenRecordsAndDropsMissingBundles() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-history-store")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        let historyStore = SupportHistoryStore(
            historyFileURL: tempURL.appendingPathComponent("support-history.json"),
            exportsDirectoryURL: exportsURL
        )

        for index in 0..<11 {
            let bundleURL = exportsURL.appendingPathComponent("support-bundle-\(index).zip")
            try Data("bundle".utf8).write(to: bundleURL)
            _ = historyStore.appendRecord(
                SupportExportRecord(
                    exportedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    issueType: .other,
                    bundleFileName: bundleURL.lastPathComponent,
                    sanitizedBundlePath: ObservabilitySanitizer().sanitize(fileURL: bundleURL),
                    draftPreview: ""
                )
            )
        }

        let newestURL = exportsURL.appendingPathComponent("support-bundle-10.zip")
        try FileManager.default.removeItem(at: newestURL)

        let records = historyStore.loadRecords()
        #expect(records.count == 9)
        #expect(records.contains { $0.bundleFileName == "support-bundle-10.zip" } == false)
        #expect(records.first?.bundleFileName == "support-bundle-9.zip")
    }

    @Test func loadRecordsSynthesizesFallbackWhenHistoryFileIsMissing() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-history-fallback")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        let bundleURL = exportsURL.appendingPathComponent("support-bundle-20260420-140000.zip")
        try Data("bundle".utf8).write(to: bundleURL)

        let historyStore = SupportHistoryStore(
            historyFileURL: tempURL.appendingPathComponent("support-history.json"),
            exportsDirectoryURL: exportsURL
        )

        let records = historyStore.loadRecords()
        #expect(records.count == 1)
        #expect(records.first?.issueType == .other)
        #expect(records.first?.bundleFileName == bundleURL.lastPathComponent)
        #expect(records.first?.draftPreview.isEmpty == true)
    }
}
