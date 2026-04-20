import Foundation
import Testing
@testable import VoidDisplay

@Suite(.serialized)
struct FeedbackBundleExporterTests {
    @Test func exportBundleProducesExpectedArchiveLayout() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: tempURL.appendingPathComponent("exports", isDirectory: true),
            appSupportRootURL: tempURL,
            virtualDisplayConfigsURL: tempURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: ObservabilitySanitizer(homePath: "/Users/tester")
        )

        let result = try exporter.exportBundle(
            draft: FeedbackDraft(happened: "Black screen", reproductionSteps: "Open app", expectedResult: "Shows content"),
            consent: FeedbackConsent(),
            state: makeStateSnapshot(),
            health: makeHealthSummary(),
            events: [makeEvent()],
            issues: [makeIssue()],
            transportCapability: FeedbackTransportCapability.localExportOnly
        )

        let entries = try archiveEntries(at: result.bundleURL)
        let manifest = try decodeArchiveEntry(
            SupportBundleManifest.self,
            relativePathSuffix: "/manifest.json",
            archiveURL: result.bundleURL
        )

        #expect(entries.contains(where: { $0.hasSuffix("/manifest.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/feedback.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/state/current-state.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/state/health-summary.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/events/recent-events.ndjson") }))
        #expect(entries.contains(where: { $0.hasSuffix("/issues/recent-issues.json") }))
        #expect(entries.contains(where: { $0.contains("/attachments/") }) == false)
        #expect(manifest.eventCount == 1)
        #expect(manifest.issueCount == 1)
        #expect(manifest.transportCapability == FeedbackTransportCapability.localExportOnly)
        #expect(manifest.attachments.isEmpty)
    }

    @Test func exportBundleIncludesWhitelistedConfigAttachmentsWhenEnabled() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle-configs")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let virtualDisplaysURL = tempURL.appendingPathComponent("virtual-displays.json")
        let shareMappingsURL = tempURL.appendingPathComponent("display-share-id-mappings.json")
        try "{\"path\":\"/Users/tester/Desktop\"}".write(to: virtualDisplaysURL, atomically: true, encoding: .utf8)
        try "{\"host\":\"192.168.0.4\"}".write(to: shareMappingsURL, atomically: true, encoding: .utf8)

        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: tempURL.appendingPathComponent("exports", isDirectory: true),
            appSupportRootURL: tempURL,
            virtualDisplayConfigsURL: virtualDisplaysURL,
            displayShareMappingsURL: shareMappingsURL,
            sanitizer: ObservabilitySanitizer(homePath: "/Users/tester")
        )

        let result = try exporter.exportBundle(
            draft: FeedbackDraft(),
            consent: FeedbackConsent(includeRelatedConfigSnapshots: true),
            state: makeStateSnapshot(),
            health: makeHealthSummary(),
            events: [],
            issues: [],
            transportCapability: FeedbackTransportCapability.localExportOnly
        )

        let entries = try archiveEntries(at: result.bundleURL)

        #expect(entries.contains(where: { $0.hasSuffix("/attachments/config/virtual-displays.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/attachments/config/display-share-id-mappings.json") }))
    }

    @Test func latestExportedBundleURLReturnsMostRecentArchive() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle-latest")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        let olderURL = exportsURL.appendingPathComponent("support-bundle-20260419-120000.zip")
        let newerURL = exportsURL.appendingPathComponent("support-bundle-20260419-130000.zip")
        try Data("older".utf8).write(to: olderURL)
        try Data("newer".utf8).write(to: newerURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: olderURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 20)],
            ofItemAtPath: newerURL.path
        )

        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: exportsURL,
            appSupportRootURL: tempURL,
            virtualDisplayConfigsURL: tempURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: ObservabilitySanitizer()
        )

        #expect(exporter.latestExportedBundleURL() == newerURL)
    }
}

private func makeStateSnapshot() -> ObservabilityStateSnapshot {
    ObservabilityStateSnapshot(
        generatedAt: Date(timeIntervalSince1970: 10),
        refreshReason: .startup,
        app: .init(
            bundleIdentifier: "com.developerchen.voiddisplay",
            version: "1.0.0",
            build: "1",
            executablePath: "~/Applications/VoidDisplay.app"
        ),
        sections: ["capture": .object(["sessions": .array([])])]
    )
}

private func makeHealthSummary() -> ObservabilityHealthSummary {
    ObservabilityHealthSummary(
        generatedAt: Date(timeIntervalSince1970: 10),
        recentEventCount: 1,
        recentIssueCount: 1,
        highestSeverity: .error,
        subsystemIssueCounts: [
            .init(subsystem: .capture, count: 1)
        ],
        recentIssueMessages: ["Something failed."]
    )
}

private func makeEvent() -> ObservabilityEvent {
    ObservabilityEvent(
        timestamp: Date(timeIntervalSince1970: 10),
        severity: .error,
        subsystem: .capture,
        operation: "Load displays",
        message: "Display load failed.",
        deduplicationKey: "capture.load"
    )
}

private func makeIssue() -> IssueRecord {
    IssueRecord(
        id: UUID(),
        deduplicationKey: "capture.load",
        subsystem: .capture,
        operation: "Load displays",
        message: "Display load failed.",
        firstSeenAt: Date(timeIntervalSince1970: 10),
        lastSeenAt: Date(timeIntervalSince1970: 10),
        occurrenceCount: 1,
        latestMetadata: [:]
    )
}

private func decodeArchiveEntry<T: Decodable>(
    _ type: T.Type,
    relativePathSuffix: String,
    archiveURL: URL
) throws -> T {
    let extractionURL = try makeTemporaryDirectory(prefix: "support-bundle-extract")
    defer { try? FileManager.default.removeItem(at: extractionURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", archiveURL.path, extractionURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let bundleRoot = try FileManager.default.contentsOfDirectory(
        at: extractionURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).first
    let entryURL = bundleRoot?.appendingPathComponent(String(relativePathSuffix.dropFirst()))
    let data = try Data(contentsOf: try #require(entryURL))
    return try ObservabilityCodec.decode(type, from: data)
}

private func archiveEntries(at url: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", url.path]
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)
    return output.split(whereSeparator: \.isNewline).map(String.init)
}
