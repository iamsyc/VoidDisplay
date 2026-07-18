@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

@Suite(.serialized)
struct FeedbackBundleExporterTests {
    @Test func exportBundleProducesExpectedArchiveLayout() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var commandInvocationCount = 0
        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: tempURL.appendingPathComponent("exports", isDirectory: true),
            virtualDisplayConfigsURL: tempURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: ObservabilitySanitizer(homePath: "/Users/tester"),
            commandRunner: { _, _, _ in
                commandInvocationCount += 1
                return "private log from /Users/tester at http://192.168.0.4:8080/display"
            }
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
        let state = try decodeArchiveEntry(
            ObservabilityStateSnapshot.self,
            relativePathSuffix: "/state/current-state.json",
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
        #expect(manifest.consent == FeedbackConsent())
        #expect(manifest.consent.hasEnhancedCollection == false)
        #expect(manifest.consent.includeUnifiedLogSummary == false)
        #expect(manifest.consent.includeCrashReportExcerpt == false)
        #expect(manifest.consent.includeRelatedConfigSnapshots == false)
        #expect(state.sections["runtime"] != nil)
        #expect(state.sections["runtime"]?.objectValue?["schemaVersion"]?.intValue == 3)
        #expect(commandInvocationCount == 0)
    }

    @Test func exportBundleSanitizesConfigAttachmentsWhenEnhancedDiagnosticsEnabled() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle-configs")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let virtualDisplaysURL = tempURL.appendingPathComponent("virtual-displays.json")
        let shareMappingsURL = tempURL.appendingPathComponent("display-share-id-mappings.json")
        let secretDisplayName = "Confidential Window Caption"
        let secretPath = "/Users/tester/Desktop/private-display.json"
        let secretIP = "192.168.0.4"
        let secretURL = "http://192.168.0.4:8080/display/share-id-raw-fixture-55"
        let secretShareID = "987654321"
        let shortControlToken = "short-control-secret"
        try """
        {
          "configs": [
            {
              "displayName": "\(secretDisplayName)",
              "diagnosticPath": "\(secretPath)",
              "diagnosticURL": "\(secretURL)",
              "controlToken": "\(shortControlToken)"
            }
          ]
        }
        """.write(to: virtualDisplaysURL, atomically: true, encoding: .utf8)
        try """
        {
          "schemaVersion": 1,
          "mappings": {
            "display-identity-fixture": \(secretShareID)
          },
          "lastHost": "\(secretIP)"
        }
        """.write(to: shareMappingsURL, atomically: true, encoding: .utf8)

        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: tempURL.appendingPathComponent("exports", isDirectory: true),
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
        let virtualDisplayConfig = try archiveEntryString(
            relativePathSuffix: "/attachments/config/virtual-displays.json",
            archiveURL: result.bundleURL
        )
        let shareMappings = try archiveEntryString(
            relativePathSuffix: "/attachments/config/display-share-id-mappings.json",
            archiveURL: result.bundleURL
        )

