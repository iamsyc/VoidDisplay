@testable import VoidDisplaySupport
@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

@Suite(.serialized)
struct SupportHistoryStoreTests {
    @Test func appendTrimsToTenRecordsAndDropsMissingBundles() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-history-store")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        let historyStore = SupportHistoryStore(
            historyFileURL: tempURL.appendingPathComponent("support-history.json")
        )

        for index in 0..<11 {
            let bundleURL = exportsURL.appendingPathComponent("support-bundle-\(index).zip")
            try Data("bundle".utf8).write(to: bundleURL)
            _ = try historyStore.appendRecord(
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

    @Test func appendRecordPropagatesHistoryWriteFailure() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-history-write-failure")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        let bundleURL = exportsURL.appendingPathComponent("support-bundle-write-failure.zip")
        try Data("bundle".utf8).write(to: bundleURL)

        let historyFileURL = tempURL.appendingPathComponent("support-history.json")
        try FileManager.default.createDirectory(at: historyFileURL, withIntermediateDirectories: false)
        let historyStore = SupportHistoryStore(
            historyFileURL: historyFileURL
        )

        #expect(throws: Error.self) {
            _ = try historyStore.appendRecord(
                SupportExportRecord(
                    exportedAt: Date(timeIntervalSince1970: 1),
                    issueType: .other,
                    bundleFileName: bundleURL.lastPathComponent,
                    sanitizedBundlePath: ObservabilitySanitizer().sanitize(fileURL: bundleURL),
                    draftPreview: ""
                )
            )
        }
    }

    @Test func loadRecordsMigratesSensitiveDraftPreviewOutOfHistoryFile() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-history-redaction")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        let bundleURL = exportsURL.appendingPathComponent("support-bundle-redaction.zip")
        try Data("bundle".utf8).write(to: bundleURL)
        let historyFileURL = tempURL.appendingPathComponent("support-history.json")
        let accessToken = String(repeating: "e", count: 64)
        let historyStore = SupportHistoryStore(
            historyFileURL: historyFileURL,
            sanitizer: ObservabilitySanitizer(homePath: "/Users/tester")
        )
        let rawRecords = [
            SupportExportRecord(
                exportedAt: Date(timeIntervalSince1970: 1),
                issueType: .cannotShare,
                bundleFileName: bundleURL.lastPathComponent,
                sanitizedBundlePath: bundleURL.path,
                draftPreview: "Share URL http://192.168.1.4/display/\(accessToken)"
            )
        ]
        try ObservabilityCodec.encode(rawRecords).write(to: historyFileURL, options: [.atomic])

        let records = historyStore.loadRecords()
        let persistedHistory = try String(contentsOf: historyFileURL, encoding: .utf8)

        #expect(records.first?.draftPreview.contains(accessToken) == false)
        #expect(records.first?.draftPreview.contains("192.168.1.4") == false)
        #expect(persistedHistory.contains(accessToken) == false)
        #expect(persistedHistory.contains("192.168.1.4") == false)
    }
}
