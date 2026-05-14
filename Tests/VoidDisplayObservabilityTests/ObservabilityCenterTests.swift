@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
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
            transport: LocalExportTransport(),
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
            transport: LocalExportTransport(),
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
            transport: LocalExportTransport(),
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