        #expect(entries.contains(where: { $0.hasSuffix("/attachments/config/virtual-displays.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/attachments/config/display-share-id-mappings.json") }))
        #expect(virtualDisplayConfig.contains(secretDisplayName) == false)
        #expect(virtualDisplayConfig.contains(secretPath) == false)
        #expect(virtualDisplayConfig.contains(secretIP) == false)
        #expect(virtualDisplayConfig.contains(secretURL) == false)
        #expect(virtualDisplayConfig.contains(shortControlToken) == false)
        #expect(virtualDisplayConfig.contains("~") == true)
        #expect(virtualDisplayConfig.contains("<redacted-ip>") == true)
        #expect(shareMappings.contains(secretShareID) == false)
        #expect(shareMappings.contains(secretIP) == false)
        #expect(shareMappings.contains("<redacted>") == true)
        #expect(shareMappings.contains("<redacted-ip>") == true)
    }

    @Test func exportBundleRedactsMalformedConfigAttachmentsWhenEnhancedDiagnosticsEnabled() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle-malformed-configs")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let virtualDisplaysURL = tempURL.appendingPathComponent("virtual-displays.json")
        let shareMappingsURL = tempURL.appendingPathComponent("display-share-id-mappings.json")
        let secretDisplayName = "Private Window Caption"
        let secretPath = "/Users/tester/Desktop/private-display.json"
        let secretIP = "192.168.0.4"
        let secretURL = "http://192.168.0.4:8080/display/share-id-raw-fixture-66"
        let secretUserText = "typed note body"
        let secretDesktopContent = "Desktop frame shows roadmap"
        let secretShareID = "123456789"
        let malformedVirtualDisplayConfig = """
        {
          "displayName": "\(secretDisplayName)",
          "diagnosticPath": "\(secretPath)",
          "diagnosticURL": "\(secretURL)",
          "lastHost": "\(secretIP)",
          "userText": "\(secretUserText)",
          "desktopContent": "\(secretDesktopContent)"
        """
        let malformedShareMappings = """
        {
          "mappings": {
            "display-identity-fixture": \(secretShareID)
          },
          "lastHost": "\(secretIP)",
        """
        try malformedVirtualDisplayConfig.write(to: virtualDisplaysURL, atomically: true, encoding: .utf8)
        try malformedShareMappings.write(to: shareMappingsURL, atomically: true, encoding: .utf8)

        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: tempURL.appendingPathComponent("exports", isDirectory: true),
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

        let virtualDisplayConfig = try archiveEntryString(
            relativePathSuffix: "/attachments/config/virtual-displays.json",
            archiveURL: result.bundleURL
        )
        let shareMappings = try archiveEntryString(
            relativePathSuffix: "/attachments/config/display-share-id-mappings.json",
            archiveURL: result.bundleURL
        )
        let virtualPlaceholder = try #require(try decodeArchiveEntry(
            JSONValue.self,
            relativePathSuffix: "/attachments/config/virtual-displays.json",
            archiveURL: result.bundleURL
        ).objectValue)
        let sharePlaceholder = try #require(try decodeArchiveEntry(
            JSONValue.self,
            relativePathSuffix: "/attachments/config/display-share-id-mappings.json",
            archiveURL: result.bundleURL
        ).objectValue)

        #expect(virtualPlaceholder["redacted"] == .bool(true))
        #expect(virtualPlaceholder["reason"] == .string("invalid_json"))
        #expect(virtualPlaceholder["sourceKind"] == .string("virtual_display_configs"))
        #expect(virtualPlaceholder["originalByteCount"]?.intValue == malformedVirtualDisplayConfig.utf8.count)
        #expect(sharePlaceholder["redacted"] == .bool(true))
        #expect(sharePlaceholder["reason"] == .string("invalid_json"))
        #expect(sharePlaceholder["sourceKind"] == .string("display_share_mappings"))
        #expect(sharePlaceholder["originalByteCount"]?.intValue == malformedShareMappings.utf8.count)

        for sensitiveFixture in [
            "displayName",
            secretDisplayName,
            secretPath,
            secretIP,
            secretURL,
            secretUserText,
            secretDesktopContent
        ] {
            #expect(virtualDisplayConfig.contains(sensitiveFixture) == false)
        }
        for sensitiveFixture in [
            #""mappings""#,
            secretShareID,
            secretIP
        ] {
            #expect(shareMappings.contains(sensitiveFixture) == false)
        }
    }

    @Test func exportBundleContinuesWhenUnifiedLogCommandTimesOut() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle-log-timeout")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var capturedCommand: (launchPath: String, arguments: [String], timeout: TimeInterval)?
        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: tempURL.appendingPathComponent("exports", isDirectory: true),
            virtualDisplayConfigsURL: tempURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: ObservabilitySanitizer(),
            commandRunner: { launchPath, arguments, timeout in
                capturedCommand = (launchPath, arguments, timeout)
                return nil
            }
        )

        let result = try exporter.exportBundle(
            draft: FeedbackDraft(happened: "Sharing failed"),
            consent: FeedbackConsent(includeUnifiedLogSummary: true),
            state: makeStateSnapshot(),
            health: makeHealthSummary(),
            events: [],
            issues: [],
            transportCapability: FeedbackTransportCapability.localExportOnly
        )

        let entries = try archiveEntries(at: result.bundleURL)
        let manifest = try decodeArchiveEntry(
            SupportBundleManifest.self,
            relativePathSuffix: "/manifest.json",
            archiveURL: result.bundleURL
        )

        #expect(capturedCommand?.launchPath == "/usr/bin/log")
        #expect(capturedCommand?.arguments.contains("--last") == true)
        #expect(capturedCommand?.timeout == 8)
        #expect(entries.contains(where: { $0.hasSuffix("/attachments/unified-log.txt") }) == false)
        #expect(manifest.attachments.isEmpty)
    }

    @Test func oversizedConfigAttachmentIsReplacedWithBoundedRedactedPlaceholder() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle-oversized-config")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let virtualDisplaysURL = tempURL.appendingPathComponent("virtual-displays.json")
        let secret = "sensitive-config-payload"
        var oversizedData = Data("{\"displayName\":\"\(secret)\",\"padding\":\"".utf8)
        oversizedData.append(Data(repeating: 0x61, count: 2 * 1_024 * 1_024))
        oversizedData.append(Data("\"}".utf8))
        try oversizedData.write(to: virtualDisplaysURL)
        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: tempURL.appendingPathComponent("exports", isDirectory: true),
            virtualDisplayConfigsURL: virtualDisplaysURL,
            displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: ObservabilitySanitizer()
        )

        let result = try exporter.exportBundle(
            draft: FeedbackDraft(happened: "Config export"),
            consent: FeedbackConsent(includeRelatedConfigSnapshots: true),
            state: makeStateSnapshot(),
            health: makeHealthSummary(),
            events: [],
            issues: [],
            transportCapability: .localExportOnly
        )
        let placeholder = try #require(try decodeArchiveEntry(
            JSONValue.self,
            relativePathSuffix: "/attachments/config/virtual-displays.json",
            archiveURL: result.bundleURL
        ).objectValue)
        let attachment = try archiveEntryString(
            relativePathSuffix: "/attachments/config/virtual-displays.json",
            archiveURL: result.bundleURL
        )

        #expect(placeholder["redacted"] == .bool(true))
        #expect(placeholder["reason"] == .string("size_limit_exceeded"))
        #expect(placeholder["originalByteCount"]?.intValue == oversizedData.count)
        #expect(attachment.contains(secret) == false)
        #expect(attachment.utf8.count < 512)
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
            virtualDisplayConfigsURL: tempURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: ObservabilitySanitizer()
        )

        #expect(exporter.latestExportedBundleURL() == newerURL)
    }

    @Test func exportBundleAppliesDefenseInDepthRedactionToEveryCoreArtifact() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle-defense-redaction")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let accessToken = String(repeating: "c", count: 64)
        let privatePath = "/Users/tester/Desktop/private.log"
        let privateIP = "192.168.40.8"
        let displayName = "Executive Presentation"
        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: tempURL.appendingPathComponent("exports", isDirectory: true),
            virtualDisplayConfigsURL: tempURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: ObservabilitySanitizer(homePath: "/Users/tester")
        )

        let state = ObservabilityStateSnapshot(
            generatedAt: Date(timeIntervalSince1970: 10),
            refreshReason: .startup,
            app: .init(
                bundleIdentifier: "com.developerchen.voiddisplay",
                version: "1.0.0",
                build: "1",
                executablePath: privatePath
            ),
            sections: [
                "runtime": .object([
                    "displayName": .string(displayName),
                    "accessCapability": .string(accessToken),
                    "address": .string("http://\(privateIP):8080/display/\(accessToken)")
                ])
            ]
        )
        let health = ObservabilityHealthSummary(
            generatedAt: Date(timeIntervalSince1970: 10),
            recentEventCount: 1,
            recentIssueCount: 1,
            highestSeverity: .error,
            subsystemIssueCounts: [.init(subsystem: .sharing, count: 1)],
            recentIssueMessages: ["Failed at \(privatePath) using \(accessToken)"]
        )
        let event = ObservabilityEvent(
            severity: .error,
            subsystem: .sharing,
            operation: "Open \(privateIP)",
            message: "Capability \(accessToken)",
            metadata: ["controlToken": accessToken, "path": privatePath]
        )
        let issue = IssueRecord(
            id: UUID(),
            deduplicationKey: "sharing|\(accessToken)",
            subsystem: .sharing,
            operation: "Open \(privateIP)",
            message: "Capability \(accessToken)",
            firstSeenAt: Date(timeIntervalSince1970: 10),
            lastSeenAt: Date(timeIntervalSince1970: 10),
            occurrenceCount: 1,
            latestMetadata: ["accessCapability": accessToken]
        )

        let result = try exporter.exportBundle(
            draft: FeedbackDraft(happened: "Failed at http://\(privateIP)/display/\(accessToken)"),
            consent: FeedbackConsent(),
            state: state,
            health: health,
            events: [event],
            issues: [issue],
            transportCapability: .localExportOnly
        )

        let coreArtifacts = try [
            "/feedback.json",
            "/state/current-state.json",
            "/state/health-summary.json",
            "/events/recent-events.ndjson",
            "/issues/recent-issues.json"
        ].map {
            try archiveEntryString(relativePathSuffix: $0, archiveURL: result.bundleURL)
        }.joined(separator: "\n")

        for sensitiveValue in [accessToken, privatePath, privateIP, displayName] {
            #expect(coreArtifacts.contains(sensitiveValue) == false)
        }
        #expect(coreArtifacts.contains("<redacted-token>") || coreArtifacts.contains("<redacted>"))
        #expect(coreArtifacts.contains("<redacted-ip>"))
        #expect(coreArtifacts.contains("~/Desktop/private.log"))
    }

    @Test func exportBundleRollsBackStagingAndPartialArchiveWhenArchiveCreationFails() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle-rollback")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: exportsURL,
            virtualDisplayConfigsURL: tempURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: ObservabilitySanitizer(),
            dateProvider: { Date(timeIntervalSince1970: 10) },
            reportIDProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! },
            archiveWriter: { _, destinationURL in
                try Data("partial".utf8).write(to: destinationURL)
                throw CocoaError(.fileWriteUnknown)
            }
        )

        do {
            _ = try exporter.exportBundle(
                draft: FeedbackDraft(happened: "Export fails"),
                consent: FeedbackConsent(),
                state: makeStateSnapshot(),
                health: makeHealthSummary(),
                events: [],
                issues: [],
                transportCapability: .localExportOnly
            )
            Issue.record("Expected archive creation to fail")
        } catch {}

        let remainingEntries = try FileManager.default.contentsOfDirectory(
            at: exportsURL,
            includingPropertiesForKeys: nil
        )
        #expect(remainingEntries.isEmpty)
    }

    @Test func repeatedExportsWithinOneSecondUseUniquePrivateArchives() throws {
        let tempURL = try makeTemporaryDirectory(prefix: "support-bundle-unique")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let reportIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ]
        var reportIndex = 0
        let exporter = FeedbackBundleExporter(
            exportsDirectoryURL: tempURL.appendingPathComponent("exports", isDirectory: true),
            virtualDisplayConfigsURL: tempURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: ObservabilitySanitizer(),
            dateProvider: { Date(timeIntervalSince1970: 10) },
            reportIDProvider: {
                defer { reportIndex += 1 }
                return reportIDs[reportIndex]
            }
        )

        let first = try exporter.exportBundle(
            draft: FeedbackDraft(happened: "First"),
            consent: FeedbackConsent(),
            state: makeStateSnapshot(),
            health: makeHealthSummary(),
            events: [],
            issues: [],
            transportCapability: .localExportOnly
        )
        let second = try exporter.exportBundle(
            draft: FeedbackDraft(happened: "Second"),
            consent: FeedbackConsent(),
            state: makeStateSnapshot(),
            health: makeHealthSummary(),
            events: [],
            issues: [],
            transportCapability: .localExportOnly
        )

        #expect(first.bundleURL != second.bundleURL)
        #expect(FileManager.default.fileExists(atPath: first.bundleURL.path))
        #expect(FileManager.default.fileExists(atPath: second.bundleURL.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: second.bundleURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
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
        sections: [
            "capture": .object(["sessions": .array([])]),
            "runtime": .object([
                "schemaVersion": .number(3),
                "surfaces": .array([])
            ])
        ]
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
    let data = try archiveEntryData(relativePathSuffix: relativePathSuffix, archiveURL: archiveURL)
    return try ObservabilityCodec.decode(type, from: data)
}

private func archiveEntryString(
    relativePathSuffix: String,
    archiveURL: URL
) throws -> String {
    String(decoding: try archiveEntryData(relativePathSuffix: relativePathSuffix, archiveURL: archiveURL), as: UTF8.self)
}

private func archiveEntryData(
    relativePathSuffix: String,
    archiveURL: URL
) throws -> Data {
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
    return try Data(contentsOf: try #require(entryURL))
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
