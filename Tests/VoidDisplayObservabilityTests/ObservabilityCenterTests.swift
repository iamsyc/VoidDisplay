@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct ObservabilityCenterTests {
    @Test func exportBundleSanitizesRuntimeSectionAndIncludesSystemAndPersistenceSnapshots() async throws {
        let isolationID = "observability-center-\(UUID().uuidString)"
        let environment = [
            PersistenceContext.persistenceModeEnvironmentKey: PersistenceContext.testIsolatedModeValue,
            PersistenceContext.testIsolationIDEnvironmentKey: isolationID,
            PersistenceContext.xCTestConfigurationEnvironmentKey: "tests.xctest"
        ]
        let persistenceContext = PersistenceContext.resolve(environment: environment)
        defer { try? FileManager.default.removeItem(at: persistenceContext.appSupportRootURL) }

        let sanitizer = ObservabilitySanitizer()
        let observability = ObservabilityCenter(
            eventStore: EventStore(directoryURL: persistenceContext.observabilityEventsDirectoryURL),
            issueStore: IssueStore(fileURL: persistenceContext.observabilityIssuesURL),
            snapshotWriter: AgentSnapshotWriter(
                currentStateURL: persistenceContext.observabilityCurrentStateURL,
                healthSummaryURL: persistenceContext.observabilityHealthSummaryURL,
                recentEventsURL: persistenceContext.observabilityRecentEventsURL,
                debounceDuration: .zero
            ),
            exporter: FeedbackBundleExporter(
                exportsDirectoryURL: persistenceContext.observabilityExportsDirectoryURL,
                virtualDisplayConfigsURL: persistenceContext.virtualDisplayConfigsURL,
                displayShareMappingsURL: persistenceContext.displayShareIDMappingsURL,
                sanitizer: sanitizer
            ),
            observabilityDirectoryURL: persistenceContext.observabilityDirectoryURL,
            sanitizer: sanitizer
        )

        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(
                StaticSnapshotProvider(
                    key: "runtime",
                    snapshot: RedactionSnapshot(
                        path: "\(NSHomeDirectory())/Library/Application Support/VoidDisplay/current-state.json",
                        url: "http://192.168.1.11:8080/display",
                        message: "See \(NSHomeDirectory())/Desktop/trace.log and connect to 10.0.0.8."
                    )
                )
            )
        )
        let systemSnapshot = SystemSnapshotProvider(
            environment: environment,
            localeProvider: { Locale(identifier: "en_US") },
            timeZoneProvider: { TimeZone(identifier: "Asia/Shanghai") ?? .current }
        ).makeSnapshot()
        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(
                StaticSnapshotProvider(key: "system", snapshot: systemSnapshot)
            )
        )
        let persistenceSnapshot = PersistenceSnapshotProvider(context: persistenceContext).makeSnapshot()
        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(
                StaticSnapshotProvider(key: "persistence", snapshot: persistenceSnapshot)
            )
        )

        let bundleURL = try await observability.exportBundle(
            draft: FeedbackDraft(happened: "Black screen"),
            consent: FeedbackConsent()
        )
        let state = try decodeArchiveEntry(
            ObservabilityStateSnapshot.self,
            relativePathSuffix: "/state/current-state.json",
            archiveURL: bundleURL
        )

        #expect(state.sections["capture"] == nil)
        #expect(state.sections["sharing"] == nil)
        #expect(state.sections["virtualDisplay"] == nil)
        #expect(state.sections["screenCatalog"] == nil)

        let runtimeSection = try #require(state.sections["runtime"])
        let runtime = try runtimeSection.decode(RedactionSnapshot.self)
        #expect(runtime.path.hasPrefix("~"))
        #expect(runtime.url == "http://<redacted-ip>:8080/display")
        #expect(runtime.message.contains("~"))
        #expect(runtime.message.contains("<redacted-ip>"))
        #expect(runtime.message.contains(NSHomeDirectory()) == false)
        #expect(runtime.message.contains("10.0.0.8") == false)

        let systemSection = try #require(state.sections["system"])
        let system = try systemSection.decode(SystemSnapshotProvider.Snapshot.self)
        #expect(system.localeIdentifier == "en_US")
        #expect(system.timeZoneIdentifier == "Asia/Shanghai")
        #expect(system.isRunningUnderXCTest)
        #expect(system.isUITestRuntimeEnabled == UITestRuntime.isEnabled)
        #expect(system.operatingSystemVersion.isEmpty == false)

        let persistenceSection = try #require(state.sections["persistence"])
        let persistence = try persistenceSection.decode(PersistenceSnapshotProvider.Snapshot.self)
        #expect(persistence.mode == "test_isolated")
        #expect(persistence.bundleIdentifier.hasPrefix("com.developerchen.voiddisplay.tests."))
        #expect(persistence.bundleIdentifier.contains(String(isolationID.prefix(48))))
        #expect(persistence.appSupportRootPath.hasPrefix("~"))
        #expect(persistence.currentStatePath.hasPrefix("~"))
        #expect(persistence.exportsDirectoryPath.hasPrefix("~"))
    }

    @Test func exportBundlePersistsRecentEventsFileAndExposesDataDirectory() async throws {
        let isolationID = "observability-events-\(UUID().uuidString)"
        let environment = [
            PersistenceContext.persistenceModeEnvironmentKey: PersistenceContext.testIsolatedModeValue,
            PersistenceContext.testIsolationIDEnvironmentKey: isolationID,
            PersistenceContext.xCTestConfigurationEnvironmentKey: "tests.xctest"
        ]
        let persistenceContext = PersistenceContext.resolve(environment: environment)
        defer { try? FileManager.default.removeItem(at: persistenceContext.appSupportRootURL) }

        let sanitizer = ObservabilitySanitizer()
        let observability = ObservabilityCenter(
            eventStore: EventStore(directoryURL: persistenceContext.observabilityEventsDirectoryURL),
            issueStore: IssueStore(fileURL: persistenceContext.observabilityIssuesURL),
            snapshotWriter: AgentSnapshotWriter(
                currentStateURL: persistenceContext.observabilityCurrentStateURL,
                healthSummaryURL: persistenceContext.observabilityHealthSummaryURL,
                recentEventsURL: persistenceContext.observabilityRecentEventsURL,
                debounceDuration: .zero
            ),
            exporter: FeedbackBundleExporter(
                exportsDirectoryURL: persistenceContext.observabilityExportsDirectoryURL,
                virtualDisplayConfigsURL: persistenceContext.virtualDisplayConfigsURL,
                displayShareMappingsURL: persistenceContext.displayShareIDMappingsURL,
                sanitizer: sanitizer
            ),
            observabilityDirectoryURL: persistenceContext.observabilityDirectoryURL,
            sanitizer: sanitizer
        )

        await observability.record(
            ObservabilityEvent(
                severity: .error,
                subsystem: .observability,
                operation: "Load diagnostics",
                message: "Recent events file should be available.",
                metadata: ["directory": persistenceContext.observabilityDirectoryURL.path]
            )
        )

        _ = try await observability.exportBundle(
            draft: FeedbackDraft(happened: "Diagnostics failed to load"),
            consent: FeedbackConsent()
        )

        let recentEventsContent = try String(
            contentsOf: persistenceContext.observabilityRecentEventsURL,
            encoding: .utf8
        )
        #expect(recentEventsContent.contains("Load diagnostics"))

        let issuesData = try Data(contentsOf: persistenceContext.observabilityIssuesURL)
        let issues = try ObservabilityCodec.decode([IssueRecord].self, from: issuesData)
        #expect(issues.count == 1)
        #expect(issues.first?.message == "Recent events file should be available.")

        let dataDirectoryURL = await observability.dataDirectoryURL()
        #expect(dataDirectoryURL == persistenceContext.observabilityDirectoryURL)

        let dataDirectoryDisplayPath = await observability.dataDirectoryDisplayPath()
        #expect(dataDirectoryDisplayPath?.hasPrefix("~") == true)
    }

    @Test func summaryTextIncludesIssueTypeAndBundleFileName() async throws {
        let isolationID = "observability-summary-\(UUID().uuidString)"
        let environment = [
            PersistenceContext.persistenceModeEnvironmentKey: PersistenceContext.testIsolatedModeValue,
            PersistenceContext.testIsolationIDEnvironmentKey: isolationID,
            PersistenceContext.xCTestConfigurationEnvironmentKey: "tests.xctest"
        ]
        let persistenceContext = PersistenceContext.resolve(environment: environment)
        defer { try? FileManager.default.removeItem(at: persistenceContext.appSupportRootURL) }

        let sanitizer = ObservabilitySanitizer()
        let observability = ObservabilityCenter(
            eventStore: EventStore(directoryURL: persistenceContext.observabilityEventsDirectoryURL),
            issueStore: IssueStore(fileURL: persistenceContext.observabilityIssuesURL),
            snapshotWriter: AgentSnapshotWriter(
                currentStateURL: persistenceContext.observabilityCurrentStateURL,
                healthSummaryURL: persistenceContext.observabilityHealthSummaryURL,
                recentEventsURL: persistenceContext.observabilityRecentEventsURL,
                debounceDuration: .zero
            ),
            exporter: FeedbackBundleExporter(
                exportsDirectoryURL: persistenceContext.observabilityExportsDirectoryURL,
                virtualDisplayConfigsURL: persistenceContext.virtualDisplayConfigsURL,
                displayShareMappingsURL: persistenceContext.displayShareIDMappingsURL,
                sanitizer: sanitizer
            ),
            observabilityDirectoryURL: persistenceContext.observabilityDirectoryURL,
            sanitizer: sanitizer
        )

        _ = try await observability.exportBundle(
            draft: FeedbackDraft(
                issueType: .blackScreen,
                happened: "Black screen after launch"
            ),
            consent: FeedbackConsent()
        )

        let summary = await observability.summaryText(
            for: FeedbackDraft(
                issueType: .blackScreen,
                happened: "Black screen after launch"
            ),
            issueTypeLine: String(localized: "Issue Type: Black Screen")
        )

        #expect(
            summary.contains(
                String(localized: "Issue Type: Black Screen")
            )
        )
        #expect(
            summary.contains("\(String(localized: "Support Package")): support-bundle-")
        )
        #expect(summary.contains(persistenceContext.observabilityExportsDirectoryURL.path) == false)
    }

    @Test func exportBundleRecoversFromPersistedEventReadAndAgentSnapshotWriteFailures() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "observability-export-recovery")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let eventsURL = tempURL.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: eventsURL.appendingPathComponent("events-20260718.ndjson", isDirectory: true),
            withIntermediateDirectories: true
        )
        let blockedSnapshotParent = tempURL.appendingPathComponent("blocked-snapshot-parent")
        try Data("file-blocks-directory".utf8).write(to: blockedSnapshotParent)
        let sanitizer = ObservabilitySanitizer(homePath: tempURL.deletingLastPathComponent().path)
        let exportsURL = tempURL.appendingPathComponent("exports", isDirectory: true)
        let observability = ObservabilityCenter(
            eventStore: EventStore(directoryURL: eventsURL),
            issueStore: IssueStore(fileURL: tempURL.appendingPathComponent("issues.json")),
            snapshotWriter: AgentSnapshotWriter(
                currentStateURL: blockedSnapshotParent.appendingPathComponent("current-state.json"),
                healthSummaryURL: blockedSnapshotParent.appendingPathComponent("health-summary.json"),
                recentEventsURL: blockedSnapshotParent.appendingPathComponent("recent-events.ndjson"),
                debounceDuration: .zero
            ),
            exporter: FeedbackBundleExporter(
                exportsDirectoryURL: exportsURL,
                virtualDisplayConfigsURL: tempURL.appendingPathComponent("virtual-displays.json"),
                displayShareMappingsURL: tempURL.appendingPathComponent("display-share-id-mappings.json"),
                sanitizer: sanitizer
            ),
            observabilityDirectoryURL: tempURL,
            sanitizer: sanitizer
        )

        let bundleURL = try await observability.exportBundle(
            draft: FeedbackDraft(happened: "Export should continue"),
            consent: FeedbackConsent()
        )

        #expect(FileManager.default.fileExists(atPath: bundleURL.path))
        #expect(await observability.exportedBundleURL() == bundleURL)
        let manifest = try decodeArchiveEntry(
            SupportBundleManifest.self,
            relativePathSuffix: "/manifest.json",
            archiveURL: bundleURL
        )
        #expect(manifest.eventCount == 0)
    }

    @Test func healthIgnoresSupportEventsButIncludesRuntimeWarnings() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "observability-health-domains")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 4_000_000)
        let observability = makeObservabilityCenter(rootURL: tempURL, now: now)

        await observability.record(
            ObservabilityEvent(
                timestamp: now.addingTimeInterval(-60),
                severity: .warning,
                subsystem: .support,
                operation: "Support workflow validation_failed",
                message: "Support export validation failed."
            )
        )
        var snapshot = await observability.diagnosticsSnapshot()
        #expect(snapshot.health.recentEventCount == 0)
        #expect(snapshot.health.highestSeverity == nil)
        #expect(snapshot.events.count == 1)

        await observability.record(
            ObservabilityEvent(
                timestamp: now,
                severity: .warning,
                subsystem: .capture,
                operation: "Capture display",
                message: "Capture is delayed."
            )
        )
        snapshot = await observability.diagnosticsSnapshot()
        #expect(snapshot.health.recentEventCount == 1)
        #expect(snapshot.health.highestSeverity == .warning)
        #expect(snapshot.events.count == 2)
    }

    @Test func oldRuntimeFailureLeavesHealthWindowButRemainsInSupportBundle() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "observability-health-window")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 5_000_000)
        let observability = makeObservabilityCenter(rootURL: tempURL, now: now)
        await observability.record(
            ObservabilityEvent(
                timestamp: now.addingTimeInterval(-2 * 24 * 60 * 60),
                severity: .error,
                subsystem: .displayRuntime,
                operation: "Restore display",
                message: "Display restoration failed.",
                deduplicationKey: "restore-display"
            )
        )

        let snapshot = await observability.diagnosticsSnapshot()
        #expect(snapshot.health.recentIssueCount == 0)
        #expect(snapshot.health.highestSeverity == nil)
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.events.isEmpty)

        let bundleURL = try await observability.exportBundle(
            draft: FeedbackDraft(happened: "Display did not restore"),
            consent: FeedbackConsent()
        )
        let manifest = try decodeArchiveEntry(
            SupportBundleManifest.self,
            relativePathSuffix: "/manifest.json",
            archiveURL: bundleURL
        )
        let issues = try decodeArchiveEntry(
            [IssueRecord].self,
            relativePathSuffix: "/issues/recent-issues.json",
            archiveURL: bundleURL
        )

        #expect(manifest.eventCount == 1)
        #expect(manifest.issueCount == 1)
        #expect(issues.map(\.deduplicationKey) == ["restore-display"])
    }

    @Test func supportBundleExcludesEventsOlderThanRetentionWindowByTimestamp() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "observability-export-retention")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date.now
        let eventStore = makeEventStore(rootURL: tempURL, now: now)
        try await eventStore.append(
            ObservabilityEvent(
                timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
                severity: .error,
                subsystem: .displayRuntime,
                operation: "Restore display",
                message: "Expired evidence must not be exported.",
                deduplicationKey: "expired-export-evidence"
            )
        )
        let observability = makeObservabilityCenter(
            rootURL: tempURL,
            now: now,
            eventStore: eventStore
        )

        let bundleURL = try await observability.exportBundle(
            draft: FeedbackDraft(happened: "Display did not restore"),
            consent: FeedbackConsent()
        )
        let manifest = try decodeArchiveEntry(
            SupportBundleManifest.self,
            relativePathSuffix: "/manifest.json",
            archiveURL: bundleURL
        )

        #expect(manifest.eventCount == 0)
    }

    @Test func supportEventFloodDoesNotDisplaceRuntimeHealthEvidence() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "observability-health-support-flood")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 6_000_000)
        let eventStore = makeEventStore(rootURL: tempURL, now: now)
        try await eventStore.append(
            ObservabilityEvent(
                timestamp: now.addingTimeInterval(-60),
                severity: .warning,
                subsystem: .capture,
                operation: "Capture display",
                message: "Capture is delayed."
            )
        )
        for index in 0..<250 {
            try await eventStore.append(
                ObservabilityEvent(
                    timestamp: now.addingTimeInterval(Double(index - 250)),
                    severity: .info,
                    subsystem: .support,
                    operation: "Support workflow \(index)",
                    message: "Recorded support workflow event."
                )
            )
        }

        let observability = makeObservabilityCenter(
            rootURL: tempURL,
            now: now,
            eventStore: eventStore
        )
        await observability.refreshSnapshot(reason: .manualDiagnosticsRefresh)
        let snapshot = await observability.diagnosticsSnapshot()

        #expect(snapshot.health.recentEventCount == 1)
        #expect(snapshot.health.highestSeverity == .warning)
    }

    @Test func runtimeInfoFloodDoesNotDisplaceEarlierRuntimeWarning() async throws {
        let tempURL = try makeTemporaryDirectory(prefix: "observability-health-runtime-flood")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let now = Date(timeIntervalSince1970: 7_000_000)
        let eventStore = makeEventStore(rootURL: tempURL, now: now)
        try await eventStore.append(
            ObservabilityEvent(
                timestamp: now.addingTimeInterval(-300),
                severity: .warning,
                subsystem: .capture,
                operation: "Capture display",
                message: "Capture is delayed."
            )
        )
        for index in 0..<250 {
            try await eventStore.append(
                ObservabilityEvent(
                    timestamp: now.addingTimeInterval(Double(index - 250)),
                    severity: .info,
                    subsystem: .sharing,
                    operation: "Sharing heartbeat \(index)",
                    message: "Sharing remains available."
                )
            )
        }

        let observability = makeObservabilityCenter(
            rootURL: tempURL,
            now: now,
            eventStore: eventStore
        )
        await observability.refreshSnapshot(reason: .manualDiagnosticsRefresh)
        let snapshot = await observability.diagnosticsSnapshot()

        #expect(snapshot.health.recentEventCount == 251)
        #expect(snapshot.health.highestSeverity == .warning)
    }
}

private struct StaticSnapshotProvider<Snapshot: Codable & Sendable>: ObservabilitySnapshotProvider, Sendable {
    let key: String
    let snapshot: Snapshot

    @MainActor
    func makeSnapshot() -> Snapshot {
        snapshot
    }
}

private struct RedactionSnapshot: Codable, Equatable, Sendable {
    let path: String
    let url: String
    let message: String
}

private func makeObservabilityCenter(
    rootURL: URL,
    now: Date,
    eventStore: EventStore? = nil
) -> ObservabilityCenter {
    let sanitizer = ObservabilitySanitizer(homePath: rootURL.deletingLastPathComponent().path)
    return ObservabilityCenter(
        eventStore: eventStore ?? EventStore(
            directoryURL: rootURL.appendingPathComponent("events", isDirectory: true),
            dateProvider: { now }
        ),
        issueStore: IssueStore(
            fileURL: rootURL.appendingPathComponent("issues.json"),
            dateProvider: { now }
        ),
        snapshotWriter: AgentSnapshotWriter(
            currentStateURL: rootURL.appendingPathComponent("current-state.json"),
            healthSummaryURL: rootURL.appendingPathComponent("health-summary.json"),
            recentEventsURL: rootURL.appendingPathComponent("recent-events.ndjson"),
            debounceDuration: .zero
        ),
        exporter: FeedbackBundleExporter(
            exportsDirectoryURL: rootURL.appendingPathComponent("exports", isDirectory: true),
            virtualDisplayConfigsURL: rootURL.appendingPathComponent("virtual-displays.json"),
            displayShareMappingsURL: rootURL.appendingPathComponent("display-share-id-mappings.json"),
            sanitizer: sanitizer
        ),
        observabilityDirectoryURL: rootURL,
        sanitizer: sanitizer,
        dateProvider: { now }
    )
}

private func makeEventStore(rootURL: URL, now: Date) -> EventStore {
    EventStore(
        directoryURL: rootURL.appendingPathComponent("events", isDirectory: true),
        deduplicationWindow: 0,
        dateProvider: { now }
    )
}

private func decodeArchiveEntry<T: Decodable>(
    _ type: T.Type,
    relativePathSuffix: String,
    archiveURL: URL
) throws -> T {
    let extractionURL = try makeTemporaryDirectory(prefix: "observability-center-extract")
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
